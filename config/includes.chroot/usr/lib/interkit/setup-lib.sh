#!/bin/bash
# interkit-setup shared helpers. Sourced by interkit-setup, its modules and helper scripts.
#
# Test / dry-run:  DEST=/some/dir  prefixes every file the tool writes;
#                  IK_DRYRUN=1     skips apt, systemctl and network calls.
#                  IK_QUIET=1      never prompts (answers come from the environment / answer file / defaults).

DEST="${DEST:-}"
IK_DIR="$DEST/etc/interkit"
IK_CONF="$IK_DIR/setup.conf"
IK_SECRETS="$IK_DIR/secrets"
IK_CERTS="$DEST/var/lib/interkit/certs"
SB_DIR="$DEST/etc/sing-box"
SB_DATA="/var/lib/sing-box"          # path as seen by the sing-box service
IK_DRYRUN="${IK_DRYRUN:-0}"
IK_QUIET="${IK_QUIET:-0}"

c_b=$'\e[1m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_g=$'\e[32m'; c_0=$'\e[0m'
say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%swarning:%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }
run()  { if [ "$IK_DRYRUN" = 1 ]; then say "[dry-run] $*"; else "$@"; fi; }

# ---- prompting -------------------------------------------------------------------------------
# ask VAR "Prompt" [default]    value comes from $VAR if already set, else prompt (required)
ask() {
  local var=$1 prompt=$2 def=${3:-} reply
  [ -n "${!var:-}" ] && return 0
  if [ "$IK_QUIET" = 1 ]; then
    [ -n "$def" ] || die "missing answer: $var (non-interactive mode)"
    printf -v "$var" '%s' "$def"; return 0
  fi
  read -r -p "$prompt${def:+ [$def]}: " reply
  printf -v "$var" '%s' "${reply:-$def}"
  [ -n "${!var}" ] || die "$var is required"
}
# ask_opt VAR "Prompt" [default]   like ask, but an empty answer is fine
ask_opt() {
  local var=$1 prompt=$2 def=${3:-} reply
  [ -n "${!var:-}" ] && return 0
  if [ "$IK_QUIET" = 1 ]; then printf -v "$var" '%s' "$def"; return 0; fi
  read -r -p "$prompt${def:+ [$def]}: " reply
  printf -v "$var" '%s' "${reply:-$def}"
}
# yesno VAR "Prompt" y|n    sets VAR to y or n
yesno() {
  local var=$1 prompt=$2 def=${3:-n} reply
  case "${!var:-}" in y|Y|yes) printf -v "$var" y; return 0;; n|N|no) printf -v "$var" n; return 0;; esac
  if [ "$IK_QUIET" = 1 ]; then printf -v "$var" '%s' "$def"; return 0; fi
  read -r -p "$prompt [$def]: " reply; reply=${reply:-$def}
  case "$reply" in y|Y|yes) printf -v "$var" y;; *) printf -v "$var" n;; esac
}

# randpw N  -> N random alphanumeric characters; aborts if that fails (never returns an empty secret)
randpw() {
  local v; v=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$1")
  [ "${#v}" = "$1" ] || die "could not generate a random value"
  printf '%s' "$v"
}

