#!/bin/bash
# Restore from the backup repository.
#
#   ./scripts/restore.sh                      # test restore to a scratch dir
#   ./scripts/restore.sh --target /some/dir   # restore somewhere specific
#   ./scripts/restore.sh --snapshot <id>      # a particular snapshot
#   ./scripts/restore.sh --in-place           # DISASTER RECOVERY - see below
#
# The default is a TEST restore into a scratch directory, because that is the
# operation you should be running regularly and an untested backup is a guess.
# Overwriting live data requires --in-place and a typed confirmation.
set -euo pipefail

source "$(dirname "$0")/restic-env.sh"
_restic_load_env

SNAPSHOT="latest"
TARGET=""
IN_PLACE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --target)   TARGET="$2"; shift 2 ;;
    --in-place) IN_PLACE=true; shift ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

echo "Available snapshots:"
restic_run snapshots --tag imap-archive
echo

if [[ "$IN_PLACE" == "true" ]]; then
  # Snapshots store absolute paths, so restoring to / puts vmail and control
  # back exactly where they came from - overwriting whatever is there now.
  cat <<MSG

################################################################
#  IN-PLACE RESTORE                                            #
#                                                              #
#  This overwrites the live archive at:                        #
#    ${vmail_dir}
#    ${control_dir}
#                                                              #
#  Stop Dovecot and the sync timer first:                      #
#    sudo systemctl stop imap-archive imap-archive-sync.timer  #
#                                                              #
#  Snapshot to restore: ${SNAPSHOT}
################################################################

MSG
  read -r -p "Type RESTORE to proceed: " confirm
  [[ "$confirm" == "RESTORE" ]] || { echo "Aborted."; exit 1; }

  if docker ps --format '{{.Names}}' | grep -qx imap_archive_dovecot; then
    echo "Error: Dovecot is still running. Stop it first." >&2
    exit 1
  fi

  echo "Restoring ${SNAPSHOT} in place..."
  restic_run_rw \
    -v "${vmail_dir}:${vmail_dir}" \
    -v "${control_dir}:${control_dir}" \
    "restic/restic:${RESTIC_VERSION}" \
    restore "${SNAPSHOT}" --target / --verbose

  cat <<MSG

Restore complete. Now:
  1. Fix ownership (restic preserves numeric ids, which may not match):
       sudo chown -R 1000:1000 "${vmail_dir}" "${control_dir}"
  2. Start Dovecot:
       sudo systemctl start imap-archive
  3. Rebuild the indexes, which are deliberately not backed up:
       docker exec imap_archive_dovecot doveadm index -u ${ARCHIVE_USER} '*'
  4. Confirm .mbsyncstate came back BEFORE re-enabling the sync timer:
       ls -la "${vmail_dir}/${ARCHIVE_USER}/mail/${ARCHIVE_FOLDER}/.mbsyncstate"
MSG
  exit 0
fi

# --- test restore ---
if [[ -z "$TARGET" ]]; then
  TARGET="$(mktemp -d /tmp/imap-archive-restore-XXXXXX)"
  SCRATCH=true
else
  SCRATCH=false
  mkdir -p "$TARGET"
fi

echo "Restoring snapshot ${SNAPSHOT} to ${TARGET} ..."
restic_run_rw -v "${TARGET}:${TARGET}" \
  "restic/restic:${RESTIC_VERSION}" \
  restore "${SNAPSHOT}" --target "${TARGET}" --verbose

echo
echo "=== Verification ==="
live_count=$(find "${vmail_dir}" -type f -path '*/cur/*' 2>/dev/null | wc -l || true)
rest_count=$(find "${TARGET}" -type f -path '*/cur/*' 2>/dev/null | wc -l || true)
echo "  live archive : ${live_count} messages"
echo "  restored     : ${rest_count} messages"
if [[ "$live_count" == "$rest_count" ]]; then
  echo "  counts MATCH"
else
  echo "  counts DIFFER (expected if mail arrived since the snapshot)"
fi

# Matching counts prove the files exist, not that they contain mail. Read one.
sample=$(find "${TARGET}" -type f -path '*/cur/*' 2>/dev/null | head -1)
if [[ -n "$sample" ]]; then
  echo
  echo "  Sample restored message:"
  grep -m3 -E '^(From|Subject|Date):' "$sample" | sed 's/^/    /' \
    || echo "    WARNING: no mail headers found - restored data may be corrupt"
fi

state=$(find "${TARGET}" -name '.mbsyncstate' 2>/dev/null | head -1)
echo
if [[ -n "$state" ]]; then
  echo "  .mbsyncstate present: $(head -3 "$state" | tr '\n' ' ')"
else
  echo "  WARNING: no .mbsyncstate in this snapshot. Restoring from it would"
  echo "           make the next sync re-pull everything as duplicates."
fi

if [[ "$SCRATCH" == "true" ]]; then
  echo
  echo "Scratch restore left at: ${TARGET}"
  echo "Remove it when done:  rm -rf ${TARGET}"
fi
