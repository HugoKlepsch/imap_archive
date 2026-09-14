# Maintenance

Day-to-day operation. Run from the repo root on the server.

## Service control

```bash
sudo systemctl status imap-archive
sudo systemctl restart imap-archive
sudo journalctl -u imap-archive -f
sudo journalctl -u imap-archive --since "1 hour ago"
```

Timers:

```bash
systemctl list-timers 'imap-archive*'
sudo journalctl -u imap-archive-cert -n 50
```

## Health checks

**Is the NAS actually mounted?** The most common cause of "all my mail
vanished". It has not; Dovecot is looking at an empty directory.

```bash
mountpoint nas_data_mnt
df -h nas_data_mnt
```

If it is not mounted, Dovecot should have refused to start
(`RequiresMountsFor`). Remount and restart:

```bash
sudo systemctl start home-hugo-git-imap_archive-nas_data_mnt.mount
sudo systemctl restart imap-archive
```

**Can a client log in?**

```bash
printf 'a LOGIN archive YOURPASSWORD\nb LOGOUT\n' \
  | openssl s_client -connect mail.hugo-klepsch.tech:993 -quiet
```

**Message count and disk use:**

```bash
set -a; source .env.bash; set +a
docker exec imap_archive_dovecot doveadm mailbox status -u "${ARCHIVE_USER}" messages '*'
du -sh "${vmail_dir}" "${local_mount_dir}"
```

## Verifying the archive is still read-only

Worth re-running after any config change. Both commands must be refused.

```bash
printf 'a LOGIN archive YOURPASSWORD\nb CREATE ShouldFail\nc APPEND INBOX {28}\r\nSubject: x\r\n\r\nhello\r\n\nd LOGOUT\n' \
  | openssl s_client -connect mail.hugo-klepsch.tech:993 -quiet 2>/dev/null | grep -E '^[bc] '
```

Expected:

```
b NO [NOPERM] Permission denied
c NO [NOPERM] Permission denied
```

Anything else means the ACL is not in effect and the archive is writable —
investigate before letting a client near it. Also worth checking that a
`SELECT` reports `PERMANENTFLAGS (\Seen)` and nothing more.

## Changing the archive password

```bash
vim .env.bash              # set ARCHIVE_PASSWORD
./scripts/gen-secrets.sh
sudo systemctl restart imap-archive
```

## Certificates

The timer checks daily and renews inside 30 days of expiry, then reloads
Dovecot. To check or force:

```bash
set -a; source .env.bash; set +a
openssl x509 -enddate -noout -in "${cert_dir}/tls.crt"

sudo ./scripts/renew-cert.sh                    # no-op unless due
sudo systemctl start imap-archive-cert.service   # same, via systemd
```

Dovecot caches the certificate at startup, so a renewal is not live until it
re-reads config. `renew-cert.sh` does that automatically when the certificate
changed; to do it by hand:

```bash
docker exec imap_archive_dovecot doveadm reload
```

**If renewal fails**, it is almost always DNS propagation. Check that the TXT
record is visible to a public resolver while the run is in progress:

```bash
dig +short TXT _acme-challenge.mail.hugo-klepsch.tech @1.1.1.1
```

Raise `LINODE_PROPAGATION_TIMEOUT` before anything else. Do not "fix" it by
lowering `LINODE_TTL` below 30 — that is already the minimum Linode accepts,
and a TTL of 0 means "zone default", which resolvers cache for hours.

## Rebuilding indexes

Indexes and control files are on local disk and are rebuildable from the
Maildir. Rebuild after a local-disk failure, or if a mailbox behaves oddly:

```bash
set -a; source .env.bash; set +a
docker exec imap_archive_dovecot doveadm index -u "${ARCHIVE_USER}" '*'
docker exec imap_archive_dovecot doveadm force-resync -u "${ARCHIVE_USER}" '*'
```

Losing `mail_control_path` is recoverable but not free: it holds
`dovecot-uidlist`, the UID-to-filename map. Regenerating it gives every message
a new IMAP UID, so clients treat the whole archive as new and re-download it.
No mail is lost. This is why the control directory is included in backups.

## Upgrading Dovecot

`DOVECOT_VERSION` is pinned deliberately. The 2.4 line changed configuration
syntax substantially from 2.3, and `config/dovecot/conf.d/10-archive.conf` is
written against 2.4.

```bash
vim .env.bash                # bump DOVECOT_VERSION
set -a; source .env.bash; set +a

# Validate the config against the NEW image before restarting anything.
docker run --rm \
  -v "$(pwd)/config/dovecot/conf.d:/etc/dovecot/conf.d:ro" \
  -v "$(pwd)/config/dovecot/acl-global:/etc/dovecot/acl-global:ro" \
  -v "$(pwd)/generated_config/dovecot:/etc/dovecot/generated:ro" \
  -e DOVEADM_PASSWORD=validate \
  "dovecot/dovecot:${DOVECOT_VERSION}" doveconf -n
```

`doveconf` reporting `Failed to get mailbox Drafts` is a pre-existing quirk of
the upstream image and appears with the stock config too — it is not a fault in
this configuration.

Confirm these four are still in effect before restarting:

```bash
... "dovecot/dovecot:${DOVECOT_VERSION}" doveconf \
      mailbox_list_layout mail_index_path mail_control_path acl_global_path
```

`mailbox_list_layout` must be `fs`. If an upgrade silently returns it to
`index`, folders become invisible to mbsync and to every non-Dovecot tool.

Then `sudo systemctl restart imap-archive` and re-run the read-only check.

## Upgrading lego

`LEGO_VERSION` is pinned for the same reason: v5 removed the `renew`
subcommand and renamed `--days` to `--renew-days`. `scripts/renew-cert.sh` is
written against the v5 interface. After bumping, run it by hand once.
