<?php
// Custom Roundcube settings for the Gmail archive.
//
// The image's entrypoint includes every *.php in /var/roundcube/config/ at the
// END of config.docker.inc.php, so anything set here overrides what the
// ROUNDCUBEMAIL_* environment variables produced.

// ---------------------------------------------------------------------------
// This is an archive, not a mail client
// ---------------------------------------------------------------------------
// There is no MTA anywhere in this stack, so nothing can be sent. Rather than
// leave a Compose button that fails at the last step, remove the UI for it.
// Dovecot's ACL already refuses the underlying IMAP writes (see
// config/dovecot/acl-global) - this just stops the interface from offering
// actions that are guaranteed to fail.
$config['disabled_actions'] = [
    'mail.compose',
    'mail.reply',
    'mail.reply-all',
    'mail.forward',
    'mail.delete',
    'mail.move',
    'mail.copy',
    'mail.purge',
    'mail.expunge',
    'settings.identities',
    'settings.folders',
];

// No identities to manage and no address book worth keeping, so do not create
// per-user cruft in the SQLite database.
$config['address_book_type'] = '';

// ---------------------------------------------------------------------------
// Behind the home-portal Caddy
// ---------------------------------------------------------------------------
// Caddy terminates TLS and forwards over plain HTTP on the docker bridge.
// Without trusting the proxy, Roundcube sees an http:// request and can build
// wrong redirect URLs and refuse to set secure cookies.
// Populated from ROUNDCUBE_TRUSTED_PROXIES; the docker bridge gateway is the
// address Caddy's traffic actually arrives from.
$rc_proxies = getenv('ROUNDCUBE_TRUSTED_PROXIES');
if ($rc_proxies) {
    $config['proxy_whitelist'] = array_map('trim', explode(',', $rc_proxies));
}

// Reject requests with a forged Host header; only this name is served.
$rc_host = getenv('MAIL_HOSTNAME');
if ($rc_host) {
    $config['trusted_host_patterns'] = ['^' . preg_quote($rc_host, '/') . '$'];
}

// ---------------------------------------------------------------------------
// Connection to Dovecot
// ---------------------------------------------------------------------------
// Reached over the compose network using MAIL_HOSTNAME, which is a network
// alias on the dovecot service. That means the certificate lego issued for
// that name validates on this internal hop too - so peer verification stays
// on rather than being disabled with allow_self_signed.
$config['imap_conn_options'] = [
    'ssl' => [
        'verify_peer'      => true,
        'verify_peer_name' => true,
    ],
];

// The archive is one flat folder; showing it expanded by default saves a click.
$config['mail_read_time'] = 0;
