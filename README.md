# node-diagnostic

Diagnose a VPN/Linux node for YouTube, video CDNs and popular services in one command. Progress bar, summary, verdict and automatic fixes — all in a single bash script, with no dependencies beyond basic utilities.

```
╔═════════════════════════════════════════════════════════════════════╗
║   Node Diagnostic v3.4 · 2026-05-06 18:42 UTC                       ║
╚═════════════════════════════════════════════════════════════════════╝

[ 1/23] ✓ Identification             host.example.com · Helsinki/FI · ~2ms→Tallinn
[ 2/23] ✓ CPU and load               2c · load 0.05 · idle 94%
[ 3/23] ✓ Memory                     55% available
[ 4/23] ✓ NIC / interface            ens3 · mtu 1500 · drops 0/0
[ 5/23] ⚠ Tunnels                    1 active: NetBird:wt0 (MTU=1280)
[ 6/23] ✓ TCP congestion             bbr + cake
[ 7/23] ⚠ TCP tuning                 mtu_probing=0
[ 8/23] ✓ Conntrack                  4006 / 524288 (0%)
[ 9/23] ⚠ DNS resolve                3/5 fail (Netbird DNS times out)
[10/23] ✗ PMTU                       1437 (instead of 1500)
[11/23] ✗ Loss to Google             max 18% loss
[12/23] ✗ Route (mtr)                10h · loss 53% at 62.115.137.119/53.0%
[13/23] ⚠ QUIC / HTTP-3              udp=on http3=off
[14/23] ✗ Speed: 1-flow              21 Mbit/s
...
```

## What it checks (23 checks)

**System** — CPU/memory/load/softirq, NIC drops, ring buffers, ethtool offloads.

**Network** — TCP congestion control + qdisc, buffers, conntrack, DNS resolution, PMTU (binary search with protection against false negatives on lossy networks), tunnels (WireGuard/NetBird/Tailscale/OpenVPN/IPsec), packet loss and latency to Google and public DNS, MTR with worst-hop detection, UDP/QUIC/HTTP-3, IPv6.

**Performance** — single-flow speed (Cachefly), 4 parallel flows, multi-CDN test (Cloudflare/Cachefly/Hetzner/OVH/Linode) to detect ASN throttling, **bufferbloat** (ping under load — the main cause of stuttering Shorts), sustained variance.

**Services** — reachability + TTFB for 19 popular ones: YouTube, Netflix, Twitch, TikTok, Telegram, Discord, WhatsApp, Signal, ChatGPT, Claude, Gemini, Spotify, Steam, GitHub and more. Distinguishes 200/blocked (403/429)/unreachable.

**IP reputation** — Cloudflare colo, geo cross-check across 3 databases (ipinfo.io, ip-api.com, ipwho.is), real location via latency to national IXs, Google CAPTCHA probe, reverse DNS, datacenter-vs-residential heuristic.

**Xray/Remnanode** — version, container resources, errors in logs, restart count.

## Install and run

# Just run it
```bash
curl -sSL https://raw.githubusercontent.com/itsvenoxy/node-diagnostic/main/node-diagnostic.sh | sudo bash
```
# Or download and run
```bash
wget https://raw.githubusercontent.com/itsvenoxy/node-diagnostic/main/node-diagnostic.sh
sudo bash node-diagnostic.sh
```

The script installs dependencies (`mpstat`, `mtr`, `dig`, `ethtool`, `conntrack`, `jq`, etc.) itself via apt/dnf/yum/apk.

## Options

```
sudo bash node-diagnostic.sh           # full run ~5 min
sudo bash node-diagnostic.sh -q        # quick run ~1 min (no mtr/4-flow/multi-CDN/services/variance/bufferbloat)
sudo bash node-diagnostic.sh -a        # apply ALL recommended fixes without asking
sudo bash node-diagnostic.sh -n        # don't offer fixes at all
sudo bash node-diagnostic.sh --dry-run # show what would be applied, but don't do it
sudo bash node-diagnostic.sh --no-net  # local configuration only (no network tests)
sudo bash node-diagnostic.sh -v        # verbose mode (everything on screen, as before)
sudo bash node-diagnostic.sh --version
sudo bash node-diagnostic.sh -h        # help
```

## What it can fix automatically

After the run, a list of relevant fixes is shown (only the ones that will actually help this specific node):

- **sysctl tuning** — BBR + cake qdisc + 64MB buffers + tcp_mtu_probing=1 + tcp_slow_start_after_idle=0 + tcp_notsent_lowat + conntrack 524288. File `/etc/sysctl.d/99-vpn-tuning.conf`.
- **MSS clamping** — iptables TCPMSS clamp in FORWARD/OUTPUT for tunnel interfaces with PMTU<1500. Persisted via `netfilter-persistent` or `/etc/iptables/rules.v4`.
- **RPS on NIC** — balance softirq across all CPUs. Creates systemd unit `node-diagnostic-rps.service`.
- **Ring buffers up** — `ethtool -G $iface rx max tx max`. Systemd unit for persistence.

