# mbsync (isync) for pulling Gmail into the archive.
#
# There is no official isync image, and this is the component that handles the
# account credentials and writes the only copy of the mail - not somewhere to
# trust an unknown third-party image. It is three lines on top of Alpine.
ARG ALPINE_VERSION=3.21
FROM alpine:${ALPINE_VERSION}

# ca-certificates: needed to verify imap.gmail.com.
# tzdata: so Received/Date handling and log timestamps match TZ.
RUN apk add --no-cache isync ca-certificates tzdata \
    && update-ca-certificates

# Must match the uid/gid the CIFS mount presents and that Dovecot runs as
# (vmail = 1000:1000 in the dovecot image). Messages mbsync writes have to be
# readable and writable by Dovecot.
RUN adduser -D -u 1000 mbsync
USER 1000:1000

ENTRYPOINT ["mbsync"]
