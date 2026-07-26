# Changelog

## [Unreleased]

### Fixed
- **Domain list frozen in a broken state by the version check.** A flaky
  `update` run (VPN/network down at cron time, or GitHub 5xx) could fail most
  source downloads and produce a gutted list — in one case only 484 domains with
  **zero** YouTube/Google entries, so only Instagram (which happened to survive)
  routed through the VPN. Two missing guards made it permanent:
  - The version marker (`.lists-version`) was saved even when downloads failed.
    The daily version-check then matched remote == local and `exit 0`'d without
    re-downloading, so the broken list stayed broken until a manual
    `update-domains.sh --force`.
  - The ipset-config regeneration only rejected an *empty* result, not a
    *gutted* one, so the tiny list overwrote the good one.
  - `update-domains.sh` now counts per-source download failures, refuses to
    replace a good list with a smaller one from a failed run (or let a healthy
    list collapse below a 1000-domain floor), and skips saving the version marker
    whenever any source failed — so the next run retries instead of
    short-circuiting. A rejected run keeps the previous lists and exits non-zero.

- **Router OOM from dnsmasq debug logging on tmpfs.** On Keenetic, `/tmp` is a
  RAM-backed tmpfs (~244 MB). A leftover debug edit in `dnsmasq.conf`
  (`log-queries` + `log-facility=/tmp/dnsmasq-debug.log`) made dnsmasq write every
  DNS query to RAM with no rotation. Over weeks the log grew until it filled tmpfs
  and triggered an out-of-memory condition that took the router down.
  - `manage.sh` now strips any `log-queries` / `log-facility=` lines from
    `dnsmasq.conf` (and removes a stale `/tmp/dnsmasq-debug.log`) before every
    start. The service writes all process output to `/dev/null` by design, so query
    logging is never shipped.

- **Broken install / self-update URLs (wrong GitHub account).** Both READMEs'
  install one-liner and `manage.sh` self-update pointed at
  `github.com/dnikonov/...` (404 — wrong account), so a fresh `curl … main.tar.gz`
  install failed outright and no user could pull script updates. Corrected to
  `github.com/DenisNikonov/...` in `README.md`, `README.ru.md`, and `manage.sh`.
  This is what lets the OOM fix above actually reach installed routers.

### Added
- **Per-device full VPN routing (`FULL_VPN_DEVICES`).** A comma-separated list of
  LAN devices (by MAC — recommended — or IP) whose *entire* traffic is routed
  through the tunnel regardless of `ROUTE_MODE`, while the rest of the LAN stays
  selective. Useful for a smart TV or console that should always go through the
  VPN. Implemented as source-matched PREROUTING jumps (bypassing the ipset dst
  match) into the existing REDIRECT/TPROXY chains, with DNS (port 53) excluded so
  forced-DNS still applies. The chains' private-net + server-IP RETURN guards
  (previously only added in `ROUTE_MODE=all`) are now also added whenever
  `FULL_VPN_DEVICES` is set, so the device's LAN and VPN-server traffic stays
  direct and no routing loop forms. `do_stop` removes these jumps before deleting
  the chains, and `manage.sh status` lists the configured devices.
- `manage.sh status` now reports `/tmp` (RAM tmpfs) usage and warns at ≥80 %, so a
  filling tmpfs is visible before it causes an OOM.
