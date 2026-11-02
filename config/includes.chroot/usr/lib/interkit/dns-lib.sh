# interkit-setup: DNS guide + verification. Provider-agnostic: the user copies records into ANY DNS provider,
# then `interkit-setup verify` checks them. (Sourced by setup-lib.sh.)

DNS_RESOLVER="${IK_DNS_RESOLVER:-1.1.1.1}"      # public resolver used for verification
DNS_GUIDE="$DEST/var/lib/interkit/dns-guide.txt"

_trace_ip() { curl -fsS"$1" --max-time 10 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p'; }
# the answer is only accepted if it really is an address of the requested family
public_ip4() {
  local v="${IK_PUBLIC_IP4:-}"; [ -n "$v" ] || v=$(_trace_ip 4)
  case "$v" in *[!0-9.]*|"") return 0;; *.*.*.*) echo "$v";; esac
}
public_ip6() {
  local v="${IK_PUBLIC_IP6:-}"; [ -n "$v" ] || v=$(_trace_ip 6)
  case "$v" in *:*) echo "$v";; esac
}
is_private_ip() { case "$1" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|127.*|169.254.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0;; esac; return 1; }

svc_mark() {   # svc_mark mail|chat|derp|web   -> remember which services are in use (drives the DNS records)
  case " ${ENABLED_SERVICES:-} " in *" $1 "*) ;; *) ENABLED_SERVICES="${ENABLED_SERVICES:+$ENABLED_SERVICES }$1"; save_answer ENABLED_SERVICES;; esac
}
has_svc() { case " ${ENABLED_SERVICES:-} " in *" $1 "*) return 0;; esac; return 1; }

dns_a_hosts() {  # hostnames that need an A/AAAA record pointing at this machine
  has_svc mail && echo "$MAIL_HOST"; has_svc chat && echo "$CHAT_HOST"
  has_svc derp && echo "$DERP_HOST"; has_svc web && echo "$WEB_HOST"
  return 0
}

# dns_records -> TYPE|NAME|VALUE|PRIORITY|WHY   (one per line)
dns_records() {
  local ip4 ip6 h dk sel="${DKIM_SELECTOR:-mail}"
  ip4=$(public_ip4); ip6=$(public_ip6)
  [ -n "$ip4$ip6" ] || ip4="<this machine's public IPv4>"
  for h in $(dns_a_hosts); do
    [ -n "$ip4" ] && echo "A|$h|$ip4||address of $h"
    [ -n "$ip6" ] && echo "AAAA|$h|$ip6||address of $h (IPv6)"
  done
  if has_svc mail; then
    echo "MX|$MAIL_DOMAIN|$MAIL_HOST|10|where mail for $MAIL_DOMAIN is delivered"
    echo "TXT|$MAIL_DOMAIN|v=spf1 mx -all||SPF: only this server may send mail for $MAIL_DOMAIN"
    echo "TXT|_dmarc.$MAIL_DOMAIN|v=DMARC1; p=none; rua=mailto:postmaster@$MAIL_DOMAIN||DMARC policy (start with p=none)"
    dk=""
    [ -f "$DEST/etc/dkimkeys/$sel.txt" ] && dk=$(tr -d '\n\t"' < "$DEST/etc/dkimkeys/$sel.txt" | sed -e 's/.*(\(.*\)).*/\1/' -e 's/[[:space:]]//g')
    echo "TXT|$sel._domainkey.$MAIL_DOMAIN|${dk:-<created when the mail module runs>}||DKIM public key (signs outgoing mail)"
  fi
  if has_svc chat && [ "${XMPP_DOMAIN:-$CHAT_HOST}" != "$CHAT_HOST" ]; then
    echo "SRV|_xmpp-client._tcp.$XMPP_DOMAIN|0 5 5222 $CHAT_HOST.|0|XMPP clients find the server"
    echo "SRV|_xmpp-server._tcp.$XMPP_DOMAIN|0 5 5269 $CHAT_HOST.|0|other XMPP servers find the server"
  fi
}

# dns_rel NAME -> what most DNS providers want in their "Name"/"Host" field: @ for the domain itself, else the part before it
dns_rel() {
  local n=${1%.}
  if [ "$n" = "$BASE_DOMAIN" ]; then echo @
  else case "$n" in *".$BASE_DOMAIN") echo "${n%."$BASE_DOMAIN"}";; *) echo "$n";; esac; fi
}
_f() { printf '      %-16s %s\n' "$1" "$2"; }
# dns_form: every record as a fill-in form with the exact fields of a DNS provider's "add record" screen
dns_form() {
  local i=0 t n v p w
  while IFS='|' read -r t n v p w; do
    [ -n "$t" ] || continue; i=$((i+1))
    echo "  [$i] $t record: $w"
    _f "Type:" "$t"
    _f "Name:" "$(dns_rel "$n")        (full name: $n)"
    case $t in
      A)    _f "IPv4 address:" "$v"; _f "Proxy:" "DNS only (grey cloud, not proxied)";;
      AAAA) _f "IPv6 address:" "$v"; _f "Proxy:" "DNS only (grey cloud, not proxied)";;
      MX)   _f "Mail server:" "$v"; _f "Priority:" "$p";;
      TXT)  _f "Content:" "$v"; _f "" "(type it without quotation marks; the provider adds them)";;
      SRV)  set -- $v; _f "Priority:" "$1"; _f "Weight:" "$2"; _f "Port:" "$3"; _f "Target:" "${4%.}";;
    esac
    _f "TTL:" "Auto (or 300)"
    echo
  done < <(dns_records)
}

