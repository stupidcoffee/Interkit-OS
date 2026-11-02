# interkit-setup module: cloudflare (OPTIONAL: API automation for DNS records, dynamic DNS, DNS-challenge certificates, tunnel)

mod_cloudflare_desc() { echo "Optional: Cloudflare API (auto DNS records, no open port 80, tunnel)"; }

mod_cloudflare_status() {
  have_secret cloudflare && echo "  api token: stored (certificate method: ${ACME_CHALLENGE:-http})" || echo "  not used (certificates by HTTP challenge; DNS records added by hand)"
  [ -f "$SB_DIR/30-cloudflared.secret.json" ] && echo "  tunnel: configured" || echo "  tunnel: not configured"
  have_systemd && echo "  ddns timer: $(systemctl is-active interkit-ddns.timer 2>/dev/null)"
}

mod_cloudflare_run() {
  need jq; need curl
  require_domain
  info "Cloudflare (optional automation)"
  say "  API token needs: Zone:DNS:Edit and Zone:Zone:Read for your zone (https://dash.cloudflare.com/profile/api-tokens)."
  ask CF_ZONE "Cloudflare DNS zone" "$BASE_DOMAIN"
  ask_secret CF_API_TOKEN cloudflare "Cloudflare API token"
  yesno DDNS_ENABLE "Keep these hosts pointed at this machine's public IP (dynamic DNS)?" y
  ask_secret_opt CF_TUNNEL_TOKEN cloudflared "Cloudflare Tunnel token (Zero Trust > Networks > Tunnels)"
  ACME_CHALLENGE=dns-cloudflare
  save_answer CF_ZONE DDNS_ENABLE ACME_CHALLENGE

  # certificates now use the DNS challenge: no open port 80, and no waiting for DNS first
  if [ -n "${ACME_DOMAINS:-}" ]; then info "switching certificates to the DNS challenge"; acme_write; fi
  svc enable interkit-certsync.timer

  if [ "$DDNS_ENABLE" = y ]; then
    if [ "$IK_DRYRUN" != 1 ]; then /usr/local/sbin/interkit-ddns || warn "first DDNS update failed (see: journalctl -u interkit-ddns)"; fi
    svc enable interkit-ddns.timer
  fi
  dns_sync && info "DNS records created for the services chosen so far"

  if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
    if [ "$IK_DRYRUN" != 1 ]; then   # a tunnel token is base64-encoded JSON; catch typos before sing-box does
      printf '%s' "$CF_TUNNEL_TOKEN" | base64 -d 2>/dev/null | jq -e . >/dev/null 2>&1 \
        || die "that does not look like a Cloudflare Tunnel token (expected the long base64 string from the dashboard)"
    fi
    info "configuring the Cloudflare Tunnel (sing-box 'cloudflared' inbound)"
    IK_TOK="$CF_TUNNEL_TOKEN" jq -n '{inbounds:[{type:"cloudflared",tag:"cloudflared",token:env.IK_TOK}]}' | sb_write 30-cloudflared.secret.json
    say "  Add public hostnames to the tunnel in the Cloudflare dashboard, e.g. -> http://127.0.0.1:8080 (tunnel traffic goes through sing-box routing)"
  fi
}
