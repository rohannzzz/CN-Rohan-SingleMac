# Private Network Service Platform: Single-Mac Edition

**Rohan, 2401020103** (individual submission)

A private network service (DNS, HTTPS edge, load-balanced backends, caching) with all Phase 2 resilience extensions, running on **one Mac**. The four "machines" are loopback addresses `127.0.0.11` to `127.0.0.14`.

```
CLIENT -> DNS 127.0.0.11 (backup 127.0.0.14)
       -> EDGE NGINX 127.0.0.12 (standby 127.0.0.13)
       -> BACKEND A :3001 / BACKEND B :3002
```

## Quick start

```bash
./single-mac.sh start      # start DNS, edge, backends (run once after boot)
./single-mac.sh check      # expect: 9 passed, 0 failed
./single-mac.sh stop       # stop services
```

Run these from the project folder. Run `start` only when the stack is not already running; use `check` to see its state.

## Results

| Ext | Topic | Evidence |
|---|---|---|
| A | Backup DNS failover | `evidence/dns/backup-dns-failover.png` |
| B | DNS TTL and cache flush | `evidence/dns/ttl-30s-countdown.png`, `ttl-cache-and-flush.png` |
| C | Firewall service isolation | `evidence/firewall/` |
| D | HA failover | `evidence/failover/backend-a-down-failover-to-b.png` |
| E | Edge cutover | `evidence/cutover/standby-edge-cutover-header.png` |
| F | 4-layer troubleshooting | `evidence/troubleshooting/diagnose-stack-4layers.png` |

Full write-up: [`docs/phase2-report.md`](docs/phase2-report.md). Viva notes: [`docs/viva-prep.md`](docs/viva-prep.md).

## Layout

```
backends/  config/  scripts/  docs/  evidence/  single-mac.sh
```

## Credits and scope

The base design, configs, backend app and test scripts come from **Team Adam** (`manas-2212/ComputerNetworks---ADAM`). This repository adapts that project to a single machine and contains my own test run, screenshots and report. Results come from loopback traffic on one Mac, not four physical machines.
