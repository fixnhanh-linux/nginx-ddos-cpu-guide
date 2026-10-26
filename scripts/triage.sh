#!/usr/bin/env bash
# triage.sh - snapshot chan doan nhanh web server (nginx + php-fpm).
#
# CHI DOC: khong sua cau hinh, khong chan IP, khong kill process.
#
# Usage:
#   sudo ./triage.sh
#   sudo ./triage.sh -o /tmp/triage.txt -n 20
#   sudo ./triage.sh --nginx-status http://127.0.0.1:8080/nginx_status
#   sudo ./triage.sh --fpm-status http://127.0.0.1/fpm-status
#
# Options:
#   -o, --output FILE     ghi ket qua ra FILE (van in ra man hinh)
#   -n, --top N           so process / IP hien thi (default 15)
#       --nginx-status U  URL stub_status
#       --fpm-status U    URL php-fpm status
#   -h, --help            tro giup
#   -V, --version         phien ban
#
# Exit codes: 0 = ok, 2 = usage error

set -uo pipefail
export LC_ALL=C

VERSION="1.0.0"
TOPN="${TOPN:-15}"
OUT=""
NGINX_STATUS_URL="${NGINX_STATUS_URL:-http://127.0.0.1/nginx_status}"
FPM_STATUS_URL="${FPM_STATUS_URL:-}"
TMP=""

usage() {
  sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "ERROR: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output)     shift; OUT=${1:-} ;;
    -n|--top)        shift; TOPN=${1:-15} ;;
    --nginx-status)  shift; NGINX_STATUS_URL=${1:-} ;;
    --fpm-status)    shift; FPM_STATUS_URL=${1:-} ;;
    -h|--help)       usage; exit 0 ;;
    -V|--version)    echo "triage.sh $VERSION"; exit 0 ;;
    *)               die "unknown option: $1 (dung -h de xem tro giup)" ;;
  esac
  shift
done

case "$TOPN" in
  ''|*[!0-9]*) die "-n phai la so nguyen duong" ;;
esac
[ "$TOPN" -ge 1 ] || die "-n phai >= 1"

have() { command -v "$1" >/dev/null 2>&1; }
sec()  { printf '\n== %s ==\n' "$*"; }
sub()  { printf '\n-- %s\n' "$*"; }

TMP=$(mktemp) || die "khong tao duoc temp file"
trap 'rm -f -- "$TMP"' EXIT

echo "dang thu thap du lieu..." >&2
exec 3>&1 4>&2
exec >"$TMP" 2>&1

sec "TRIAGE - $(date -Is)"
printf '  host      : %s\n' "$(hostname 2>/dev/null || echo '?')"
printf '  kernel    : %s\n' "$(uname -sr 2>/dev/null || echo '?')"
printf '  uptime    : %s\n' "$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo '?')"
printf '  virt      : %s\n' "$(systemd-detect-virt 2>/dev/null || echo 'unknown')"
printf '  run as    : uid=%s\n' "$(id -u)"

# ---------------------------------------------------------------- CPU / load
sec "CPU va load"
printf '  nproc     : %s\n' "$(nproc 2>/dev/null || echo '?')"
printf '  model     : %s\n' \
  "$(awk -F: '/model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
printf '  loadavg   : %s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"

load1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)
cores=$(nproc 2>/dev/null || echo 1)
if [ -n "$load1" ] && [ "$cores" -gt 0 ] 2>/dev/null; then
  awk -v l="$load1" -v n="$cores" \
    'BEGIN{printf "  load/core : %.2f%s\n", l/n, (l/n > 1 ? "  <-- QUA TAI" : "")}'
fi

if have mpstat; then
  sub "mpstat -P ALL 1 1 (1 giay)"
  mpstat -P ALL 1 1 2>/dev/null | sed 's/^/  /'
fi

sub "top $TOPN process theo CPU"
printf '  %7s %7s %5s %5s %8s %10s  %s\n' PID PPID '%CPU' '%MEM' RSS ELAPSED COMMAND
ps -eo pid=,ppid=,pcpu=,pmem=,rss=,etime=,comm=,args= --sort=-pcpu 2>/dev/null \
  | awk -v self="$$" '$1 != self' \
  | head -n "$TOPN" | cut -c1-180 | sed 's/^/  /'

