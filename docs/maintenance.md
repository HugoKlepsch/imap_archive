# Maintenance

Day-to-day operation. Run from the repo root on the server.

## Service control

```bash
sudo systemctl status imap-archive              # Dovecot
sudo systemctl status imap-archive-roundcube    # web UI
sudo systemctl restart imap-archive
sudo journalctl -u imap-archive -f
sudo journalctl -u imap-archive --since "1 hour ago"
```

Roundcube is a separate unit so it can be restarted without interrupting
Thunderbird sessions. It `Requires` the Dovecot unit because it joins the
docker network that project creates, so restarting Dovecot alone can leave the
web UI briefly unable to connect; restart it afterwards if the UI errors.

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

## Roundcube

```bash
curl -sI http://127.0.0.1:8083/ | head -1                 # direct, bypassing Caddy
curl -sI https://mail.hugo-klepsch.tech/ | head -1        # through home-portal
docker logs imap_archive_roundcube --tail 50
```

If the direct call works and the proxied one does not, the problem is in
home-portal's Caddyfile or the local DNS record, not in this stack.

**"Connection to storage server failed"** means Roundcube could not reach
Dovecot. It connects to `MAIL_HOSTNAME` over the compose network — which is a
network alias on the dovecot service — so the causes are, in order: Dovecot is
down; the network was recreated without restarting Roundcube; or the
certificate no longer matches `MAIL_HOSTNAME`. Peer verification is on
deliberately, so a name mismatch is a hard failure rather than a warning.

```bash
docker exec imap_archive_roundcube getent hosts mail.hugo-klepsch.tech
```

**Logged out constantly** usually means `ROUNDCUBE_DES_KEY` changed, which
invalidates every existing session. That is harmless — log in again.

**Wrong redirect URLs, or a login loop behind Caddy**, means
`ROUNDCUBE_TRUSTED_PROXIES` does not list the address Caddy's traffic actually
arrives from. Check it against `ip -4 addr show docker0`.

## Gmail sync

```bash
sudo ./scripts/sync-gmail.sh                  # run now
systemctl list-timers 'imap-archive-sync*'
sudo journalctl -u imap-archive-sync -n 100
LIST=true sudo ./scripts/sync-gmail.sh        # list Gmail folders (read-only)
```

The script prints a before/after message count, so a normal incremental run
reads `1234 -> 1237 messages (+3)`.

**Never use `mbsync --dry-run` against this archive.** It writes the messages
it claims it "would pull" without recording them in `.mbsyncstate`, so the next
real sync pulls them again. Verified: 3 messages became 6. `sync-gmail.sh`
refuses `DRY_RUN=true` for this reason. To preview, use `LIST=true` or sync a
small Gmail label.

### If message counts jump unexpectedly

Almost always a lost or corrupted `.mbsyncstate`, which lives inside the
destination folder on the NAS:

```bash
set -a; source .env.bash; set +a
ls -la "${vmail_dir}/${ARCHIVE_USER}/mail/${ARCHIVE_FOLDER}/.mbsyncstate"
```

Without it mbsync has no memory of what it already pulled and re-pulls the
whole folder, adding a second copy of every message. If it is gone, **do not
just re-run the sync** — restore it from backup first. If it cannot be
restored, the archive needs de-duplicating by `Message-ID` before syncing again.

### Deduplicating

```bash
set -a; source .env.bash; set +a
cd "${vmail_dir}/${ARCHIVE_USER}/mail/${ARCHIVE_FOLDER}/cur"
grep -h '^Message-ID:' * | sort | uniq -d | head    # are there duplicates?
```

`doveadm deduplicate -u "${ARCHIVE_USER}" ${ARCHIVE_FOLDER}` can remove them,
but it deletes mail — take a backup first and re-read
[backup-restore.md](backup-restore.md).

### Authentication failures

Gmail App Passwords are revoked whenever the account password changes, and
Google expires unused ones. Create a new one at
<https://myaccount.google.com/apppasswords>, update `GMAIL_APP_PASSWORD`, then
`./scripts/gen-secrets.sh`.

### What mbsync changes about a message

Two modifications, both expected and neither data loss:

- **CRLF → LF.** IMAP transmits CRLF; on-disk Maildir uses LF. Dovecot converts
  back when serving the message, so clients see the original.
- **An added `X-TUID:` header**, which isync uses to track messages.

