#!/usr/bin/env bash
# nginx-top.sh - phan tich access log nginx de tim dau hieu DDoS / flood.
#
# CHI DOC file log. Khong sua cau hinh, khong chan IP.
#
# Usage:
#   sudo ./nginx-top.sh
#   sudo ./nginx-top.sh -f /var/log/nginx/site.access.log -n 30
#   sudo ./nginx-top.sh -m 200000 -b 500 -o /tmp/report.txt
#
# Options:
#   -f, --file FILE   access log (default /var/log/nginx/access.log; ho tro .gz; '-' = stdin)
#   -n, --top N       so dong top moi muc (default 15)
#   -m, --max N       chi phan tich N dong cuoi (default 0 = toan bo)
#   -b, --big N       nguong IP "dang ngo" theo so request (default 300)
#   -o, --output FILE ghi bao cao ra FILE
#   -h, --help        tro giup
#   -V, --version     phien ban
#
# Exit codes: 0 = ok, 2 = usage error / khong doc duoc log

set -uo pipefail
export LC_ALL=C

VERSION="1.0.0"
LOG="${LOG:-/var/log/nginx/access.log}"
TOPN=15
MAXLINES=0
BIG=300
OUT=""
TMP=""

usage() {
  sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "ERROR: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--file)   shift; LOG=${1:-} ;;
    -n|--top)    shift; TOPN=${1:-15} ;;
    -m|--max)    shift; MAXLINES=${1:-0} ;;
    -b|--big)    shift; BIG=${1:-300} ;;
    -o|--output) shift; OUT=${1:-} ;;
    -h|--help)   usage; exit 0 ;;
    -V|--version) echo "nginx-top.sh $VERSION"; exit 0 ;;
    *)           die "unknown option: $1 (dung -h de xem tro giup)" ;;
  esac
  shift
done

for v in "$TOPN" "$MAXLINES" "$BIG"; do
  case "$v" in ''|*[!0-9]*) die "-n/-m/-b phai la so nguyen" ;; esac
done
[ "$TOPN" -ge 1 ] || die "-n phai >= 1"

if [ "$LOG" != "-" ]; then
  [ -r "$LOG" ] || die "khong doc duoc log: $LOG"
fi

have() { command -v "$1" >/dev/null 2>&1; }
sec()  { printf '\n== %s ==\n' "$*"; }

TMP=$(mktemp) || die "khong tao duoc temp file"
RAW=$(mktemp) || die "khong tao duoc temp file"
trap 'rm -f -- "$TMP" "$RAW"' EXIT

# ---------------------------------------------------------------- extract
emit_log() {
  if [ "$LOG" = "-" ]; then
    cat
  elif [ "${LOG##*.}" = "gz" ]; then
    gzip -dc -- "$LOG" 2>/dev/null
  else
    cat -- "$LOG"
  fi
}

if [ "$MAXLINES" -gt 0 ]; then
  emit_log | tail -n "$MAXLINES" >"$RAW"
else
  emit_log >"$RAW"
fi

awk '
BEGIN { OFS = "\t" }
{
  t = ""; req = ""; st = "-"; by = 0; ref = ""; ua = ""

  if (match($0, /\[[^]]*\]/)) t = substr($0, RSTART + 1, RLENGTH - 2)

  if (match($0, /"[^"]*"/)) {
    req  = substr($0, RSTART + 1, RLENGTH - 2)
    rest = substr($0, RSTART + RLENGTH)
  } else {
    rest = ""
  }

  split(rest, s, " ")
  if (s[1] ~ /^[0-9][0-9][0-9]$/) st = s[1]
  if (s[2] ~ /^[0-9]+$/)         by = s[2]

  nq = split($0, q, "\"")
  if (nq >= 5) ref = q[4]
  if (nq >= 7) ua  = q[6]

  if (req != "") {
    split(req, r, " ")
    meth = r[1]
    path = r[2]
  } else {
    meth = "-"; path = "-"
  }

  print $1, t, meth, path, st, by, ref, ua
}
' "$RAW" >"$TMP"

