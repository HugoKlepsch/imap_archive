#!/bin/bash
# Generate Dovecot's passwd-file from .env.bash.
#
# Dovecot never sees ARCHIVE_PASSWORD; it reads only the ARGON2ID hash written
# here. Re-run this after changing ARCHIVE_USER or ARCHIVE_PASSWORD, then
# restart Dovecot (see docs/maintenance.md).
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE=".env.bash"
[[ -f "$ENV_FILE" ]] || { echo "Error: $ENV_FILE not found. Copy .env.bash.template." >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a

: "${ARCHIVE_USER:?not set in .env.bash}"
: "${ARCHIVE_PASSWORD:?not set in .env.bash}"
: "${DOVECOT_VERSION:?not set in .env.bash}"

if [[ "$ARCHIVE_PASSWORD" == "CHANGEME" ]]; then
  echo "Error: ARCHIVE_PASSWORD is still CHANGEME. Set a real one." >&2
  exit 1
fi

OUT_DIR="$(pwd)/generated_config/dovecot"
mkdir -p "$OUT_DIR"

# Hash using the same Dovecot version that will verify it.
echo "Hashing password with ARGON2ID..."
HASH="$(docker run --rm -i "dovecot/dovecot:${DOVECOT_VERSION}" \
          doveadm pw -s ARGON2ID -p "$ARCHIVE_PASSWORD")"

# passwd-file format: user:password:uid:gid:gecos:home:shell:extra
# The empty fields fall back to mail_uid / mail_gid / mail_home from
# config/dovecot/conf.d/10-archive.conf.
umask 077
printf '%s:%s::::::\n' "$ARCHIVE_USER" "$HASH" > "$OUT_DIR/users"
chmod 640 "$OUT_DIR/users"

echo "Wrote $OUT_DIR/users for user '${ARCHIVE_USER}'."
echo "Restart Dovecot to pick it up:  sudo systemctl restart imap-archive"