# ---- answers & secrets -----------------------------------------------------------------------
save_answer() {  # save_answer VAR...   (non-secret answers only)
  local v; mkdir -p "$IK_DIR"; touch "$IK_CONF"
  for v in "$@"; do
    grep -v "^$v=" "$IK_CONF" > "$IK_CONF.tmp" 2>/dev/null || true
    printf '%s=%q\n' "$v" "${!v}" >> "$IK_CONF.tmp"
    mv "$IK_CONF.tmp" "$IK_CONF"
  done
  chmod 644 "$IK_CONF"
}
put_secret() {   # put_secret NAME VALUE
  ( umask 077; mkdir -p "$IK_SECRETS"; printf '%s' "$2" > "$IK_SECRETS/$1.secret" )
  chmod 700 "$IK_SECRETS"; chmod 600 "$IK_SECRETS/$1.secret"
}
get_secret() { cat "$IK_SECRETS/$1.secret" 2>/dev/null; }
have_secret() { [ -s "$IK_SECRETS/$1.secret" ]; }
# _read_secret VAR "Prompt" [opt]   hidden input for API keys on a console with no clipboard:
#   - "@/path/to/file" reads the value from a file (first line), e.g. on a USB stick mounted with `mount /dev/sdb1 /mnt`
#   - after typing it shows the length and the last 4 characters so a typo is caught before it is saved
#   - with "opt", an empty answer returns 1 (skipped)
_read_secret() {
  local var=$1 prompt=$2 opt=${3:-} reply f ok tail=""
  if [ -z "${IK_SECRET_HINT:-}" ]; then
    IK_SECRET_HINT=1
    say "  No copy/paste on this screen? Either type the key (hidden), or enter  @/path/to/file  to read it from a file"
    say "  (for example on a USB stick), or run interkit-setup over SSH from your own computer, where you can paste."
  fi
  while :; do
    read -r -s -p "$prompt${opt:+ (empty to skip)}: " reply || die "no input (is this a terminal?)"; echo
    if [ -z "$reply" ]; then [ -n "$opt" ] && return 1; warn "an answer is required"; continue; fi
    case "$reply" in
      @*) f=${reply#@}
          [ -r "$f" ] || { warn "cannot read $f"; continue; }
          reply=$(head -n1 "$f" | tr -d '\r\n ') ;;
    esac
    [ -n "$reply" ] || { warn "that was empty"; continue; }
    [ "${#reply}" -ge 12 ] && tail=", ending in ...${reply: -4}"
    read -r -p "  got ${#reply} characters$tail. Correct? [Y/n] " ok
    case "$ok" in n|N|no) continue;; esac
    printf -v "$var" '%s' "$reply"; return 0
  done
}
# ask_secret VAR NAME "Prompt"   -> VAR from env, else stored secret NAME, else prompt (hidden)
ask_secret() {
  local var=$1 name=$2 prompt=$3
  if [ -n "${!var:-}" ]; then put_secret "$name" "${!var}"; return 0; fi
  if have_secret "$name"; then printf -v "$var" '%s' "$(get_secret "$name")"; return 0; fi
  [ "$IK_QUIET" = 1 ] && die "missing secret: $var (non-interactive mode)"
  _read_secret "$var" "$prompt"
  put_secret "$name" "${!var}"
}
# ask_secret_opt VAR NAME "Prompt"  -> like ask_secret but empty is allowed (VAR stays empty)
ask_secret_opt() {
  local var=$1 name=$2 prompt=$3
  if [ -n "${!var:-}" ]; then put_secret "$name" "${!var}"; return 0; fi
  if have_secret "$name"; then printf -v "$var" '%s' "$(get_secret "$name")"; return 0; fi
  [ "$IK_QUIET" = 1 ] && return 0
  _read_secret "$var" "$prompt" opt && put_secret "$name" "${!var}"
  return 0
}

