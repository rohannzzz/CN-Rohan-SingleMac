#!/usr/bin/env bash
# ==============================================================================
# single-mac.sh — run the whole Team Adam 4-Mac project on ONE Mac
#
# Idea: every "Mac" becomes its own loopback IP on this machine, so each role
# keeps a distinct IP and the existing configs/scripts keep working unchanged.
#
#     Mac 1  Primary DNS      127.0.0.11   dnsmasq :53
#     Mac 2  Edge NGINX       127.0.0.12   nginx   :80/:443
#     Mac 3  Backend A        127.0.0.13   node    :3001   (+ standby edge :443)
#     Mac 4  Backend B/DNS2   127.0.0.14   node    :3002   (+ backup DNS :53)
#
# Put this file in the project root (next to README.md), then:
#   chmod +x single-mac.sh && ./single-mac.sh setup && ./single-mac.sh start
#   ./single-mac.sh check
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RUN=/tmp/adam
export CERTS="$ROOT/.certs"
export M1=127.0.0.11 M2=127.0.0.12 M3=127.0.0.13 M4=127.0.0.14
DOMAIN=app.team1.test

PRIMARY_CONF="$ROOT/config/dnsmasq/dnsmasq-phase2-primary.conf"
BACKUP_CONF="$ROOT/config/dnsmasq/dnsmasq-phase2-backup.conf"
EDGE_CONF="$ROOT/config/nginx/nginx-phase2.conf"
STANDBY_CONF="$ROOT/config/nginx/nginx-standby.conf"
PF_CONF="$ROOT/config/firewall/pf-rules.conf"

say()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mxx  %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$ROOT/scripts/update-ips.sh" ] || die "Put single-mac.sh in the project root (next to README.md)."

# ------------------------------------------------------------------ setup ----
aliases_up() {
  for ip in $M1 $M2 $M3 $M4; do
    ifconfig lo0 | grep -q "inet $ip " || sudo ifconfig lo0 alias "$ip" 255.255.255.255
  done
}

deps() {
  command -v brew >/dev/null || die "Homebrew is required: https://brew.sh"
  for p in nginx dnsmasq node; do
    command -v "$p" >/dev/null || { say "Installing $p"; brew install "$p"; }
  done
}

certs() {
  mkdir -p "$CERTS"
  if [ ! -f "$CERTS/app.team1.test.key" ]; then
    say "Generating self-signed certificate"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$CERTS/app.team1.test.key" -out "$CERTS/app.team1.test.crt" \
      -subj "/CN=app.team1.test/O=Team1" \
      -addext "subjectAltName=DNS:app.team1.test,DNS:api.team1.test" 2>/dev/null \
      || die "openssl failed"
    cp "$CERTS/app.team1.test.key" "$CERTS/team1.test.key"
    cp "$CERTS/app.team1.test.crt" "$CERTS/team1.test.crt"
    chmod 600 "$CERTS"/*.key
  fi
  touch "$ROOT/.gitignore"
  for e in .certs .bin; do grep -qxF "$e" "$ROOT/.gitignore" || echo "$e" >> "$ROOT/.gitignore"; done
}

# Regenerate every config for loopback IPs and make the two nginx / two dnsmasq
# instances able to coexist on one machine.
gen() {
  [ -d "$ROOT/config.4mac-backup" ] || cp -R "$ROOT/config" "$ROOT/config.4mac-backup"
  say "Regenerating configs with update-ips.sh ($M1 $M2 $M3 $M4)"
  echo n | bash "$ROOT/scripts/update-ips.sh" --non-interactive $M1 $M2 $M3 $M4 >/dev/null \
    || die "update-ips.sh failed"

  # dnsmasq: primary and backup must not both bind 127.0.0.1:53
  perl -pi -e 's/^listen-address=.*/listen-address=$ENV{M1}/' "$PRIMARY_CONF"
  perl -pi -e 's/^listen-address=.*/listen-address=$ENV{M4}/' "$BACKUP_CONF"

  # nginx: separate pid files, bind each edge to its own IP, certs from ./.certs,
  # and make upstream connections originate from the edge IP (needed for pf rules)
  perl -pi -e '
    s#^worker_processes 1;#pid $ENV{RUN}/nginx-primary.pid;\nworker_processes 1;#;
    s#listen 80;#listen $ENV{M2}:80;#;
    s#listen 443 ssl;#listen $ENV{M2}:443 ssl;#;
    s#^(\s*)proxy_connect_timeout 1s;#$1proxy_connect_timeout 1s;\n$1proxy_bind $ENV{M2};#;
    s#/opt/homebrew/etc/nginx/certs#$ENV{CERTS}#g;
  ' "$EDGE_CONF"
  perl -pi -e '
    s#^worker_processes 1;#pid $ENV{RUN}/nginx-standby.pid;\nworker_processes 1;#;
    s#listen 80;#listen $ENV{M3}:80;#;
    s#listen 443 ssl;#listen $ENV{M3}:443 ssl;#;
    s#^(\s*)proxy_connect_timeout 1s;#$1proxy_connect_timeout 1s;\n$1proxy_bind $ENV{M2};#;
    s#/opt/homebrew/etc/nginx/certs#$ENV{CERTS}#g;
  ' "$STANDBY_CONF"

  # pf: on one machine all traffic is loopback, so pf must NOT skip lo0
  cat > "$PF_CONF" <<EOF
# Single-Mac service isolation: only the edge IP may reach the backend ports
edge_ip = "$M2"
backend_ports = "{ 3001, 3002 }"

pass in quick on lo0 proto tcp from \$edge_ip to any port \$backend_ports
block return-rst in quick on lo0 proto tcp from any to any port \$backend_ports
EOF
}

