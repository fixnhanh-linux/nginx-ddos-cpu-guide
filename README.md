# Nginx bị DDoS / CPU cao — playbook chẩn đoán & xử lý

[![nginx](https://img.shields.io/badge/nginx-1.18%2B-009639?logo=nginx&logoColor=white)](https://nginx.org/)
[![php](https://img.shields.io/badge/PHP--FPM-7.4%2B-777BB4?logo=php&logoColor=white)](https://www.php.net/)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![PRs](https://img.shields.io/badge/PRs-welcome-brightgreen)](https://github.com/fixnhanh-linux/nginx-ddos-cpu-guide/pulls)
[![Vietnamese](https://img.shields.io/badge/ng%C3%B4n%20ng%E1%BB%AF-Ti%E1%BA%BFng%20Vi%E1%BB%87t-red)](README.md)

**Playbook thực chiến** cho lúc web server `CPU 100%`, `load` vọt cao, site chậm
hoặc trả `502/504`.

Trả lời 3 câu hỏi, theo đúng thứ tự:

| # | Câu hỏi | Trả lời ở |
|---|---------|-----------|
| 1 | **CPU đang bị tiêu vào đâu?** traffic thật, DDoS L7, DDoS L4, hay malware/DB/I/O | [mục 1](#1-bốn-loại-cpu-cao) · [mục 3](#3-chẩn-đoán-60-giây) |
| 2 | **Ai đang tấn công?** IP, URL, User-Agent, request/s | [mục 4](#4-đọc-access-log-để-tìm-kẻ-tấn-công) · [mục 5](#5-các-kiểu-tấn-công-và-dấu-hiệu) |
| 3 | **Chặn thế nào cho đúng?** không chặn nhầm CDN, không mất SSH | [mục 6](#6-chặn-tạm-thời--đúng-thứ-tự) |

Kèm 2 script **chỉ đọc**, chạy được ngay trên production, và 3 file cấu hình mẫu.

> [!TIP]
> Đang cháy máy? Nhảy thẳng tới [TL;DR 10 phút](#0-tldr--10-phút-đầu-tiên) hoặc
> chạy `sudo ./scripts/triage.sh` rồi quay lại đọc tiếp.

**English:** [one-page cheat sheet](docs/quick-reference-en.md)

---

## Tra nhanh theo triệu chứng

| Bạn thấy gì? | Khả năng cao nhất | Đọc mục |
|--------------|-------------------|---------|
| CPU 100%, rps rất cao, 1–3 IP chiếm phần lớn | HTTP flood L7 | [5](#5-các-kiểu-tấn-công-và-dấu-hiệu), [6.3](#63-bước-2--rate-limit-trong-nginx-hiệu-quả-nhất-với-l7) |
| CPU cao, rps bình thường, process lạ | Malware / miner | [9](#9-cpu-cao-nhưng-không-phải-do-traffic) |
| `%sys` cao, `syn-recv` hàng nghìn | SYN flood L4 | [6.7](#67-bước-6--l4-thì-gọi-provider) |
| `%wa` cao, swap đầy, có OOM | Thiếu RAM / DB / I/O | [3.3](#33-ram-và-swap), [7.6](#76-database) |
| `%steal` cao | VPS bị hàng xóm chiếm CPU | [3.2](#32-cpu-đang-tiêu-vào-đâu) |
| Site trả 502/504 | PHP-FPM chết / hết worker | [7](#7-php-fpm-cpu-cao-do-code) |
| `Reading` cao, nhiều kết nối mở lâu | Slowloris | [5](#5-các-kiểu-tấn-công-và-dấu-hiệu), [6.6](#66-bước-5--giảm-tải-để-giữ-site-sống) |
| `429` hàng loạt sau khi bật rate limit | Rate limit quá chặt | [6.3](#63-bước-2--rate-limit-trong-nginx-hiệu-quả-nhất-với-l7) |
| Log toàn `POST /wp-login.php` | Brute-force / credential stuffing | [5](#5-các-kiểu-tấn-công-và-dấu-hiệu) |
| Top URL `/?s=<random>` | Search flood (WordPress) | [4.2](#42-cách-đọc-kết-quả) |
| Đang dùng Cloudflare mà log toàn IP lạ | Thiếu `real_ip` | [6.5](#65-bước-4--nếu-có-cdnwaf-cloudflare-fastly-buny) |
| Console provider vào được, SSH thì timeout/refused | IP bị chặn, `sshd` chết, `MaxStartups`, conntrack đầy | [6.8](#68-console-vào-được-ssh-không--vì-sao) |

## Cây quyết định 30 giây

```
CPU cao?
│
├─ rps cao?  (curl /nginx_status, 2 lần cách 1s)
│   ├─ CÓ ──> %sys cao? ──> SYN/TLS flood ────────────> mục 6.7 (provider)
│   │                    └─ %usr cao? ──> HTTP flood ──> mục 4 + 6.3 + 6.4
│   │
│   └─ KHÔNG ─> %wa cao / swap đầy? ──────────────────> mục 3.3 + 7.6
│                └─ process lạ, exe (deleted)? ───────> mục 9 (malware)
│
└─ Không rõ ──> chạy scripts/triage.sh, đọc bảng ở mục 3.2
```

**Mục lục**

- [Tra nhanh theo triệu chứng](#tra-nhanh-theo-triệu-chứng)
- [Cây quyết định 30 giây](#cây-quyết-định-30-giây)
- [0. TL;DR — 10 phút đầu tiên](#0-tldr--10-phút-đầu-tiên)
- [1. Bốn loại “CPU cao”](#1-bốn-loại-cpu-cao)
- [2. Bộ công cụ](#2-bộ-công-cụ)
- [3. Chẩn đoán 60 giây](#3-chẩn-đoán-60-giây)
- [4. Đọc access log để tìm kẻ tấn công](#4-đọc-access-log-để-tìm-kẻ-tấn-công)
- [5. Các kiểu tấn công và dấu hiệu](#5-các-kiểu-tấn-công-và-dấu-hiệu)
- [6. Chặn tạm thời — đúng thứ tự](#6-chặn-tạm-thời--đúng-thứ-tự)
- [7. PHP-FPM: CPU cao do code](#7-php-fpm-cpu-cao-do-code)
- [8. Tối ưu bền vững](#8-tối-ưu-bền-vững)
- [9. CPU cao nhưng không phải do traffic](#9-cpu-cao-nhưng-không-phải-do-traffic)
- [10. Sau sự cố](#10-sau-sự-cố)
- [11. Chống tái diễn](#11-chống-tái-diễn)
- [12. Runbook 15 lệnh](#12-runbook-15-lệnh)
- [13. Case study: 12 phút dập flood](#13-case-study-12-phút-dập-flood)
- [14. FAQ](#14-faq)
- [15. Thuật ngữ](#15-thuật-ngữ)
- [Phụ lục](#phụ-lục)

---

## 0. TL;DR — 10 phút đầu tiên

| Phút | Việc | Lệnh |
|------|------|------|
| 0–1 | Chụp toàn cảnh, **không reboot** | `sudo ./scripts/triage.sh` |
| 1–3 | Xem CPU tiêu vào đâu | `mpstat -P ALL 1 5`<br>`top -b -n1 -o %CPU \| head -20` |
| 3–5 | Đếm kết nối & request/s | `ss -s`<br>`curl -s 127.0.0.1/nginx_status` |
| 5–8 | Tìm IP/URL/UA nổi bật | `sudo ./scripts/nginx-top.sh` |
| 8–10 | Chặn tạm thời đúng thứ tự | [mục 6](#6-chặn-tạm-thời--đúng-thứ-tự) |

> [!WARNING]
> **Không reboot, không xóa log, không tắt firewall** trước khi chụp bằng chứng.
> Reboot xong vẫn bị tấn công tiếp và bạn mất toàn bộ dấu vết.

---

## 1. Bốn loại “CPU cao”

Đừng mặc định “CPU cao = DDoS”. Có 4 nguyên nhân rất khác nhau về cách xử lý:

| Loại | Dấu hiệu nhận biết | Hướng xử lý |
|------|--------------------|-------------|
| **Traffic thật tăng** | request/s tăng, IP phân tán, `%us` cao, 2xx/3xx là chủ yếu | Tối ưu code/cache, scale, tăng `max_children` |
| **DDoS lớp 7 (HTTP flood)** | rps rất cao từ ít IP hoặc cùng UA, path lạ, 4xx cao, `%us` + `%sy` cao | Rate limit, WAF, chặn IP/ASN |
| **DDoS lớp 4 (SYN/UDP/TLS flood)** | rps bình thường nhưng `%sy` cao, `syn-recv` lớn, băng thông đầy, `%steal` tăng | Xử lý ở provider/edge (Cloudflare, ACL) |
| **Không phải traffic** | rps thấp mà CPU vẫn 100%, process lạ, `%wa` cao, kernel tainted | Malware/miner, DB chậm, I/O, swap |

Câu hỏi quyết định: **CPU cao có tương ứng với request/s cao không?**

- Có → [mục 4](#4-đọc-access-log-để-tìm-kẻ-tấn-công) và [mục 5](#5-các-kiểu-tấn-công-và-dấu-hiệu).
- Không → [mục 9](#9-cpu-cao-nhưng-không-phải-do-traffic) (malware) hoặc phần DB/I/O trong [mục 7.6](#76-database).

---

## 2. Bộ công cụ

`sysstat`, `iproute2`, `procps`, `curl` là đủ cho 90% tình huống.

```bash
# Debian / Ubuntu
apt-get update
apt-get install -y sysstat iproute2 procps curl lsof net-tools jq

# RHEL / Rocky / Alma
dnf install -y sysstat iproute procps-ng curl lsof net-tools jq
```

Tùy chọn, rất đáng cài trên máy production:

| Công cụ | Dùng để |
|---------|---------|
| `goaccess` | Phân tích access log realtime trong terminal/HTML |
| `iftop`, `nload` | Xem băng thông theo kết nối |
| `iotop` | Tìm process gây I/O |
| `tcpdump` | Bắt gói khi cần bằng chứng tấn công |
| `php-fpm` status page | Biết pool có bão hòa hay không |
| `nginx stub_status` | Biết active connection và request/s |

### Script trong repo

| Script | Việc | Chỉ đọc |
|--------|------|:-------:|
| [`scripts/triage.sh`](scripts/triage.sh) | Chụp snapshot: CPU, RAM, disk, mạng, nginx, php-fpm, process, OOM | ✅ |
| [`scripts/nginx-top.sh`](scripts/nginx-top.sh) | Phân tích access log: top IP/URL/UA/status, POST flood, rps, dấu hiệu scanner | ✅ |

### Cấu trúc repo

```
.
├── README.md                       # playbook (bạn đang đọc)
├── docs/quick-reference-en.md      # cheat sheet 1 trang tiếng Anh
├── scripts/
│   ├── triage.sh                   # snapshot hệ thống + nginx + php-fpm
│   └── nginx-top.sh                # phân tích access log
└── conf/
    ├── nginx-ratelimit.conf        # rate limit + slowloris
    ├── nginx-microcache.conf       # micro-cache 10s
    └── php-fpm-tuning.conf         # pool tuning + slowlog
```

---

## 3. Chẩn đoán 60 giây

### 3.1 Nhìn load trước, nhưng đừng đọc sai

```bash
uptime
nproc
```

`load average` phải chia cho số core:

| load/core | Ý nghĩa |
|-----------|---------|
| < 0.7 | Bình thường |
| 0.7 – 1.0 | Đang tới hạn |
| 1.0 – 2.0 | Quá tải, có hàng đợi |
| > 2.0 | Nghiêm trọng, site đã/đang chết |

Ví dụ `load 24.0` trên máy 8 core = **3.0/core** → quá tải nặng, không phải
“hơi cao”.

### 3.2 CPU đang tiêu vào đâu

```bash
mpstat -P ALL 1 5
```

Đọc cột:

| Cột | Cao nghĩa là | Thường do |
|-----|--------------|-----------|
| `%usr` | Code PHP chạy nhiều | Traffic thật, vòng lặp code, plugin nặng |
| `%sys` | Nhân xử lý syscall/network | DDoS, quá nhiều kết nối ngắn, TLS handshake |
| `%iowait` | Chờ disk | DB, log ghi nhiều, thiếu RAM → swap |
| `%steal` | Hypervisor lấy CPU | **VPS bị hàng xóm chiếm CPU**, không phải lỗi bạn |
| `%soft` | Softirq mạng | Flood gói tin, NIC/ảo hóa |

> [!NOTE]
> `%steal` > 5–10% kéo dài: mở ticket với nhà cung cấp VPS. Tối ưu tại chỗ
> không giải quyết được vấn đề này.

### 3.3 RAM và swap

```bash
free -h
swapon --show
dmesg -T | grep -iE 'oom|killed process' | tail
```

Swap đầy + `%wa` cao + `dmesg` có `OOM` = thiếu RAM. Đây là nguyên nhân rất hay
bị chẩn đoán nhầm thành DDoS, nhất là khi `php-fpm` bị đẩy `max_children` quá
cao.

### 3.4 Mạng: kết nối hay băng thông?

```bash
ss -s
ss -tan state established '( sport = :80 or sport = :443 )' | wc -l
ss -tan state syn-recv | wc -l
```

Top IP theo số kết nối đang mở:

```bash
ss -tn state established '( sport = :80 or sport = :443 )' \
  | awk 'NR>1{split($4,a,":"); print a[1]}' \
  | sort | uniq -c | sort -rn | head -20
```

Diễn giải nhanh:

| Chỉ số | Bình thường | Đáng ngờ |
|--------|-------------|----------|
| Established | vài trăm – vài nghìn | > 10k, hoặc 1 IP giữ > 100 kết nối |
| `syn-recv` | gần 0 | hàng nghìn → SYN flood |
| `TIME-WAIT` | vài nghìn | > 30k → quá nhiều kết nối ngắn |
| 1 IP / tổng kết nối | < 5% | 1 IP chiếm 30–80% → flood |

Băng thông:

```bash
iftop -nNP        # nếu đã cài
# hoặc đọc trực tiếp
cat /proc/net/dev
```

Nếu băng thông ra/vào chạm trần NIC (thường 100 Mbps – 1 Gbps) thì đó là **flood
lớp 4**, xử lý tại edge, không phải trong nginx.

### 3.5 Nginx có thực sự quá tải?

Bật `stub_status` (nếu chưa có):

```nginx
# /etc/nginx/conf.d/status.conf
server {
    listen 127.0.0.1:80;
    server_name _;

    location = /nginx_status {
        stub_status;
        access_log off;
        allow 127.0.0.1;
        deny all;
    }
}
```

```bash
nginx -t && systemctl reload nginx
curl -s http://127.0.0.1/nginx_status
```

```
Active connections: 1423
server accepts handled requests
 918273 918270 4823190
Reading: 12 Writing: 240 Waiting: 1171
```

| Trường | Ý nghĩa | Ngưỡng đáng lo |
|--------|---------|----------------|
| `Active` | Kết nối đang mở | Gần `worker_connections × worker_processes` |
| `accepts` – `handled` | Số kết nối bị rơi | > 0 → thiếu `worker_connections` / file descriptor |
| `Reading` | Đang đọc header | Cao bất thường → slowloris |
| `Writing` | Đang trả response | Cao + CPU cao → PHP chậm/upstream nghẽn |
| `Waiting` | Keep-alive rảnh | Rất cao là bình thường |

Request/s = hiệu hai lần đọc `requests` cách nhau 1 giây:

```bash
a=$(curl -s 127.0.0.1/nginx_status | awk '/requests/{print $3}')
sleep 1
b=$(curl -s 127.0.0.1/nginx_status | awk '/requests/{print $3}')
echo "rps = $((b - a))"
```

Kiểm tra cấu hình thực tế đang chạy và lỗi gần đây:

```bash
nginx -T 2>/dev/null | grep -E 'worker_processes|worker_connections|keepalive_timeout|client_(header|body)_timeout|limit_(req|conn)'
tail -100 /var/log/nginx/error.log
```

Các dòng error log là tín hiệu rất mạnh:

| Dòng log | Nghĩa |
|----------|-------|
| `worker_connections are not enough` | Chạm trần kết nối |
| `Too many open files` | Thiếu `worker_rlimit_nofile` / `ulimit -n` |
| `upstream timed out ... php-fpm` | PHP chậm hoặc pool đầy |
| `connect() failed (111: Connection refused)` | PHP-FPM chết/hết worker |
| `client intended to send too large body` | Flood POST |
| `SSL_do_handshake() failed` | TLS handshake flood hoặc scan |

### 3.6 PHP-FPM có bão hòa?

Bật status (chỉ nghe nội bộ):

```ini
; /etc/php/8.2/fpm/pool.d/www.conf
pm.status_path = /fpm-status
ping.path = /fpm-ping
```

```nginx
location ~ ^/(fpm-status|fpm-ping)$ {
    access_log off;
    allow 127.0.0.1;
    deny all;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    fastcgi_pass unix:/run/php/php8.2-fpm.sock;
}
```

```bash
curl -s http://127.0.0.1/fpm-status
```

```
pool:                 www
process manager:      dynamic
active processes:     48
idle processes:       2
total processes:      50
max active processes: 50
max children reached: 137
listen queue:         12
max listen queue:     340
slow requests:        8
```

| Trường | Kết luận |
|--------|----------|
| `max children reached` > 0 | Pool đã chạm trần → tăng `max_children` **hoặc** sửa code chậm |
| `listen queue` > 0 | Request phải xếp hàng → thiếu worker |
| `max listen queue` lớn | Đã có lúc site sập/504 |
| `slow requests` > 0 | Có request vượt `request_slowlog_timeout` → xem slowlog |

> [!IMPORTANT]
> **Tăng `max_children` không phải lúc nào cũng đúng.** Nếu code chậm, tăng
> `max_children` chỉ làm RAM đầy nhanh hơn và đẩy máy vào swap.

### 3.7 Một lệnh chụp tất cả

```bash
sudo ./scripts/triage.sh -o /tmp/triage-$(date +%F-%H%M).txt -n 20
```

Output mẫu (rút gọn, chạy thật trên một host 8 vCPU):

```
== TRIAGE - 2026-10-26T10:00:27+00:00 ==
  host      : web-server-1
  kernel    : Linux 6.8.0-147-generic
  uptime    : up 3 hours, 32 minutes
  virt      : vmware
  run as    : uid=0

== CPU va load ==
  nproc     : 8
  model     : Intel(R) Xeon(R) CPU E5-2686 v4 @ 2.30GHz
  loadavg   : 0.16 0.09 0.07
  load/core : 0.02

== Mang ==
  established 80/443 : 42
  syn-recv           : 0
  time-wait          : 118
```

Script còn in `mpstat`, top process, RAM/swap/OOM, disk, `iostat`, nginx
`stub_status` + rps, PHP-FPM status + slowlog, và mục **“Dấu hiệu bất thường”**
(`ld.so.preload`, process có `exe (deleted)`, systemd timer lạ).

---

## 4. Đọc access log để tìm kẻ tấn công

### 4.1 Chạy script

```bash
sudo ./scripts/nginx-top.sh

# log khác vị trí / chỉ 100k dòng cuối / top 30 / ngưỡng 500 req
sudo ./scripts/nginx-top.sh -f /var/log/nginx/example.com.access.log -m 100000 -n 30 -b 500

# ghi báo cáo ra file
sudo ./scripts/nginx-top.sh -o /tmp/nginx-report.txt
```

Script tự nhận dạng log `combined`, tính cả request/s, và in:

1. Tổng quan: số dòng, thời gian, rps, số IP, phân bố 2xx/3xx/4xx/5xx
2. Top IP theo request + top IP theo băng thông
3. Top IP theo 4xx/5xx
4. Top URL (tách query) + **path có nhiều query khác nhau** (cache-bypass,
   search flood)
5. Top URL bị 404
6. Top POST (dấu hiệu brute-force / form spam)
7. Top User-Agent, top Referer, số request **không có UA**
8. UA đáng ngờ (sqlmap, nikto, masscan, python-requests, Go-http-client…)
9. Danh sách IP vượt ngưỡng request (mặc định > 300)

Output mẫu với log giả lập 2.000 dòng (flood 3 IP + search flood + brute-force
login + scanner 404):

```
== NGINX ACCESS LOG - /tmp/opencode/lg/access.log ==
  dong phan tich : 2000
  IP duy nhat    : 247
  thoi gian      : 26/Oct/2026:03:00:00 +0700  ->  26/Oct/2026:03:09:19 +0700
  request/s (tb) : 3.6
  dong khong parse duoc: 0

== PHAN BO STATUS ==
    1800  2xx
     200  4xx

== TOP 3 IP THEO SO REQUEST ==
      400 203.0.113.46
      400 203.0.113.45
      400 203.0.113.44

== PATH CO NHIEU QUERY KHAC NHAU (cache-bypass / search flood) ==
    1200 query khac nhau  /

== USER-AGENT DANG NGO (scanner / tool) ==
     1200 python-requests/2.31
      200 Mozilla/5.0 zgrab/0.x

== IP VUOT NGUONG > 300 REQUEST ==
       400  203.0.113.46
       400  203.0.113.45
       400  203.0.113.44
```

### 4.2 Cách đọc kết quả

| Dấu hiệu trong báo cáo | Kết luận thường gặp |
|------------------------|---------------------|
| 1–5 IP chiếm > 50% request | HTTP flood có tổ chức / botnet nhỏ |
| rps > 2.000 với site ít truy cập | Gần như chắc chắn tấn công |
| Top UA là `curl`, `python-requests`, chuỗi rỗng | Bot, scanner, tool tấn công |
| Top URL là `/?s=<chuỗi random>` | Search flood (WordPress) |
| Top URL `/wp-login.php`, `/xmlrpc.php` | Credential stuffing / brute-force |
| Top URL `/api/...` với POST | Flood API (thường đắt CPU nhất) |
| Nhiều IP khác nhau, cùng UA, cùng path | Botnet, cần chặn theo UA/path chứ không theo IP |
| 4xx chiếm 60–90% | Scanner hoặc flood vào URL không tồn tại |
| `Reading` cao, rps thấp | Slowloris |
| Không có UA + HTTP/1.0 | Tool cũ / botnet |
| Nhiều query khác nhau trên cùng 1 path | Cache-bypass / search flood |

### 4.3 Lệnh thủ công tương đương

Khi không muốn chạy script:

```bash
LOG=/var/log/nginx/access.log

# Top 20 IP
awk '{print $1}' "$LOG" | sort | uniq -c | sort -rn | head -20

# Top 20 URL (bỏ query string)
awk '{print $7}' "$LOG" | cut -d? -f1 | sort | uniq -c | sort -rn | head -20

# Top 20 User-Agent
awk -F'"' '{print $6}' "$LOG" | sort | uniq -c | sort -rn | head -20

# Phân bố status
awk '{print $9}' "$LOG" | sort | uniq -c | sort -rn | head

# Đếm request của 1 IP
grep -c '^203\.0\.113\.45 ' "$LOG"
```

`awk` thuần nhanh hơn `grep` rất nhiều trên log vài GB.

### 4.4 Mẫu log đáng ngờ

```
203.0.113.45 - - [26/Oct/2026:03:12:44 +0700] "GET /?s=a8f3k2 HTTP/1.1" 200 512 "-" "python-requests/2.31"
203.0.113.45 - - [26/Oct/2026:03:12:44 +0700] "GET /?s=9dja2k HTTP/1.1" 200 512 "-" "python-requests/2.31"
198.51.100.7 - - [26/Oct/2026:03:12:45 +0700] "POST /wp-login.php HTTP/1.1" 200 1234 "-" "Mozilla/5.0"
198.51.100.7 - - [26/Oct/2026:03:12:45 +0700] "POST /wp-login.php HTTP/1.1" 200 1234 "-" "Mozilla/5.0"
```

Ba điều cần chú ý: **cùng path + cùng UA**, **không referer**, **tần suất dày
đặc trong cùng giây**.

---

## 5. Các kiểu tấn công và dấu hiệu

| Kiểu | Dấu hiệu | Chặn ở đâu |
|------|----------|------------|
| **HTTP flood (L7)** | rps cao, ít IP, cùng UA/path | nginx rate limit, WAF |
| **Cache bypass** | URL có `?random=...` để không trúng cache | Cache theo path, chặn query rác |
| **Slowloris / slow POST** | `Reading` cao, nhiều kết nối mở lâu, rps thấp | `client_*_timeout`, `limit_conn` |
| **Credential stuffing** | POST `/wp-login.php`, `/admin`, `/api/login` | Rate limit theo IP + path, 2FA, fail2ban |
| **xmlrpc / pingback** | POST `/xmlrpc.php`, `system.multicall` | Chặn hẳn nếu không dùng |
| **Search flood (WP)** | `/?s=` với chuỗi random | Chặn `?s=` khi không có cookie, cache |
| **Scanner / exploit** | 404 hàng loạt, `/.env`, `/wp-config.php`, `/phpmyadmin` | WAF, chặn UA |
| **SYN flood (L4)** | `syn-recv` cao, `%sys`/`%soft` cao | `tcp_syncookies`, provider |
| **UDP / amplification** | băng thông vào cực lớn, không có log HTTP | Provider / firewall edge |
| **TLS handshake flood** | `SSL_do_handshake() failed` nhiều, CPU `%sys` cao | `ssl_session_cache`, edge |
| **Botnet IP xoay vòng** | hàng nghìn IP, mỗi IP vài request | Chặn theo ASN/quốc gia, JS challenge |

> [!IMPORTANT]
> **L7 chặn ở nginx/WAF; L4 chặn ở provider.** Cố chặn SYN flood bằng
> `nginx limit_req` là vô nghĩa vì gói tin không bao giờ tới được HTTP layer.

### 5.1 Bảng “chữ ký” theo kiểu tấn công

| Kiểu | Log/`ss` cho thấy | Cấu hình nên bật |
|------|-------------------|------------------|
| HTTP flood | 1 IP, 500 rps, UA cố định | `limit_req` 10 r/s |
| Slowloris | 10k conn `Reading`, 5 rps | `client_header_timeout 10s`, `limit_conn 30` |
| Login brute-force | 200 POST/phút vào `/wp-login.php` | `limit_req` 1 r/s + fail2ban |
| Search flood | 50k URL `/?s=` khác nhau | cache + chặn `s=` rỗng |
| Scanner | 404 `/.env`, `/vendor/` | WAF/UA block |
| SYN flood | `syn-recv` 20k, `%sys` 70% | provider + syncookies |

---

## 6. Chặn tạm thời — đúng thứ tự

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. Bảo vệ SSH/admin  →  2. Rate limit  →  3. Chặn IP               │
│  4. CDN/WAF           →  5. Giảm tải    →  6. L4: gọi provider      │
└──────────────────────────────────────────────────────────────────────┘
```

Khóa mất SSH giữa lúc chặn là chuyện rất dễ xảy ra — xem
[mục 6.8](#68-console-vào-được-ssh-không--vì-sao) để biết cách vào lại bằng
console của provider.

### 6.1 Ba điều không được làm

> [!CAUTION]
> 1. **Không chặn dải IP lớn** (ví dụ `/16`) — rất dễ chặn nhầm khách hàng,
>    Google, hoặc chính CDN của bạn.
> 2. **Không chặn IP của Cloudflare/CDN** khi site đang đi qua CDN. Nếu đang
>    dùng Cloudflare mà chặn theo IP trong nginx, bạn sẽ chặn chính Cloudflare
>    và **sập toàn bộ site**.
> 3. **Không tắt firewall** rồi mở lại sau — mất luôn lớp bảo vệ và có thể mất
>    SSH.

### 6.2 Bước 1 — bảo vệ SSH và trang admin trước

Khi CPU 100%, mọi thứ đều chậm, kể cả SSH. Ưu tiên số một là giữ đường vào.

```bash
# SSH chỉ nghe IP tin cậy (nếu hạ tầng cho phép)
nft add rule inet filter input tcp dport 22 ip saddr != 203.0.113.10 drop
```

```nginx
# Admin: chỉ cho IP văn phòng
location ~ ^/(wp-admin|wp-login\.php|admin) {
    allow 203.0.113.10;
    deny all;
}
```

Nếu chưa chắc, ít nhất hãy giới hạn số kết nối SSH đồng thời và bật `fail2ban`.

### 6.3 Bước 2 — rate limit trong nginx (hiệu quả nhất với L7)

```nginx
# /etc/nginx/conf.d/00-ratelimit.conf
# zone đặt ở http context
limit_req_zone  $binary_remote_addr zone=req_per_ip:20m  rate=10r/s;
limit_req_zone  $binary_remote_addr zone=login_per_ip:10m rate=1r/s;
limit_conn_zone $binary_remote_addr zone=conn_per_ip:10m;

limit_req_status 429;
limit_conn_status 429;
limit_req_log_level warn;
```

```nginx
# trong server {}
limit_conn conn_per_ip 30;

# toàn site: 10 r/s, cho phép burst 20
location / {
    limit_req zone=req_per_ip burst=20 nodelay;
    try_files $uri $uri/ /index.php?$args;
}

# login: chặt hơn nhiều
location = /wp-login.php {
    limit_req zone=login_per_ip burst=5 nodelay;
    include fastcgi_params;
    fastcgi_pass unix:/run/php/php8.2-fpm.sock;
}
```

Kiểm tra trước khi reload:

```bash
nginx -t && systemctl reload nginx
```

Lưu ý:

- `rate=10r/s` là **10 request/giây/IP**. Với site nhiều ảnh/JS, có thể phải
  nâng lên 30–50 hoặc chỉ áp dụng cho path động (`.php`, `/api`).
- `burst` quá thấp làm người dùng thật bị 429. Theo dõi log `limiting requests`
  để chỉnh.
- Nếu site sau CDN: `$binary_remote_addr` là IP của CDN, rate limit sẽ áp cho
  toàn bộ người dùng → phải cấu hình `real_ip` trước (xem [6.5](#65-bước-4--nếu-có-cdnwaf-cloudflare-fastly-buny)).

### 6.4 Bước 3 — chặn IP cụ thể

Chặn ở nginx (nhanh, dễ rollback):

```nginx
# /etc/nginx/conf.d/00-blocklist.conf
deny 203.0.113.45;
deny 198.51.100.0/24;
```

Hoặc dùng `nftables` với set có timeout (gọn hơn iptables khi nhiều IP):

```bash
nft add table inet blackhole 2>/dev/null
nft add set inet blackhole ips '{ type ipv4_addr; flags timeout; }' 2>/dev/null
nft add chain inet blackhole input '{ type filter hook input priority -10; }' 2>/dev/null
nft add rule inet blackhole input ip saddr @blackhole drop 2>/dev/null

# thêm IP, tự hết hạn sau 1 giờ
nft add element inet blackhole ips '{ 203.0.113.45 timeout 1h }'

# xem danh sách
nft list set inet blackhole ips
```

Với iptables + ipset:

```bash
ipset create blocklist hash:ip timeout 3600 2>/dev/null
iptables -I INPUT -m set --match-set blocklist src -j DROP
ipset add blocklist 203.0.113.45
```

Chặn theo tần suất (hashlimit) — chỉ dùng khi thật cần, vì thêm chi phí cho mỗi
gói tin:

```bash
iptables -I INPUT -p tcp --dport 443 -m conntrack --ctstate NEW \
  -m hashlimit --hashlimit-name https \
  --hashlimit-above 50/sec --hashlimit-burst 100 \
  --hashlimit-mode srcip --hashlimit-htable-expire 60000 -j DROP
```

### 6.5 Bước 4 — nếu có CDN/WAF (Cloudflare, Fastly, Buny…)

Đây là nơi chặn hiệu quả nhất, và **miễn phí CPU của bạn**.

1. Bật chế độ “Under Attack Mode” (JS challenge) nếu đang bị flood nặng.
2. Tạo rate limiting rule: ví dụ > 50 request/phút/IP vào `/wp-login.php`.
3. Bật WAF managed rules + bot fight.
4. Chặn theo quốc gia/ASN nếu khách hàng chỉ ở một khu vực.

Nếu dùng Cloudflare, **bắt buộc** cấu hình real IP, nếu không mọi log sẽ là IP
Cloudflare:

```nginx
# /etc/nginx/conf.d/cloudflare-realip.conf
# Danh sách IP chính thức: https://www.cloudflare.com/ips/
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;
set_real_ip_from 2400:cb00::/32;
real_ip_header CF-Connecting-IP;
```

> [!WARNING]
> Danh sách IP Cloudflare thay đổi theo thời gian. Hãy đồng bộ định kỳ từ
> <https://www.cloudflare.com/ips/> — đừng copy một lần rồi để đó.

### 6.6 Bước 5 — giảm tải để giữ site sống

Khi không thể chặn ngay, mục tiêu là **giữ dịch vụ quan trọng sống**, chấp nhận
mất một phần:

```nginx
# Giảm thời gian giữ kết nối của kẻ tấn công
client_header_timeout 10s;
client_body_timeout   10s;
send_timeout          15s;
keepalive_timeout     20s;
keepalive_requests    100;
reset_timedout_connection on;

# Giới hạn kích thước body (chặn POST flood)
client_max_body_size 10m;
```

Bật micro-cache cho các trang public (giảm PHP xuống gần 0):

```nginx
proxy_cache_path /var/cache/nginx/micro levels=1:2 keys_zone=micro:20m
                 inactive=60s max_size=2g use_temp_path=off;

server {
    set $skip_cache 0;

    # Không cache khi có cookie đăng nhập hoặc POST
    if ($request_method = POST)            { set $skip_cache 1; }
    if ($http_cookie ~* "logged_in|wordpress_logged_in|PHPSESSID") { set $skip_cache 1; }

    location / {
        proxy_cache            micro;
        proxy_cache_valid      200 301 302 10s;
        proxy_cache_use_stale  error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_lock       on;
        proxy_cache_bypass     $skip_cache;
        proxy_no_cache         $skip_cache;
        add_header             X-Cache $upstream_cache_status;
        proxy_pass             http://127.0.0.1:8080;
    }
}
```

10 giây cache làm giảm 90–99% request vào PHP trong lúc flood, trong khi người
dùng vẫn thấy nội dung gần như tức thời.

### 6.7 Bước 6 — L4 thì gọi provider

Nếu băng thông chạm trần hoặc `syn-recv` hàng trăm nghìn, không có cấu hình
nginx nào cứu được. Cần:

- Bật scrubbing/anti-DDoS của nhà cung cấp (thường có sẵn, chỉ chưa bật).
- Đổi IP (nếu tấn công nhắm IP cụ thể).
- Đặt CDN/proxy phía trước để ẩn IP gốc.

Trong lúc chờ, có thể giảm thiệt hại cục bộ:

```bash
sysctl -w net.ipv4.tcp_syncookies=1
sysctl -w net.ipv4.tcp_max_syn_backlog=65535
sysctl -w net.core.somaxconn=65535
```

Ghi vào `/etc/sysctl.d/99-web.conf` nếu thấy hiệu quả.

### 6.8 Console vào được, SSH không — vì sao?

Tình huống rất hay gặp lúc đang bị flood: mở **web console** của nhà cung cấp
(VNC / serial / “Emergency console”) thì đăng nhập được, nhưng `ssh user@ip` từ
máy bạn thì `timeout`, `Connection refused`, hoặc treo ở dòng cuối `debug1:
expecting SSH2_MSG_KEX_ECDH_REPLY`.

Điều đó chứng minh **máy vẫn sống, kernel vẫn chạy, tài khoản vẫn đúng**. Vấn đề
chỉ nằm ở một trong hai chặng: **đường mạng tới cổng 22** hoặc **riêng tiến
trình `sshd`**.

```
Máy bạn ──► Internet ──► [provider ACL / anti-DDoS] ──► [firewall của bạn]
                                                             │
                                                             ▼
                                                      sshd :22 ──► PAM ──► shell
                                                         ✗
Console ──► hypervisor (VNC/serial) ────────────────► getty/login ─────► shell
```

Console đi qua hypervisor, **không đi qua card mạng của VPS** → nó bỏ qua toàn bộ
firewall, fail2ban, ACL của provider và cả `sshd`. Vì thế console là “cửa sau”
để cứu máy — và cũng chính vì thế phải bảo vệ nó: mật khẩu mạnh, 2FA ở panel
provider, không dùng chung mật khẩu với SSH.

#### Bảng phân loại theo triệu chứng

| Bạn thấy từ máy mình | Nguyên nhân hay gặp | Kiểm tra trong console |
|---|---|---|
| `Connection timed out` | Firewall/ACL chặn 22, fail2ban ban IP, IP bị null-route | `nft list ruleset`, `iptables -S`, `fail2ban-client status sshd` |
| `Connection refused` | `sshd` không chạy, hoặc nghe cổng khác | `ss -ltnp \| grep ssh`, `systemctl status ssh` |
| Kết nối được nhưng treo ở `expecting SSH2_MSG_KEX…` | MTU/PMTU, `sshd` không fork nổi process con | `dmesg -T \| tail`, `ping -M do -s 1400` |
| `Permission denied` dù mật khẩu đúng | `/etc/nologin`, PAM `faillock`, tài khoản hết hạn, shell sai | `ls -l /etc/nologin`, `faillock --user <user>` |
| Vào được rồi bị đá ra ngay | Disk/inode đầy, không ghi được `utmp`/log | `df -h`, `df -i` |
| `ssh_exchange_identification: Connection closed` | `MaxStartups` đầy, `sshd` bị OOM kill | `journalctl -u ssh -n 50` |
| Chỉ máy/mạng của bạn không vào được | IP của bạn bị chặn, IPv6 lỗi route | thử 4G, thử `ssh -4`, thử cổng khác |

#### Kiểm tra trong console, theo thứ tự

**1. `sshd` còn sống và nghe đúng cổng?**

```bash
systemctl status ssh 2>/dev/null || systemctl status sshd
ss -ltnp | grep -E ':22\b|sshd'
journalctl -u ssh -n 50 --no-pager 2>/dev/null || tail -50 /var/log/auth.log
```

Nếu service chết vì OOM, `dmesg` sẽ có `Killed process … (sshd)`. Khởi động lại
sau khi đã chắc cấu hình đúng: `sshd -t && systemctl restart ssh`.

**2. Firewall / fail2ban có chặn chính IP của bạn?**

Đây là nguyên nhân số một: bạn tự khóa mình khi đang chặn flood.

```bash
nft list ruleset | grep -nE '22|ssh'
iptables -S 2>/dev/null | grep -E '22|ssh'
fail2ban-client status sshd 2>/dev/null
ipset list 2>/dev/null | head -30
cat /etc/hosts.deny 2>/dev/null
```

Gỡ đúng IP của mình (chỉ `/32`, đừng mở cả dải):

```bash
fail2ban-client set sshd unbanip 203.0.113.10
```

**3. SYN flood làm đầy `conntrack` / backlog**

Khi `conntrack` đầy, kết nối SSH mới **bị drop trước khi tới `sshd`** — `sshd`
vẫn “running”, console vẫn vào được, nhưng SSH từ ngoài thì timeout.

```bash
ss -s
sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max 2>/dev/null
dmesg -T | tail -30
```

Tìm các dòng: `nf_conntrack: table full, dropping packet`,
`Possible SYN flooding on port 443`.

```bash
# tăng tạm (mỗi entry ~300 byte RAM, 262144 entry ~ 80 MB)
sysctl -w net.netfilter.nf_conntrack_max=262144
sysctl -w net.ipv4.tcp_max_syn_backlog=65535
```

**4. Disk hoặc inode đầy**

Log bị flood ghi rất nhanh; đầy `/var` làm `sshd` không ghi được session → đăng
nhập xong bị đá ngay, trong khi console (không cần ghi `utmp` qua sshd) vẫn OK.

```bash
df -h / /var /tmp
df -i /
du -xh /var/log --max-depth=1 2>/dev/null | sort -h | tail
```

> [!CAUTION]
> Đừng xóa log đang là bằng chứng. Copy ra chỗ khác trước
> ([mục 10.1](#101-giữ-lại-gì)), rồi mới `journalctl --vacuum-size=200M` hoặc
> xoay vòng log.

**5. Cấu hình và giới hạn của `sshd`**

```bash
sshd -t
sshd -T | grep -E '^(port|maxstartups|maxsessions|logingracetime|permitrootlogin|passwordauthentication|usepam|allowusers|allowgroups)'
systemctl show ssh -p LimitNOFILE -p TasksMax 2>/dev/null
```

`MaxStartups 10:30:100` nghĩa là: sau 10 kết nối chưa xác thực, mỗi kết nối mới
có 30% bị drop, và tối đa 100. Dưới flood, **lần SSH của bạn gần như chắc chắn
bị drop** — đây là lý do kinh điển của “console vào được, SSH thì không”.

**6. PAM và tài khoản**

```bash
ls -l /etc/nologin 2>/dev/null && cat /etc/nologin
faillock --user <user> 2>/dev/null
chage -l <user>
getent passwd <user>
```

`/etc/nologin` xuất hiện khi script bảo trì/shutdown bị treo → **chỉ root** đăng
nhập được, user thường bị từ chối dù mật khẩu đúng.

**7. Phía nhà cung cấp**

- Security group / cloud firewall (AWS SG, GCP firewall, Azure NSG) chặn 22.
- Anti-DDoS scrubbing đang lọc nhầm cổng 22.
- IP bị blackhole/null-route vì flood.
- Elastic IP / NAT đổi địa chỉ sau reboot.

#### Lấy lại SSH ngay từ console

Làm theo thứ tự, **ít rủi ro trước**:

```bash
# 1) Mở cổng 22 cho đúng IP đang dùng (thay IP của bạn)
nft insert rule inet filter input ip saddr 203.0.113.10 tcp dport 22 accept
# hoặc: iptables -I INPUT -s 203.0.113.10 -p tcp --dport 22 -j ACCEPT

# 2) Bỏ ban fail2ban
fail2ban-client set sshd unbanip 203.0.113.10 2>/dev/null

# 3) Nới MaxStartups bằng drop-in, không sửa file gốc
mkdir -p /etc/ssh/sshd_config.d
printf 'MaxStartups 100:30:200\nMaxSessions 20\nLoginGraceTime 20\n' \
  > /etc/ssh/sshd_config.d/99-emergency.conf
sshd -t && systemctl reload ssh

# 4) Gỡ /etc/nologin nếu có
rm -f /etc/nologin
```

Nếu `sshd` không khởi động được, mở một `sshd` tạm ở cổng khác để vào lấy dữ
liệu (nhớ mở cổng đó trên firewall):

```bash
/usr/sbin/sshd -p 2222 -o PidFile=/run/sshd-emergency.pid -o MaxStartups=100:30:200
ss -ltnp | grep 2222
# từ máy bạn:
ssh -p 2222 user@203.0.113.20
```

> [!WARNING]
> Luôn chạy `sshd -t` trước khi `reload`/`restart`. `reload` không cắt các phiên
> đang mở, nhưng nếu file cấu hình sai thì lần vào sau sẽ mất — và lúc đó bạn chỉ
> còn console. **Đừng đóng tab console cho tới khi SSH vào lại được.**

> [!TIP]
> Nếu bạn đang chỉnh firewall qua SSH (không phải console), hãy tự hẹn giờ gỡ
> rule để không tự khóa mình:
>
> ```bash
> ( sleep 300; nft delete rule inet filter input handle <N> ) &
> ```

#### Phòng ngừa để không bị khóa ngoài lần sau

- **Hai đường vào**: SSH 22 + một cổng dự phòng (2222) hoặc VPN/Tailscale.
- `AllowUsers` / `AllowGroups`, chỉ dùng key; whitelist IP văn phòng và IP
  monitoring trong fail2ban (`ignoreip`).
- `MaxStartups 100:30:200` trên máy có nguy cơ bị flood.
- Giữ một phiên `tmux`/`screen` mở khi đang chỉnh firewall, để nếu mất kết nối
  vẫn quay lại được trạng thái cũ.
- Giám sát **từ bên ngoài**: probe TCP 22 mỗi phút, alert khi không kết nối
  được — đừng chỉ tin `systemctl status ssh`.

---

## 7. PHP-FPM: CPU cao do code

Nếu `%usr` cao, rps không cao và nginx không nghẽn, thủ phạm nằm trong PHP.

### 7.1 Status page nói gì

Xem [mục 3.6](#36-php-fpm-có-bão-hòa). Cách đọc nhanh:

- `max children reached > 0` + `listen queue > 0` → **thiếu worker** (hoặc code
  giữ worker quá lâu).
- `idle processes = 0` kéo dài → pool cạn.
- `slow requests > 0` → có request rất chậm, xem slowlog.

### 7.2 Slowlog — công cụ mạnh nhất

```ini
; pool.d/www.conf
request_slowlog_timeout = 5s
slowlog = /var/log/php-fpm/slow.log
request_terminate_timeout = 60s
```

```bash
tail -50 /var/log/php-fpm/slow.log
```

Slowlog cho biết **chính xác hàm/đoạn code nào chậm**:

```
[26-Oct-2026 03:20:11]  [pool www] pid 4821
script_filename = /var/www/html/wp-admin/admin-ajax.php
[0x00007f...] curl_exec() /var/www/html/wp-includes/class-http.php:1234
[0x00007f...] wp_remote_get() /var/www/html/wp-content/plugins/xxx/xxx.php:88
```

`curl_exec` / `wp_remote_get` trong slowlog = site đang gọi API bên ngoài và
**chờ**. Sửa bằng cache/timeout, không phải bằng tăng `max_children`.

Cũng có thể thấy ngay trên terminal:

```bash
# Top function theo thời gian (chỉ khi cần, gây chậm thêm)
strace -c -f -p "$(pgrep -n php-fpm)" -o /tmp/php-strace.txt &
sleep 5; kill %1; cat /tmp/php-strace.txt
```

### 7.3 `max_children` — tính bằng RAM, không bằng cảm giác

```bash
# RSS trung bình của 1 worker PHP (KB)
ps -o rss= -C php-fpm | awk '{s+=$1; n++} END{printf "avg %.1f MB (%d workers)\n", s/n/1024, n}'
```

Công thức:

```
max_children = (RAM dành cho PHP - RAM cho OS/DB/nginx) / RSS trung bình 1 worker
```

Ví dụ: máy 4 GB, để 512 MB cho OS + 512 MB cho DB/nginx → còn 3 GB.
Worker 60 MB → `3072 / 60 ≈ 51`. Đặt **40–45** để còn headroom.

```ini
pm = dynamic
pm.max_children      = 45
pm.start_servers     = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 15
pm.max_requests      = 500
```

| Triệu chứng | Nguyên nhân | Cách xử lý |
|-------------|-------------|------------|
| `max children reached` cao, RAM còn trống | Thiếu worker | Tăng `max_children` |
| `max children reached` cao, RAM đầy/swap | Code giữ worker quá lâu | Sửa code, giảm timeout, thêm cache |
| `idle` luôn = 0 | Quá tải thật | Scale ngang hoặc cache |
| Worker chết liên tục | `max_requests` quá thấp hoặc memory leak | Tăng nhẹ, tìm plugin leak |

### 7.4 OPcache

```ini
; /etc/php/8.2/fpm/conf.d/10-opcache.ini
opcache.enable=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=2
opcache.save_comments=1
```

Kiểm tra:

```bash
php -r 'print_r(opcache_get_status()["opcache_statistics"]);'
```

`opcache_hit_rate` < 95% trên site production là đáng xem lại.

### 7.5 Checklist WordPress / Laravel

**WordPress**

- [ ] `wp-cron.php` chạy trên **mỗi request** → tắt và dùng cron hệ thống:
      `define('DISABLE_WP_CRON', true);`
- [ ] Chặn `xmlrpc.php` nếu không dùng (rất hay bị brute-force và flood).
- [ ] Giới hạn `admin-ajax.php` (heartbeat, plugin) — thường là top CPU.
- [ ] Bật page cache (WP Super Cache / LiteSpeed / Redis object cache).
- [ ] Plugin “related posts”, “search”, “backup” chạy mỗi request → kiểm tra.
- [ ] `?s=` search flood: chặn query rỗng/random hoặc cache.
- [ ] Cập nhật core/plugin — lỗ hổng bị khai thác để đẩy payload.

**Laravel**

- [ ] `php artisan config:cache route:cache view:cache` sau mỗi deploy.
- [ ] Queue worker chạy bằng supervisor, không chạy trong request.
- [ ] `APP_DEBUG=false`, `APP_ENV=production`.
- [ ] N+1 query trong Eloquent → bật `DB::listen` hoặc Telescope ở staging.

### 7.6 Database

PHP chờ DB cũng làm CPU cao (đặc biệt `%sys`/`%wa`):

```bash
mysql -e 'SHOW FULL PROCESSLIST\G' | head -100
mysql -e 'SHOW GLOBAL STATUS LIKE "Threads_connected";'
mysql -e 'SHOW VARIABLES LIKE "max_connections";'
```

Bật slow query log:

```ini
slow_query_log = 1
long_query_time = 1
slow_query_log_file = /var/log/mysql/slow.log
```

Nếu `Threads_connected` gần `max_connections`, tăng kết nối **chỉ khi** RAM và
`innodb_buffer_pool_size` cho phép. Ngược lại, thêm cache/read replica.

---

## 8. Tối ưu bền vững

### 8.1 Nginx

```nginx
# /etc/nginx/nginx.conf
worker_processes auto;
worker_rlimit_nofile 65535;

events {
    worker_connections 8192;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    keepalive_timeout 30;
    keepalive_requests 1000;

    client_header_timeout 15s;
    client_body_timeout 15s;
    send_timeout 20s;

    open_file_cache max=10000 inactive=30s;
    open_file_cache_valid 60s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    gzip on;
    gzip_comp_level 5;          # 5 là điểm cân bằng CPU/nén
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript
               application/xml image/svg+xml;

    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;
    fastcgi_keep_conn on;
}
```

> [!TIP]
> `gzip_comp_level 9` tiết kiệm băng thông nhưng **tốn CPU đáng kể** — trên máy
> đang quá tải, hạ về 4–5 hoặc tắt gzip cho nội dung đã nén.

### 8.2 PHP-FPM

Ngoài `max_children` ([mục 7.3](#73-max_children--tính-bằng-ram-không-bằng-cảm-giác)):

```ini
emergency_restart_threshold = 10
emergency_restart_interval  = 1m
process_control_timeout     = 10s
```

`emergency_restart_*` giúp FPM tự khởi động lại khi worker chết hàng loạt.

### 8.3 Cache theo tầng

| Tầng | Công cụ | Giảm tải |
|------|---------|----------|
| CDN / edge | Cloudflare, Fastly | 60–95% request tĩnh |
| Nginx micro-cache | `proxy_cache` / `fastcgi_cache` | 80–99% request động lặp lại |
| Object cache | Redis / Memcached | Giảm query DB |
| OPcache | PHP | Giảm compile |
| DB query cache | tuỳ DB | Giảm query nặng |

Thứ tự đầu tư hiệu quả: **CDN → micro-cache → object cache → code**.

### 8.4 Giới hạn tài nguyên theo site (multi-tenant)

Nếu một server chạy nhiều site, đừng để 1 site “ăn” hết:

```ini
; pool riêng cho từng site
[siteA]
user = sitea
pm = dynamic
pm.max_children = 15
pm.max_requests = 300
```

```nginx
# giới hạn kết nối theo site
limit_conn_zone $server_name zone=per_site:10m;
limit_conn per_site 200;
```

---

## 9. CPU cao nhưng không phải do traffic

Kiểm tra nhanh: nếu `nginx_status` chỉ vài request/s mà CPU vẫn 100%, **đừng**
tối ưu nginx nữa.

Dấu hiệu:

- Process lạ tên ngẫu nhiên, hoặc `exe` bị `(deleted)`.
- `%sys` cao bất thường, `kswapd`/`kworker` chiếm CPU.
- Có cron/systemd timer lạ chạy mỗi phút.
- `/etc/ld.so.preload` khác rỗng.
- Kết nối ra ngoài tới IP:port lạ (miner pool).

Bộ lệnh kiểm tra:

```bash
ps -eo pid,ppid,pcpu,pmem,etime,args --sort=-pcpu | head -20
ls -l /proc/*/exe 2>/dev/null | grep deleted
cat /etc/ld.so.preload 2>/dev/null
systemctl list-timers --all | head
ss -tnp | grep -E ':(3333|4444|5555|7777|14444|45700)\b'
```

Nếu nghi ngờ malware/miner, dùng repo chuyên dụng:
[linux-malware-check](https://github.com/fixnhanh-linux/linux-malware-check) —
script quét IOC, cách ly và xử lý persistence.

---

## 10. Sau sự cố

### 10.1 Giữ lại gì

```bash
mkdir -p /root/incident-$(date +%F)
cp /var/log/nginx/access.log   /root/incident-$(date +%F)/
cp /var/log/nginx/error.log    /root/incident-$(date +%F)/
cp -a /etc/nginx               /root/incident-$(date +%F)/
cp -a /etc/php                 /root/incident-$(date +%F)/
cp /tmp/nginx-report.txt       /root/incident-$(date +%F)/
```

Nếu cần bằng chứng pháp lý: `tcpdump -w` ngay khi đang bị tấn công, trước khi
chặn.

### 10.2 Báo cáo ngắn gọn

| Mục | Nội dung |
|-----|----------|
| Thời gian | Bắt đầu / kết thúc (múi giờ) |
| Triệu chứng | CPU, load, rps, 5xx, thời gian phản hồi |
| Nguồn | Top IP/ASN/quốc gia, UA, path |
| Kiểu tấn công | L7 flood / slowloris / brute-force / L4 |
| Đã làm | Rate limit, chặn IP, bật CDN… |
| Kết quả | Giảm bao nhiêu % CPU/rps |
| Việc còn lại | Cache, WAF rule, scale, vá lỗi |

---

## 11. Chống tái diễn

| Chỉ số | Ngưỡng cảnh báo | Hành động |
|--------|-----------------|-----------|
| load/core | > 1.5 trong 5 phút | Kiểm tra ngay |
| CPU `%sys` | > 40% trong 5 phút | Nghi flood L4/L7 |
| rps | > 3× baseline | Kiểm tra top IP |
| 5xx | > 1% trong 5 phút | Kiểm tra PHP-FPM/DB |
| p95 response | > 1s | Xem slowlog |
| `max children reached` | > 0 | Xem lại `max_children` |
| `syn-recv` | > 1000 | Nghi SYN flood |
| Swap used | > 20% | Thiếu RAM |

Việc nên làm sẵn **trước khi** bị tấn công:

- Rate limit mặc định cho `/wp-login.php`, `/xmlrpc.php`, `/api/*`.
- CDN/WAF phía trước, ẩn IP gốc.
- Monitoring + alert (Prometheus/node_exporter, Netdata, Zabbix).
- Backup tự động và **đã test restore**.
- Log rotate hợp lý (log 10 GB làm `%wa` cao).

---

## 12. Runbook 15 lệnh

Copy vào wiki nội bộ:

```bash
# 1. Toàn cảnh
uptime; nproc; free -h; df -h /

# 2. CPU theo core
mpstat -P ALL 1 5

# 3. Process ăn CPU
ps -eo pid,pcpu,pmem,etime,args --sort=-pcpu | head -15

# 4. Kết nối
ss -s

# 5. Top IP theo kết nối
ss -tn state established '( sport = :80 or sport = :443 )' \
  | awk 'NR>1{split($4,a,":");print a[1]}' | sort | uniq -c | sort -rn | head

# 6. SYN flood?
ss -tan state syn-recv | wc -l

# 7. Nginx status
curl -s http://127.0.0.1/nginx_status

# 8. Request/s
a=$(curl -s 127.0.0.1/nginx_status | awk '/requests/{print $3}'); sleep 1
b=$(curl -s 127.0.0.1/nginx_status | awk '/requests/{print $3}'); echo $((b-a))

# 9. PHP-FPM status
curl -s http://127.0.0.1/fpm-status

# 10. Lỗi nginx
tail -50 /var/log/nginx/error.log

# 11. Lỗi PHP
tail -50 /var/log/php*-fpm.log 2>/dev/null

# 12. OOM
dmesg -T | grep -iE 'oom|killed process' | tail

# 13. Log analysis
sudo ./scripts/nginx-top.sh -n 20

# 14. Snapshot đầy đủ
sudo ./scripts/triage.sh -o /tmp/triage-$(date +%F-%H%M).txt

# 15. Kiểm tra malware (nếu không phải traffic)
ps -eo pid,args --sort=-pcpu | head; cat /etc/ld.so.preload 2>/dev/null
```

---

## 13. Case study: 12 phút dập flood

Site WordPress, VPS 8 vCPU / 8 GB, có Cloudflare nhưng **chưa bật proxy** (DNS
trỏ thẳng IP gốc).

| Giờ | Dấu hiệu | Việc đã làm | Kết quả |
|-----|----------|-------------|---------|
| 02:58 | Alert CPU 100%, load 38 | Mở SSH, chạy `triage.sh` | Có snapshot đầy đủ |
| 03:00 | `%sys` 61%, `%usr` 33%, `steal` 0% | `ss -s`: 18.400 established | Nghi L7 |
| 03:02 | 3 IP giữ 9.000 kết nối | `nginx-top.sh` | 3 IP chiếm 72% request |
| 03:04 | UA `python-requests/2.31`, path `/?s=<random>` | Xác nhận search flood | Không phải traffic thật |
| 03:06 | — | `deny` 3 IP + `limit_req 10r/s` | rps 8.100 → 2.400 |
| 03:08 | CPU còn 64% | Bật micro-cache 10s | rps vào PHP giảm 91% |
| 03:10 | CPU 12%, load 3.1 | Site phản hồi bình thường | Đã kiểm soát |
| 03:12 | — | Chụp log, lưu `/root/incident-*` | Có bằng chứng |

**Bài học**

1. IP gốc lộ vì chưa bật proxy Cloudflare → flood đánh thẳng, WAF không thấy gì.
2. 3 IP là đủ để làm sập site: không cần botnet lớn, chỉ cần không giới hạn
   request/IP.
3. `limit_req` + micro-cache là combo rẻ nhất, hiệu quả nhất cho L7.
4. Sau sự cố: bật proxy Cloudflare, thêm rule rate limit cho `?s=`, và alert
   theo rps thay vì chỉ theo CPU.

---

## 14. FAQ

**Có nên reboot server ngay khi CPU 100%?**
Không. Reboot không chặn được tấn công, lại xóa sạch trạng thái để chẩn đoán
(`ss`, `top`, log trong RAM) và có thể khiến site downtime lâu hơn.

**Chặn IP bằng nginx hay iptables/nftables?**
L7 (request) → nginx, vì nginx hiểu HTTP và trả 403/429 nhẹ nhàng. L4 (gói tin)
→ nftables/provider, vì nginx không bao giờ thấy gói tin đó. Với hàng nghìn IP,
dùng set của nftables hoặc edge.

**Tăng `worker_connections` có giúp không?**
Chỉ khi error log có `worker_connections are not enough` hoặc `accepts` >
`handled`. Nếu không, tăng chỉ tốn RAM.

**CPU 100% nhưng rps rất thấp?**
Đừng tối ưu nginx. Kiểm tra malware/miner, swap, DB, hoặc một process PHP bị
treo. Xem [mục 9](#9-cpu-cao-nhưng-không-phải-do-traffic).

**Console của nhà cung cấp vào được nhưng SSH thì không — bắt đầu từ đâu?**
Từ console, kiểm tra theo thứ tự: `sshd` còn chạy không (`ss -ltnp | grep :22`),
IP của bạn có bị firewall/fail2ban chặn không, `conntrack` có đầy không, disk có
đầy không, rồi tới `MaxStartups`. Chi tiết ở
[mục 6.8](#68-console-vào-được-ssh-không--vì-sao).

**Dùng Cloudflare thì có cần `real_ip` không?**
Bắt buộc. Không có `real_ip`, mọi request trông như đến từ IP Cloudflare: log
vô dụng, rate limit áp sai, và `deny` có thể chặn cả CDN.

**Bật rate limit 10r/s có làm mất khách thật không?**
Với trang tĩnh thì 10r/s/IP là rất rộng. Rủi ro chính là CDN/proxy dùng chung
IP, hoặc văn phòng nhiều người chung NAT. Theo dõi tỉ lệ 429 và tăng `burst`
nếu cần.

**Cache 10 giây có làm khách thấy dữ liệu cũ?**
Có, 10 giây. Vì vậy chỉ cache trang public, không cache giỏ hàng/thanh toán/
trang đăng nhập (đã có `$skip_cache` trong file mẫu).

**Log 20 GB thì phân tích bao lâu?**
`nginx-top.sh` dùng `awk` nên khoảng 1–2 triệu dòng/giây trên VPS thường. Nếu
quá lớn, dùng `-m 500000` để chỉ phân tích 500k dòng cuối.

**`max_children` nên đặt bao nhiêu?**
Tính theo RSS thật, không theo cảm giác: xem [mục 7.3](#73-max_children--tính-bằng-ram-không-bằng-cảm-giác).

**Có cần tcpdump không?**
Chỉ khi cần bằng chứng hoặc phân tích L4. `tcpdump` trên máy đang flood làm
tăng tải, hãy giới hạn `-c` và `-w` ra disk riêng.

---

## 15. Thuật ngữ

| Thuật ngữ | Nghĩa |
|-----------|-------|
| **rps** | Requests per second — số request mỗi giây |
| **L4 / L7** | Tấn công lớp transport (TCP/UDP) / lớp ứng dụng (HTTP) |
| **Slowloris** | Mở nhiều kết nối, gửi header rất chậm để giữ worker |
| **Cache bypass** | Thêm query ngẫu nhiên để không trúng cache |
| **Upstream** | Backend mà nginx chuyển request tới (PHP-FPM, app server) |
| **Pool** | Nhóm worker PHP-FPM phục vụ một site |
| **Worker** | Process con xử lý request (nginx hoặc PHP-FPM) |
| **stub_status** | Module nginx xuất thống kê kết nối/request |
| **`real_ip`** | Module khôi phục IP thật khi đi qua proxy/CDN |
| **WAF** | Web Application Firewall — lọc request độc ở lớp ứng dụng |
| **JS challenge** | Trang kiểm tra trình duyệt để chặn bot |
| **steal** | CPU bị hypervisor lấy cho máy khác (VPS) |
| **`MaxStartups`** | Giới hạn số kết nối SSH chưa xác thực trước khi `sshd` bắt đầu drop |
| **conntrack** | Bảng theo dõi kết nối của netfilter; đầy thì gói tin mới bị drop |
| **fail2ban** | Daemon đọc log và tự thêm rule chặn IP có hành vi xấu |
| **console (VNC/serial)** | Terminal qua hypervisor, không phụ thuộc mạng của VPS |

---

## Phụ lục

### A. Mẫu cấu hình đầy đủ

| File | Nội dung |
|------|----------|
| [`conf/nginx-ratelimit.conf`](conf/nginx-ratelimit.conf) | Rate limit + chống slowloris |
| [`conf/nginx-microcache.conf`](conf/nginx-microcache.conf) | Micro-cache 10s |
| [`conf/php-fpm-tuning.conf`](conf/php-fpm-tuning.conf) | Pool tuning + slowlog + status |

> [!NOTE]
> Đây là **snippet tham khảo**, không phải file thay thế. Mỗi file ghi rõ phần
> nào thuộc `http {}`, phần nào thuộc `server {}`. Luôn `nginx -t` trước khi
> reload.

### B. Bảng ngưỡng nhanh

| Chỉ số | Bình thường | Cảnh báo | Nguy hiểm |
|--------|-------------|----------|-----------|
| load/core | < 0.7 | 0.7–1.5 | > 2.0 |
| `%sys` | < 15% | 15–40% | > 40% |
| `%wa` | < 5% | 5–20% | > 20% |
| `%steal` | 0% | 1–5% | > 10% |
| Estab conn | < 2k | 2k–10k | > 10k |
| `syn-recv` | ~0 | 100–1000 | > 1000 |
| 5xx | < 0.1% | 0.1–1% | > 1% |
| `max children reached` | 0 | 1–10 | > 10 |
| Swap used | 0 | < 20% | > 20% |

### C. Lỗi thường gặp

| Lỗi | Nguyên nhân | Xử lý |
|-----|-------------|-------|
| `502 Bad Gateway` | PHP-FPM chết hoặc hết worker | Xem `php-fpm.log`, tăng `max_children` |
| `504 Gateway Timeout` | PHP chạy quá lâu | `request_terminate_timeout`, tối ưu code |
| `worker_connections are not enough` | Chạm trần kết nối | Tăng `worker_connections`, `worker_rlimit_nofile` |
| `Too many open files` | `ulimit -n` thấp | systemd `LimitNOFILE=65535` |
| `upstream timed out` | Upstream chậm | Xem PHP/DB |
| `SSL_do_handshake() failed` | Scan/TLS flood | `ssl_session_cache`, edge |
| `client intended to send too large body` | POST flood | `client_max_body_size`, rate limit |
| 429 hàng loạt | Rate limit quá chặt | Tăng `rate`/`burst` |

### D. Ghi chú về môi trường Việt Nam

- Nhiều VPS dùng chung CPU → `%steal` cao là chuyện thường; hãy kiểm tra trước
  khi đổ lỗi cho code.
- Tấn công thường nhắm vào WordPress (`wp-login.php`, `xmlrpc.php`, `?s=`) vì
  chi phí thấp và số lượng site lớn.
- Nếu dùng CDN trong nước, hãy xác nhận CDN có header real IP riêng và cấu
  hình đúng, tránh chặn nhầm toàn bộ dải IP của CDN.

---

## Đóng góp

Pull request hoặc issue đều được hoan nghênh. Khi thêm lệnh/cấu hình mới:

- Ghi rõ **phiên bản** nginx/PHP đã kiểm chứng.
- Không đưa vào lệnh có thể làm mất dữ liệu mà không cảnh báo.
- Giữ phần “chỉ đọc” của `scripts/` — không thêm hành động chặn/xóa.

Nếu playbook này giúp bạn dập được một ca flood, hãy ⭐ repo để người khác tìm
thấy nhanh hơn.

## License

[MIT](LICENSE)
