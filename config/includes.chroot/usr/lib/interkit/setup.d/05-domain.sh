# interkit-setup module: domain (base domain, hostnames, certificate method, DNS guide)

mod_domain_desc() { echo "Your domain, hostnames and certificate method (start here)"; }

mod_domain_status() {
  echo "  domain: ${BASE_DOMAIN:-<not set>}   certificates: ${ACME_CHALLENGE:-http}${ACME_PENDING:+ (waiting for DNS)}"
  [ -n "${BASE_DOMAIN:-}" ] && echo "  hosts: mail=${MAIL_HOST:-mail.$BASE_DOMAIN} chat=${CHAT_HOST:-chat.$BASE_DOMAIN} derp=${DERP_HOST:-derp.$BASE_DOMAIN} web=${WEB_HOST:-fossil.$BASE_DOMAIN}"
  echo "  services: ${ENABLED_SERVICES:-<none yet>}"
}

mod_domain_run() {
  info "Domain"
  say "  All TLS certificates come from sing-box's ACME (Let's Encrypt). Use your own domain; the host names below"
  say "  are defaults you can change (e.g. mail.xxx.com, chat.xxx.com)."
  ask BASE_DOMAIN "Your domain name (for example: example.com)"
  ask ACME_EMAIL "E-mail for Let's Encrypt notices" "admin@$BASE_DOMAIN"
  ask MAIL_HOST "Mail server host name" "mail.$BASE_DOMAIN"
  ask CHAT_HOST "Chat (XMPP) host name" "chat.$BASE_DOMAIN"
  ask DERP_HOST "DERP relay host name" "derp.$BASE_DOMAIN"
  ask WEB_HOST  "Admin web (Fossil) host name" "fossil.$BASE_DOMAIN"
  say "  Certificate method:  http  = no API keys; needs port 80 open and each host's DNS record in place (default)"
  say "                       dns-cloudflare = Cloudflare API token; no open port, records can be created for you"
  ask ACME_CHALLENGE "Certificate method" http
  case "$ACME_CHALLENGE" in http|dns-cloudflare) ;; *) die "certificate method must be 'http' or 'dns-cloudflare'";; esac
  save_answer BASE_DOMAIN ACME_EMAIL MAIL_HOST CHAT_HOST DERP_HOST WEB_HOST ACME_CHALLENGE
  if [ "$ACME_CHALLENGE" = dns-cloudflare ] && ! have_secret cloudflare; then
    say "  Next: interkit-setup cloudflare   (stores your API token)"
  fi
  say "  Next: choose services (web, derp, xmpp, postfix), then: interkit-setup dns   and   interkit-setup verify"
}
