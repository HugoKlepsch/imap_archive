# Orientation

Start here if you have not touched this system in a year.

## What this is

A **read-only IMAP server holding an archive of Gmail**. Mail is copied out of
Gmail into local storage so that it can be deleted from Gmail to free quota,
while staying searchable from Thunderbird and a web UI on the home network.

## What this is not

It is **not a mail server**. It cannot send mail and it cannot receive mail.
There is no MTA, no port 25, nothing listening on the public internet. The only
way a message enters the archive is a sync job writing a file to disk.

## The one thing to keep in mind

> Once messages are deleted from Gmail, this system is the **only** copy.

Every design decision below follows from that sentence. If you are about to
change something and it trades safety for convenience, that is the trade you
are making.

## How the pieces fit

```
                         (phase 3)
  Gmail  ──── mbsync ────────────────►  Maildir on the NAS
  (IMAP, app password)                        │
                                              │  read-only
                                              ▼
                                        Dovecot ──────► Thunderbird (IMAPS 993)
                                              │  ▲
                                              │  └── Roundcube ◄── home-portal
                                              │        (web UI)      Caddy, TLS
                                              │                   https://mail...
                                              └──── restic ──► object storage
                                                    (phase 4)
```

Mail arrives by **filesystem writes, not IMAP**. mbsync drops Maildir files
straight onto the share; Dovecot notices them on its next scan. This is why
the archive can be read-only over IMAP and still grow.

## Where things live, and why it matters

| What                       | Where                                | Why                                                                                         |
|----------------------------|--------------------------------------|---------------------------------------------------------------------------------------------|
| Messages                   | NAS over CIFS (`nas_data_mnt/vmail`) | Bulk storage. Plain Maildir: one directory per folder, one file per message.                |
| Indexes, control, volatile | **Local disk** (`local_data_mnt/`)   | Dovecot locks and mmaps these. SMB does not implement that correctly and will corrupt them. |
| TLS certificate            | Local disk (`local_data_mnt/certs`)  | Written by lego, read by Dovecot.                                                           |
| Secrets                    | `.env.bash` (gitignored)             | Never committed.                                                                            |
| Password hash              | `generated_config/dovecot/users`     | Generated from `.env.bash`; never committed.                                                |

**Never move the index/control/volatile paths onto the NAS mount.** It will
appear to work and then quietly corrupt mailboxes.

## Design decisions worth knowing

- **Maildir, not mdbox.** mdbox packs messages into larger files and is more
  efficient over a network share, but it is a Dovecot-proprietary format. The
  archive is meant to outlive Dovecot, so one-file-per-message wins.
- **`mailbox_list_layout = fs`.** Dovecot 2.4 defaults to `index`, which hides
  the folder list inside a Dovecot index file. `fs` keeps the directory tree
  self-describing, and is what lets mbsync write into it.
- **All Mail, flat.** Gmail shows one message under every label *and* in All
  Mail. Syncing labels as folders would store popular messages several times;
  syncing All Mail alone stores each exactly once. Search replaces browsing.
- **`Sync PullNew` and nothing else.** mbsync copies new messages from Gmail
  and never propagates deletions or flag changes. Plain `Pull` would mirror
  deletions, so emptying Gmail would empty the archive — the exact disaster
  this system exists to prevent. The cost is that read/unread state is not
  mirrored, which does not matter for an archive.
- **mbsync writes files, Dovecot serves them.** The two never talk to each
  other. Because delivery happens on the filesystem rather than over IMAP, the
  read-only ACL applies to people and not to the sync.
- **ACL-enforced read-only.** Clients get lookup, read, and `\Seen`. No delete,
  no expunge, no folder creation. A stray drag in Thunderbird cannot destroy
  the only copy. Verify with `docs/maintenance.md`.
- **The web UI is fronted by home-portal, not by this stack.** Roundcube is
  published on a plain host port and the home-portal Caddy terminates TLS for
  `mail.hugo-klepsch.tech` with its existing `*.hugo-klepsch.tech` wildcard —
  the same pattern as immich, bazarr and the rest. Home wifi and VPN only.
- **The hostname is not in public DNS.** Its A record lives only in the local
  resolver. DNS-01 still works because the only publicly visible record is the
  short-lived `_acme-challenge` TXT record that lego creates and removes.
- **Dovecot gets its own certificate, separate from Caddy's wildcard.** Caddy
  is an HTTP proxy and cannot serve IMAPS, and having Dovecot terminate TLS
  itself preserves client IPs in the logs. The two ACME clients request
  different names (`*.hugo-klepsch.tech` versus `mail.hugo-klepsch.tech`), so
  their challenge records never collide.
- **Roundcube reaches Dovecot by `MAIL_HOSTNAME` over the compose network**,
  which is a network alias on the dovecot service. The real certificate
  therefore validates on the internal hop too, so peer verification stays on
  instead of being disabled.
- **Ports are 31143/31993 inside the container.** The upstream image ships
  `vendor.d/rootless.conf` which moves them there, because Dovecot runs
  unprivileged as `vmail` and cannot bind below 1024. The compose file maps
  them to the standard 143/993 on the host. This is correct, not a typo.

## Build status

| Phase | What                                     | Status    |
|-------|------------------------------------------|-----------|
| 1     | Dovecot, TLS, read-only archive, systemd | **Built** |
| 2     | Roundcube web UI                         | Not built |
| 3     | mbsync pulling Gmail                     | Not built |
| 4     | Verification, restic offsite backup      | Not built |

Nothing has been deleted from Gmail, and nothing should be until phase 4 is
finished and a restore has been tested.

## Where to go next

- Setting it up the first time: [initial-setup.md](initial-setup.md)
- Day-to-day operation: [maintenance.md](maintenance.md)
- Backups and recovery: [backup-restore.md](backup-restore.md)