Before applying — automatic backup (`sysctl -a` and `iptables-save`) into `/var/backups/node-diagnostic/`. History of applied fixes — in `/etc/node-diagnostic.applied`. At the end a rollback command is printed.

## Standalone tuning scripts

Two companion scripts let you apply or undo the same optimizations **without running the full diagnosis first**. They share the paths, systemd units, backup dir and journal with `node-diagnostic.sh`, so they're fully interoperable.

### `apply-tuning.sh` — apply everything at once

Applies all recommended optimizations unconditionally:

- **sysctl** — BBR + cake, 64MB buffers, `tcp_mtu_probing`, `tcp_fastopen`, conntrack 524288 (`/etc/sysctl.d/99-vpn-tuning.conf`)
- **iptables MSS clamp** — `--clamp-mss-to-pmtu` on FORWARD/OUTPUT, persisted via `netfilter-persistent` or `/etc/iptables/rules.v4`
- **RPS** — spread softirq across all CPUs, persisted via `vpn-rps.service`
- **NIC ring buffers** — raised to maximum, persisted via `vpn-ring.service`
- **vm.swappiness = 10** (`/etc/sysctl.d/98-swappiness.conf`)

```bash
# Just run it
curl -sSL https://raw.githubusercontent.com/itsvenoxy/node-diagnostic/main/apply-tuning.sh | sudo bash
# Or download and run
wget https://raw.githubusercontent.com/itsvenoxy/node-diagnostic/main/apply-tuning.sh
sudo bash apply-tuning.sh
```

```bash
sudo bash apply-tuning.sh             # apply everything
sudo bash apply-tuning.sh --dry-run   # show what would change, change nothing
sudo bash apply-tuning.sh -i eth0     # force a specific interface
sudo bash apply-tuning.sh -h          # help
```

A backup snapshot (`sysctl -a` + `iptables-save`) is written to `/var/backups/node-diagnostic/` before any change, and every action is recorded in `/etc/node-diagnostic.applied`.

### `revert-tuning.sh` — undo it all

Cleanly reverses everything `apply-tuning.sh` (or `node-diagnostic.sh`) did:

- removes `99-vpn-tuning.conf` and `98-swappiness.conf`
- deletes the iptables MSS-clamp rules from FORWARD/OUTPUT
- disables + removes `vpn-rps.service` and `vpn-ring.service`
- optionally restores `net.*` sysctls from the latest backup snapshot (`--restore`)
- clears the journal `/etc/node-diagnostic.applied`

```bash
# Just run it
curl -sSL https://raw.githubusercontent.com/itsvenoxy/node-diagnostic/main/revert-tuning.sh | sudo bash
# Or download and run
wget https://raw.githubusercontent.com/itsvenoxy/node-diagnostic/main/revert-tuning.sh
sudo bash revert-tuning.sh
```

```bash
sudo bash revert-tuning.sh            # remove tuning, reload defaults
sudo bash revert-tuning.sh --restore  # also restore net.* from the latest backup
sudo bash revert-tuning.sh --dry-run  # show what would be removed
```

> Without `--restore`, the running `net.*` values stay in effect until the next reboot (the drop-in files are gone, so they won't reapply). Backups in `/var/backups/node-diagnostic/` are never deleted.

## Run artifacts

- `/tmp/node-diagnostic-<ts>.log` — full detailed log
- `/tmp/node-diagnostic-summary-<ts>.txt` — compact flat summary (no ANSI colors, easy to share)
- `/var/backups/node-diagnostic/sysctl-<ts>.txt` — snapshot of settings before the fix
- `/var/backups/node-diagnostic/iptables-<ts>.rules` — snapshot of iptables before the fix

## Typical scenario

```bash
# 1. Full diagnosis
sudo bash node-diagnostic.sh

# 2. Apply the recommended fixes (or -a for everything at once)

# 3. Quickly re-check what got fixed
sudo bash node-diagnostic.sh -q
```

## Comparing nodes

Run on two nodes, compare the summaries:

```bash
# Helsinki, NODE HOST AS198550 — slow
[10/23] ✗ Loss to Google     max 18% loss
[11/23] ✗ Route             10h · loss 53% at 62.115.137.119/53.0%
[14/23] ✗ Speed: 1-flow      21 Mbit/s

# Helsinki, OC NETWORKS AS209693 — working
[10/23] ✓ Loss to Google     max 0% loss
[11/23] ✓ Route             8h · loss 0%
[14/23] ✓ Speed: 1-flow      800 Mbit/s
```

In that case sysctl settings won't help — the problem is the provider's peering. The script sees this and warns about it separately in the summary.

## System requirements

- Linux (Ubuntu/Debian/RHEL/Fedora/Alpine)
- bash 4+
- root to apply fixes (diagnostics without root work too, but some checks are skipped)

Tested on Ubuntu 22.04, Debian 12, Alpine 3.18.

## License

MIT.
