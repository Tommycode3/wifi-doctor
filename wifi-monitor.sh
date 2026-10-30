#!/bin/bash
#
# wifi-monitor.sh — Long-running Wi-Fi monitor (catches intermittent drops)
#
# Use it when the problem is NOT constant but "drops every now and then" or "slows down at random".
# Leave it running for minutes/hours on the problematic network: it logs one row per sample
# with time, RSSI/noise, and latency to the gateway and the internet. Ctrl-C to stop.
#
# USAGE:
#   bash wifi-monitor.sh                               # every 5s, forever
#   INTERVAL=10 DURATION=1800 bash wifi-monitor.sh     # every 10s for 30 min
#
# Output: monitor-<date>.csv next to this script

set -u
IFACE="${WIFI_IFACE:-en0}"
INTERVAL="${INTERVAL:-5}"
DURATION="${DURATION:-0}"   # 0 = forever
# Output goes next to this script (override: WIFI_DOCTOR_DIR=/some/dir)
BASE="${WIFI_DOCTOR_DIR:-$(cd "$(dirname "$0")" && pwd)}"
STAMP="$(date +%Y%m%d-%H%M%S)"
CSV="$BASE/monitor-$STAMP.csv"
mkdir -p "$BASE"

run_to() { local s="$1"; shift; "$@" & local p=$!; ( sleep "$s"; kill -9 "$p" 2>/dev/null ) & local k=$!; wait "$p" 2>/dev/null; local rc=$?; kill -9 "$k" 2>/dev/null; wait "$k" 2>/dev/null; return $rc; }

GW="$(route -n get default 2>/dev/null | awk '/gateway/{print $2; exit}')"

get_rssi_noise() {
  system_profiler SPAirPortDataType 2>/dev/null | awk '
    /Signal \/ Noise/ { s=$0; sub(/.*: /,"",s); print s; f=1; exit }
    END { if(!f) print "n/a n/a" }' | sed 's/ dBm//g; s/\// /g' | awk '{print $1","$2}'
}

echo "timestamp,ssid,rssi_dBm,noise_dBm,gateway_ms,internet_ms,dns_ok" > "$CSV"
echo "[Wi-Fi monitor] writing to: $CSV"
echo "[Wi-Fi monitor] interval ${INTERVAL}s, duration $([ "$DURATION" = 0 ] && echo 'unlimited' || echo "${DURATION}s"). Ctrl-C to stop."
echo ""
printf "%-10s %-8s %-8s %-12s %-12s %s\n" "time" "RSSI" "Noise" "gateway" "internet" "dns"

START="$(date +%s)"
trap 'echo ""; echo "[done] Report: $CSV"; exit 0' INT

while :; do
  NOW="$(date +%s)"
  [ "$DURATION" != 0 ] && [ $((NOW - START)) -ge "$DURATION" ] && break
  TS="$(date +%H:%M:%S)"
  SSID="$(networksetup -getairportnetwork "$IFACE" 2>/dev/null | sed 's/.*: //')"
  RN="$(get_rssi_noise)"; R="${RN%,*}"; N="${RN#*,}"
  if [ -n "$GW" ]; then
    PG="$(run_to 4 ping -c 1 -t 2 "$GW" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}')"
    [ -z "$PG" ] && PG="TIMEOUT"
  else PG="no-gw"; fi
  PI="$(run_to 4 ping -c 1 -t 2 1.1.1.1 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}')"
  [ -z "$PI" ] && PI="TIMEOUT"
  if run_to 5 dig +time=2 +tries=1 +short apple.com 2>/dev/null | grep -q .; then D="ok"; else D="FAIL"; fi

  echo "$TS,$SSID,$R,$N,$PG,$PI,$D" >> "$CSV"
  printf "%-10s %-8s %-8s %-12s %-12s %s\n" "$TS" "${R:-n/a}" "${N:-n/a}" "$PG" "$PI" "$D"
  sleep "$INTERVAL"
done
echo ""
echo "[done] Report: $CSV"
