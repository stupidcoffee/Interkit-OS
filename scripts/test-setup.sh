#!/bin/bash
# Quick checks of interkit-setup that need no root, network or systemd (dry run in a temp root). Run by CI before the build.
#   scripts/test-setup.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$SRC/config/includes.chroot/usr/local/sbin/interkit-setup"
export IK_LIB="$SRC/config/includes.chroot/usr/lib/interkit" DEST; DEST=$(mktemp -d)
export IK_PUBLIC_IP4=203.0.113.5 IK_DRYRUN=1
fail=0; ok() { echo "ok   $1"; }; bad() { echo "FAIL $1"; fail=1; }
t() { local name=$1; shift; if "$@" >"$DEST/out" 2>&1; then ok "$name"; else bad "$name"; sed 's/^/     /' "$DEST/out" | tail -5; fi; }
has() { grep -q -- "$1" "$DEST/out"; }

for f in "$BIN" "$IK_LIB"/*.sh "$IK_LIB"/setup.d/*.sh; do t "syntax $(basename "$f")" bash -n "$f"; done
t "syntax webui.py" python3 -m py_compile "$IK_LIB/webui.py"

# every module must be loaded (regression: a sourcing line was once deleted by an edit)
t "status lists every module" bash "$BIN" -n -q status
for m in domain cloudflare web derp xmpp postfix; do grep -q "$m" "$DEST/out" && ok "module $m loaded" || bad "module $m missing from status"; done
! grep -q "command not found" "$DEST/out" && ok "no 'command not found'" || bad "'command not found' in status"

printf 'BASE_DOMAIN=example.com\nACME_EMAIL=a@example.com\nMAIL_DOMAIN=example.com\nENABLED_SERVICES="mail chat web"\nXMPP_DOMAIN=example.com\n' > "$DEST/ans"
t "domain module (dry run)" bash "$BIN" -n -q -f "$DEST/ans" domain
t "dns guide prints forms" bash "$BIN" -n -q -f "$DEST/ans" dns
has "Mail server:" && has "(full name:" && ok "dns form fields present" || bad "dns form fields missing"

# answer files are data, never code
printf 'BASE_DOMAIN=example.com\nPATH=/evil\n$(touch %s/pwned)=x\n' "$DEST" > "$DEST/evil"
( . "$IK_LIB/setup-lib.sh"; load_env "$DEST/evil" ) >/dev/null 2>&1
[ ! -e "$DEST/pwned" ] && ok "load_env does not execute input" || bad "load_env executed input"
exit $fail
