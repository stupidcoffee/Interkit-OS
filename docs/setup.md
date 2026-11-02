# interkit-setup

Guided setup, in the spirit of `setup-alpine`, for services that need a domain, DNS and TLS.

    sudo interkit-setup                 # menu
    sudo interkit-setup domain          # 1. your domain + host names
    sudo interkit-setup web derp xmpp postfix    # 2. the services you want
    sudo interkit-setup dns             # 3. DNS records to copy into your DNS provider
    sudo interkit-setup verify          # 4. check them, then certificates are requested
    sudo interkit-setup -f answers -q all        # non-interactive (answers from a file/environment)
    sudo interkit-setup status

## No clipboard on the server console?

- Run `interkit-setup` over SSH from your own computer (`ssh USER@IP`, find the IP with `ip -br a`) and paste there.
- At any secret prompt (Cloudflare token, tunnel token) you can enter `@/path/to/file` to read the value from the first
  line of a file, e.g. on a USB stick (`mount /dev/sdb1 /mnt`, then `@/mnt/token.txt`).
- **Browser form:** `sudo interkit-setup web-ui` (menu: `w`) prints a URL like `https://<IP>:8765/`, a one-time code and the
  certificate fingerprint. Open the URL on another computer, compare the fingerprint your browser shows (the certificate is
  self-signed and made on the spot, so expect a warning), then fill in the domain, certificate method and API tokens and paste
  them. The server then saves them like the `.env` loader does and closes. It runs as `nobody`, uses HTTPS only, ends after one
  successful submit, after 5 wrong codes or after 15 minutes, validates every field, logs nothing, and never executes input.
  Only use it on a network you trust; it listens on all interfaces while it is open.
- **USB stick with a `.env`:** copy `docs/interkit.env.example` to the stick as `interkit.env` (or `.env`), fill in the
  domain and API keys, plug it in and run `sudo interkit-setup`. It finds the file on any removable drive, asks once, and uses
  the values instead of prompting (`interkit-setup -u` does it without asking). The file is read as plain `KEY=VALUE`
  lines, never executed, and only known settings are accepted. It is copied to memory (`/run`) and removed on exit; API keys
  are stored in `/etc/interkit/secrets` like typed ones. Delete the file from the stick afterwards: it holds secrets in
  plain text.
- Typed secrets are hidden, but the length and last 4 characters are shown so a typo is caught before saving.
- `interkit-setup dns` also publishes to the Fossil web UI (wiki page "DNS setup", login admin, password in `/root/fossil-admin-password`) so you can copy it from another computer. It prints every record as a fill-in form (Type, Name, Value, Priority, TTL, proxy off) and is saved to
  `/var/lib/interkit/dns-guide.txt` so you can read it from another computer.

## One domain, replaceable host names

You enter your domain once (`example.com`); the host names derive from it and can be changed:

| Service | Default host | Notes |
|---|---|---|
| mail (Postfix) | `mail.<domain>` | addresses are `user@<domain>`; MX points at the mail host |
| chat (Prosody XMPP) | `chat.<domain>` | JIDs are `user@chat.<domain>` (certificate matches, no apex record needed) |
| DERP relay (sing-box) | `derp.<domain>` | tcp 443 + udp 3478 |
| admin web (Fossil) | `fossil.<domain>` | HTTPS on tcp 8443 |

## TLS: everything from sing-box's ACME

sing-box (1.14+, `certificate_providers`, type `acme`) obtains every certificate. Two methods:

- **`http` (default, no API keys)**: Let's Encrypt HTTP challenge on port 80. Each host's A record must already
  point at this machine, so certificates are only requested after `interkit-setup verify` (or the service
  module itself) sees correct DNS. This avoids Let's Encrypt's failed-validation limits.
- **`dns-cloudflare` (optional)**: DNS challenge through a Cloudflare API token: no open port 80, DNS records are
  created for you, dynamic DNS keeps the A records current, and an optional Cloudflare Tunnel is available.
  Enable with `interkit-setup cloudflare`.

Consumers: **DERP** uses the provider directly. **Fossil** serves HTTPS itself (`fossil server --cert --pkey`).
**Postfix / Prosody** cannot talk to sing-box, so `interkit-certsync` (hourly) copies each host's certificate from
sing-box's storage to `/var/lib/interkit/certs/<host>/` (key `0640 root:ssl-cert`) and reloads/restarts those services.

