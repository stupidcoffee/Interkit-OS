#!/usr/bin/env python3
"""interkit-setup web-ui: a one-time HTTPS form for the domain and API keys.

Started by `interkit-setup web-ui` (as an unprivileged user). It serves ONE form over HTTPS with a throw-away
certificate, accepts it once, writes KEY=VALUE lines to --out and exits. It never runs anything; interkit-setup reads
the file afterwards with the same safe loader it uses for a USB .env.

Protection: the one-time code (environment IK_WEBUI_CODE, shown on the server's console), 5 wrong tries end the
server, 15 minutes end the server, strict validation of every field, no logging of requests.
Exit status: 0 = form accepted, 2 = timed out, 3 = too many wrong codes.
"""
import argparse, hmac, html, os, re, ssl, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

TIMEOUT_SECONDS = 15 * 60
MAX_TRIES = 5
MAX_BODY = 16 * 1024

HOST_RE = re.compile(r'^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$')
EMAIL_RE = re.compile(r'^[^@\s"\']{1,64}@[a-z0-9.-]{1,253}$')
SECRET_RE = re.compile(r'^[\x21-\x7e]{8,4096}$')          # printable ASCII, no spaces/controls
NOQUOTE_RE = re.compile(r'^[^"\'\\]*$')

STATE = {"tries": 0, "rc": 2, "done": False}
LOCK = threading.Lock()


