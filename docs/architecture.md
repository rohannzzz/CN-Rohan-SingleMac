# Architecture: Single-Mac Private Network Service Platform

**Rohan, 2401020103** (individual submission). Base design from Team Adam (`manas-2212/ComputerNetworks---ADAM`), adapted to run on one Mac.

## 1. Topology

The original design uses four laptops on one Wi-Fi LAN. Here each laptop is replaced by a loopback address on one Mac.

```
                 CLIENT (macOS resolver, curl, dig)
                              |
                              | DNS :53
                              v
        +-----------------------------------------------+
        | PRIMARY DNS   127.0.0.11   dnsmasq             |
        | BACKUP DNS    127.0.0.14   dnsmasq (Ext A)     |
        | app.team1.test -> 127.0.0.12   (TTL 30 s)      |
        +-----------------------+-----------------------+
                                |
                                v
        +-----------------------------------------------+
        | PRIMARY EDGE  127.0.0.12   NGINX :80 / :443    |
        | TLS termination, HTTP->HTTPS 301, round-robin, |
        | Cache-Control, passive health checks           |
        | STANDBY EDGE  127.0.0.13   NGINX :443 (Ext E)  |
        +-----------+-------------------------+---------+
                    | HTTP                    | HTTP
                    v                         v
        +-------------------+       +-------------------+
        | BACKEND A         |       | BACKEND B         |
        | 127.0.0.13:3001   |       | 127.0.0.14:3002   |
        | Node.js Express   |       | Node.js Express   |
        +-------------------+       +-------------------+
```

## 2. Roles and addresses

| Original machine | Loopback address | Services | Key behaviour |
|---|---|---|---|
| Mac 1 | `127.0.0.11` | Primary DNS (`dnsmasq`, UDP/TCP 53) | Short TTL (30 s) so changes propagate quickly |
| Mac 2 | `127.0.0.12` | Primary edge (`nginx`, TCP 80 and 443) | TLS termination, load balancing, passive health checks |
| Mac 3 | `127.0.0.13` | Backend A (`:3001`), standby NGINX (`:443`) | Backend and migration target |
| Mac 4 | `127.0.0.14` | Backend B (`:3002`), backup `dnsmasq` | Second backend and DNS redundancy |

All addresses and the domain names (`app.team1.test`, `api.team1.test`) are defined once in `config/network.env`.

## 3. Request flow by layer

| Step | Layer | What happens |
|---|---|---|
| 1 | Application (DNS) | The client asks the resolver for `app.team1.test`; the primary DNS answers `127.0.0.12` (backup DNS if the primary is down). |
| 2 | Transport (TCP) | Three-way handshake to `127.0.0.12:443`. |
| 3 | Security (TLS) | TLS handshake; the edge presents a self-signed certificate, trusted on this Mac with `./single-mac.sh trust-cert`. |
| 4 | Application (HTTP) | `GET /`; the edge picks Backend A or B round-robin and adds the `X-Backend` header. |
| 5 | Application (cache) | `/api/status` carries `Cache-Control: max-age=60`. |

## 4. Phase 2 design

| Extension | Mechanism | Component |
|---|---|---|
| A: Backup DNS | Second dnsmasq on `127.0.0.14`; client lists both nameservers | DNS |
| B: TTL and cache | TTL 30 s; client cache flushed with `dscacheutil` and `mDNSResponder` | DNS and client |
| C: Service isolation | `pf` rules on ports 3001 and 3002: `pass in quick` from `127.0.0.12`, `block return-rst` for all others | Firewall |
| D: High availability | NGINX `max_fails=1`, `fail_timeout=10s`, retry on the next upstream | Edge |
| E: Edge migration | Standby NGINX on `127.0.0.13` plus DNS record change; `X-Edge-Proxy` header shows which edge served | Edge and DNS |
| F: Troubleshooting | `scripts/diagnose-stack.sh` checks DNS, network and port, TLS, application in order | Tooling |

## 5. What this setup does and does not prove

- **Proves:** the real software (dnsmasq, NGINX, pf, Express) behaves as designed: resolution, TLS, balancing, caching, failover and isolation.
- **Does not prove:** physical-network behaviour (Wi-Fi latency, ARP between hosts, firewall traffic crossing a real link). Everything stays on the loopback interface.

## 6. Control script

`single-mac.sh` is the single entry point: `start`, `stop <service>`, `start <service>`, `check`, `fw-on`, `fw-off`, `dns-point <ip|reset>` and `run <script>`. `./single-mac.sh check` runs 9 checks and must report `9 passed, 0 failed`.
