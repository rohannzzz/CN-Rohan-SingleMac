# Team 1 DNS

Mac 1 runs dnsmasq as the private DNS resolver.

DNS server:
127.0.0.11

Private records:

- app.team1.test -> 127.0.0.12
- api.team1.test -> 127.0.0.12

Clients configured to use this DNS server:

- (Mac 2 / Edge)
- (Mac 3 / Backend A)
- (Mac 4 / Backend B)
