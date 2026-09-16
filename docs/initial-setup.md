# Initial setup

Setting the archive up on a fresh server, end to end.

Commands run on the server, from the repo root, unless stated otherwise.

## 0. Prerequisites

- Docker and the compose plugin.
- A CIFS share on the NAS for the archive (`imap_archive`).
- A Linode DNS API token with read/write on the zone.
- `cifs-utils` installed (`sudo pacman -S cifs-utils` / `apt install cifs-utils`).

## 1. Ownership

The containers run as `vmail`, which is uid/gid **1000:1000** inside both the
Dovecot image and the mbsync image, and that is not configurable. Everything
they read or write on the host therefore has to be owned by uid 1000 — which
on a single-admin server is your own account, so there is nothing to create.

```bash
id -u        # expect 1000; if it is not, see app_uid in .env.bash.template
```

Do **not** create a service account for this with `useradd -r`. A system
account gets a uid below 1000, and with the 0770 modes used below the
container cannot even traverse the tree:

```
cert_file: open(/etc/dovecot/certs/tls.crt) failed: Permission denied
```

## 2. Samba credentials

```bash
sudo install -m 600 /dev/null /etc/samba/creds_imap_archive
sudo vim /etc/samba/creds_imap_archive
```

Contents — no quotes, add `domain=` if you need it:

```
username=foo
password=bar
```

## 3. DNS

Add the hostname to the **local resolver** (pihole), pointing at this server —
the same arrangement as `immich.hugo-klepsch.tech` and the other home-portal
hosts:

```
mail.hugo-klepsch.tech.   A   10.8.0.22
```

Do **not** add it to the public Linode zone. DNS-01 still works: the only
record that has to be publicly visible is the short-lived `_acme-challenge`
TXT record, which lego creates and deletes through the Linode API. Nothing
about this host becomes reachable from the internet.

## 4. Configuration

```bash
cp .env.bash.template .env.bash
vim .env.bash
```

Every value is commented in the template. The ones with no sensible default:

| Variable           | Notes                                                      |
|--------------------|------------------------------------------------------------|
| `MAIL_HOSTNAME`    | Must match the DNS record from step 3 and the certificate. |
| `LINODE_TOKEN`     | Linode DNS API token.                                      |
| `ARCHIVE_PASSWORD` | The IMAP login. `openssl rand -base64 24`                  |
| `DOVEADM_PASSWORD` | Admin API. Defaults to `supersecret` upstream — set it.    |

While testing, point `ACME_CA` at Let's Encrypt **staging**. Production has
tight rate limits and a misconfigured DNS token can burn them quickly.

```bash
chmod 600 .env.bash
```

## 5. Generate the password hash

Dovecot never sees the plaintext — only the ARGON2ID hash this writes.

```bash
./scripts/gen-secrets.sh
```

## 6. Create the data directories

The NAS mount point must exist before systemd can mount onto it, and the
local-disk directories must exist before Dovecot starts.

```bash
set -a; source .env.bash; set +a
mkdir -p "${nas_mount_dir}" "${index_dir}" "${control_dir}" "${volatile_dir}" \
         "${cert_dir}" "${roundcube_db_dir}"
sudo chown -R "${app_uid}:${app_gid}" "${local_mount_dir}"
sudo chmod -R 0770 "${local_mount_dir}"
```

`app_uid`/`app_gid` are 1000:1000 for the reason given in step 1, and match
`nas_mount_uid`/`nas_mount_gid` — the CIFS mount presents the archive as the
same owner. Check it with `ls -lnd "${local_mount_dir}"`: the numeric owner
must be 1000, not a lower system uid.

## 7. Install the systemd units

```bash
INSTALL=true ./create-systemd-service.sh
```

Inspect what landed in `generated_config/` before enabling anything. Then:

```bash
sudo systemctl enable --now home-hugo-git-imap_archive-nas_data_mnt.mount
mountpoint nas_data_mnt    # must say "is a mountpoint" before going further
```

Do not skip that check. `imap-archive.service` declares `RequiresMountsFor`, so
it will refuse to start without the mount — which is the intended behaviour, as
starting Dovecot against an unmounted (and therefore empty) directory looks
exactly like catastrophic data loss.

## 8. Get the certificate

```bash
sudo ./scripts/renew-cert.sh
```

Expect this to take a few minutes: it writes a TXT record and waits for
propagation. Linode rebuilds its zone files on a 15-minute cycle, so a first
issuance can take most of that; the run ends as soon as the record is visible.

