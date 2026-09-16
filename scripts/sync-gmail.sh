#!/bin/bash
# Pull new mail from Gmail into the archive.
#
#   ./scripts/sync-gmail.sh                # normal incremental sync
#   LIST=true ./scripts/sync-gmail.sh      # show the configured folder pair
#   LIST_ALL=true ./scripts/sync-gmail.sh  # list every folder Gmail offers
#
# Both listing modes are read-only and exit without syncing. Under sudo the
# assignment goes AFTER it - `sudo LIST=true ...` - because sudo resets the
# environment and would otherwise drop the variable.
#
# Refuses to run if the archive holds messages but .mbsyncstate is missing or
# empty, which would cause mbsync to pull a duplicate copy of everything.
# Override only if you understand the consequence: ALLOW_MISSING_SYNC_STATE=true
#
# There is deliberately no dry-run option. See the guard below.
#
# Run by imap-archive-sync.timer. Safe to run by hand at any time and safe to
# interrupt: mbsync journals its progress and resumes where it stopped.
#
# This writes Maildir files directly onto the share. It does not go through
# IMAP, so Dovecot's read-only ACL does not apply to it - that is by design.
#
# Afterwards it asks Dovecot, via doveadm, to subscribe and index the folder.
# Both are no-ops if Dovecot is not running.
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE=".env.bash"
[[ -f "$ENV_FILE" ]] || { echo "Error: $ENV_FILE not found." >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a

: "${vmail_dir:?not set in .env.bash}"
: "${ARCHIVE_USER:?not set in .env.bash}"
: "${ARCHIVE_FOLDER:?not set in .env.bash}"
: "${nas_mount_dir:?not set in .env.bash}"

MBSYNCRC="generated_config/mbsync/mbsyncrc"
if [[ ! -f "$MBSYNCRC" ]]; then
  echo "Error: $MBSYNCRC missing. Run ./scripts/gen-secrets.sh first." >&2
  exit 1
fi

if [[ -z "${GMAIL_APP_PASSWORD:-}" ]]; then
  echo "Error: GMAIL_APP_PASSWORD is empty in .env.bash." >&2
  echo "       Create one at https://myaccount.google.com/apppasswords" >&2
  exit 1
fi

# Refuse to run against an unmounted share. Without this the sync would write
# into the empty local directory that the mount point is when unmounted,
# silently building a second archive on the wrong disk and reporting success.
if ! mountpoint -q "${nas_mount_dir}"; then
  echo "Error: ${nas_mount_dir} is not mounted. Refusing to sync." >&2
  exit 1
fi

COMPOSE_FILE="compose/mbsync/docker-compose-mbsync.yml"
ARCHIVE_PATH="${vmail_dir}/$(echo "$ARCHIVE_USER" | tr '[:upper:]' '[:lower:]')/mail/${ARCHIVE_FOLDER}"

count_messages() {
  # Maildir: one file per message across cur/ and new/. mbsync's own state
  # files live in the folder root, so they are not counted.
  #
  # The folder does not exist until the first sync creates it. find then exits
  # 1, and with `set -o pipefail` that status propagates through the pipe and
  # kills the script - silently, because the message went to /dev/null. The
  # `|| true` is what makes a fresh archive count as 0 rather than exit 1.
  find "${ARCHIVE_PATH}/cur" "${ARCHIVE_PATH}/new" -type f 2>/dev/null | wc -l || true
}

# ---------------------------------------------------------------------------
# Sync-state guard
# ---------------------------------------------------------------------------
# Refuse to sync a non-empty archive that has no .mbsyncstate.
#
# mbsync is a synchroniser, not a downloader: it decides what to fetch purely
# from the pairing table in .mbsyncstate, never by looking at what is already
# in the Maildir. If that file is missing while messages exist, mbsync treats
# every message on the Gmail side as new and pulls a second complete copy of
# the archive. The messages already here become permanently orphaned - mbsync
# re-pairs the far-side UIDs to the NEW copies and will never touch the old
# ones again.
#
# It does not self-heal, it compounds on each run, and the only cleanup is
# deduplicating by Message-ID, which means deleting mail from what may be the
# only remaining copy. Verified: removing the state file turned a 5-message
# archive into 10, with every Message-ID duplicated.
#
# The correct recovery is to restore .mbsyncstate from backup BEFORE syncing
# again - see docs/backup-restore.md. Hence this is a hard stop, not a warning:
# unattended on a daily timer, the alternative is discovering a doubled archive
# the next morning.
STATE_FILE="${ARCHIVE_PATH}/.mbsyncstate"
EXISTING="$(count_messages)"

# Neither listing mode writes anything, so both skip the guard below and the
# post-sync accounting at the end.
LIST_MODE=""
if [[ "${LIST_ALL:-false}" == "true" ]]; then
  LIST_MODE="stores"
elif [[ "${LIST:-false}" == "true" ]]; then
  LIST_MODE="channel"
fi

if [[ -z "${LIST_MODE}" && "${EXISTING}" -gt 0 ]]; then
  STATE_PROBLEM=""
  if [[ ! -f "${STATE_FILE}" ]]; then
    STATE_PROBLEM="missing"
  elif [[ ! -s "${STATE_FILE}" ]]; then
    # A zero-byte state file is as dangerous as no state file: mbsync finds no
    # pairings and re-pulls everything just the same.
    STATE_PROBLEM="empty"
  fi

  if [[ -n "${STATE_PROBLEM}" && "${ALLOW_MISSING_SYNC_STATE:-false}" != "true" ]]; then
    cat >&2 <<MSG
Error: refusing to sync - the mbsync state file is ${STATE_PROBLEM}.

  archive folder : ${ARCHIVE_PATH}
  messages held  : ${EXISTING}
  state file     : ${STATE_FILE}

The archive holds messages but mbsync has no record of them. Syncing now would
pull a second complete copy of every message from Gmail and orphan the
${EXISTING} already here. This does not repair itself and gets worse each run.

What to do instead:

  1. Restore the state file from backup, then sync normally:
       restic restore latest --include '*/.mbsyncstate' --target /
  2. If it genuinely cannot be restored, the archive must be deduplicated by
     Message-ID before syncing again. See docs/maintenance.md.

If this really is a fresh archive whose messages arrived some other way, and
you accept that they will be duplicated, override with:

  sudo ALLOW_MISSING_SYNC_STATE=true $0
MSG
    exit 1
  fi
fi

# mbsync's --dry-run is NOT safe for this setup and is refused here.
#
# Despite reporting "would pull N new message(s)" and changing nothing on the
# Gmail side, mbsync 1.5 still WRITES those messages into the destination
# Maildir - while not recording them in .mbsyncstate. The following real sync
# then pulls them again, duplicating every message. Verified: a dry run
# followed by a real run turned 3 messages into 6, each Message-ID twice.
#
# To preview safely use LIST=true, or sync a small Gmail label first.
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  echo "Error: DRY_RUN is not supported - mbsync's --dry-run writes messages" >&2
  echo "       to the archive without recording them, which causes duplicates." >&2
  echo "       Use LIST=true, or point GMAIL_SOURCE_FOLDER at a small label." >&2
  exit 1
fi

MBSYNC_ARGS=(-c /mbsyncrc)
case "${LIST_MODE}" in
  stores)
    # --list-stores enumerates the STORE, so no channel is involved and there
    # is nothing that could sync. This is the one that answers "what is my
    # All Mail folder actually called", which is locale-dependent - and the
    # reason `--list` cannot: the channel names one explicit folder, so it
    # echoes back whatever GMAIL_SOURCE_FOLDER says, spelled right or not.
    echo "Listing every folder on the Gmail side..."
    MBSYNC_ARGS+=(--list-stores gmail-remote)
    ;;
  channel)
    # Resolves the configured channel: one line, Gmail folder <=> archive
    # folder. Proves the credentials and TLS work, not that the folder exists.
    echo "Listing the configured folder pair..."
    MBSYNC_ARGS+=(--list gmail-archive)
    ;;
  *)
    MBSYNC_ARGS+=(--verbose gmail-archive)
    ;;