total=$(wc -l <"$TMP" | tr -d ' ')
if [ "$total" -eq 0 ]; then
  die "log rong hoac khong doc duoc: $LOG"
fi

# ---------------------------------------------------------------- stats
first_t=$(awk -F'\t' 'NR==1{print $2}' "$TMP")
last_t=$(awk -F'\t' 'END{print $2}' "$TMP")

month_num() {
  case "$1" in
    Jan) echo 01 ;; Feb) echo 02 ;; Mar) echo 03 ;; Apr) echo 04 ;;
    May) echo 05 ;; Jun) echo 06 ;; Jul) echo 07 ;; Aug) echo 08 ;;
    Sep) echo 09 ;; Oct) echo 10 ;; Nov) echo 11 ;; Dec) echo 12 ;;
    *)   echo "" ;;
  esac
}

to_epoch() {
  local t=$1 d m y rest hms tz mm
  case "$t" in
    [0-9][0-9]/*/*:[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ;;
    *) return 1 ;;
  esac
  d=${t%%/*}; rest=${t#*/}
  m=${rest%%/*}; rest=${rest#*/}
  y=${rest%%:*}; rest=${rest#*:}
  hms=${rest% *}; tz=${rest#* }
  mm=$(month_num "$m")
  [ -n "$mm" ] || return 1
  date -d "$y-$mm-$d $hms $tz" +%s 2>/dev/null
}

uniq_ips=$(cut -f1 "$TMP" | sort -u | wc -l | tr -d ' ')
unparsed=$(awk -F'\t' '$5 == "-"' "$TMP" | wc -l | tr -d ' ')

rps="?"
e1=$(to_epoch "$first_t" || true)
e2=$(to_epoch "$last_t" || true)
if [ -n "${e1:-}" ] && [ -n "${e2:-}" ] && [ "$e2" -gt "$e1" ] 2>/dev/null; then
  rps=$(awk -v n="$total" -v d="$((e2 - e1))" 'BEGIN{printf "%.1f", n/d}')
fi

# ---------------------------------------------------------------- report
exec 3>&1 4>&2
exec >"$TMP.report" 2>&1

sec "NGINX ACCESS LOG - $LOG"
printf '  dong phan tich : %s\n' "$total"
printf '  IP duy nhat    : %s\n' "$uniq_ips"
printf '  thoi gian      : %s  ->  %s\n' "${first_t:-?}" "${last_t:-?}"
printf '  request/s (tb) : %s\n' "$rps"
printf '  dong khong parse duoc: %s\n' "$unparsed"

if [ "$unparsed" -gt 0 ]; then
  printf '  (!) log khong phai format combined chuan - ket qua co the sai\n'
fi

sec "PHAN BO STATUS"
awk -F'\t' '{c[substr($5,1,1)"xx"]++} END{for(k in c) printf "%8d  %s\n", c[k], k}' "$TMP" \
  | sort -k2
printf '\n  chi tiet:\n'
cut -f5 "$TMP" | sort | uniq -c | sort -rn | head -n 10 | sed 's/^/  /'

sec "TOP $TOPN IP THEO SO REQUEST"
cut -f1 "$TMP" | sort | uniq -c | sort -rn | head -n "$TOPN" | sed 's/^/  /'

sec "TOP $TOPN IP THEO BANG THONG (bytes tra ve)"
awk -F'\t' '{b[$1]+=$6} END{for(i in b) printf "%.1f MB\t%s\n", b[i]/1048576, i}' "$TMP" \
  | sort -rn | head -n "$TOPN" | awk -F'\t' '{printf "  %10s  %s\n", $1, $2}'

sec "TOP $TOPN IP THEO 4xx/5xx (dau hieu scan/flood)"
awk -F'\t' '$5 ~ /^[45]/ {c[$1]++} END{for(i in c) printf "%8d  %s\n", c[i], i}' "$TMP" \
  | sort -rn | head -n "$TOPN" | sed 's/^/  /'

sec "TOP $TOPN URL (da bo query string)"
cut -f4 "$TMP" | cut -d'?' -f1 | sort | uniq -c | sort -rn | head -n "$TOPN" | sed 's/^/  /'

sec "PATH CO NHIEU QUERY KHAC NHAU (cache-bypass / search flood)"
awk -F'\t' '$4 ~ /\?/ {split($4, a, "?"); print a[1] "\t" $4}' "$TMP" \
  | sort -u | cut -f1 | uniq -c | sort -rn | head -n "$TOPN" \
  | awk '{printf "  %6d query khac nhau  %s\n", $1, $2}'

sec "TOP $TOPN URL BI 404"
awk -F'\t' '$5 == "404" {print $4}' "$TMP" | cut -d'?' -f1 \
  | sort | uniq -c | sort -rn | head -n "$TOPN" | sed 's/^/  /'

sec "TOP $TOPN POST (brute-force / form flood)"
awk -F'\t' '$3 == "POST" {print $4}' "$TMP" | cut -d'?' -f1 \
  | sort | uniq -c | sort -rn | head -n "$TOPN" | sed 's/^/  /'

sec "TOP $TOPN USER-AGENT"
awk -F'\t' '$8 != "" {print $8}' "$TMP" | sort | uniq -c | sort -rn \
  | head -n "$TOPN" | cut -c1-160 | sed 's/^/  /'

empty_ua=$(awk -F'\t' '$8 == ""' "$TMP" | wc -l | tr -d ' ')
printf '\n  request khong co User-Agent : %s\n' "$empty_ua"

sec "USER-AGENT DANG NGO (scanner / tool)"
awk -F'\t' 'tolower($8) ~ /(sqlmap|nikto|nmap|masscan|zgrab|nessus|acunetix|python-requests|go-http-client|curl\/|wget\/|libwww|httpclient|scanner|dirbuster|gobuster|wfuzz|exploit)/ {print $8}' "$TMP" \
  | sort | uniq -c | sort -rn | head -n "$TOPN" | cut -c1-160 | sed 's/^/  /'

sec "TOP $TOPN REFERER (trong = khong co referer)"
awk -F'\t' '$7 != "" && $7 != "-" {print $7}' "$TMP" | sort | uniq -c | sort -rn \
  | head -n "$TOPN" | cut -c1-160 | sed 's/^/  /'

sec "IP VUOT NGUONG > $BIG REQUEST"
awk -F'\t' -v t="$BIG" '{c[$1]++} END{for(i in c) if (c[i] > t) printf "%8d  %s\n", c[i], i}' "$TMP" \
  | sort -rn | head -n 50 | sed 's/^/  /'

printf '\n== GOI Y ==\n'
cat <<'EOF'
  - 1-5 IP chiem >50% request        -> chan IP / rate limit theo IP
  - nhieu IP, cung UA/path           -> chan theo UA + path, bat WAF challenge
  - top URL la /wp-login.php         -> siet login, fail2ban, 2FA
  - top URL la /?s=...               -> search flood, chan query + cache
  - POST /api/... rat nhieu          -> rate limit rieng cho /api
  - 4xx chiem 60-90%                 -> scanner, chan UA/ASN
  - UA rong hoac curl/python         -> bot, chan theo UA
EOF

printf '\n== END %s ==\n' "$(date -Is)"

exec 1>&3 2>&4

if [ -n "$OUT" ]; then
  mkdir -p -- "$(dirname -- "$OUT")" 2>/dev/null || true
  if cp -- "$TMP.report" "$OUT" 2>/dev/null; then
    echo "da ghi bao cao: $OUT" >&2
  else
    echo "khong ghi duoc $OUT" >&2
  fi
fi

cat -- "$TMP.report"
rm -f -- "$TMP.report"