A byte-for-byte comparison against Gmail will therefore always differ. Verified
that, ignoring those two, archived messages are identical to the source
including attachments — which is what `scripts/verify-archive.sh` checks.

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

Raise `LINODE_PROPAGATION_TIMEOUT` before anything else; it is a cap, so a
larger value costs nothing on a run that succeeds quickly. Do not "fix" it by
lowering `LINODE_TTL` below 300 — lego refuses to start below that, and a TTL
of 0 means "zone default", which resolvers cache for hours.

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

## Backups

```bash
./scripts/backup.sh                    # run now (daily timer)
./scripts/check-backup.sh              # verify data (weekly timer)
./scripts/restore.sh                   # test restore to a scratch dir
sudo journalctl -u imap-archive-backup -n 50
systemctl list-timers 'imap-archive*'
```

Both scripts refuse to run without `RESTIC_PASSWORD`, and `backup.sh` refuses
if the NAS is not mounted — an empty snapshot plus retention would eventually
age out the last good one.

**Check the timers are actually firing.** This is the failure mode the whole
backup exists to avoid, and nothing currently alerts on it:

```bash
systemctl list-timers 'imap-archive*'          # LAST column should be recent
systemctl is-failed imap-archive-backup.service
```

## Alerting

```bash
./scripts/notify-discord.sh --test          # confirm the webhook still works
```

Every unit carries `OnFailure=imap-archive-alert@%n.service`. A failure posts a
red embed with the unit name, the `Result` systemd recorded, and the last 25
journal lines.

The notifier **always exits 0**, even when delivery fails. A failure handler
that can itself fail is a loop, and a broken webhook should not turn one failed
unit into two. The consequence is that a silently broken webhook looks exactly
like "nothing has failed" - which is what the weekly heartbeat is for.

Check delivery is genuinely working:

```bash
sudo journalctl -u 'imap-archive-alert@*' -n 30
```

`notify-discord: delivery failed, HTTP 404` means the webhook was deleted in
Discord; `HTTP 429` means rate limiting.

### Why this uses host tools

`notify-discord.sh` runs `curl`, `jq` and `journalctl` on the host rather than
in a container like everything else here. If docker is what broke, a
docker-based alert would fail at exactly the moment it is needed. Those three
binaries are a hard requirement on the server.

## Verifying against Gmail

```bash
./scripts/verify-archive.sh                        # counts + 50-message sample
FULL=true SAMPLE_SIZE=500 ./scripts/verify-archive.sh
```

Read-only on both sides; safe to run any time. Worth repeating periodically
while Gmail still has the originals, and during any batch deletion.

Once you have deleted from Gmail, the count check will report the archive
holding **more** messages than Gmail. That is correct and expected. What still
matters is the sample comparison and, if anything is odd, `FULL=true` coverage.

If it reports mismatches, do not delete anything further. `MISSING` means
`sync-gmail.sh` has not caught up; content mismatches mean something corrupted
a message in place, which is what the backup is for.

## Upgrading Roundcube

The document root is not persisted — the entrypoint re-extracts the
application on every start — so an upgrade is only a version bump:

```bash
vim .env.bash                 # bump ROUNDCUBE_VERSION
sudo systemctl restart imap-archive-roundcube
```

The SQLite database is persisted and migrated automatically on start. Check
`config/roundcube/custom.inc.php` still applies afterwards: the settings it
uses (`disabled_actions`, `proxy_whitelist`, `imap_conn_options`) are stable,
but a major version could rename them, and a silently ignored
`disabled_actions` would put the Compose button back.

```bash
docker exec imap_archive_roundcube \
  grep -c "custom.inc.php" /var/www/html/config/config.docker.inc.php   # expect 1
```

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

## Upgrading mbsync

`ALPINE_VERSION` in `.env.bash` pins the base image, and isync comes from that
Alpine release. After bumping it, rebuild and re-verify idempotency — run the
sync twice and confirm the second run pulls **0** messages:

```bash
docker compose -f compose/mbsync/docker-compose-mbsync.yml build --no-cache
sudo ./scripts/sync-gmail.sh     # note the count
sudo ./scripts/sync-gmail.sh     # must be +0
```

That second run is the test that matters. A version that silently stops
honouring `SyncState` would re-pull the entire archive on every timer firing.

## Upgrading lego

`LEGO_VERSION` is pinned for the same reason: v5 removed the `renew`
subcommand and renamed `--days` to `--renew-days`. `scripts/renew-cert.sh` is
written against the v5 interface. After bumping, run it by hand once.
