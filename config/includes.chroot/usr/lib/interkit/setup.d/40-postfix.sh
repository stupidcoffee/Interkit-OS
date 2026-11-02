# interkit-setup module: postfix (full mail server: Postfix + OpenDKIM, TLS certificate from sing-box ACME)

mod_postfix_desc() { echo "Mail server (Postfix + DKIM, certificate from sing-box ACME)"; }

mod_postfix_status() {
  if [ -n "${MAIL_HOST:-}" ] && [ -f "$DEST/etc/postfix/main.cf" ]; then
    echo "  configured: ${MAIL_HOST} for ${MAIL_DOMAIN:-?}"
    have_systemd && echo "  postfix: $(systemctl is-active postfix 2>/dev/null)  opendkim: $(systemctl is-active opendkim 2>/dev/null)"
  else echo "  not configured"; fi
}

mod_postfix_run() {
  need jq
  require_domain
  info "Mail server (Postfix)"
  ask MAIL_DOMAIN "Mail domain (addresses look like user@DOMAIN)" "$BASE_DOMAIN"
  svc_mark mail
  ask DKIM_SELECTOR "DKIM selector" mail
  save_answer MAIL_DOMAIN MAIL_HOST DKIM_SELECTOR
  say "  Needs: inbound tcp 25, outbound tcp 25 NOT blocked by your provider, and a PTR (reverse DNS)"
  say "  record for this IP set to $MAIL_HOST at your hosting provider (Cloudflare cannot set PTR)."

  if [ "$IK_DRYRUN" != 1 ]; then
    printf 'postfix postfix/mailname string %s\npostfix postfix/main_mailer_type select Internet Site\n' "$MAIL_DOMAIN" | debconf-set-selections
  fi
  apt_install postfix opendkim opendkim-tools ssl-cert alpine

  acme_add "$MAIL_HOST"; info "adding $MAIL_HOST to the certificate list"; acme_write
  wait_cert "$MAIL_HOST" || warn "continuing without a certificate: TLS will not work until one exists"
  local cert="/var/lib/interkit/certs/$MAIL_HOST"

  info "writing Postfix configuration"
  pc() { if [ "$IK_DRYRUN" = 1 ]; then say "[dry-run] postconf -e $1"; else postconf -e "$1"; fi; }
  pc "myhostname = $MAIL_HOST"
  pc "mydomain = $MAIL_DOMAIN"
  pc 'myorigin = $mydomain'
  pc 'mydestination = $myhostname, localhost.$mydomain, localhost, $mydomain'
  pc 'inet_interfaces = all'
  pc 'mynetworks = 127.0.0.0/8 [::1]/128'
  pc 'smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination'
  pc 'smtpd_helo_required = yes'
  pc 'disable_vrfy_command = yes'
  pc 'home_mailbox ='   # empty = default mbox spool /var/mail/<user>; Debian's alpine cannot read Maildir
  pc "smtpd_tls_cert_file = $cert/fullchain.pem"
  pc "smtpd_tls_key_file = $cert/privkey.pem"
  pc 'smtpd_tls_security_level = may'
  pc 'smtp_tls_security_level = may'
  pc 'smtpd_tls_protocols = >=TLSv1.2'
  pc 'smtp_tls_protocols = >=TLSv1.2'
  pc 'smtpd_milters = inet:localhost:12301'
  pc 'non_smtpd_milters = $smtpd_milters'
  pc 'milter_default_action = accept'

  info "configuring Alpine (mail client)"
  mkdir -p "$DEST/etc"
  cat > "$DEST/etc/pine.conf" <<CONF
# managed by interkit-setup: system defaults for Alpine (users can override in ~/.pinerc)
smtp-server=localhost
user-domain=$MAIL_DOMAIN
CONF
  run chmod 644 "$DEST/etc/pine.conf"

  info "setting up DKIM (selector $DKIM_SELECTOR)"
  if [ "$IK_DRYRUN" != 1 ]; then
    install -d -o opendkim -g opendkim -m 0750 /etc/dkimkeys
    [ -f "/etc/dkimkeys/$DKIM_SELECTOR.private" ] || \
      opendkim-genkey -b 2048 -d "$MAIL_DOMAIN" -s "$DKIM_SELECTOR" -D /etc/dkimkeys
    chown opendkim:opendkim "/etc/dkimkeys/$DKIM_SELECTOR.private"; chmod 600 "/etc/dkimkeys/$DKIM_SELECTOR.private"
    sed -i '/^# BEGIN interkit/,/^# END interkit/d' /etc/opendkim.conf
    cat >> /etc/opendkim.conf <<EOF
# BEGIN interkit
Domain $MAIL_DOMAIN
Selector $DKIM_SELECTOR
KeyFile /etc/dkimkeys/$DKIM_SELECTOR.private
Socket inet:12301@localhost
Canonicalization relaxed/simple
# END interkit
EOF
    # Debian's /etc/default/opendkim may carry its own SOCKET; make sure it does not override ours
    [ -f /etc/default/opendkim ] && sed -i 's/^SOCKET=/#SOCKET=/' /etc/default/opendkim
    postfix check || warn "'postfix check' reported problems (see above)"
  fi
  svc enable opendkim; svc restart opendkim
  svc enable postfix; svc restart postfix

  dns_finish
  say "  Mail is delivered to /var/mail/<user> (one mbox per local user). Read and send it with: alpine"
  say "  (Debian's alpine cannot read Maildir, so Postfix uses the default mbox spool.) There is no IMAP server yet."
  say "  Test: send to a Gmail address and check 'Show original' for spf=pass dkim=pass."
}