def page(body, status_note=""):
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>interkit setup</title>
<style>
:root{{--bg:#1515ab;--panel:#b2b2b2;--ink:#000;--accent:#a82d25;--ok:#1a6b2a}}
@media (prefers-color-scheme:dark){{:root{{--panel:#c8c8c8}}}}
body{{margin:0;background:var(--bg);font:16px/1.45 ui-monospace,Menlo,Consolas,monospace;color:#fff}}
main{{max-width:40rem;margin:0 auto;padding:1.5rem 1rem}}
.box{{background:var(--panel);color:var(--ink);padding:1.2rem 1.2rem 1.4rem;border:2px solid #000;box-shadow:6px 6px 0 #000}}
h1{{font-size:1.1rem;margin:0 0 .8rem;color:var(--accent)}}
label{{display:block;margin:.8rem 0 .2rem;font-weight:bold}} small{{display:block;color:#333}}
input,select{{width:100%;box-sizing:border-box;font:inherit;padding:.45rem;border:2px solid #000;background:#fff;color:#000}}
.row{{display:flex;gap:.6rem;align-items:center}} .row input{{width:auto}}
button{{margin-top:1.2rem;font:inherit;font-weight:bold;padding:.6rem 1.2rem;background:var(--accent);color:#fff;border:2px solid #000;cursor:pointer}}
.err{{background:#fff;border:2px solid var(--accent);padding:.5rem;margin-bottom:.8rem;color:var(--accent)}}
.ok{{color:var(--ok)}} details{{margin-top:1rem}}
</style></head><body><main><div class="box">{status_note}{body}</div></main></body></html>"""


def form(error="", values=None):
    v = values or {}
    e = lambda k: html.escape(v.get(k, ""), quote=True)
    sel = lambda k, x: " selected" if v.get(k, "http") == x else ""
    err = f'<div class="err">{html.escape(error)}</div>' if error else ""
    return page(f"""<h1>interkit setup</h1>{err}
<p>Fill this in once. It is saved on the server and this page then closes itself.</p>
<form method="post" action="/" autocomplete="off">
<label for="code">One-time code <small>shown on the server's screen</small></label>
<input id="code" name="code" required autocomplete="off" autocapitalize="characters" spellcheck="false">
<label for="d">Your domain <small>for example: example.com</small></label>
<input id="d" name="BASE_DOMAIN" required value="{e('BASE_DOMAIN')}" placeholder="example.com" inputmode="url">
<label for="m">E-mail for Let's Encrypt notices</label>
<input id="m" name="ACME_EMAIL" required value="{e('ACME_EMAIL')}" placeholder="admin@example.com" type="email">
<label for="c">Certificate method</label>
<select id="c" name="ACME_CHALLENGE">
<option value="http"{sel('ACME_CHALLENGE','http')}>http: no API key; needs port 80 and your DNS records in place</option>
<option value="dns-cloudflare"{sel('ACME_CHALLENGE','dns-cloudflare')}>dns-cloudflare: Cloudflare API token, no open port</option>
</select>
<label for="z">Cloudflare zone <small>only for dns-cloudflare; usually your domain</small></label>
<input id="z" name="CF_ZONE" value="{e('CF_ZONE')}">
<label for="t">Cloudflare API token <small>only for dns-cloudflare (Zone:DNS:Edit, Zone:Zone:Read)</small></label>
<input id="t" name="CF_API_TOKEN" type="password" autocomplete="off">
<label for="u">Cloudflare Tunnel token <small>optional</small></label>
<input id="u" name="CF_TUNNEL_TOKEN" type="password" autocomplete="off">
<div class="row"><input id="dd" type="checkbox" name="DDNS_ENABLE" value="y"{' checked' if v.get('DDNS_ENABLE','y')=='y' else ''}>
<label for="dd" style="margin:0">Keep the DNS records pointed at this machine's IP (dynamic DNS)</label></div>
<details><summary>Host names (optional)</summary>
<label for="h1">Mail host</label><input id="h1" name="MAIL_HOST" value="{e('MAIL_HOST')}" placeholder="mail.example.com">
<label for="h2">Chat host</label><input id="h2" name="CHAT_HOST" value="{e('CHAT_HOST')}" placeholder="chat.example.com">
<label for="h3">DERP host</label><input id="h3" name="DERP_HOST" value="{e('DERP_HOST')}" placeholder="derp.example.com">
<label for="h4">Admin web host</label><input id="h4" name="WEB_HOST" value="{e('WEB_HOST')}" placeholder="fossil.example.com">
</details>
<button type="submit">Save</button></form>""")


def validate(f):
    """Return (clean dict, error string)."""
    g = lambda k: (f.get(k, [""])[0]).strip()
    out = {}
    domain = g("BASE_DOMAIN").lower().rstrip(".")
    if not HOST_RE.match(domain):
        return None, "That does not look like a domain name (example: example.com)."
    out["BASE_DOMAIN"] = domain
    email = g("ACME_EMAIL").lower()
    if not EMAIL_RE.match(email):
        return None, "That does not look like an e-mail address."
    out["ACME_EMAIL"] = email
    method = g("ACME_CHALLENGE") or "http"
    if method not in ("http", "dns-cloudflare"):
        return None, "Unknown certificate method."
    out["ACME_CHALLENGE"] = method
    for k in ("MAIL_HOST", "CHAT_HOST", "DERP_HOST", "WEB_HOST"):
        if g(k):
            h = g(k).lower().rstrip(".")
            if not HOST_RE.match(h):
                return None, f"{k.replace('_HOST','').title()} host name is not valid."
            out[k] = h
    out["DDNS_ENABLE"] = "y" if g("DDNS_ENABLE") == "y" else "n"
    if method == "dns-cloudflare":
        zone = (g("CF_ZONE") or domain).lower()
        if not HOST_RE.match(zone):
            return None, "Cloudflare zone is not valid."
        out["CF_ZONE"] = zone
        if not SECRET_RE.match(g("CF_API_TOKEN")) or not NOQUOTE_RE.match(g("CF_API_TOKEN")):
            return None, "dns-cloudflare needs the Cloudflare API token (no spaces or quotes)."
        out["CF_API_TOKEN"] = g("CF_API_TOKEN")
    if g("CF_TUNNEL_TOKEN"):
        if not SECRET_RE.match(g("CF_TUNNEL_TOKEN")) or not NOQUOTE_RE.match(g("CF_TUNNEL_TOKEN")):
            return None, "The tunnel token has spaces or quotes in it."
        out["CF_TUNNEL_TOKEN"] = g("CF_TUNNEL_TOKEN")
    return out, ""


def make_handler(code, outpath, server_ref):
    class H(BaseHTTPRequestHandler):
        timeout = 10            # a stalled client (even mid-TLS-handshake) cannot hold the server
        server_version = "interkit"
        sys_version = ""

        def log_message(self, *a):     # never log: requests carry secrets
            pass

        def _send(self, status, body, ctype="text/html; charset=utf-8"):
            data = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy",
                             "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if STATE["done"]:
                return self._send(410, page("<h1>Done</h1><p>This page has closed.</p>"))
            self._send(200, form()) if self.path == "/" else self._send(404, page("<h1>Not found</h1>"))

        def do_POST(self):
            if self.path != "/" or STATE["done"]:
                return self._send(404, page("<h1>Not found</h1>"))
            try:
                n = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                n = -1
            if n < 0 or n > MAX_BODY:
                return self._send(413, page("<h1>Too large</h1>"))
            f = parse_qs(self.rfile.read(n).decode("utf-8", "replace"), keep_blank_values=True)
            with LOCK:
                if STATE["done"]:
                    return self._send(410, page("<h1>Done</h1>"))
                given = (f.get("code", [""])[0]).strip().upper().encode()
                if not hmac.compare_digest(given, code.encode()):
                    STATE["tries"] += 1
                    if STATE["tries"] >= MAX_TRIES:
                        STATE["done"], STATE["rc"] = True, 3
                        self._send(403, page("<h1>Locked</h1><p>Too many wrong codes. Start it again on the server.</p>"))
                        threading.Thread(target=server_ref["srv"].shutdown, daemon=True).start()
                        return
                    left = MAX_TRIES - STATE["tries"]
                    keep = {k: v[0] for k, v in f.items() if k in ("BASE_DOMAIN", "ACME_EMAIL", "ACME_CHALLENGE", "CF_ZONE")}
                    return self._send(403, form(f"Wrong code. {left} tries left.", keep))
                clean, err = validate(f)
                if err:
                    keep = {k: v[0] for k, v in f.items() if k in ("BASE_DOMAIN", "ACME_EMAIL", "ACME_CHALLENGE", "CF_ZONE",
                                                                  "MAIL_HOST", "CHAT_HOST", "DERP_HOST", "WEB_HOST")}
                    return self._send(400, form(err, keep))
                fd = os.open(outpath, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w") as fh:
                    for k, v in clean.items():
                        fh.write(f"{k}={v}\n")
                STATE["done"], STATE["rc"] = True, 0
            self._send(200, page('<h1 class="ok">Saved</h1><p>Your settings were sent to the server. '
                                 'You can close this page and go back to the server screen.</p>'))
            threading.Thread(target=server_ref["srv"].shutdown, daemon=True).start()
    return H


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--bind", default="0.0.0.0")
    a = ap.parse_args()
    code = os.environ.pop("IK_WEBUI_CODE", "")
    if len(code) < 6:
        sys.exit("webui: IK_WEBUI_CODE missing")
    ref = {}
    srv = ThreadingHTTPServer((a.bind, a.port), make_handler(code, a.out, ref))
    srv.daemon_threads = True
    ref["srv"] = srv
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(a.cert, a.key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)
    threading.Timer(TIMEOUT_SECONDS, srv.shutdown).start()
    srv.serve_forever()
    srv.server_close()
    os._exit(STATE["rc"])


if __name__ == "__main__":
    main()