# ---- system helpers --------------------------------------------------------------------------
have_systemd() { [ -d /run/systemd/system ]; }
svc() {  # svc enable|restart|reload|stop UNIT...
  local a=$1; shift
  if [ "$IK_DRYRUN" = 1 ]; then say "[dry-run] systemctl $a $*"; return 0; fi
  have_systemd || { warn "systemd is not running: skipped 'systemctl $a $*'"; return 0; }
  case $a in enable) systemctl enable --now "$@";; *) systemctl "$a" "$@";; esac
}
apt_install() {
  if [ "$IK_DRYRUN" = 1 ]; then say "[dry-run] apt-get install -y $*"; return 0; fi
  if [ -z "${IK_APT_UPDATED:-}" ]; then DEBIAN_FRONTEND=noninteractive apt-get update -qq; IK_APT_UPDATED=1; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"; }

# ---- Cloudflare API --------------------------------------------------------------------------
CF_API=https://api.cloudflare.com/client/v4
cf() {  # cf METHOD PATH [json-body]
  local m=$1 p=$2 d=${3:-}
  if [ "$IK_DRYRUN" = 1 ]; then say "[dry-run] cloudflare $m $p ${d:+$d}" >&2; echo '{"success":true,"result":[{"id":"dryrun"}]}'; return 0; fi
  have_secret cloudflare || die "no Cloudflare API token stored (run: interkit-setup cloudflare)"
  # the token goes through a process-substitution header file so it never appears in `ps`
  if [ -n "$d" ]; then
    curl -fsS -X "$m" "$CF_API$p" -H @<(printf 'Authorization: Bearer %s\n' "$(get_secret cloudflare)") \
      -H 'Content-Type: application/json' --data "$d"
  else
    curl -fsS -X "$m" "$CF_API$p" -H @<(printf 'Authorization: Bearer %s\n' "$(get_secret cloudflare)") \
      -H 'Content-Type: application/json'
  fi
}
cf_zone_id() { cf GET "/zones?name=$1" | jq -r '.result[0].id // empty'; }
# cf_upsert ZONE_ID TYPE NAME BODY_JSON    create the record, or update it if type+name already exists
cf_upsert() {
  local z=$1 t=$2 n=$3 body=$4 id
  id=$(cf GET "/zones/$z/dns_records?type=$t&name=$n" | jq -r '.result[0].id // empty')
  if [ -n "$id" ]; then cf PUT "/zones/$z/dns_records/$id" "$body" >/dev/null
  else cf POST "/zones/$z/dns_records" "$body" >/dev/null; fi
}
cf_rec() {  # cf_rec ZONE_ID TYPE NAME CONTENT [PRIORITY]  -> simple records (A, AAAA, TXT, MX, CNAME); never proxied
  local z=$1 t=$2 n=$3 c=$4 p=${5:-}
  cf_upsert "$z" "$t" "$n" "$(jq -nc --arg t "$t" --arg n "$n" --arg c "$c" --arg p "$p" \
    '{type:$t,name:$n,content:$c,ttl:1} + (if $t=="A" or $t=="AAAA" or $t=="CNAME" then {proxied:false} else {} end) + (if $p!="" then {priority:($p|tonumber)} else {} end)')"
}
# cf_rec_safe ZONE_ID TYPE NAME CONTENT [PRIORITY]   for MX and policy TXT records (SPF, DMARC, DKIM):
# never overwrites an existing record that differs; warns and skips instead, so existing mail keeps working.
cf_rec_safe() {
  local z=$1 t=$2 n=$3 c=$4 p=${5:-} existing pre
  existing=$(cf GET "/zones/$z/dns_records?type=$t&name=$n" | jq -c '.result // []')
  if [ "$IK_DRYRUN" = 1 ]; then existing='[]'; fi
  if [ "$(printf '%s' "$existing" | jq 'length')" = 0 ]; then cf_rec "$z" "$t" "$n" "$c" "$p"; return 0; fi
  if [ "$t" = MX ]; then
    if printf '%s' "$existing" | jq -e --arg c "$c" 'map(select(.content==$c))|length>0' >/dev/null; then return 0; fi
    warn "MX records already exist for $n and none points to $c: not replacing them. Update the MX by hand."
    return 0
  fi
  # TXT: same content = done; same policy prefix but different content = do not clobber; unrelated TXT coexists
  pre=$(printf '%s' "$c" | sed -n 's/^\(v=[A-Za-z0-9]*\).*/\1/p')
  if printf '%s' "$existing" | jq -e --arg c "$c" 'map(select(.content==$c))|length>0' >/dev/null; then return 0; fi
  if [ -n "$pre" ] && printf '%s' "$existing" | jq -e --arg p "$pre" 'map(select(.content|startswith($p)))|length>0' >/dev/null; then
    warn "a $pre TXT record already exists at $n with different content: not replacing it. Merge it by hand: $c"
    return 0
  fi
  cf POST "/zones/$z/dns_records" "$(jq -nc --arg t "$t" --arg n "$n" --arg c "$c" '{type:$t,name:$n,content:$c,ttl:1}')" >/dev/null
}

cf_srv() {  # cf_srv ZONE_ID NAME PORT TARGET
  cf_upsert "$1" SRV "$2" "$(jq -nc --arg n "$2" --argjson port "$3" --arg tg "$4" \
    '{type:"SRV",name:$n,ttl:1,data:{priority:0,weight:5,port:$port,target:$tg}}')"
}

# ---- sing-box config fragments ---------------------------------------------------------------
# The packaged service runs `sing-box -C /etc/sing-box`, which merges every *.json there.
# Fragments with secrets are named *.secret.json (git/fossil-ignored, 0640 root:sing-box).
sb_write() {  # sb_write NAME   (JSON on stdin) -- validates the merged config, restarts, rolls back on failure
  local f="$SB_DIR/$1" tmp
  mkdir -p "$SB_DIR"; tmp=$(mktemp)
  # the directory is readable only by root and the sing-box service user
  getent group sing-box >/dev/null 2>&1 && { chgrp sing-box "$SB_DIR"; chmod 0750 "$SB_DIR"; }
  cat > "$tmp"
  jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; die "generated invalid JSON for $1"; }
  [ -f "$f" ] && cp -a "$f" "$f.prev"
  install -m 0640 -g sing-box "$tmp" "$f" 2>/dev/null || install -m 0640 "$tmp" "$f"
  rm -f "$tmp"
  if [ "$IK_DRYRUN" != 1 ] && command -v sing-box >/dev/null 2>&1; then
    if ! sing-box -D /tmp check -C "$SB_DIR"; then
      if [ -f "$f.prev" ]; then mv "$f.prev" "$f"; else rm -f "$f"; fi
      die "sing-box rejected $1 (change rolled back)"
    fi
  else
    warn "sing-box config check skipped"
  fi
  rm -f "$f.prev"
  svc restart sing-box
}

