# Viva Preparation

**Rohan, 2401020103** (individual submission)

## 1. 30-second summary

"I ran the Private Network Service Platform, with all Phase 2 extensions A to F, on a single Mac. The four machines of the original design are four loopback addresses, `127.0.0.11` to `127.0.0.14`. DNS resolves `app.team1.test` to an NGINX edge over HTTPS, which load-balances two backends. I tested backup DNS, TTL, a pf firewall, backend failover, an edge cutover and a four-layer diagnosis tool, and the final health check is 9 passed, 0 failed."

**Be ready to say honestly:** the base design, configs and scripts come from Team Adam; my part is the single-Mac adaptation, my own test run, screenshots and report. All traffic is loopback, so this is not a physical four-node network.

## 2. Concept questions

### DNS
- **What does DNS do here?** It maps `app.team1.test` to the edge, `127.0.0.12`. The `.test` name is reserved, so it never clashes with the real internet.
- **What is TTL?** How many seconds a resolver or client may cache an answer. Ours is 30 s.
- **Why a short TTL?** A change (for example an edge cutover) reaches clients within about 30 s. The cost is more queries.
- **Why did the old IP persist after the record changed?** The macOS cache kept it until TTL expiry; `dscacheutil -flushcache` and `killall -HUP mDNSResponder` clear it at once.
- **How does backup DNS work?** The client lists two nameservers. If the first does not answer, it tries the second. Both serve the same records.
- **Which record type?** `A` (name to IPv4 address).

### TCP and TLS
- **TCP three-way handshake?** SYN, SYN-ACK, ACK before any data.
- **What does TLS add?** Encryption, server authentication via a certificate, and integrity.
- **Why does `curl` work without `-k`?** The self-signed certificate was added to the system trust store (`./single-mac.sh trust-cert`), so it verifies.
- **Why a certificate warning in Layer 3 of the diagnosis?** The certificate is self-signed, so the check flags it. It is an expected false alarm.
- **What does the edge do with HTTP?** Port 80 returns `301` to HTTPS.

### HTTP, caching and load balancing
- **What does `Cache-Control: max-age=60` mean?** Clients and caches may reuse the response for 60 s without asking again.
- **What is round-robin?** Requests alternate A, B, A, B. `X-Backend` shows which server answered.
- **What is a reverse proxy?** The client talks only to the edge; the edge talks to the backends. That gives one entry point, TLS in one place and hidden backends.

### Extensions
- **A: Backup DNS.** Proves name resolution survives a DNS failure. Evidence: resolved via `127.0.0.14`.
- **B: TTL and cache.** Proves TTL behaviour and manual cache invalidation.
- **C: Firewall.** `pf` allows ports 3001 and 3002 only from the edge `127.0.0.12`. `pass in quick` stops rule evaluation at a match. `block return-rst` rejects with a TCP reset, so the client sees "refused" immediately instead of waiting for a timeout.
- **D: Failover.** NGINX uses `max_fails=1` and `fail_timeout=10s`. A failed upstream is skipped and the request is retried on the other backend, so the client sees no 502.
- **E: Edge cutover.** Standby NGINX on `127.0.0.13`; the DNS record moves to it; `X-Edge-Proxy` changes from `nginx-primary-mac2` to `nginx-standby-mac3`.
- **F: Troubleshooting.** Work bottom-up: Layer 1 DNS, Layer 2 reachability and port 443, Layer 3 TLS, Layer 4 application. With both backends stopped, Layers 1 and 2 pass and Layer 4 fails with `502 Bad Gateway`, so the fault is in the backends.
- **Why 502 and not 504?** 502 means the edge got no valid answer from an upstream (connection refused). 504 means the upstream was reached but too slow.

### Single-Mac setup
- **How can one Mac have four addresses?** The whole `127.0.0.0/8` block is loopback. The extra addresses are added as aliases on `lo0` (check with `ifconfig lo0 | grep 127.0.0`).
- **What is different from four Macs?** No physical link, so no Wi-Fi latency, ARP between hosts or real cross-host firewall traffic.
- **Why is this still valid?** The same software and configs run; what is tested is service behaviour, not the physical medium.

## 3. Live demo cheat sheet

Run from the project folder.

| Goal | Command |
|---|---|
| Health check | `./single-mac.sh check` |
| Start everything (after reboot) | `./single-mac.sh start` |
| DNS record | `dig app.team1.test` |
| HTTPS, no `-k` | `curl -v https://app.team1.test/` |
| Cache header | `curl -I https://app.team1.test/api/status` |
| Load balancing | loop of `curl -s https://app.team1.test/` showing `X-Backend` |
| Failover | `./single-mac.sh stop backend-a`, run requests, then `./single-mac.sh start backend-a` |
| Firewall | `./single-mac.sh fw-on`, test direct :3001 and :3002, then `./single-mac.sh fw-off` |
| Edge cutover | `./single-mac.sh start standby`, then `./single-mac.sh dns-point 127.0.0.13`, later `./single-mac.sh dns-point reset` and `./single-mac.sh stop standby` |
| Fault diagnosis | stop both backends, then `./single-mac.sh run ./scripts/diagnose-stack.sh` |

Before the viva, make sure `./single-mac.sh check` says `9 passed, 0 failed`, the firewall is off and DNS is reset.
