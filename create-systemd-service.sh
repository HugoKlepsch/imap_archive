#!/bin/bash
# Generate (and optionally install) the systemd units for the IMAP archive.
#
#   ./create-systemd-service.sh                        # generate only
#   INSTALL=true ./create-systemd-service.sh           # generate + install
#   INSTALL=true ENABLE_NOW=true ./create-systemd-service.sh   # + enable & start
#
# Units generated:
#   imap-archive-alert@.service    Discord alert, triggered by OnFailure=
#   <mount>.mount                  CIFS mount for the NAS share (the mail)
#   imap-archive.service           Dovecot via docker compose
#   imap-archive-roundcube.service Roundcube web UI via docker compose
#   imap-archive-sync.service      mbsync pull from Gmail
#   imap-archive-sync.timer        runs the above daily (not auto-enabled)
#   imap-archive-backup.service    restic backup to object storage
#   imap-archive-backup.timer      runs the above daily (not auto-enabled)
#   imap-archive-check.service     restic data verification
#   imap-archive-check.timer       runs the above weekly (not auto-enabled)
#   imap-archive-cert.service      lego certificate issuance/renewal
#   imap-archive-cert.timer        runs the above daily
#
# Originally by Uli Köhler (https://techoverflow.net), CC0 1.0 Universal.
# Modified by Hugo Klepsch.

set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=".env.bash"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: $ENV_FILE not found. Copy .env.bash.template and fill it in." >&2
  exit 1
fi

set -a
if ! source "$ENV_FILE"; then
  echo "Error: failed to source $ENV_FILE." >&2
  exit 1
fi
set +a
echo "$ENV_FILE loaded successfully."

: "${smb_host:?not set}"; : "${smb_drive:?not set}"; : "${nas_mount_dir:?not set}"
: "${smb_creds_file:?not set}"; : "${MAIL_HOSTNAME:?not set}"

COMPOSE="$(command -v docker-compose || echo "$(command -v docker) compose")"

GEN_DIR="$(pwd)/generated_config"
mkdir -p "${GEN_DIR}"
echo "Generated units are written to ${GEN_DIR}/ before installation"

########################################
# Alerting
########################################
# A template unit: OnFailure=imap-archive-alert@%n.service passes the failed
# unit's name as the instance, so one unit covers everything.
#
# This unit deliberately has NO OnFailure of its own - a failure handler that
# can itself trigger a failure handler is a loop. notify-discord.sh also always
# exits 0 for the same reason.
alert_unit_name="imap-archive-alert@.service"
echo "Creating alert template unit... ${alert_unit_name}"

cat >"${GEN_DIR}/${alert_unit_name}" <<EOF
[Unit]
Description=Discord alert for %i
# Do not add OnFailure here.

[Service]
Type=oneshot
User=root
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/scripts/notify-discord.sh --failure %i
EOF

# Every unit below gets this. The mount is included because a silent mount
# failure is what makes Dovecot serve an empty archive.
ON_FAILURE="OnFailure=imap-archive-alert@%n.service"

########################################
# NAS mount unit
########################################
# systemd derives a mount unit's name from its mount point, so this has to be
# computed rather than hardcoded: /a/b/c -> a-b-c.mount
mount_dir_path="$(pwd)/${nas_mount_dir}"
mount_unit_name="${mount_dir_path#/}"
mount_unit_name="${mount_unit_name//\//-}.mount"
echo "Creating systemd NAS mount... ${mount_unit_name}"

cat >"${GEN_DIR}/${mount_unit_name}" <<EOF
[Unit]
Description=IMAP archive NAS mount (message storage)
After=network-online.target
Requires=network-online.target
${ON_FAILURE}

[Mount]
What=//${smb_host}/${smb_drive}
Where=${mount_dir_path}
Type=cifs
Options=credentials=${smb_creds_file},uid=${nas_mount_uid},gid=${nas_mount_gid},file_mode=0660,dir_mode=0770,iocharset=utf8,nofail,_netdev
TimeoutSec=30

[Install]
WantedBy=multi-user.target
EOF

########################################
# Dovecot service
########################################
imap_unit_name="imap-archive.service"
echo "Creating Dovecot systemd service... ${imap_unit_name}"

# RequiresMountsFor is the important part: if the NAS share is not mounted,
# Dovecot must not start. Without it, docker would happily bind-mount the
# empty local directory that the mount point is when unmounted, and Dovecot
# would come up serving an empty archive - which looks exactly like data loss.
cat >"${GEN_DIR}/${imap_unit_name}" <<EOF
[Unit]
Description=IMAP archive (Dovecot) in docker compose
After=${mount_unit_name} docker.service network-online.target
Requires=${mount_unit_name} docker.service
RequiresMountsFor=${mount_dir_path}
${ON_FAILURE}

