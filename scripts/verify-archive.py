#!/usr/bin/env python3
"""Verify the archive against Gmail before deleting anything from Gmail.

Three checks, cheapest first:

  1. Counts     - Gmail vs Maildir files on disk vs what Dovecot serves.
  2. Coverage   - every Gmail Message-ID present in the archive (--full).
  3. Content    - a random sample compared field by field, including
                  attachment payload hashes.

Why not just compare bytes: mbsync rewrites CRLF to LF when it stores a
message as a Maildir file, and adds an X-TUID header of its own. Both are
expected and neither is data loss, but they mean a byte-for-byte comparison
reports every single message as corrupt. So this compares PARSED content -
decoded headers, decoded body text, and decoded attachment payloads.
"""

import email
import email.policy
import hashlib
import imaplib
import os
import random
import re
import ssl
import sys
from collections import Counter

imaplib._MAXLINE = 10_000_000


def log(msg=""):
    print(msg, flush=True)


def normalise_text(s):
    """Whitespace-insensitive comparison.

    CRLF vs LF is the whole reason this function exists. Trailing whitespace
    per line and at the end of the body is also normalised, because transfer
    encodings are free to add or drop it.
    """
    if s is None:
        return ""
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    s = "\n".join(line.rstrip() for line in s.split("\n"))
    return s.strip()


def message_parts(msg):
    """Return (body_text, [(filename, size, sha256), ...]) for a parsed message."""
    bodies, attachments = [], []
    for part in msg.walk():
        if part.is_multipart():
            continue
        filename = part.get_filename()
        disposition = (part.get_content_disposition() or "").lower()
        try:
            payload = part.get_payload(decode=True)
        except Exception:
            payload = None
        if payload is None:
            payload = b""

        if filename or disposition == "attachment":
            attachments.append((
                filename or "<unnamed>",
                len(payload),
                hashlib.sha256(payload).hexdigest(),
            ))
        elif part.get_content_type() in ("text/plain", "text/html"):
            charset = part.get_content_charset() or "utf-8"
            try:
                bodies.append(payload.decode(charset, errors="replace"))
            except LookupError:
                bodies.append(payload.decode("utf-8", errors="replace"))

    return normalise_text("\n".join(bodies)), sorted(attachments)


def header(msg, name):
    try:
        v = msg.get(name)
        return normalise_text(str(v)) if v is not None else ""
    except Exception:
        return ""


MSGID_RE = re.compile(rb"^message-id:\s*(.+?)\s*$", re.I | re.M)


def scan_maildir(root):
    """Map Message-ID -> file path by reading only each file's header block."""
    index, no_id, total = {}, 0, 0
    for sub in ("cur", "new"):
        d = os.path.join(root, sub)
        if not os.path.isdir(d):
            continue
        for name in os.listdir(d):
            path = os.path.join(d, name)
            if not os.path.isfile(path):
                continue
            total += 1
            try:
                with open(path, "rb") as fh:
                    head = fh.read(16384).split(b"\n\n", 1)[0]
            except OSError:
                continue
            m = MSGID_RE.search(head)
            if m:
                index.setdefault(m.group(1).decode("utf-8", "replace").strip(), path)
            else:
                no_id += 1
    return index, total, no_id


def parse_file(path):
    with open(path, "rb") as fh:
        return email.message_from_binary_file(fh, policy=email.policy.default)