## DNS guide + verification (any DNS provider)

`interkit-setup dns` prints a table, a zone-file version, the reverse-DNS (PTR) request and the ports to open. It is
also saved to `/var/lib/interkit/dns-guide.txt` and published as the Fossil wiki page **DNS setup** (log in as `admin`).
`interkit-setup verify` then queries a public resolver (`IK_DNS_RESOLVER`, default 1.1.1.1) and reports
`OK` / `MISSING` per record, warns when the PTR record or outbound port 25 is not right, and exits non-zero if any record
is missing. When DNS is correct it requests the certificates.

## Safety rules built in

- DNS records created through the Cloudflare API: A/AAAA/SRV are created or updated; **MX, SPF, DMARC and DKIM are never
  overwritten** when a different one exists (a warning tells you to merge by hand).
- Postfix: no open relay (`permit_mynetworks, reject_unauth_destination`), TLS >= 1.2. Mail goes to `/var/mail/<user>`
  and the client is **Alpine** (Debian's Alpine cannot read Maildir). No IMAP server yet.
- DERP refuses to run as an open relay unless you type `open-relay`.
- Secrets live in `/etc/interkit/secrets/*.secret` (0600) and in sing-box fragments `*.secret.json` (0640 `root:sing-box`),
  are passed to `jq` through the environment, never as arguments, and `/etc/sing-box` is `0750 root:sing-box`.
- `config.fossil` (tracks `/etc`) ignores anything matching `*secret*`, `*privkey*`, `*private_key*`, `*.private`, `*.key`,
  `*shadow*`, `*ssh_host_*`, `*/private/*`, `*credstore*`, `system-connections`, `wireguard`, `openvpn`, `*.p12`, `*.pfx`
  (set at first boot, so it applies to systems booted from images built after this change).
- Every sing-box change is validated with `sing-box check` and rolled back if rejected.

## What was tested, and what was not

Tested with the real programs in a throwaway root filesystem made from the interkit ISO (sing-box 1.14.4, Prosody 13.0.1,
Postfix 3.10, OpenDKIM 2.11, Alpine 2.26, Fossil 2.26), systemd **not** running, Cloudflare **faked** by a `curl` shim:

- `sing-box check` accepts the ACME provider (DNS challenge variant), the loopback Trojan anchor that references it,
  the `cloudflared` inbound and the `derp` service. (The HTTP-challenge variant was only dry-run, see below.)
- Prosody config check passes, account creation works, 5222/5269 serve TLS 1.3 with the synced certificate.
- Postfix: STARTTLS with the right certificate; relay to an outside domain refused from a non-local address; a message
  sent to `alice@example.com` landed in `/var/mail/alice`, and **Alpine opened that mailbox and listed it**.
- Fossil serves HTTPS with the synced certificate as user `fossil` through the `ssl-cert` group; plain HTTP is refused;
  the key is unreadable without the group.
- `interkit-certsync`: copies, sets permissions, idempotent.
- `interkit-setup dns` output (IPv4/IPv6 handling, zone-file lines); `interkit-setup verify` against live DNS reports
  OK / MISSING correctly. The whole flow was dry-run (`-n`) for the domain model.

**Not tested** (needs a real domain, ports reachable from the internet, or a booted system):

- Real ACME issuance and renewal. The **HTTP-challenge config was not run through `sing-box check`** (only generated),
  and sing-box's docs do not say where certificates are stored; the sync assumes the certmagic layout
  `<data_directory>/certificates/<CA>/<host>/<host>.crt|.key`.
- The real Cloudflare API (endpoints and payloads are from general knowledge, exercised only against a shim).
- systemd units/timers, service reloads after renewal, and the Fossil HTTPS drop-in under systemd.
- The Cloudflare Tunnel connecting; DERP serving clients (`verify_client_url` is passed through as given).
- DKIM signing end to end; Prosody's live "STARTTLS required" behaviour (it is configured).
- Mail needs: inbound/outbound TCP 25 open at your provider, and a PTR record (a DNS provider cannot set PTR).
