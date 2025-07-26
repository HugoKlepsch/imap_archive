# IMAP archive

---

# High-level design

## Goal

Run an IMAP server for archiving emails. Sync emails to server using `imapsync`.

## Components

| Component | Description       | Ports    |
|-----------|-------------------|----------|
| Dovecot   | IMAP server       | 143, 993 |
| Roundcube | IMAP server webUI | 8080     |

Components are run as docker containers, started with docker-compose,
service lifecycle managed by Systemd unit files. Configuration and secrets
are stored in `.env` files.

## Permissions

* All components will run as `imapapp:imapapp`.
* Server management user is also in `imapapp` group.

## Secrets

Secrets are stored in `.env.bash` file. A template is provided in `.env.bash.template`.

# Details

## Users & Groups

Create `imapapp:imapapp` and ensure that your devops user `user` has access:

```shell
sudo groupadd imapapp
sudo useradd -r -g imapapp -s /bin/false -M imapapp
sudo usermod -a -G imapapp user
```

## Storage

* All data is stored on my Synology NAS, mounted via Samba.
* Application configs are not on the NAS-mounted drive because they contain
  SQLite DBs and don't tend to work well with NAS mounts because they don't 
  support file locking properly.
* Mounted as `nobody:imapapp`

### Directory Structure

TODO `tree` output

```
```

### Samba credentials 

Create a credential file here:

```bash
sudo vim /etc/samba/creds_imap_archive 
```

In it, we have something like this:

```
username=foo
password=bar
```

Note: no quotations needed. If you need it, `domain` can also be added.

Protect it:

```bash
sudo chmod 600 /etc/samba/creds_imap_archive
```

### Systemd mount using CIFS

The `create-systemd-service.sh` script will generate a set of systemd units, 
one of which mounts the samba share. For me, I want to mount it to 
`/home/user/imap_archive/nas_data_mnt`, so it creates a 
`home-user-imap_archive-nas_data_mnt.mount` unit. This is then installed into 
`/etc/systemd/system/`.

# Backup & Restore

TODO

* The config directories are backed up using the `backup.sh` script. 
* You can restore from backup using `restore.sh`.
* `backup.sh` is run daily using `imap-archive-backup.service` and `imap-archive-backup.timer`
  (generated). These run as imapapp:imapapp

## Usage

### Manual Backup

```bash
./backup.sh
```

- Creates timestamped backup in `~/imap_archive/nas_data_mnt/backups/`
- Excludes cache, logs, and temporary files
- Keeps the latest 30 days of backups
- Creates `latest_backup.tar.gz` symlink
- Must be run as `imapapp:imapapp` user:group

### Manual Restore

```bash
./restore.sh
```

- Interactive menu to select backup
- Creates safety backup of existing data
- Restores selected backup to the original location

**Or specify backup file directly:**

```bash
./restore.sh imap_backup_20240623_120000.tar.gz
```

### Check Backup Status

```bash
# View systemd timer status
sudo systemctl status imap-archive-backup.timer

# View recent backup logs
sudo journalctl -u imap-archive-backup.service -n 20

# Check backup directory
ls -la ~/imap_archive/nas_data_mnt/backups/
```

## Directory Structure

TODO

```
~/imap_archive/
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

* Copy base files from plex-pms. These offer a bunch of utilities for Ops [DONE]
