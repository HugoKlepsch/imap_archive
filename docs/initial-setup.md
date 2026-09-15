# Initial setup

Setting the archive up on a fresh server. Phases 1–2 — the Gmail sync and the
offsite backup are not built yet.

Commands run on the server, from the repo root, unless stated otherwise.

## 0. Prerequisites

- Docker and the compose plugin.
- A CIFS share on the NAS for the archive (`imap_archive`).
- A Linode DNS API token with read/write on the zone.
- `cifs-utils` installed (`sudo pacman -S cifs-utils` / `apt install cifs-utils`).

## 1. User and group

Everything that touches archive data runs as `imapapp`, and your admin user
needs to be able to read it.

```bash
sudo groupadd imapapp
sudo useradd -r -g imapapp -s /bin/false -M imapapp
sudo usermod -a -G imapapp "$USER"
```

Log out and back in for the group change to take effect.

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

| Variable           | Notes                                                        |
|--------------------|--------------------------------------------------------------|
| `MAIL_HOSTNAME`    | Must match the DNS record from step 3 and the certificate.   |
| `LINODE_TOKEN`     | Its own token, so it can be revoked without affecting Caddy. |
| `ARCHIVE_PASSWORD` | The IMAP login. `openssl rand -base64 24`                    |
| `DOVEADM_PASSWORD` | Admin API. Defaults to `supersecret` upstream — set it.      |

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
sudo chown -R imapapp:imapapp "${local_mount_dir}"
sudo chmod -R 0770 "${local_mount_dir}"
```

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

Expect this to take two to three minutes: it writes a TXT record and waits for
propagation. `LINODE_TTL=30` is deliberate — Linode treats a TTL of 0 as "zone
default", which public resolvers then cache for many hours, causing the CA to
keep seeing a stale record. The same problem is documented in the Caddyfile in
`~/git/reverse-proxy`.

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

## 12. Thunderbird

| Setting             | Value                    |
|---------------------|--------------------------|
| Protocol            | IMAP                     |
| Server              | `mail.hugo-klepsch.tech` |
| Port                | 993                      |
| Connection security | SSL/TLS                  |
| Authentication      | Normal password          |
| Username            | `archive`                |

Thunderbird will show the folders as read-only. That is correct.

## What is not set up yet

Phases 3–4 (Gmail sync, verification, offsite backup) are not built.
**Nothing should be deleted from Gmail until phase 4 is complete and a restore
has actually been tested.**