# acme_write: (re)generate the ACME certificate provider for every host in $ACME_DOMAINS.
#   ACME_CHALLENGE=http            (default) HTTP-01 on port 80: no API keys, but each host's A record must already point here
#   ACME_CHALLENGE=dns-cloudflare  DNS-01 through the Cloudflare API: no open port, needs the token (module: cloudflare)
# sing-box only manages a certificate provider that something references, so a loopback-only Trojan inbound
# (random password, never used by anyone) references it as an "anchor". (A 'direct' inbound has no tls support.)
acme_write() {
  local doms anchor_pw tok="" challenge="${ACME_CHALLENGE:-http}"
  [ -n "${ACME_DOMAINS:-}" ] || die "no certificate hostnames configured"
  if [ "$challenge" = dns-cloudflare ]; then
    tok=$(get_secret cloudflare) || true
    [ -n "$tok" ] || [ "$IK_DRYRUN" = 1 ] || die "Cloudflare token missing"
  elif [ "$IK_DRYRUN" != 1 ] && [ "${IK_SKIP_DNS_CHECK:-0}" != 1 ]; then
    # Let's Encrypt limits failed validations, so only ask once DNS points here
    if ! hosts_resolve_here "$ACME_DOMAINS"; then
      ACME_PENDING=1; save_answer ACME_PENDING
      warn "certificates NOT requested yet: DNS is not ready. Add the records (interkit-setup dns), then run: interkit-setup verify"
      return 0
    fi
  fi
  ACME_PENDING=""; save_answer ACME_PENDING
  have_secret anchor || put_secret anchor "$(randpw 32)"
  anchor_pw=$(get_secret anchor)
  doms=$(printf '%s\n' $ACME_DOMAINS | jq -R . | jq -sc .)
  # secrets go to jq through the environment, not argv (argv is visible to every user in `ps`)
  IK_TOK="${tok:-DRYRUN}" IK_PW="$anchor_pw" jq -n --argjson d "$doms" --arg email "${ACME_EMAIL:-}" --arg mode "$challenge" \
        --arg host "${ACME_DOMAINS%% *}" --arg dd "$SB_DATA/certmagic" '
    ( { type: "acme", tag: "interkit-acme", domain: $d, data_directory: $dd, email: $email, provider: "letsencrypt" }
      + ( if $mode == "dns-cloudflare" then { dns01_challenge: { provider: "cloudflare", api_token: env.IK_TOK } }
          else { disable_tls_alpn_challenge: true } end ) ) as $prov
    | { certificate_providers: [ $prov ],
        inbounds: [ { type: "trojan", tag: "interkit-cert-anchor", listen: "127.0.0.1", listen_port: 18443,
                      users: [ { name: "anchor", password: env.IK_PW } ],
                      tls: { enabled: true, server_name: $host, certificate_provider: "interkit-acme" } } ] }' \
    | sb_write 20-acme.secret.json
}
acme_add() {  # acme_add HOST...   add hostnames to the certificate list (and save)
  local h
  for h in "$@"; do
    case " ${ACME_DOMAINS:-} " in *" $h "*) ;; *) ACME_DOMAINS="${ACME_DOMAINS:+$ACME_DOMAINS }$h";; esac
  done
  save_answer ACME_DOMAINS
}

# wait_cert HOST [seconds]   run certsync until HOST's certificate has been issued by sing-box
wait_cert() {
  local h=$1 t=${2:-600} n=0
  [ "$IK_DRYRUN" = 1 ] && { say "[dry-run] wait for certificate of $h"; return 0; }
  [ -z "${ACME_PENDING:-}" ] || { warn "$h: certificate pending (DNS not ready); configuration is written, TLS starts working once it is issued"; return 1; }
  info "waiting for sing-box to obtain the certificate for $h (DNS-01 can take a few minutes)..."
  while [ "$n" -lt "$t" ]; do
    /usr/local/sbin/interkit-certsync >/dev/null 2>&1
    [ -s "$IK_CERTS/$h/fullchain.pem" ] && { info "certificate for $h is ready"; return 0; }
    sleep 10; n=$((n+10))
  done
  warn "no certificate for $h after ${t}s. Check: journalctl -u sing-box -e"
  return 1
}

