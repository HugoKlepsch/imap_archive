# Multi-user: scope of work

**Status: not implemented, and not planned for now.** This is a survey of what
adding a second archive user (or a small handful — partner, close family) would
actually cost, written while the answer was fresh so it does not have to be
re-derived later.

The short version: **Dovecot is already multi-user.** The work is concentrated
in mbsync and in the scripts that wrap it, all of which assume exactly one
account. Nothing in the design has to be undone; the single-user assumption
lives in the generated config and the shell, not in the architecture.

## Already multi-user, no changes needed

| Piece | Why it is already fine |
|---|---|
| `config/dovecot/conf.d/10-archive.conf` | `mail_home`, `mail_index_path`, `mail_control_path` and `mail_volatile_path` all key off `%{user \| lower}`. Per-user paths fall out automatically. |
| `passdb` / `userdb passwd-file` | The passwd-file format is a list of users. Several lines is its native mode, not a workaround. |
| `config/dovecot/acl-global` | `* owner lrs` is evaluated against each mailbox's owner, so every user gets read-only on their own mail and no visibility into anyone else's — there is no shared namespace defined. `acl_globals_only = yes` also means no user can grant another access. |
| Roundcube | Nothing in `config/roundcube/custom.inc.php` or the compose file pins a username. It is already a generic IMAP frontend; per-user preferences land in the SQLite database, which handles that natively. |
| `scripts/backup.sh` | Backs up `${vmail_dir}` and `${control_dir}` wholesale, so new users are covered the moment they exist. |
| TLS, ports, compose network | Unaffected. One certificate, one hostname, one Dovecot. |

## What would actually need work

### 1. The generated mbsync config is single-account

`scripts/gen-secrets.sh` emits one `IMAPAccount gmail`, one `IMAPStore
gmail-remote`, one `MaildirStore archive-local` and one `Channel
gmail-archive`. Each user needs their own set with unique names
(`gmail-hugo`, `archive-hugo`, …), plus a `Group` to run them together or a
list of channel names passed to mbsync.

Mechanical, but mind the blank-line trap documented in `gen-secrets.sh`: a
blank line ends a section, and because `Create`/`Remove`/`Expunge`/`Sync` are
also valid *global* options they would be silently accepted as defaults rather
than channel settings. No error, just the wrong behaviour. That hazard applies
once per section, so a generated multi-section file has more places to get it
wrong.

### 2. `.env.bash` has no shape for per-user data

`ARCHIVE_USER`, `ARCHIVE_PASSWORD`, `GMAIL_ADDRESS`, `GMAIL_APP_PASSWORD`,
`GMAIL_SOURCE_FOLDER` and `ARCHIVE_FOLDER` are all flat scalars.

The useful fact here: **none of those are read by `docker compose`.** Compose
only consumes `vmail_dir`, the `*_dir` paths, ports, versions and
`MAIL_HOSTNAME`. So per-user data can move into something bash arrays can hold
(or a separate `users.tsv` / `users.d/*.env`) without breaking the
`set -a; source .env.bash` → compose handoff that every script relies on.

Do not make them arrays *in* `.env.bash` and expect compose to see them — bash
arrays do not export — but compose does not need them, so this costs nothing.

### 3. `scripts/sync-gmail.sh` is single-user end to end

`ARCHIVE_PATH`, `count_messages`, the `.mbsyncstate` guard, the before/after
report and the closing `doveadm index -u "${ARCHIVE_USER}"` all assume one
account. This needs a loop.

One decision worth making deliberately rather than by accident: the
sync-state guard is a hard `exit 1`. As written, one user's missing
`.mbsyncstate` would abort every other user's sync too. Per-user
skip-and-continue, with a non-zero exit at the end so the unit still fails, is
almost certainly what is wanted — and `scripts/notify-discord.sh` should name
which user failed.

### 4. `scripts/verify-archive.sh` is single-user

Same shape: per-user Gmail credentials and per-user archive path. The Python
half (`scripts/verify-archive.py`) takes everything through the environment
and does not need to change.

### 5. `scripts/restore.sh` — cosmetic only

Only the printed post-restore guidance references `ARCHIVE_USER`; the restore
itself is tree-wide. A text fix, not a logic change.

## Three things to decide before building it

### Passwords

Today `ARCHIVE_PASSWORD` is plaintext in `.env.bash`, and `gen-secrets.sh`
re-hashes it on every run. With other people involved that means **their**
passwords sitting in cleartext on the server.

The better shape for multi-user is to stop regenerating the file from
plaintext: have a script *add or update* one user in
`generated_config/dovecot/users`, prompting for the password and keeping only
the ARGON2ID hash. Regenerating everything from stored plaintext does not
scale past a single user who is also the operator.

### There is no quota anywhere

Nothing in `config/` or `compose/` configures one. One person's 80 GB Gmail can
fill the NAS and take the archive down for everyone.

Note that Dovecot's quota plugin would **not** help here: mbsync writes Maildir
files through the filesystem and never touches IMAP, which is the path quota
enforces on. It would be advisory at best. Real protection is a free-space
check in `sync-gmail.sh` before each user's channel runs.

### Gmail app passwords are the human friction

Each person needs 2FA enabled on their Google account, has to generate an app
password, and has to hand it over. That is the step most likely to stall
onboarding — not anything in this repository.

## One note on isolation

All mail is owned by uid 1000 (`vmail`) regardless of which user it belongs to.
Separation between users is enforced by Dovecot, not by the filesystem. That is
fine for family, and worth knowing before assuming it is a hard boundary.
