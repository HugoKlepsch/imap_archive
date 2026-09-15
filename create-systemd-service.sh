#!/bin/bash
# Generate (and optionally install) the systemd units for the IMAP archive.
#
#   ./create-systemd-service.sh                        # generate only
#   INSTALL=true ./create-systemd-service.sh           # generate + install
#   INSTALL=true ENABLE_NOW=true ./create-systemd-service.sh   # + enable & start
#
# Units generated:
#   <mount>.mount                  CIFS mount for the NAS share (the mail)
#   imap-archive.service           Dovecot via docker compose
#   imap-archive-roundcube.service Roundcube web UI via docker compose
#   imap-archive-sync.service      mbsync pull from Gmail
#   imap-archive-sync.timer        runs the above daily (not auto-enabled)
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
# Install
########################################
if [[ "${INSTALL:-false}" != "true" ]]; then
  echo
  echo "Run with INSTALL=true ./create-systemd-service.sh to install."
  exit 0
fi

for unit in "${mount_unit_name}" "${imap_unit_name}" "${roundcube_unit_name}" \
            "${sync_service_unit_name}" "${sync_timer_unit_name}" \
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
echo "NOT enabled: ${sync_timer_unit_name}"
echo "  Run the first Gmail sync manually, then enable it:"
echo "    sudo systemctl enable --now ${sync_timer_unit_name}"
echo "Done."
