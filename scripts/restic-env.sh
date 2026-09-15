#!/bin/bash
# Shared restic plumbing, sourced by backup.sh / restore.sh / check-backup.sh.
# Not executable on its own.
#
# restic runs in a container so the server needs nothing installed and the
# version is pinned like every other component here.

_restic_load_env() {
  cd "$(dirname "${BASH_SOURCE[1]}")/.."

  local env_file=".env.bash"
  [[ -f "$env_file" ]] || { echo "Error: $env_file not found." >&2; exit 1; }
  set -a; source "$env_file"; set +a

  : "${RESTIC_REPOSITORY:?not set in .env.bash}"
  : "${RESTIC_VERSION:?not set in .env.bash}"
  : "${vmail_dir:?not set in .env.bash}"
  : "${control_dir:?not set in .env.bash}"
  : "${restic_cache_dir:?not set in .env.bash}"

  # Without the password the repository cannot be read AT ALL. There is no
  # recovery path and no support line to call.
  if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
    echo "Error: RESTIC_PASSWORD is empty. The repository would be" >&2
    echo "       unreadable. See docs/backup-restore.md." >&2
    exit 1
  fi
  if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    echo "Error: object storage credentials are not set in .env.bash." >&2
    exit 1
  fi

  mkdir -p "${restic_cache_dir}"
}

# Run restic with the repo, credentials and mounts wired up.
# Data paths are mounted READ-ONLY: a backup tool has no business writing to
# the thing it is backing up, and restore.sh overrides this deliberately.
restic_run() {
  docker run --rm -i \
    -e "RESTIC_REPOSITORY=${RESTIC_REPOSITORY}" \
    -e "RESTIC_PASSWORD=${RESTIC_PASSWORD}" \
    -e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}" \
    -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}" \
    -e "RESTIC_CACHE_DIR=/cache" \
    -v "${restic_cache_dir}:/cache" \
    -v "${vmail_dir}:${vmail_dir}:ro" \
    -v "${control_dir}:${control_dir}:ro" \
    "restic/restic:${RESTIC_VERSION}" "$@"
}

# Same, but with the data paths writable - restore only.
restic_run_rw() {
  docker run --rm -i \
    -e "RESTIC_REPOSITORY=${RESTIC_REPOSITORY}" \
    -e "RESTIC_PASSWORD=${RESTIC_PASSWORD}" \
    -e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}" \
    -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}" \
    -e "RESTIC_CACHE_DIR=/cache" \
    -v "${restic_cache_dir}:/cache" \
    "$@"
}

ensure_repo() {
  if restic_run cat config >/dev/null 2>&1; then
    return 0
  fi
  echo "No repository at ${RESTIC_REPOSITORY} - initialising..."
  restic_run init
  echo
  echo "############################################################"
  echo "# Repository created. Store RESTIC_PASSWORD somewhere that  #"
  echo "# is NOT this server and NOT the archive. Without it these  #"
  echo "# backups are permanently unreadable.                       #"
  echo "############################################################"
  echo
}