# ---------------------------------------------------------------- memory
sec "RAM va swap"
free -h 2>/dev/null | sed 's/^/  /'
if have swapon; then
  sub "swap dang dung"
  swapon --show 2>/dev/null | sed 's/^/  /' || echo "  (khong co swap)"
fi

sub "OOM killer (neu co)"
oom=$(dmesg -T 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -5)
if [ -n "$oom" ]; then
  printf '%s\n' "$oom" | sed 's/^/  /'
else
  echo "  (khong thay OOM trong dmesg)"
fi

# ---------------------------------------------------------------- disk / io
sec "Disk va I/O"
df -h / 2>/dev/null | sed 's/^/  /'
df -i / 2>/dev/null | sed 's/^/  /'
if have iostat; then
  sub "iostat -xz 1 2 (dong %util cao la nghen IO)"
  iostat -xz 1 2 2>/dev/null | sed 's/^/  /'
else
  sub "vmstat 1 2 (r, b, si, so, wa)"
  vmstat 1 2 2>/dev/null | sed 's/^/  /'
fi

# ---------------------------------------------------------------- network
sec "Mang"
sub "ss -s"
ss -s 2>/dev/null | sed 's/^/  /'

est=$(ss -H -tan state established '( sport = :80 or sport = :443 )' 2>/dev/null | wc -l)
syn=$(ss -H -tan state syn-recv 2>/dev/null | wc -l)
tw=$(ss -H -tan state time-wait 2>/dev/null | wc -l)
printf '\n  established 80/443 : %s\n' "$est"
printf '  syn-recv           : %s\n' "$syn"
printf '  time-wait          : %s\n' "$tw"

sub "top $TOPN IP theo so ket noi 80/443"
ss -H -tn state established '( sport = :80 or sport = :443 )' 2>/dev/null \
  | awk '{split($4,a,":"); print a[1]}' \
  | sort | uniq -c | sort -rn | head -n "$TOPN" | sed 's/^/  /'

# ---------------------------------------------------------------- nginx
sec "Nginx"
if have nginx; then
  nginx -v 2>&1 | sed 's/^/  /'
  nginx -t 2>&1 | sed 's/^/  /' || true

  sub "workers"
  printf '  nginx process: %s\n' "$(pgrep -c -x nginx 2>/dev/null || echo 0)"

  sub "cau hinh dang chay (cac directive quan trong)"
  nginx -T 2>/dev/null \
    | grep -E '^[[:space:]]*(worker_processes|worker_connections|worker_rlimit_nofile|multi_accept|keepalive_timeout|client_header_timeout|client_body_timeout|send_timeout|client_max_body_size|limit_req_zone|limit_conn_zone|fastcgi_cache|proxy_cache|ssl_session_cache)' \
    | head -30 | sed 's/^/  /'

  if [ -n "$NGINX_STATUS_URL" ] && have curl; then
    sub "stub_status: $NGINX_STATUS_URL"
    status=$(curl -s --max-time 3 "$NGINX_STATUS_URL" 2>/dev/null)
    if [ -n "$status" ]; then
      printf '%s\n' "$status" | sed 's/^/  /'

      # request/s trong 1 giay
      a=$(printf '%s\n' "$status" | awk '/requests/{print $3}')
      sleep 1
      status2=$(curl -s --max-time 3 "$NGINX_STATUS_URL" 2>/dev/null)
      b=$(printf '%s\n' "$status2" | awk '/requests/{print $3}')
      if [ -n "${a:-}" ] && [ -n "${b:-}" ] && [ "$b" -ge "$a" ] 2>/dev/null; then
        printf '\n  requests/s : %s\n' "$((b - a))"
      fi
    else
      echo "  (khong lay duoc stub_status - da bat chua?)"
    fi
  fi

  errlog=""
  for f in /var/log/nginx/error.log /var/log/nginx/error.log.1; do
    [ -r "$f" ] && { errlog=$f; break; }
  done
  if [ -n "$errlog" ]; then
    sub "20 dong cuoi $errlog"
    tail -n 20 "$errlog" | sed 's/^/  /'
  fi