def main():
    gmail_user = os.environ["GMAIL_ADDRESS"]
    gmail_pass = os.environ["GMAIL_APP_PASSWORD"]
    folder = os.environ.get("GMAIL_SOURCE_FOLDER", "[Gmail]/All Mail")
    archive_path = os.environ["ARCHIVE_PATH"]
    sample_size = int(os.environ.get("SAMPLE_SIZE", "50"))
    full = os.environ.get("FULL", "false").lower() == "true"

    log("=" * 68)
    log("Archive verification")
    log("=" * 68)

    log(f"\nScanning archive at {archive_path} ...")
    index, local_total, no_id = scan_maildir(archive_path)
    log(f"  files on disk      : {local_total}")
    log(f"  distinct Message-ID: {len(index)}")
    if no_id:
        log(f"  without Message-ID : {no_id}  (cannot be matched by ID)")
    dupes = local_total - no_id - len(index)
    if dupes > 0:
        log(f"  DUPLICATE copies   : {dupes}  <-- investigate, see docs/maintenance.md")

    # Overridable so this can be exercised against a local IMAP server in
    # testing. Leave unset in normal use - it defaults to Gmail.
    imap_host = os.environ.get("GMAIL_IMAP_HOST", "imap.gmail.com")
    imap_port = int(os.environ.get("GMAIL_IMAP_PORT", "993"))
    cafile = os.environ.get("GMAIL_IMAP_CAFILE") or None

    log(f"\nConnecting to {imap_host} as {gmail_user} ...")
    ctx = ssl.create_default_context(cafile=cafile)
    M = imaplib.IMAP4_SSL(imap_host, imap_port, ssl_context=ctx)
    try:
        M.login(gmail_user, gmail_pass)
        typ, data = M.select(f'"{folder}"', readonly=True)
        if typ != "OK":
            log(f"ERROR: cannot select {folder!r}: {data}")
            return 2
        remote_total = int(data[0])
        log(f"  messages in {folder!r}: {remote_total}")

        # ---------------- 1. counts ----------------
        log("\n--- 1. Counts ---")
        log(f"  Gmail            : {remote_total}")
        log(f"  Archive on disk  : {local_total}")
        delta = local_total - remote_total
        if delta == 0:
            log("  MATCH")
        elif delta > 0:
            log(f"  Archive has {delta} MORE. Expected if you already deleted from")
            log("  Gmail; otherwise suspect duplicates.")
        else:
            log(f"  Archive has {-delta} FEWER - {-delta} message(s) not yet pulled.")
            log("  Run scripts/sync-gmail.sh before trusting this archive.")

        # ---------------- 2. coverage ----------------
        missing = []
        if full:
            log("\n--- 2. Coverage (every Gmail Message-ID) ---")
            log("  Fetching all Message-IDs from Gmail (slow) ...")
            remote_ids = []
            CHUNK = 2000
            for start in range(1, remote_total + 1, CHUNK):
                end = min(start + CHUNK - 1, remote_total)
                typ, resp = M.fetch(
                    f"{start}:{end}", "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])"
                )
                if typ != "OK":
                    log(f"  ERROR fetching {start}:{end}")
                    continue
                for item in resp:
                    if isinstance(item, tuple) and len(item) > 1:
                        m = MSGID_RE.search(item[1])
                        if m:
                            remote_ids.append(
                                m.group(1).decode("utf-8", "replace").strip()
                            )
                log(f"    {min(end, remote_total)}/{remote_total}")
            missing = [i for i in remote_ids if i not in index]
            log(f"  Gmail Message-IDs read : {len(remote_ids)}")
            log(f"  Missing from archive   : {len(missing)}")
            for mid in missing[:20]:
                log(f"    {mid}")
            if len(missing) > 20:
                log(f"    ... and {len(missing) - 20} more")
            if not missing:
                log("  ALL PRESENT")
        else:
            log("\n--- 2. Coverage --- (skipped; set FULL=true to run)")

        # ---------------- 3. content ----------------
        log(f"\n--- 3. Content sample ({sample_size} messages) ---")
        if remote_total == 0:
            log("  nothing to sample")
            return 0

        picks = random.sample(
            range(1, remote_total + 1), min(sample_size, remote_total)
        )
        results = Counter()
        failures = []

        for n, seq in enumerate(sorted(picks), 1):
            typ, resp = M.fetch(str(seq), "(BODY.PEEK[])")
            if typ != "OK" or not resp or not isinstance(resp[0], tuple):
                results["fetch_failed"] += 1
                continue
            remote_msg = email.message_from_bytes(
                resp[0][1], policy=email.policy.default
            )
            mid = header(remote_msg, "Message-ID")

            if not mid:
                results["no_message_id"] += 1
                continue
            if mid not in index:
                results["MISSING"] += 1
                failures.append((mid, "not present in archive"))
                continue

            local_msg = parse_file(index[mid])

            problems = []
            for field in ("Subject", "From", "To", "Date"):
                r, l = header(remote_msg, field), header(local_msg, field)
                if r != l:
                    problems.append(f"{field}: gmail={r!r} archive={l!r}")

            r_body, r_atts = message_parts(remote_msg)
            l_body, l_atts = message_parts(local_msg)
            if r_body != l_body:
                problems.append(
                    f"body differs (gmail {len(r_body)} chars, "
                    f"archive {len(l_body)} chars)"
                )
            if r_atts != l_atts:
                problems.append(f"attachments differ: gmail={r_atts} archive={l_atts}")

            if problems:
                results["MISMATCH"] += 1
                failures.append((mid, "; ".join(problems)))
            else:
                results["ok"] += 1
                if r_atts:
                    results["ok_with_attachments"] += 1

            if n % 10 == 0:
                log(f"    checked {n}/{len(picks)}")

        log("")
        log(f"  identical            : {results['ok']}")
        log(f"    of which w/ attach : {results['ok_with_attachments']}")
        log(f"  mismatched           : {results['MISMATCH']}")
        log(f"  missing from archive : {results['MISSING']}")
        if results["no_message_id"]:
            log(f"  no Message-ID        : {results['no_message_id']} (skipped)")
        if results["fetch_failed"]:
            log(f"  fetch failed         : {results['fetch_failed']}")

        for mid, why in failures[:20]:
            log(f"\n  FAIL {mid}\n       {why}")

        log("\n" + "=" * 68)
        bad = results["MISMATCH"] + results["MISSING"] + len(missing)
        if bad == 0 and delta >= 0:
            log("PASS - no discrepancies found.")
            log("Remember this is a sample, not a proof. Re-run with a larger")
            log("SAMPLE_SIZE, and with FULL=true, before deleting from Gmail.")
            return 0
        log("FAIL - discrepancies found. Do NOT delete anything from Gmail.")
        return 1
    finally:
        try:
            M.close()
        except Exception:
            pass
        M.logout()


if __name__ == "__main__":
    sys.exit(main())