[Service]
Type=simple
RestartSec=10
Restart=always
User=root
Group=docker
WorkingDirectory=$(pwd)
ExecStartPre=/bin/bash -c ". ${ENV_FILE}; ${COMPOSE} -f compose/dovecot/docker-compose-dovecot.yml down"
ExecStart=/bin/bash -c ". ${ENV_FILE}; ${COMPOSE} -f compose/dovecot/docker-compose-dovecot.yml up"
ExecStop=/bin/bash -c ". ${ENV_FILE}; ${COMPOSE} -f compose/dovecot/docker-compose-dovecot.yml down"

[Install]
WantedBy=multi-user.target
EOF

########################################
# Roundcube service
########################################
roundcube_unit_name="imap-archive-roundcube.service"
echo "Creating Roundcube systemd service... ${roundcube_unit_name}"

# Kept as its own unit rather than folded into imap-archive.service so the web
# UI can be restarted without interrupting Thunderbird sessions. It Requires
# the Dovecot unit because it joins the docker network that project creates,
# and BindsTo would be too aggressive - a Dovecot restart should not tear this
# down permanently.
cat >"${GEN_DIR}/${roundcube_unit_name}" <<EOF
[Unit]
Description=IMAP archive web UI (Roundcube) in docker compose
After=${imap_unit_name} docker.service network-online.target
Requires=${imap_unit_name} docker.service
${ON_FAILURE}

[Service]
Type=simple
RestartSec=10
Restart=always
User=root
Group=docker
WorkingDirectory=$(pwd)
ExecStartPre=/bin/bash -c ". ${ENV_FILE}; ${COMPOSE} -f compose/roundcube/docker-compose-roundcube.yml down"
ExecStart=/bin/bash -c ". ${ENV_FILE}; ${COMPOSE} -f compose/roundcube/docker-compose-roundcube.yml up"
ExecStop=/bin/bash -c ". ${ENV_FILE}; ${COMPOSE} -f compose/roundcube/docker-compose-roundcube.yml down"

[Install]
WantedBy=multi-user.target
EOF

########################################
# Gmail sync
########################################
sync_service_unit_name="imap-archive-sync.service"
sync_timer_unit_name="imap-archive-sync.timer"
echo "Creating Gmail sync service... ${sync_service_unit_name}"

# TimeoutStartSec=infinity because the FIRST sync of a large Gmail account can
# run for many hours - Google throttles IMAP downloads, so a 15GB mailbox is a
# multi-day job. systemd's default timeout would kill it partway. Subsequent
# incremental runs take seconds.
#
# mbsync journals its progress, so an interrupted run resumes rather than
# restarting, and re-running is always safe.
cat >"${GEN_DIR}/${sync_service_unit_name}" <<EOF
[Unit]
Description=Pull new mail from Gmail into the archive
After=${mount_unit_name} docker.service network-online.target
Requires=${mount_unit_name} docker.service
RequiresMountsFor=${mount_dir_path}
${ON_FAILURE}

[Service]
Type=oneshot
TimeoutStartSec=infinity
User=root
Group=docker
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/scripts/sync-gmail.sh

[Install]
WantedBy=multi-user.target
EOF

echo "Creating Gmail sync timer... ${sync_timer_unit_name}"
# Daily rather than hourly: Gmail throttles IMAP, nothing here is time
# critical, and a slower cadence keeps well clear of the daily download cap.
cat >"${GEN_DIR}/${sync_timer_unit_name}" <<EOF
[Unit]
Description=Pull new mail from Gmail daily
Requires=${sync_service_unit_name}

