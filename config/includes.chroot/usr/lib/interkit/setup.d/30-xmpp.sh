# interkit-setup module: xmpp (Prosody, TLS certificate synced from sing-box ACME)

mod_xmpp_desc() { echo "XMPP server (Prosody, certificate from sing-box ACME)"; }

mod_xmpp_status() {
  if [ -f "$DEST/etc/prosody/conf.d/interkit.cfg.lua" ]; then
    echo "  configured: ${XMPP_DOMAIN:-?}"
    have_systemd && echo "  prosody: $(systemctl is-active prosody 2>/dev/null)"
  else echo "  not configured"; fi
}

mod_xmpp_run() {
  need jq
  require_domain
  info "XMPP (Prosody)"
  ask XMPP_DOMAIN "XMPP domain (the part after @ in user addresses)" "$CHAT_HOST"
  XMPP_HOST="$CHAT_HOST"; svc_mark chat
  if [ "$XMPP_DOMAIN" != "$CHAT_HOST" ] && [ "${ACME_CHALLENGE:-http}" = http ]; then
    warn "XMPP domain $XMPP_DOMAIN differs from $CHAT_HOST: its certificate needs an A record for $XMPP_DOMAIN pointing here (HTTP method). Using $CHAT_HOST as the XMPP domain avoids that."
  fi
  ask XMPP_ADMIN "Admin account name" admin
  save_answer XMPP_DOMAIN XMPP_HOST XMPP_ADMIN

  apt_install prosody ssl-cert   # ssl-cert provides the group that may read the TLS key
  acme_add "$XMPP_DOMAIN"; info "adding $XMPP_DOMAIN to the certificate list"; acme_write
  wait_cert "$XMPP_DOMAIN" || warn "continuing without a certificate: Prosody will not start until one exists"

  local cert="/var/lib/interkit/certs/$XMPP_DOMAIN"
  mkdir -p "$DEST/etc/prosody/conf.d"
  cat > "$DEST/etc/prosody/conf.d/interkit.cfg.lua" <<EOF
-- managed by interkit-setup (re-run 'interkit-setup xmpp' to regenerate)
admins = { "$XMPP_ADMIN@$XMPP_DOMAIN" }
c2s_require_encryption = true
s2s_require_encryption = true
s2s_secure_auth = true
allow_registration = false

VirtualHost "$XMPP_DOMAIN"
    ssl = {
        key = "$cert/privkey.pem";
        certificate = "$cert/fullchain.pem";
    }
EOF
  run chmod 644 "$DEST/etc/prosody/conf.d/interkit.cfg.lua"
  # let prosody read the key copied by interkit-certsync
  getent group ssl-cert >/dev/null 2>&1 && run usermod -aG ssl-cert prosody

  if [ "$IK_DRYRUN" != 1 ] && command -v prosodyctl >/dev/null 2>&1; then
    prosodyctl check config || warn "prosodyctl reported problems (see above)"
  fi
  svc enable prosody; svc restart prosody

  # admin account
  if [ "$IK_DRYRUN" != 1 ] && command -v prosodyctl >/dev/null 2>&1; then
    XMPP_ADMIN_PASSWORD="${XMPP_ADMIN_PASSWORD:-$(randpw 20)}"
    if prosodyctl register "$XMPP_ADMIN" "$XMPP_DOMAIN" "$XMPP_ADMIN_PASSWORD" 2>/dev/null; then
      put_secret xmpp-admin "$XMPP_ADMIN_PASSWORD"
      info "created $XMPP_ADMIN@$XMPP_DOMAIN (password stored in $IK_SECRETS/xmpp-admin.secret)"
    else
      say "  account $XMPP_ADMIN@$XMPP_DOMAIN already exists (change it with: prosodyctl passwd $XMPP_ADMIN@$XMPP_DOMAIN)"
    fi
  fi

  dns_finish
  say "  Open tcp 5222 (clients) and 5269 (other servers)."
}