# require_cloudflare: the Cloudflare module provides the certificates every other module needs
require_cloudflare() {
  [ -n "${CF_ZONE:-}" ] && [ -n "${ACME_EMAIL:-}" ] && have_secret cloudflare \
    || die "run the cloudflare module first: interkit-setup cloudflare"
}

# require_domain: the domain module provides the base domain, hostnames and certificate method every service needs
require_domain() {
  [ -n "${BASE_DOMAIN:-}" ] && [ -n "${ACME_EMAIL:-}" ] || die "run the domain module first: interkit-setup domain"
  MAIL_HOST="${MAIL_HOST:-mail.$BASE_DOMAIN}"; CHAT_HOST="${CHAT_HOST:-chat.$BASE_DOMAIN}"
  DERP_HOST="${DERP_HOST:-derp.$BASE_DOMAIN}"; WEB_HOST="${WEB_HOST:-fossil.$BASE_DOMAIN}"
  ACME_CHALLENGE="${ACME_CHALLENGE:-http}"
}

# ---- answer files / USB stick ----------------------------------------------------------------
# Variables an answer file (-f FILE, or interkit.env / .env on a USB stick) may set. Anything else is ignored, so a file
# can never overwrite PATH, IFS and the like.
IK_ENV_VARS=" BASE_DOMAIN ACME_EMAIL ACME_CHALLENGE MAIL_HOST CHAT_HOST DERP_HOST WEB_HOST WEB_PORT MAIL_DOMAIN DKIM_SELECTOR
 XMPP_DOMAIN XMPP_ADMIN DERP_PORT DERP_STUN DERP_VERIFY_URL DERP_OPEN_OK CF_ZONE CF_API_TOKEN CF_TUNNEL_TOKEN DDNS_ENABLE
 ENABLED_SERVICES IK_PUBLIC_IP4 IK_PUBLIC_IP6 "
# load_env FILE   read KEY=VALUE lines (optional "export ", optional quotes, # comments). The file is NEVER executed.
load_env() {
  local f=$1 line k v
  [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}; line=${line#export }
    case "$line" in ''|'#'*) continue;; esac
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    k=${line%%=*}; v=${line#*=}
    case "$v" in \"*\") v=${v#\"}; v=${v%\"};; \'*\') v=${v#\'}; v=${v%\'};; esac
    case "$IK_ENV_VARS" in *[[:space:]]"$k"[[:space:]]*) printf -v "$k" '%s' "$v";; *) warn "$f: ignoring unknown setting $k";; esac
  done < "$f"
}
# find_usb_env  -> prints the path of a private copy (in /run) of interkit.env, .env or interkit.conf found on a
# removable drive (mounted read-only if it is not mounted yet, unmounted again afterwards). Returns 1 if none.
find_usb_env() {
  local dev rm fs mp mnt="" f name out="" tmp
  command -v lsblk >/dev/null 2>&1 || return 1
  while read -r dev rm fs mp; do
    [ "$rm" = 1 ] && [ -n "$fs" ] || continue
    if [ -n "$mp" ]; then mnt=$mp; own=0
    else mnt=$(mktemp -d /run/interkit-usb.XXXXXX); own=1
      mount -o ro,nosuid,nodev,noexec "$dev" "$mnt" 2>/dev/null || { rmdir "$mnt"; continue; }
    fi
    for name in interkit.env .env interkit.conf; do
      f="$mnt/$name"
      if [ -f "$f" ]; then
        tmp=$(umask 077; mktemp /run/interkit-env.XXXXXX); cat "$f" > "$tmp"; out=$tmp; IK_USB_DEV=$dev; IK_USB_NAME=$name; break
      fi
    done
    if [ "$own" = 1 ]; then umount "$mnt" 2>/dev/null; rmdir "$mnt" 2>/dev/null; fi
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  done < <(lsblk -rno PATH,RM,FSTYPE,MOUNTPOINT 2>/dev/null)
  return 1
}

# shellcheck disable=SC1091
. "${IK_LIB:-/usr/lib/interkit}/dns-lib.sh"