`LINODE_TTL=300` is both the lowest value lego's Linode provider accepts and
its default — it rejects anything lower outright. Do not set it to 0: Linode
reads that as "zone default", which public resolvers then cache for many
hours, causing the CA to keep seeing a stale record. The same problem is
documented in the Caddyfile in `~/git/reverse-proxy`.

It should end with an expiry date. Then enable the renewal timer:

```bash
sudo systemctl enable --now imap-archive-cert.timer
```

## 9. Start Dovecot

```bash
sudo systemctl enable --now imap-archive
sudo systemctl status imap-archive
sudo journalctl -u imap-archive -f
```

Expect `Dovecot v2.4.1 ... starting up for imap`.

## 10. Verify

From another machine on the LAN or VPN:

```bash
printf 'a LOGIN archive YOURPASSWORD\nb LIST "" *\nc LOGOUT\n' \
  | openssl s_client -connect mail.hugo-klepsch.tech:993 -quiet
```

Three things to confirm:

1. **No certificate warnings** — the chain validates, so DNS-01 worked.
2. `a OK ... Logged in` — the passwd-file and hash are correct.
3. Run the read-only check in [maintenance.md](maintenance.md#verifying-the-archive-is-still-read-only).

## 11. Roundcube

```bash
sudo systemctl enable --now imap-archive-roundcube
sudo journalctl -u imap-archive-roundcube -f
```

First start takes longer than you expect — the entrypoint extracts the
application into an empty document root every time. That is deliberate: no
state lives there, so the upgrade path never has to run.

Check it directly on the host port before involving Caddy:

```bash
curl -sI http://127.0.0.1:8083/ | head -1     # expect 200
```

### Caddyfile entry

Roundcube is served by the **home-portal** Caddy, which already holds a
`*.hugo-klepsch.tech` wildcard, so no new certificate work is needed. Add this
to `~/git/home-portal/Caddyfile`, in alphabetical position inside the
`*.hugo-klepsch.tech` block:

```caddy
	@mail host mail.hugo-klepsch.tech
	handle @mail {
		reverse_proxy 10.8.0.22:8083
	}
```

Then reload it from the home-portal repo:

```bash
cd ~/git/home-portal
docker compose -f compose/docker-compose.yml exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Visit `https://mail.hugo-klepsch.tech` from the home network or the VPN and log
in as `archive`. There is no Compose button — there is no MTA in this stack and
the UI has it removed rather than offering an action that would fail.

Two certificates are in play at this point, which is expected: Caddy serves the
web UI with its wildcard, while Dovecot serves IMAPS with the single-name
certificate lego issued. They are requested independently and their ACME
challenge records never collide.

## 12. First Gmail sync

Create an **App Password** at <https://myaccount.google.com/apppasswords> — it
requires 2FA on the account, and it is not your Google password. Put it in
`GMAIL_APP_PASSWORD`, then regenerate the config:

```bash
./scripts/gen-secrets.sh
```

Check the connection and confirm the folder name, which is locale-dependent —
`[Gmail]/All Mail` on an English account:

```bash
LIST=true sudo ./scripts/sync-gmail.sh
```

### Sync a small label first

Do not point the first run at All Mail. Apply a Gmail label to a handful of
messages, set `GMAIL_SOURCE_FOLDER` to it, and sync that:

```bash
vim .env.bash            # GMAIL_SOURCE_FOLDER="test-archive"
./scripts/gen-secrets.sh
sudo ./scripts/sync-gmail.sh
```

Then confirm those messages appear in Thunderbird or Roundcube, with
attachments intact, before committing to the full pull.

> **There is no dry-run option, deliberately.** mbsync's `--dry-run` reports
> "would pull N messages" while actually writing them to the archive and *not*
> recording them in `.mbsyncstate` — the next real sync then pulls them again.
> Verified: a dry run followed by a real run turned 3 messages into 6. The
> script refuses `DRY_RUN=true` for this reason. Use `LIST=true`, or a small
> label as above.

### The full pull

Point `GMAIL_SOURCE_FOLDER` back at `[Gmail]/All Mail`, regenerate, and run it
inside `tmux` or `screen`:

```bash
vim .env.bash
./scripts/gen-secrets.sh
tmux new -s gmailsync
sudo ./scripts/sync-gmail.sh
```

Expect this to take **hours to days**. Google throttles IMAP downloads at
roughly 2.5 GB/day, so a large mailbox is a multi-day job. This is normal.

It is safe to interrupt and safe to re-run: mbsync journals its progress and
resumes rather than starting over. The systemd unit sets
`TimeoutStartSec=infinity` for the same reason.

### Enable the timer

Only after a successful full sync:

```bash
sudo systemctl enable --now imap-archive-sync.timer
systemctl list-timers 'imap-archive*'
```

## 13. Backup, verify, and only then delete

This is the gate. Everything before it is reversible because Gmail still holds
the originals; after it, this archive is the only copy.

### Back up

```bash
./scripts/backup.sh
```

The first run uploads the whole archive and can take hours. Store
`RESTIC_PASSWORD` somewhere that is not this server — without it the repository
is permanently unreadable.

### Prove the backup restores

```bash
./scripts/check-backup.sh     # re-reads and checksums a sample of the data
./scripts/restore.sh          # test restore into a scratch directory
```

Read the restore output. It must show matching counts, a readable sample
message, and `.mbsyncstate` present.

### Verify the archive against Gmail

```bash
FULL=true SAMPLE_SIZE=500 ./scripts/verify-archive.sh
```

Read-only on both sides. It checks three things:

1. **Counts** — Gmail vs files on disk vs what Dovecot serves.
2. **Coverage** (`FULL=true`) — every Gmail Message-ID present in the archive.
3. **Content** — a random sample compared field by field: Subject, From, To,
   Date, decoded body text, and each attachment's filename, size and SHA-256.

It compares *parsed* content rather than raw bytes, because mbsync legitimately
rewrites CRLF to LF and adds an `X-TUID` header. A byte comparison would report
every message as corrupt.

Exit code 0 and `PASS` means no discrepancies. Anything else stops here.

### Enable the timers

```bash
sudo systemctl enable --now imap-archive-backup.timer
sudo systemctl enable --now imap-archive-check.timer
systemctl list-timers 'imap-archive*'
```

### Then, and only then

Delete from Gmail — in batches, re-running `verify-archive.sh` as you go. Note
that once messages are gone from Gmail the count check will legitimately show
the archive holding *more* than Gmail; that is expected and reported as such.

## 14. Alerting

Nothing else in this stack tells you when a timer quietly stops working, and a
backup that has been failing for six months is worse than no backup because it
is trusted.

Create a webhook in Discord under **Server Settings -> Integrations -> Webhooks**,
put the URL in `DISCORD_WEBHOOK_URL`, and test it:

```bash
vim .env.bash     # DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
./scripts/notify-discord.sh --test
```

You should get a blue "Test notification" in the channel. Then reinstall the
units so every one of them picks up the `OnFailure=` hook:

```bash
INSTALL=true ./create-systemd-service.sh
sudo systemctl daemon-reload
```

Every unit - the NAS mount, Dovecot, Roundcube, the sync, the backup, the
verification and the certificate renewal - now carries
`OnFailure=imap-archive-alert@%n.service`, which posts the failure and the last
25 journal lines.

`DISCORD_HEARTBEAT="true"` additionally posts a green message after each weekly
backup verification. That exists because silence is ambiguous: it means either
"everything is fine" or "the timer stopped running in June". One message a week
tells those apart. Set it to `false` for failures only.

Leaving `DISCORD_WEBHOOK_URL` empty disables alerting entirely - the notifier
does nothing and exits cleanly.

## 15. Thunderbird

| Setting             | Value                    |
|---------------------|--------------------------|
| Protocol            | IMAP                     |
| Server              | `mail.hugo-klepsch.tech` |
| Port                | 993                      |
| Connection security | SSL/TLS                  |
| Authentication      | Normal password          |
| Username            | `archive`                |

Thunderbird will show the folders as read-only. That is correct.

## Before you delete anything from Gmail

Step 13 is not optional and not a formality. All three must have been run
against the real archive, on this server, and passed:

| Check                       | Proves                                            |
|-----------------------------|---------------------------------------------------|
| `scripts/backup.sh`         | A snapshot exists in object storage.              |
| `scripts/restore.sh`        | That snapshot actually restores, end to end.      |
| `scripts/verify-archive.sh` | Every message in Gmail is present in the archive. |

Confirm the timers are enabled (`systemctl list-timers 'imap-archive-*'`) and
that `RESTIC_PASSWORD` is stored somewhere that is neither this server nor the
archive — without it the backups are permanently unreadable.

**Only then delete from Gmail.**
