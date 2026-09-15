#!/bin/bash
# Verify the backup repository by re-reading and checksumming a sample of the
# actual data.
#
#   ./scripts/check-backup.sh
#   RESTIC_CHECK_SUBSET=25% ./scripts/check-backup.sh
#
# Run by imap-archive-check.timer, weekly.
#
# This exists because `restic check` on its own only validates metadata and
# structure - it will happily pass on a repository whose data blobs are
# unreadable. --read-data-subset is what proves the bytes come back.
set -euo pipefail

source "$(dirname "$0")/restic-env.sh"
_restic_load_env

SUBSET="${RESTIC_CHECK_SUBSET:-5%}"

echo "Checking repository structure..."
restic_run check

echo
echo "Re-reading ${SUBSET} of repository data and verifying checksums..."
echo "(this downloads that share of the repository - expect egress)"
restic_run check --read-data-subset="${SUBSET}"

echo
echo "Repository verified."
STATS="$(restic_run stats --mode raw-data 2>/dev/null | tail -n +2)"
echo "$STATS"

# Weekly heartbeat. Failures alert on their own via OnFailure=, but a silent
# channel is ambiguous: it means either "all well" or "the timer has not run
# since June". One message a week tells the two apart.
if [[ "${DISCORD_HEARTBEAT:-true}" == "true" ]]; then
  SNAPS="$(restic_run snapshots --tag imap-archive --latest 1 2>/dev/null | tail -4)"
  ./scripts/notify-discord.sh --success "imap-archive-check.service" \
    "Verified ${SUBSET} of repository data, no errors.

${SNAPS}

${STATS}" || true
fi