dns_guide() {
  local ip4 ip6 line t n v p w
  has_svc mail || has_svc chat || has_svc derp || has_svc web || { warn "no services chosen yet; run the service modules first (or: interkit-setup all)"; }
  ip4=$(public_ip4)
  { echo "DNS records for ${BASE_DOMAIN:-your domain}"
    echo "Add these at your DNS provider (copy/paste), then run:  interkit-setup verify"
    echo "Use DNS-only records (if your provider has a proxy/CDN switch, turn it OFF)."
    echo
    echo "How to fill in each record (one \"Add record\" per entry below):"
    echo "  - Name: '@' means the domain itself. Type the short name; if your provider wants the full name, use the one in brackets."
    echo "  - TTL: choose Auto, or 300. Priority is only used for MX and SRV."
    echo "  - Do not add a dot at the end of a host name unless your provider asks for it."
    echo
    dns_form
    echo "Summary table:"
    printf '%-6s %-40s %-5s %s\n' TYPE NAME PRIO VALUE
    while IFS='|' read -r t n v p w; do [ -n "$t" ] || continue; printf '%-6s %-40s %-5s %s\n' "$t" "$n" "$p" "$v"; done < <(dns_records)
    echo
    echo "Zone-file format:"
    while IFS='|' read -r t n v p w; do [ -n "$t" ] || continue
      case $t in MX) echo "$n. 300 IN MX $p $v.";; TXT) echo "$n. 300 IN TXT \"$v\"";; SRV) echo "$n. 300 IN SRV $v";; *) echo "$n. 300 IN $t $v";; esac
    done < <(dns_records)
    if has_svc mail; then echo; echo "Reverse DNS (PTR): ask your hosting provider to set the PTR of ${ip4:-your IP} to $MAIL_HOST (a DNS provider cannot do this)."; fi
    if [ -n "$ip4" ] && is_private_ip "$ip4"; then echo; echo "WARNING: $ip4 is a private address. This machine is behind NAT: forward the needed ports to it and use your public IP in the records."; fi
    echo; echo "Ports to open: $(dns_ports)"
    echo; echo "Reading this on the server's screen? Open it on your own computer instead (so you can copy and paste):"
    echo "  ssh <user>@<this-machine-IP>  then:  cat /var/lib/interkit/dns-guide.txt"
    if has_svc web && [ -f "$DEST/etc/systemd/system/interkit-fossil-web.service.d/10-https.conf" ]; then
      echo "  or in your browser: https://${WEB_HOST}:${WEB_PORT:-8443}/  -> wiki page \"DNS setup\""
    else
      echo "  or in your browser: http://<this-machine-IP>:8080/  -> wiki page \"DNS setup\"  (plain http: use a trusted network)"
    fi
    echo "  Log in as admin; the password is in /root/fossil-admin-password (sudo cat /root/fossil-admin-password)."
  } | tee_guide
}
tee_guide() {  # print, save to a file, and publish as a Fossil wiki page (admin login) when the repo exists
  local txt; txt=$(cat); printf '%s\n' "$txt"
  mkdir -p "$(dirname "$DNS_GUIDE")"; printf '%s\n' "$txt" > "$DNS_GUIDE"
  fossil_wiki_publish "DNS setup" "$txt" || true
}
dns_ports() {
  local p=""; has_svc web && p="$p tcp/${WEB_PORT:-8443}"; has_svc derp && p="$p tcp/${DERP_PORT:-443} udp/${DERP_STUN:-3478}"
  has_svc chat && p="$p tcp/5222 tcp/5269"; has_svc mail && p="$p tcp/25"
  [ "${ACME_CHALLENGE:-http}" = http ] && p="$p tcp/80(certificates)"; echo "${p:-none yet}"
}
fossil_wiki_publish() {  # fossil_wiki_publish TITLE TEXT   (Fossil wiki, visible after logging in as admin)
  local title=$1 body=$2 repo="$DEST/var/lib/fossil/config.fossil" f
  [ "$IK_DRYRUN" = 1 ] && return 0
  [ -f "$repo" ] && command -v fossil >/dev/null 2>&1 || return 1
  f=$(mktemp); printf '<h1>%s</h1>\n<verbatim>\n%s\n</verbatim>\n' "$title" "$body" > "$f"; chmod 644 "$f"
  local fx=(runuser -u fossil -- env HOME=/var/lib/fossil FOSSIL_USER=admin fossil)
  if "${fx[@]}" wiki list -R "$repo" 2>/dev/null | grep -qx "$title"; then "${fx[@]}" wiki commit "$title" "$f" -R "$repo" >/dev/null 2>&1
  else "${fx[@]}" wiki create "$title" "$f" -R "$repo" >/dev/null 2>&1; fi
  local rc=$?; rm -f "$f"; return $rc
}

