# Nginx under DDoS / high CPU — one-page cheat sheet

English quick reference for the Vietnamese playbook in
[`README.md`](../README.md).

## 1. Identify the bottleneck

```bash
uptime; nproc                      # load / cores > 1.5 means trouble
mpstat -P ALL 1 5                  # %usr vs %sys vs %wa vs %steal
free -h; swapon --show             # swap full + %wa high = RAM shortage
ss -s                              # connection summary
ss -H -tan state syn-recv | wc -l  # thousands = SYN flood (L4)
dmesg -T | grep -i oom | tail      # OOM kills
```

| CPU column high | Means | Action |
|-----------------|-------|--------|
| `%usr` | PHP/app work | Optimise code, cache, scale |
| `%sys` | syscalls / network | DDoS L4/L7, raise timeouts, edge protection |
| `%wa` | disk wait | DB, logging, swap |
| `%steal` | hypervisor | VPS noisy neighbour — open a ticket |

## 2. Is nginx actually overloaded?

Enable `stub_status` on localhost, then:

```bash
curl -s http://127.0.0.1/nginx_status
a=$(curl -s 127.0.0.1/nginx_status | awk '/requests/{print $3}'); sleep 1
b=$(curl -s 127.0.0.1/nginx_status | awk '/requests/{print $3}'); echo "rps=$((b-a))"
tail -100 /var/log/nginx/error.log
```

Key error strings: `worker_connections are not enough`, `Too many open files`,
`upstream timed out`, `connect() failed (111)`, `SSL_do_handshake() failed`.

## 3. Find the attacker

```bash
sudo ./scripts/nginx-top.sh -n 30
```

Reads: top IP / URL / UA / status, POST flood, requests-per-IP, rps, scanners.

Manual equivalents:

```bash
awk '{print $1}' access.log | sort | uniq -c | sort -rn | head -20
awk '{print $7}' access.log | cut -d? -f1 | sort | uniq -c | sort -rn | head
awk -F'"' '{print $6}' access.log | sort | uniq -c | sort -rn | head
```

## 4. Block in the right order

1. **Protect SSH/admin** — allowlist your IP.
2. **nginx rate limit** — `limit_req_zone` 10 r/s, login 1 r/s.
3. **Block IPs** — nginx `deny`, `nftables` set, or CDN.
4. **CDN/WAF** — challenge mode, rate limiting rules, WAF.
5. **Reduce load** — micro-cache 10s, shorter timeouts.
6. **L4** — provider scrubbing; nginx cannot help there.

> Behind Cloudflare? Configure `real_ip` **before** blocking, or you will block
> Cloudflare itself and take the site down.

## 5. PHP-FPM

```bash
curl -s http://127.0.0.1/fpm-status
tail -50 /var/log/php-fpm/slow.log
ps -o rss= -C php-fpm | awk '{s+=$1;n++} END{printf "%.1f MB/worker\n", s/n/1024}'
```

```
max_children = (RAM for PHP) / (average RSS per worker)
```

`max children reached > 0` + free RAM → raise `max_children`.
`max children reached > 0` + swap full → fix the code, not the pool.

## 6. Thresholds

| Metric | Normal | Warning | Critical |
|--------|--------|---------|----------|
| load/core | < 0.7 | 0.7–1.5 | > 2.0 |
| `%sys` | < 15% | 15–40% | > 40% |
| `%wa` | < 5% | 5–20% | > 20% |
| established 80/443 | < 2k | 2k–10k | > 10k |
| `syn-recv` | ~0 | 100–1k | > 1k |
| 5xx | < 0.1% | 0.1–1% | > 1% |
| `max children reached` | 0 | 1–10 | > 10 |

## 7. High CPU without traffic

Check for malware/miner: unknown processes, `exe (deleted)`, non-empty
`/etc/ld.so.preload`, unknown systemd timers, outbound connections to mining
pools. Use [linux-malware-check](https://github.com/fixnhanh-linux/linux-malware-check).

## 8. Do not

- Reboot before capturing evidence.
- Delete logs.
- Block large IP ranges or your CDN.
- Raise `max_children` without checking RAM.
- Disable the firewall to "test".
