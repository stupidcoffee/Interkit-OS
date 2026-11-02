# interkit-setup module: derp (Tailscale DERP relay run by sing-box, TLS from sing-box ACME)

mod_derp_desc() { echo "DERP relay (sing-box 'derp' service, TLS from sing-box ACME)"; }

mod_derp_status() {
  [ -f "$SB_DIR/40-derp.json" ] && echo "  configured: host ${DERP_HOST:-?} tcp ${DERP_PORT:-?} stun udp ${DERP_STUN:-?}" || echo "  not configured"
}

mod_derp_run() {
  need jq
  require_domain
  info "DERP relay ($DERP_HOST)"
  ask DERP_PORT "TCP port (HTTPS)" 443
  ask DERP_STUN "STUN UDP port" 3478
  say "  A DERP relay must verify its clients, or anyone can relay traffic through your server."
  say "  Verification URL(s): sing-box calls these to admit a client (e.g. your tailscale/headscale verify endpoint)."
  ask_opt DERP_VERIFY_URL "Client verification URL (empty = OPEN RELAY, not recommended)"
  if [ -z "$DERP_VERIFY_URL" ]; then
    ask_opt DERP_OPEN_OK "Type 'open-relay' to confirm you want an unauthenticated relay"
    [ "$DERP_OPEN_OK" = open-relay ] || die "aborted: refusing to configure an open relay"
  fi
  save_answer DERP_PORT DERP_STUN DERP_VERIFY_URL; svc_mark derp

  acme_add "$DERP_HOST"; info "certificate list: $ACME_DOMAINS"; acme_write
  jq -n --arg host "$DERP_HOST" --argjson port "$DERP_PORT" --argjson stun "$DERP_STUN" \
        --arg key "$SB_DATA/derper.key" --arg v "$DERP_VERIFY_URL" '{
    services: [ ({
      type: "derp", listen: "::", listen_port: $port,
      tls: { enabled: true, server_name: $host, certificate_provider: "interkit-acme" },
      config_path: $key, home: "blank",
      stun: { enabled: true, listen_port: $stun }
    } + (if $v != "" then { verify_client_url: [ $v ] } else {} end)) ]
  }' | sb_write 40-derp.json
  say "  Open: tcp $DERP_PORT and udp $DERP_STUN. Point your Tailscale/headscale DERP map at $DERP_HOST."
  dns_finish
}