# ---- verification ----------------------------------------------------------------------------
_dig() { dig +short +time=4 +tries=2 "$@" @"$DNS_RESOLVER" 2>/dev/null; }
_norm() { tr -d ' "\n\t'; }
dns_verify() {
  local bad=0 t n v p w got ip4 want ok
  command -v dig >/dev/null 2>&1 || die "'dig' is required (apt install bind9-dnsutils)"
  info "checking DNS via $DNS_RESOLVER ..."
  while IFS='|' read -r t n v p w; do
    [ -n "$t" ] || continue
    case "$v" in "<"*) printf '  %-5s %-38s ? %s\n' "$t" "$n" "$v"; continue;; esac
    got=$(_dig "$t" "$n")
    case $t in
      A|AAAA) want="$v";    echo "$got" | grep -qx -- "$want" && ok=1 || ok=0;;
      MX)     want="$p $v."; echo "$got" | grep -qi -x -- "$want" && ok=1 || ok=0;;
      SRV)    want="$v";    echo "$got" | grep -qi -x -- "$want" && ok=1 || ok=0;;
      TXT)    want=$(printf '%s' "$v" | _norm); if printf '%s' "$got" | _norm | grep -q -F -- "$want"; then ok=1; else ok=0; fi;;
      *)      ok=0;;
    esac
    if [ "$ok" = 1 ]; then printf '  %sOK%s   %-5s %s\n' "$c_g" "$c_0" "$t" "$n"; else printf '  %sMISSING%s %-5s %s   (expected: %s)\n' "$c_r" "$c_0" "$t" "$n" "$v"; bad=$((bad+1)); fi
  done < <(dns_records)
  if has_svc mail; then
    ip4=$(public_ip4)
    if [ -n "$ip4" ]; then
      got=$(_dig -x "$ip4" | head -n1)
      if [ "${got%.}" = "$MAIL_HOST" ]; then printf '  %sOK%s   PTR   %s -> %s\n' "$c_g" "$c_0" "$ip4" "$MAIL_HOST"; else printf '  %swarn%s PTR   %s -> %s (should be %s; set at your hosting provider)\n' "$c_y" "$c_0" "$ip4" "${got:-nothing}" "$MAIL_HOST"; fi
    fi
    if timeout 6 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null; then printf '  %sOK%s   outbound port 25 is open\n' "$c_g" "$c_0"; else printf '  %swarn%s outbound port 25 looks blocked by your provider (mail to other servers will fail)\n' "$c_y" "$c_0"; fi
  fi
  if [ "$bad" = 0 ]; then info "all records found"; else warn "$bad record(s) missing or wrong. DNS can take a few minutes to propagate; fix them and run 'interkit-setup verify' again."; fi
  return "$bad"
}

# hosts_resolve_here "host host ..."  -> 0 if every host's A record points at this machine (needed before an HTTP challenge)
hosts_resolve_here() {
  local h ip4 got bad=0
  command -v dig >/dev/null 2>&1 || { warn "dig missing: cannot check DNS before requesting certificates"; return 0; }
  ip4=$(public_ip4); [ -n "$ip4" ] || { warn "could not determine this machine's public IP"; return 0; }
  for h in $1; do
    got=$(_dig A "$h")
    if ! echo "$got" | grep -qx -- "$ip4"; then warn "$h does not resolve to $ip4 yet (found: ${got:-nothing})"; bad=1; fi
  done
  return $bad
}

# dns_sync: create/update every record through the Cloudflare API (only when the optional cloudflare module is set up)
dns_sync() {
  local zid t n v p w
  have_secret cloudflare || return 1
  zid=$(cf_zone_id "${CF_ZONE:-$BASE_DOMAIN}"); [ -n "$zid" ] || { warn "Cloudflare zone ${CF_ZONE:-$BASE_DOMAIN} not found; add the records by hand (interkit-setup dns)"; return 1; }
  while IFS='|' read -r t n v p w; do
    [ -n "$t" ] || continue
    case "$v" in "<"*) continue;; esac
    case $t in
      A|AAAA) cf_rec "$zid" "$t" "$n" "$v";;
      MX)     cf_rec_safe "$zid" MX "$n" "$v" "$p";;
      TXT)    cf_rec_safe "$zid" TXT "$n" "$v";;
      SRV)    set -- $v; cf_srv "$zid" "$n" "$3" "${4%.}";;
    esac
  done < <(dns_records)
}
# dns_finish: end of every service module
dns_finish() {
  if [ "${ACME_CHALLENGE:-http}" = dns-cloudflare ] && have_secret cloudflare; then
    if dns_sync; then info "DNS records created through the Cloudflare API (an existing MX/SPF/DMARC/DKIM record is never overwritten)"; fi
  else
    say "  Next: add the DNS records at your DNS provider:  interkit-setup dns     then check them:  interkit-setup verify"
  fi
}