[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

########################################
# Certificate renewal
########################################
cert_service_unit_name="imap-archive-cert.service"
cert_timer_unit_name="imap-archive-cert.timer"
echo "Creating certificate renewal service... ${cert_service_unit_name}"

cat >"${GEN_DIR}/${cert_service_unit_name}" <<EOF
[Unit]
Description=Renew the IMAP archive TLS certificate (ACME DNS-01 via Linode)
After=network-online.target docker.service
Requires=network-online.target docker.service
${ON_FAILURE}

[Service]
Type=oneshot
User=root
Group=docker
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/scripts/renew-cert.sh

[Install]
WantedBy=multi-user.target
EOF

echo "Creating certificate renewal timer... ${cert_timer_unit_name}"
cat >"${GEN_DIR}/${cert_timer_unit_name}" <<EOF
[Unit]
Description=Check the IMAP archive TLS certificate daily
Requires=${cert_service_unit_name}

[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

########################################
# Offsite backup
########################################
backup_service_unit_name="imap-archive-backup.service"
backup_timer_unit_name="imap-archive-backup.timer"
echo "Creating backup service... ${backup_service_unit_name}"

# After the sync rather than before: back up what was just pulled, so a
# snapshot is never a full day behind the archive.
cat >"${GEN_DIR}/${backup_service_unit_name}" <<EOF
[Unit]
Description=Back up the IMAP archive to offsite object storage
After=${mount_unit_name} docker.service network-online.target ${sync_service_unit_name}
Requires=${mount_unit_name} docker.service
RequiresMountsFor=${mount_dir_path}
${ON_FAILURE}

[Service]
Type=oneshot
# The first backup uploads the entire archive and can run for many hours.
TimeoutStartSec=infinity
User=root
Group=docker
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/scripts/backup.sh

[Install]
WantedBy=multi-user.target
EOF

echo "Creating backup timer... ${backup_timer_unit_name}"
# An hour after the sync timer's window, so the two do not contend for the
# NAS mount or the network.
cat >"${GEN_DIR}/${backup_timer_unit_name}" <<EOF
[Unit]
Description=Back up the IMAP archive daily
Requires=${backup_service_unit_name}

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

########################################
# Backup verification
########################################
check_service_unit_name="imap-archive-check.service"
check_timer_unit_name="imap-archive-check.timer"
echo "Creating backup check service... ${check_service_unit_name}"

# Separate from the backup because it is slow and costs egress. `restic check`
# alone only validates metadata; this re-reads a sample of the actual data.
# A backup that has never been read back is not a backup.
cat >"${GEN_DIR}/${check_service_unit_name}" <<EOF
[Unit]
Description=Verify the IMAP archive backup by re-reading repository data
After=docker.service network-online.target
Requires=docker.service
${ON_FAILURE}

[Service]
Type=oneshot
TimeoutStartSec=infinity
User=root
Group=docker
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/scripts/check-backup.sh

[Install]
WantedBy=multi-user.target
EOF

echo "Creating backup check timer... ${check_timer_unit_name}"
cat >"${GEN_DIR}/${check_timer_unit_name}" <<EOF
[Unit]
Description=Verify the IMAP archive backup weekly
Requires=${check_service_unit_name}

[Timer]
OnCalendar=Sun *-*-* 05:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

########################################
# Install
########################################
if [[ "${INSTALL:-false}" != "true" ]]; then
  echo
  echo "Run with INSTALL=true ./create-systemd-service.sh to install."
  exit 0
fi

for unit in "${alert_unit_name}" \
            "${mount_unit_name}" "${imap_unit_name}" "${roundcube_unit_name}" \
            "${sync_service_unit_name}" "${sync_timer_unit_name}" \
            "${backup_service_unit_name}" "${backup_timer_unit_name}" \
            "${check_service_unit_name}" "${check_timer_unit_name}" \
            "${cert_service_unit_name}" "${cert_timer_unit_name}"; do
  echo "Installing /etc/systemd/system/${unit}"
  sudo cp "${GEN_DIR}/${unit}" "/etc/systemd/system/${unit}"
done

sudo systemctl daemon-reload

if [[ "${ENABLE_NOW:-false}" != "true" ]]; then
  echo
  echo "Installed. Run with INSTALL=true ENABLE_NOW=true to enable & start."
  exit 0
fi

echo "Enabling & starting units..."
sudo systemctl enable --now "${mount_unit_name}"
sudo systemctl enable --now "${imap_unit_name}"
sudo systemctl enable --now "${roundcube_unit_name}"
# Only the timer is enabled; it pulls in the service it runs.
sudo systemctl enable --now "${cert_timer_unit_name}"
# The sync timer is deliberately NOT enabled here. Run the first sync by hand
# so the initial pull can be watched - see docs/initial-setup.md.
echo
echo "NOT enabled: ${sync_timer_unit_name}, ${backup_timer_unit_name}, ${check_timer_unit_name}"
echo "  Run the first Gmail sync manually, then enable it:"
echo "    sudo systemctl enable --now ${sync_timer_unit_name}"
echo "  Run the first backup manually (it uploads everything), then:"
echo "    sudo systemctl enable --now ${backup_timer_unit_name}"
echo "    sudo systemctl enable --now ${check_timer_unit_name}"
echo "Done."