else
  echo "  (khong tim thay nginx trong PATH - co the chay trong container?)"
fi

# ---------------------------------------------------------------- php-fpm
sec "PHP-FPM"
fpm_count=$(pgrep -c -f 'php-fpm' 2>/dev/null || true)
printf '  php-fpm process : %s\n' "${fpm_count:-0}"

if have php; then
  php -v 2>/dev/null | head -1 | sed 's/^/  /'
fi

sub "pool config (pm.*)"
found_pool=0
for f in /etc/php/*/fpm/pool.d/*.conf; do
  [ -r "$f" ] || continue
  found_pool=1
  echo "  $f"
  grep -hE '^[[:space:]]*(pm|pm\.max_children|pm\.start_servers|pm\.min_spare_servers|pm\.max_spare_servers|pm\.max_requests|request_terminate_timeout|request_slowlog_timeout|listen)[[:space:]]*=' \
    "$f" 2>/dev/null | sed 's/^/    /'
done
[ "$found_pool" -eq 1 ] || echo "  (khong thay /etc/php/*/fpm/pool.d/*.conf)"

if [ -n "$FPM_STATUS_URL" ] && have curl; then
  sub "php-fpm status: $FPM_STATUS_URL"
  fst=$(curl -s --max-time 3 "$FPM_STATUS_URL" 2>/dev/null)
  if [ -n "$fst" ]; then
    printf '%s\n' "$fst" | sed 's/^/  /'
  else
    echo "  (khong lay duoc status - da bat pm.status_path chua?)"
  fi
fi

sub "slowlog / error log"
found_log=0
for f in /var/log/php-fpm/slow.log /var/log/php-fpm/*.log /var/log/php*-fpm.log; do
  [ -r "$f" ] || continue
  found_log=1
  echo "  $f"
  tail -n 15 "$f" | sed 's/^/    /'
done
[ "$found_log" -eq 1 ] || echo "  (khong tim thay log php-fpm)"

# ---------------------------------------------------------------- persistence
sec "Dau hieu bat thuong (khi CPU cao ma traffic thap)"
sub "ld.so.preload"
if [ -s /etc/ld.so.preload ]; then
  sed 's/^/  /' /etc/ld.so.preload
else
  echo "  (trong hoac khong ton tai)"
fi

sub "process co exe da bi xoa"
deleted=""
nfound=0
for p in /proc/[0-9]*/exe; do
  link=$(readlink "$p" 2>/dev/null) || continue
  case "$link" in
    *"(deleted)"*)
      deleted="${deleted}  ${p#/proc/} -> $link"$'\n'
      nfound=$((nfound + 1))
      ;;
  esac
  [ "$nfound" -ge 5 ] && break
done
if [ -n "$deleted" ]; then
  printf '%s' "$deleted"
else
  echo "  (khong co)"
fi

sub "systemd timer dang bat"
if have systemctl; then
  systemctl list-timers --all --no-pager 2>/dev/null | head -12 | sed 's/^/  /'
fi

# ---------------------------------------------------------------- summary
sec "GOI Y BUOC TIEP"
cat <<'EOF'
  - load/core > 1.5, est conn cao       -> chay scripts/nginx-top.sh
  - syn-recv lon, %sys/%soft cao        -> nghi L4/SYN flood, xu ly o provider
  - %wa cao, swap day, co OOM           -> thieu RAM hoac I/O, xem DB/disk
  - rps thap ma CPU 100%, process la    -> nghi malware/miner (xem repo linux-malware-check)
  - php-fpm max children reached > 0    -> xem lai max_children va slowlog
EOF

printf '\n== END %s ==\n' "$(date -Is)"

exec 1>&3 2>&4

if [ -n "$OUT" ]; then
  mkdir -p -- "$(dirname -- "$OUT")" 2>/dev/null || true
  if cp -- "$TMP" "$OUT" 2>/dev/null; then
    echo "da ghi bao cao: $OUT" >&2
  else
    echo "khong ghi duoc $OUT" >&2
  fi
fi
cat -- "$TMP"
