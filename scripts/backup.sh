#!/bin/bash
# Back the archive up to S3-compatible object storage, encrypted, then apply
# the retention policy.
#
#   ./scripts/backup.sh
#
# Run by imap-archive-backup.timer. Safe to run by hand and safe to interrupt.
set -euo pipefail

source "$(dirname "$0")/restic-env.sh"
_restic_load_env

: "${nas_mount_dir:?not set in .env.bash}"

# Never back up an unmounted share. Doing so would record an empty or partial
# snapshot, and after enough days the retention policy would age out the last
# good one - turning a mount failure into real data loss.
if ! mountpoint -q "${nas_mount_dir}"; then
  echo "Error: ${nas_mount_dir} is not mounted. Refusing to back up." >&2
  exit 1
fi

ensure_repo

echo "Backing up:"
echo "  ${vmail_dir}     (the mail, and .mbsyncstate)"
echo "  ${control_dir}   (dovecot-uidlist)"
echo

# Excluded:
#   */tmp/*  - Maildir's staging area for partially written messages. Those are
#              not yet real mail and are routinely half-written.
# NOT excluded, deliberately:
#   .mbsyncstate - lives inside the archive folder. Restoring mail without it
#                  makes the next sync re-pull everything as duplicates.
#   Indexes and the FTS database are simply not in the paths above; they are
#   rebuildable with `doveadm index`.
restic_run backup \
  "${vmail_dir}" "${control_dir}" \
  --tag imap-archive \
  --exclude '*/tmp/*' \
  --verbose

echo
echo "Applying retention policy..."
# --prune actually reclaims space; without it forget only drops the snapshot
# references and the data stays.
restic_run forget \
  --tag imap-archive \
  --keep-daily   "${RESTIC_KEEP_DAILY:-7}" \
  --keep-weekly  "${RESTIC_KEEP_WEEKLY:-5}" \
  --keep-monthly "${RESTIC_KEEP_MONTHLY:-12}" \
  --keep-yearly  "${RESTIC_KEEP_YEARLY:-75}" \
  --prune

echo
echo "Structural check..."
# Metadata only - fast, runs every time. The expensive check that re-reads
# actual data is scripts/check-backup.sh, on its own weekly timer.
restic_run check

echo
restic_run snapshots --tag imap-archive --latest 3
echo "Backup complete."
