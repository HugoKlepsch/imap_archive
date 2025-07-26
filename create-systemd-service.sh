#!/bin/bash -e
# Create a systemd service that autostarts & manages a docker-compose instance in the current directory
# by Uli Köhler - https://techoverflow.net
# Licensed as CC0 1.0 Universal
# Modified by Hugo Klepsch

set -euo pipefail

SERVICENAME=$(basename $(pwd))

# Load variables
ENV_FILE=".env.bash"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: $ENV_FILE file not found." >&2
  exit 1
fi

# Use 'set -a' to export all sourced variables to the environment
set -a
if ! source "$ENV_FILE"; then
  echo "Error: Failed to source $ENV_FILE." >&2
  exit 1
fi
set +a
echo "$ENV_FILE loaded successfully."

# Create generated_config directory, where the generated unit files go before they are installed
GEN_DIR="$(pwd)/generated_config"
mkdir -p "${GEN_DIR}"
echo "Generated units are written to ${GEN_DIR}/ before installation"

# Generate the systemd mount unit name
mount_dir_path="$(pwd)/${nas_mount_dir}"
# Strip leading slash, replace slashes with dashes and append ".mount"
mount_unit_name="${mount_dir_path#/}"
mount_unit_name="${mount_unit_name//\//-}.mount"
echo "Creating systemd NAS mount... ${mount_unit_name}"
# Create systemd mount file
cat >"${GEN_DIR}/${mount_unit_name}" <<EOF
[Unit]
Description=IMAP archive NAS mount
After=network-online.target
Requires=network-online.target
Restart=on-failure
RestartSec=10
# 60 attempts 10 seconds apart = 10 minutes minimum. Might be longer due to TimeoutSec
StartLimitBurst=60

[Mount]
What=//${smb_host}/${smb_drive}
Where=${mount_dir_path}
Type=cifs
Options=credentials=/etc/samba/creds_imap_archive,uid=${nas_mount_user},gid=${nas_mount_group},file_mode=0775,dir_mode=0775,iocharset=utf8,nofail
TimeoutSec=30

[Install]
WantedBy=multi-user.target
EOF

imap_unit_name="imap-archive.service"
echo "Creating imap-archive systemd service... ${imap_unit_name}"
# Create systemd service file
cat >"${GEN_DIR}/${imap_unit_name}" <<EOF
[Unit]
Description=Run local IMAP server and webUI in docker compose
After=${mount_unit_name} docker.service network-online.target
Requires=${mount_unit_name} docker.service network-online.target

[Service]
RestartSec=10
Restart=always
User=root
Group=docker
WorkingDirectory=$(pwd)
# Shutdown container (if running) when unit is started
ExecStartPre=/bin/bash -c ". ${ENV_FILE}; $(which docker-compose) -f docker-compose.yml down"
# Start container when unit is started
ExecStart=/bin/bash -c ". ${ENV_FILE}; $(which docker-compose) -f docker-compose.yml up"
# Stop container when unit is stopped
ExecStop=/bin/bash -c ". ${ENV_FILE}; $(which docker-compose) -f docker-compose.yml down"

[Install]
WantedBy=multi-user.target
EOF

backup_service_unit_name="imap-archive-backup.service"
echo "Creating backup systemd service... ${backup_service_unit_name}"
# Create systemd service file
cat >"${GEN_DIR}/${backup_service_unit_name}" <<EOF
[Unit]
Description=IMAP archive data backup service
After=${mount_unit_name}
Requires=${mount_unit_name}

[Service]
Type=oneshot
User=imapapp
Group=imapapp
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/backup.sh

[Install]
WantedBy=multi-user.target
EOF

backup_timer_unit_name="imap-archive-backup.timer"
echo "Creating backup systemd timer... ${backup_timer_unit_name}"
# Create systemd service file
cat >"${GEN_DIR}/${backup_timer_unit_name}" <<EOF
[Unit]
Description=Run IMAP archive data backup daily
Requires=${backup_service_unit_name}

[Timer]
OnCalendar=daily
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

if [[ "${INSTALL:-false}" == "true" ]]; then
	echo "Installing systemd samba mount... /etc/systemd/system/${mount_unit_name}"
	sudo cp "${GEN_DIR}/${mount_unit_name}" "/etc/systemd/system/${mount_unit_name}"

	echo "Installing imap-archive systemd service... /etc/systemd/system/${imap_unit_name}"
	sudo cp "${GEN_DIR}/${imap_unit_name}" "/etc/systemd/system/${imap_unit_name}"

  # TODO: backup/restore is not implemented yet
	# echo "Installing imap-archive backup service... /etc/systemd/system/${backup_service_unit_name}"
	# sudo cp "${GEN_DIR}/${backup_service_unit_name}" "/etc/systemd/system/${backup_service_unit_name}"

	# echo "Installing imap-archive backup timer... /etc/systemd/system/${backup_timer_unit_name}"
	# sudo cp "${GEN_DIR}/${backup_timer_unit_name}" "/etc/systemd/system/${backup_timer_unit_name}"

	sudo systemctl daemon-reload

	if [[ "${ENABLE_NOW:-false}" == "true" ]]; then
		echo "Enabling & starting ${mount_unit_name}, ${imap_unit_name}, ${backup_service_unit_name}, ${backup_timer_unit_name}"
		# Start systemd units on startup (and right now)
		sudo systemctl enable --now "${mount_unit_name}"
		sudo systemctl enable --now "${imap_unit_name}"
		# Note: you only need to enable/start the timer, not the service it runs
		# TODO: backup/restore is not implemented yet
		# sudo systemctl enable --now "${backup_timer_unit_name}"
		exit 0
	else
		echo "Run with INSTALL=true ENABLE_NOW=true ./create... to install and start and enable"
		exit 0
	fi
else
	echo "Run with INSTALL=true ./create... to install"
	exit 0
fi

exit 0
