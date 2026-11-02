# interkit-setup module: web (the Fossil admin web UI over HTTPS, certificate from sing-box ACME)

mod_web_desc() { echo "Admin web UI (Fossil) over HTTPS"; }

mod_web_status() {
  if [ -f "$DEST/etc/systemd/system/interkit-fossil-web.service.d/10-https.conf" ]; then echo "  https: https://${WEB_HOST:-?}:${WEB_PORT:-8443}/"
    have_systemd && echo "  fossil-web: $(systemctl is-active interkit-fossil-web 2>/dev/null)"
  else echo "  plain http on :8080 (not configured for https)"; fi
}

mod_web_run() {
  need jq
  require_domain
  info "Admin web UI (Fossil) over HTTPS"
  ask WEB_PORT "HTTPS port" 8443
  save_answer WEB_PORT; svc_mark web
  apt_install ssl-cert
  acme_add "$WEB_HOST"; info "certificate list: $ACME_DOMAINS"; acme_write
  wait_cert "$WEB_HOST" || warn "continuing: the web UI stays on plain http (:8080) until the certificate exists; re-run this module then"
  local cert="/var/lib/interkit/certs/$WEB_HOST"
  if [ "$IK_DRYRUN" = 1 ] || [ -s "$IK_CERTS/$WEB_HOST/fullchain.pem" ]; then
    local d="$DEST/etc/systemd/system/interkit-fossil-web.service.d"; mkdir -p "$d"
    cat > "$d/10-https.conf" <<EOF
# managed by interkit-setup: serve the Fossil web UI over HTTPS with the sing-box ACME certificate
[Service]
ExecStart=
ExecStart=/usr/bin/fossil server /var/lib/fossil --repolist --skin /usr/share/interkit/fossil-skin --port $WEB_PORT --cert $cert/fullchain.pem --pkey $cert/privkey.pem
SupplementaryGroups=ssl-cert
EOF
    run systemctl daemon-reload
    svc restart interkit-fossil-web
    say "  Web UI: https://$WEB_HOST:$WEB_PORT/   (plain http on :8080 is now off). Open tcp $WEB_PORT."
  fi
}