esac

BEFORE="${EXISTING}"
echo "Archive currently holds ${BEFORE} messages in '${ARCHIVE_FOLDER}'."

START="$(date +%s)"
docker compose -f "$COMPOSE_FILE" run --rm mbsync "${MBSYNC_ARGS[@]}"
ELAPSED=$(( $(date +%s) - START ))

if [[ -n "${LIST_MODE}" ]]; then
  exit 0
fi

AFTER="$(count_messages)"
echo
echo "Sync finished in ${ELAPSED}s. ${BEFORE} -> ${AFTER} messages (+$(( AFTER - BEFORE )))."

if [[ "${AFTER}" -gt 0 ]] && docker ps --format '{{.Names}}' | grep -qx imap_archive_dovecot; then
  # Subscribe the archive folder.
  #
  # mbsync creates the folder by making a directory on the share; it never
  # speaks IMAP and so never subscribes anything. Dovecot keeps subscriptions
  # in its own file under mail_control_path, which therefore stays empty.
  #
  # Thunderbird hides that: it offers unsubscribed folders with a toggle. But
  # Roundcube builds its folder list from LSUB, so an unsubscribed folder is
  # simply absent - and config/roundcube/custom.inc.php disables
  # settings.folders, so there is no UI to subscribe it either. The symptom is
  # a web client that shows an empty INBOX and no sign that the archive exists.
  #
  # Idempotent, so it runs on every sync rather than only on the first: it also
  # repairs the subscription if the control directory is ever lost or rebuilt.
  docker exec imap_archive_dovecot \
    doveadm mailbox subscribe -u "${ARCHIVE_USER}" "${ARCHIVE_FOLDER}" || \
    echo "Warning: could not subscribe '${ARCHIVE_FOLDER}'; it may not appear in Roundcube." >&2

  # Dovecot indexes new files lazily, on the next client access. Nudging it here
  # means the first person to open the folder does not wait for a large scan,
  # and keeps the full-text index current for search.
  if [[ "${AFTER}" -ne "${BEFORE}" ]]; then
    echo "Indexing new messages..."
    docker exec imap_archive_dovecot \
      doveadm index -u "${ARCHIVE_USER}" "${ARCHIVE_FOLDER}" || \
      echo "Warning: indexing failed; Dovecot will index on next access instead." >&2
  fi
fi