setup() {
  sudo -v || die "sudo required"
  deps
  say "Creating loopback aliases"; aliases_up
  certs
  gen
  say "Routing *.team1.test to the two DNS servers (/etc/resolver)"
  sudo mkdir -p /etc/resolver
  printf 'nameserver %s\nnameserver %s\n' "$M1" "$M4" | sudo tee /etc/resolver/team1.test >/dev/null
  # macOS 'dig' ignores /etc/resolver, so give scripts a dig that asks our DNS servers
  mkdir -p "$ROOT/.bin"
  cat > "$ROOT/.bin/dig" <<EOF
#!/usr/bin/env bash
# dig wrapper: if no @server is given, try primary DNS then backup DNS
for a in "\$@"; do case "\$a" in @*) exec /usr/bin/dig "\$@";; esac; done
out=\$(/usr/bin/dig @$M1 +time=1 +tries=1 "\$@" 2>&1)
if echo "\$out" | grep -qE 'timed out|no servers could be reached|connection refused'; then
  exec /usr/bin/dig @$M4 +time=1 +tries=1 "\$@"
fi
printf '%s\n' "\$out"
EOF
  chmod +x "$ROOT/.bin/dig"
  say "Setup done. Next: ./single-mac.sh start   then   ./single-mac.sh check"
  echo "    (optional, for 'curl https://$DOMAIN' without -k: ./single-mac.sh trust-cert)"
}

# --------------------------------------------------------------- services ----
ALL_SVCS="backend-a backend-b dns1 dns2 edge standby"   # start order (standby optional)
DEFAULT_SVCS="backend-a backend-b edge dns1 dns2"

pidfile() { echo "$RUN/$1.pid"; }
alive()   { [ -f "$(pidfile "$1")" ] && kill -0 "$(cat "$(pidfile "$1")")" 2>/dev/null || \
            { [ -f "$(pidfile "$1")" ] && sudo kill -0 "$(cat "$(pidfile "$1")")" 2>/dev/null; }; }

start_node() {  # name dir port
  local name=$1 dir=$ROOT/backends/$2 port=$3
  lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && { warn "$name: port $port already in use"; return 1; }
  [ -d "$dir/node_modules" ] || (cd "$dir" && npm install --silent)
  # exec makes the subshell BECOME node, so $! is node's real PID
  (cd "$dir" && exec nohup node server.js >"$RUN/$name.log" 2>&1) &
  echo $! >"$(pidfile "$name")"
}

