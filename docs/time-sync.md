# Time sync in interkit

**Decision:** the system clock is kept by Debian's default **systemd-timesyncd**.
sing-box's built-in NTP stays enabled, but with `write_to_system: false`, so it only
supplies corrected time to sing-box's own protocols (TLS, etc.) and never touches the OS clock.

- `config/includes.chroot/etc/sing-box/config.json` -> `ntp` block (`write_to_system: false`)
- `config/package-lists/interkit.list.chroot` -> `systemd-timesyncd`
- `config/hooks/normal/0300-singbox.hook.chroot` -> `systemctl enable systemd-timesyncd`

## sing-box `write_to_system` (undocumented option)

`ntp.write_to_system` (bool, default false) makes sing-box set the **operating system clock**
after a successful NTP exchange. It is **not in sing-box's documentation**
(docs/configuration/ntp only lists `enabled`, `server`, `server_port`, `interval` + dial fields;
the docs say the NTP service only provides time to protocols like TLS/Shadowsocks/VMess).

What was verified, and how (source reading only; the binary was never run here):
- The field exists in `option/ntp.go` at tag **v1.14.4** (`WriteToSystem bool json:"write_to_system,omitempty"`).
  sing-box `sing-box check` accepts it only if the version supports it, so re-check after upgrades.
- Behaviour comes from the `sing` library, `common/ntp` (read from its `main` branch; the exact
  `sing` version pinned by sing-box v1.14.4 was NOT checked):
  - Applies time with `settimeofday` -> the clock **steps** (jumps); there is no slewing (`adjtime`).
  - One server, one query per `interval` (default 30 min) plus one at startup. No retry, no averaging.
  - After a successful exchange it calls `SetSystemTime(...)`; a write failure is only logged.
  - On any failure it keeps the previous offset and waits for the next tick.
  - No NTS/authentication; plain UDP. Little reply validation was visible (no stratum / leap /
    kiss-o-death checks in the part of the code read). Offset math (`parseTime`) was not read.
  - Linux and macOS only (`//go:build linux || darwin`).
- Setting the clock needs `CAP_SYS_TIME`. The packaged `sing-box.service` runs as user `sing-box`
  with `CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH` and
  **no** `CAP_SYS_TIME`, so enabling the option without a drop-in would fail (error logged only).

## Why not use it for the system clock

| | timesyncd (chosen) | sing-box ntp + write_to_system |
|---|---|---|
| Servers | list with fallback (`0-3.debian.pool.ntp.org`) | one |
| Applying time | slew small / step large | always steps |
| Failure | next server, adaptive polling | log, retry next interval |
| Auth / NTS | no | no |
| Maturity | ships with Debian | undocumented option |
| Extra privilege | none | needs CAP_SYS_TIME |

A plain, unauthenticated, single-source reply that steps the clock lets anyone on the network
path set the time, which weakens TLS (certificate validity depends on the clock).
For authenticated time use **chrony with NTS** (not installed; would replace timesyncd).

## How to enable it anyway (untested)

1. `config.json`: set `"write_to_system": true`.
2. Add a unit drop-in `/etc/systemd/system/sing-box.service.d/10-ntp.conf`
   (these lists are additive to the packaged ones):
   ```
   [Service]
   CapabilityBoundingSet=CAP_SYS_TIME
   AmbientCapabilities=CAP_SYS_TIME
   ```
3. Disable timesyncd so two services don't fight over the clock: `systemctl mask systemd-timesyncd`.
4. Verify: `journalctl -u sing-box`, and `date` before/after a sync.
   (An earlier revision of this repo shipped exactly this setup; see the Fossil history.)

## Environment note

During testing, hostnames resolved to `198.18.x.x` (a reserved range) from the builder VM, so the
host network appears to use fake-IP DNS / a transparent proxy. NTP via timesyncd still worked
(`NTPSynchronized=yes`, stratum 2), but keep this in mind when debugging time or DNS.
