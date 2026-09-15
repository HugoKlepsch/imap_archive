#!/bin/bash
# Verify the archive against Gmail. Read-only on both sides.
#
#   ./scripts/verify-archive.sh                    # counts + 50-message sample
#   SAMPLE_SIZE=500 ./scripts/verify-archive.sh    # bigger sample
#   FULL=true ./scripts/verify-archive.sh          # + every Gmail Message-ID
#
# Run FULL=true with a large SAMPLE_SIZE at least once, and read the result,
# before deleting anything from Gmail.
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE=".env.bash"
[[ -f "$ENV_FILE" ]] || { echo "Error: $ENV_FILE not found." >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a

: "${GMAIL_ADDRESS:?not set}"; : "${vmail_dir:?not set}"
: "${ARCHIVE_USER:?not set}"; : "${ARCHIVE_FOLDER:?not set}"

if [[ -z "${GMAIL_APP_PASSWORD:-}" ]]; then
  echo "Error: GMAIL_APP_PASSWORD is empty in .env.bash." >&2
  exit 1
fi

ARCHIVE_PATH="${vmail_dir}/$(echo "$ARCHIVE_USER" | tr '[:upper:]' '[:lower:]')/mail/${ARCHIVE_FOLDER}"
[[ -d "$ARCHIVE_PATH" ]] || { echo "Error: no archive folder at $ARCHIVE_PATH" >&2; exit 1; }

# Cross-check what Dovecot serves against what is on disk. A file that exists
# but is not served (bad filename, wrong permissions) would otherwise pass a
# disk-only count.
if docker ps --format '{{.Names}}' | grep -qx imap_archive_dovecot; then
  served="$(docker exec imap_archive_dovecot \
      doveadm mailbox status -u "${ARCHIVE_USER}" messages "${ARCHIVE_FOLDER}" 2>/dev/null \
      | sed -n 's/.*messages=\([0-9]*\).*/\1/p')"
  ondisk="$(find "${ARCHIVE_PATH}/cur" "${ARCHIVE_PATH}/new" -type f 2>/dev/null | wc -l)"
  echo "Dovecot serves: ${served:-unknown}   files on disk: ${ondisk}"
  if [[ -n "$served" && "$served" != "$ondisk" ]]; then
    echo "WARNING: Dovecot serves a different count than exists on disk." >&2
    echo "         Run: doveadm force-resync -u ${ARCHIVE_USER} ${ARCHIVE_FOLDER}" >&2
  fi
  echo
else
  echo "Note: Dovecot is not running; skipping the served-count cross-check."
  echo
fi

# Runs in a container so the server needs no particular Python installed, and
# so this behaves identically everywhere. Stdlib only - no pip, no network
# beyond Gmail itself. The archive is mounted read-only.
exec docker run --rm -i \
  -v "$(pwd)/scripts/verify-archive.py:/verify.py:ro" \
  -v "${ARCHIVE_PATH}:/archive:ro" \
  -e "GMAIL_ADDRESS=${GMAIL_ADDRESS}" \
  -e "GMAIL_APP_PASSWORD=${GMAIL_APP_PASSWORD}" \
  -e "GMAIL_SOURCE_FOLDER=${GMAIL_SOURCE_FOLDER:-[Gmail]/All Mail}" \
  -e "ARCHIVE_PATH=/archive" \
  -e "SAMPLE_SIZE=${SAMPLE_SIZE:-50}" \
  -e "FULL=${FULL:-false}" \
  -e "GMAIL_IMAP_HOST=${GMAIL_IMAP_HOST:-imap.gmail.com}" \
  -e "GMAIL_IMAP_PORT=${GMAIL_IMAP_PORT:-993}" \
  "python:${PYTHON_VERSION:-3.13-alpine}" python3 /verify.py