start_svc() {
  mkdir -p "$RUN"
  case "$1" in
    backend-a) start_node backend-a backend-a 3001 ;;
    backend-b) start_node backend-b backend-b 3002 ;;
    dns1) sudo brew services stop dnsmasq >/dev/null 2>&1
          sudo dnsmasq -C "$PRIMARY_CONF" --pid-file="$(pidfile dns1)" ;;
    dns2) sudo dnsmasq -C "$BACKUP_CONF" --pid-file="$(pidfile dns2)" ;;
    edge)    sudo nginx -t -c "$EDGE_CONF" 2>&1 | tail -1; sudo nginx -c "$EDGE_CONF" ;;
    standby) sudo nginx -t -c "$STANDBY_CONF" 2>&1 | tail -1; sudo nginx -c "$STANDBY_CONF" ;;
    *) die "unknown service '$1' (one of: $ALL_SVCS)" ;;
  esac
  sleep 0.4
  if [ "$1" = edge ]; then pf=$RUN/nginx-primary.pid; elif [ "$1" = standby ]; then pf=$RUN/nginx-standby.pid; else pf=$(pidfile "$1"); fi
  if [ -f "$pf" ] && sudo kill -0 "$(cat "$pf")" 2>/dev/null; then echo "  started  $1"; else warn "$1 did not start (see $RUN/ and 'sudo nginx -t -c ...')"; fi
}

stop_svc() {
  local pf
  case "$1" in
    edge) pf=$RUN/nginx-primary.pid ;;
    standby) pf=$RUN/nginx-standby.pid ;;
    backend-a|backend-b|dns1|dns2) pf=$(pidfile "$1") ;;
    *) die "unknown service '$1'" ;;
  esac
  [ -f "$pf" ] && { sudo kill "$(cat "$pf")" 2>/dev/null; rm -f "$pf"; }
  # backends: also kill whatever still listens on the port (covers orphaned processes)
  case "$1" in backend-a) port=3001;; backend-b) port=3002;; *) port="";; esac
  if [ -n "$port" ]; then
    pids=$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null)
    [ -n "$pids" ] && kill $pids 2>/dev/null
    sleep 0.3
    if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then warn "$1 still listening on $port"; else echo "  stopped  $1"; fi
  else
    echo "  stopped  $1"
  fi
}

start_all() { sudo -v; aliases_up; for s in $DEFAULT_SVCS; do start_svc "$s"; done
              sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null; true; }
stop_all()  { for s in standby edge dns1 dns2 backend-a backend-b; do stop_svc "$s"; done; }

status() {
  echo "Listening sockets:"
  sudo lsof -nP -iTCP:80,443,3001,3002 -sTCP:LISTEN -iUDP:53 2>/dev/null | awk 'NR==1||/nginx|node|dnsmasq/' 
  echo; echo "DNS: $DOMAIN -> $(PATH="$ROOT/.bin:$PATH" dig +short $DOMAIN)"
}

# --------------------------------------------------------- DNS / firewall ----
dns_point() {  # dns_point <ip|reset> — change the A record on the primary DNS and restart it
  local ip=${1:-}; [ -n "$ip" ] || die "usage: dns-point <ip|reset>   (reset = $M2, standby edge = $M3)"
  [ "$ip" = reset ] && ip=$M2
  perl -pi -e 's#^address=/app\.team1\.test/.*#address=/app.team1.test/'"$ip"'#' "$PRIMARY_CONF"
  stop_svc dns1; start_svc dns1
  sudo dscacheutil -flushcache 2>/dev/null; sudo killall -HUP mDNSResponder 2>/dev/null
  echo "  primary DNS now answers: $(/usr/bin/dig @$M1 +short $DOMAIN)"
}

fw_on()  { sudo pfctl -nf "$PF_CONF" && sudo pfctl -ef "$PF_CONF" 2>&1 | grep -v "^$"; sudo pfctl -sr 2>/dev/null | grep -E '3001|3002'; }
fw_off() { sudo pfctl -f /etc/pf.conf 2>/dev/null; sudo pfctl -d 2>&1 | tail -1; }

