#!/bin/bash
# Obtain or renew the TLS certificate for MAIL_HOSTNAME using ACME DNS-01
# against Linode DNS, and reload Dovecot if the certificate changed.
#
# DNS-01 is what lets this work for a host that is not reachable from the
# internet: we prove control of the name by writing a TXT record, so
# MAIL_HOSTNAME can point at a private address (e.g. 10.8.0.22) and still get
# a publicly trusted certificate.
#
# Run by imap-archive-cert.timer. Safe to run by hand at any time; lego is a
# no-op unless the certificate is within 30 days of expiry (--days below).
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE=".env.bash"
[[ -f "$ENV_FILE" ]] || { echo "Error: $ENV_FILE not found." >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a

: "${MAIL_HOSTNAME:?not set in .env.bash}"
: "${ACME_EMAIL:?not set in .env.bash}"
: "${LINODE_TOKEN:?not set in .env.bash}"
: "${cert_dir:?not set in .env.bash}"

LEGO_DIR="$(pwd)/${local_mount_dir}/lego"
mkdir -p "$LEGO_DIR" "$cert_dir"

# lego stores its account key and certificate history here; losing it just
# means a new ACME account, but keeping it avoids re-registering every renewal.
BEFORE_SUM="$(sha256sum "${cert_dir}/tls.crt" 2>/dev/null | cut -d' ' -f1 || echo none)"

# lego v5 folded `renew` into `run`: it issues on first use and renews
# afterwards, so this one command is correct in both cases.
#
# --renew-days 30 makes it a no-op until the certificate is close to expiry,
# which is what makes it safe on a daily timer. (This flag was --days in
# lego v4; the v4 `renew` subcommand no longer exists. That is why
# LEGO_VERSION is pinned rather than tracking :latest.)
#
# --dns.resolvers pins propagation checks to 1.1.1.1 rather than the system
# resolver, matching the Caddyfile in ~/git/reverse-proxy.
docker run --rm \
  -v "${LEGO_DIR}:/data" \
  -e "LINODE_TOKEN=${LINODE_TOKEN}" \
  -e "LINODE_TTL=${LINODE_TTL:-30}" \
  -e "LINODE_PROPAGATION_TIMEOUT=${LINODE_PROPAGATION_TIMEOUT:-180}" \
  -e "LINODE_POLLING_INTERVAL=${LINODE_POLLING_INTERVAL:-15}" \
  "goacme/lego:v${LEGO_VERSION:?set LEGO_VERSION in .env.bash}" \
    run \
    --path /data \
    --accept-tos \
    --email "${ACME_EMAIL}" \
    --server "${ACME_CA:-https://acme-v02.api.letsencrypt.org/directory}" \
    --dns linode \
    --dns.resolvers 1.1.1.1:53 \
    --domains "${MAIL_HOSTNAME}" \
    --renew-days 30

# Publish under stable names, so the Dovecot config never has to know about
# lego's directory layout.
install -m 0644 "${LEGO_DIR}/certificates/${MAIL_HOSTNAME}.crt" "${cert_dir}/tls.crt"
install -m 0640 "${LEGO_DIR}/certificates/${MAIL_HOSTNAME}.key" "${cert_dir}/tls.key"

AFTER_SUM="$(sha256sum "${cert_dir}/tls.crt" | cut -d' ' -f1)"

if [[ "$BEFORE_SUM" != "$AFTER_SUM" ]]; then
  echo "Certificate changed; reloading Dovecot."
  # Dovecot caches the certificate at startup, so a renewal is not picked up
  # until it is told to re-read its config.
  if docker ps --format '{{.Names}}' | grep -qx imap_archive_dovecot; then
    docker exec imap_archive_dovecot doveadm reload
    echo "Dovecot reloaded."
  else
    echo "Dovecot is not running; it will pick up the new certificate on start."
  fi
else
  echo "Certificate unchanged; nothing to reload."
fi

echo "Expires: $(openssl x509 -enddate -noout -in "${cert_dir}/tls.crt" | cut -d= -f2)"
