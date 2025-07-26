# IMAP archive

---

# High level design

## Goal

Run a IMAP server for archiving emails. Sync emails to server using `imapsync`.

## Components

* Dovecot - IMAP server		(port 143, 993)
* Roundcube - IMAP server webUI	(port 8080)

Components are run as docker containers, started with docker-compose,
service lifecycle managed by Systemd unit files. Configuration and secrets
are stored in `.env` files.

## Permissions

* All components will run as `imapapp:imapapp`.
* Server management user is also in `imapapp` group.

## Secrets

Secrets are stored in `.env.bash` file. A template is provided in `.env.bash.template`.

# Details

## Storage

* All data is stored on my Synology NAS, mounted via Samba.
* Application configs are not on the NAS-mounted drive, because they contain
  SQLite DBs, and don't tend to work well with NAS mounts because they don't 
  support file locking properly.
* Mounted as `plex:plexapp`
* All data is on one filesystem so that hardlinks can be used to enable
  atomic moves and deduplication.

### Directory Structure

TODO `tree` output

```
```

### Samba credentials 

Create a credentials file here:

```bash
sudo vim /etc/samba/creds_imap_archive 
```

In it, we have something like this:

```
username=foo
password=bar
```

Note: no quotation marks needed. If you need it, `domain` can also be added.

Protect it:

```bash
sudo chmod 600 /etc/samba/creds_imap_archive
```

### Systemd mount using CIFS


The `create-systemd-service.sh` script will generate a set of systemd units, 
one of which mounts the samba share. For me, I want to mount it to 
`/home/user/imap-archive/nas_data_mnt`, so it creates a 
`home-user-imap-archive-plex_data_mnt.mount` unit. This is then installed into 
`/etc/systemd/system/`.

## Torrent client (qBittorrent)

* qBittorrent is the torrent client.
* It is run as `transmission:plexapp`.
* It is run using the `arrs` systemd service in the arrs compose file 
  `arrs-compose/docker-compose-arrs.yml`.
* Set a WebUI password on first use. The temporary password is printed in 
  the logs on first startup.
* You must configure a proxy. My seedbox provider has a HTTP proxy service, 
  which I configure in the qBittorrent webUI.
* WebUI is available on port 3489.

# Backup & Restore

* The config directories are backed up using the `backup.sh` script. 
* You can restore from backup using `restore.sh`.
* `backup.sh` is run daily using `plex-backup.service` and `plex-backup.timer`
  (generated).

## Usage

### Manual Backup

```bash
./backup.sh
```

- Creates timestamped backup in `~/plex/plex_data_mnt/plex2/backups/`
- Excludes cache, logs, and temporary files
- Keeps latest 30 days of backups
- Creates `latest_backup.tar.gz` symlink
- Must be run as `plex:plexapp` user:group

### Manual Restore

```bash
./restore.sh
```

- Interactive menu to select backup
- Creates safety backup of existing data
- Restores selected backup to original location

**Or specify backup file directly:**

```bash
./restore.sh plex_backup_20240623_120000.tar.gz
```

### Check Backup Status

```bash
# View systemd timer status
sudo systemctl status plex-backup.timer

# View recent backup logs
sudo journalctl -u plex-backup.service -n 20

# Check backup directory
ls -la ~/plex/plex_data_mnt/plex2/backups/
```

## Directory Structure

```
~/plex/
├── backup.sh              # Backup script
├── restore.sh             # Restore script
├── local_data_mnt/plex/   # Source data
└── plex_data_mnt/plex2/backups/  # Backup destination
    ├── plex_backup_YYYYMMDD_HHMMSS.tar.gz
    ├── latest_backup.tar.gz -> (symlink to latest)
    ├── backup.log
    └── restore.log
```

# Progress

* plex2 NAS mounting has migrated from sshfs -> SMB [DONE]
* plex2 users `plex` and `arr` as well as `plexapp` group created [DONE]
* plex2 running under `plex:plexapp`, replacing old plex deployment [DONE]
* NAS mounted as `nobody:plexapp` [WON'T DO: plex doesn't like it...]
* plex config now on non-NAS mount to avoid file locking issues [DONE]
* Set up seedbox network namespace [DONE]
* Run transmission in `seedbox` network namespace [WON'T DO: easier to run qBT with HTTP proxy]
* Run arrs in seedbox network namespace [WON'T DO: arrs don't need to be proxied]
* Run qBittorrent with HTTP proxy [DONE]
* Run arrs & qBT in docker-compose [DONE]
* Create backup scripts, run daily [DONE]
* Set up libraries [DONE]
* Run plex off of new libraries [DONE]
* Actually route qBittorrent traffic via VPN using GlueTUN [DONE]
* Fix download client connection issues: port forwarding? [DONE: switched to airVPN w/ port forwarding]
* Set up overseerr [DONE]
* Set up automatic collections using kometa [TODO]