trust_cert()   { sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CERTS/app.team1.test.crt" && say "Certificate trusted (remove later with: untrust-cert)"; }
untrust_cert() { sudo security delete-certificate -c app.team1.test /Library/Keychains/System.keychain; }

# ------------------------------------------------------------------ check ----
check() {
  export PATH="$ROOT/.bin:$PATH"
  local ok=0 bad=0
  t() { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "  PASS  $d"; ok=$((ok+1)); else echo "  FAIL  $d"; bad=$((bad+1)); fi; }
  c_dns1()  { /usr/bin/dig @$M1 +short +time=1 +tries=1 $DOMAIN | grep -q .; }
  c_dns2()  { /usr/bin/dig @$M4 +short +time=1 +tries=1 $DOMAIN | grep -q .; }
  c_sys()   { dscacheutil -q host -a name $DOMAIN | grep -q ip_address; }
  c_a()     { curl -s --max-time 2 http://$M3:3001/ | grep -q '"A"'; }
  c_b()     { curl -s --max-time 2 http://$M4:3002/ | grep -q '"B"'; }
  c_https() { [ "$(curl -sk --max-time 3 -o /dev/null -w '%{http_code}' https://$DOMAIN/)" = 200 ]; }
  c_redir() { [ "$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://$DOMAIN/)" = 301 ]; }
  c_lb()    { local o; o=$(for i in 1 2 3 4 5 6; do curl -sk -D - -o /dev/null https://$DOMAIN/ | tr -d '\r' | grep -i '^x-backend'; done)
              echo "$o" | grep -qi ': A' && echo "$o" | grep -qi ': B'; }
  c_cache() { curl -skI https://$DOMAIN/api/status | grep -qi 'cache-control: max-age=60'; }
  echo "Single-Mac stack check"
  t "Primary DNS ($M1) answers"               c_dns1
  t "Backup DNS  ($M4) answers"               c_dns2
  t "macOS resolver resolves $DOMAIN"         c_sys
  t "Backend A direct (fails if firewall ON)" c_a
  t "Backend B direct (fails if firewall ON)" c_b
  t "HTTPS via edge returns 200"              c_https
  t "HTTP -> HTTPS redirect (301)"            c_redir
  t "Load balancing alternates A and B"       c_lb
  t "Cache-Control: max-age=60 on /api/status" c_cache
  echo "Result: $ok passed, $bad failed"
}

teardown() {
  stop_all; fw_off
  for ip in $M1 $M2 $M3 $M4; do sudo ifconfig lo0 -alias "$ip" 2>/dev/null; done
  sudo rm -f /etc/resolver/team1.test
  if [ -d "$ROOT/config.4mac-backup" ]; then rm -rf "$ROOT/config" && mv "$ROOT/config.4mac-backup" "$ROOT/config"; fi
  say "Back to the original 4-Mac configuration."
}

usage() { cat <<EOF
Usage: ./single-mac.sh <command>

  setup                 one-time: loopback IPs, certs, configs, DNS routing
  start | stop          start / stop everything
  start <svc> | stop <svc>   one service: $ALL_SVCS
  status                what is listening
  check                 quick PASS/FAIL health check of the whole stack
  dns-point <ip|reset>  change app.team1.test A record (Ext B: 10.7.21.99, Ext E: $M3)
  fw-on | fw-off        service-isolation firewall (Ext C)
  trust-cert | untrust-cert   trust the self-signed cert (curl without -k)
  shell                 subshell where 'dig' uses the project DNS servers
  run <cmd...>          run any project script that way, e.g. run ./scripts/test-ha-failover.sh
  gen                   regenerate configs only
  teardown              undo everything, restore the 4-Mac configs
EOF
}

case "${1:-}" in
  setup) setup ;;
  gen) certs; gen ;;
  start) if [ -n "${2:-}" ]; then sudo -v; start_svc "$2"; else start_all; fi ;;
  stop)  if [ -n "${2:-}" ]; then stop_svc "$2"; else stop_all; fi ;;
  restart) stop_all; start_all ;;
  status) status ;;
  check) check ;;
  dns-point) dns_point "${2:-}" ;;
  fw-on) fw_on ;;
  fw-off) fw_off ;;
  trust-cert) trust_cert ;;
  untrust-cert) untrust_cert ;;
  shell) PATH="$ROOT/.bin:$PATH" exec "${SHELL:-bash}" ;;
  run) shift; PATH="$ROOT/.bin:$PATH" "$@" ;;
  teardown) teardown ;;
  *) usage ;;
esac
