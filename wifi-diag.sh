#!/bin/bash
#
# wifi-diag.sh — OFFLINE Wi-Fi diagnostic collector for macOS
#
# Collects everything needed to diagnose a Wi-Fi network while you are
# connected to it (even with no working internet).
# Produces a folder + a single .txt report + a tarball to analyse later.
#
# USAGE:
#   1) Connect to the problematic Wi-Fi network.
#   2) Run:      bash wifi-diag.sh
#      (for maximum detail:  sudo bash wifi-diag.sh)
#   3) Reconnect to a network that works.
#   4) Read or share RESULTS-*/REPORT.txt (next to this script).
#
# Needs no internet to run. Every test has a timeout: if the network is
# dead, the script does NOT hang, it records the failure and moves on.

set -u

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
IFACE="${WIFI_IFACE:-en0}"          # Wi-Fi interface (override: WIFI_IFACE=en1 ...)
SAMPLE_SECONDS="${SAMPLE_SECONDS:-45}"  # duration of signal/connectivity sampling
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-3}" # seconds between samples
PING_TIMEOUT=4                       # timeout (s) for single tests

STAMP="$(date +%Y%m%d-%H%M%S)"
# Output goes next to this script (override: WIFI_DOCTOR_DIR=/some/dir)
BASE="${WIFI_DOCTOR_DIR:-$(cd "$(dirname "$0")" && pwd)}"
OUTDIR="$BASE/RESULTS-$STAMP"
RAW="$OUTDIR/raw"
REPORT="$OUTDIR/REPORT.txt"
mkdir -p "$RAW"

# ----------------------------------------------------------------------------
# Helper: portable timeout (macOS has no `timeout`)
# ----------------------------------------------------------------------------
run_to() {
  # run_to <seconds> <command...>
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
  local killer=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill -9 "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null
  return $rc
}

# Colours only on a terminal
if [ -t 1 ]; then
  C_G="\033[32m"; C_Y="\033[33m"; C_B="\033[34m"; C_R="\033[31m"; C_0="\033[0m"
else
  C_G=""; C_Y=""; C_B=""; C_R=""; C_0=""
fi

step() { printf "${C_B}[*]${C_0} %s\n" "$1"; }
ok()   { printf "${C_G}[ok]${C_0} %s\n" "$1"; }
warn() { printf "${C_Y}[!]${C_0} %s\n" "$1"; }

# Writes a section header into the REPORT
sec() {
  {
    echo ""
    echo "================================================================"
    echo "== $1"
    echo "================================================================"
  } >> "$REPORT"
}
# Runs a command, appends its output to the REPORT + saves it raw
cap() {
  # cap <title> <raw_file> <command...>
  local title="$1" rawfile="$2"; shift 2
  sec "$title"
  echo "\$ $*" >> "$REPORT"
  if run_to 25 "$@" > "$RAW/$rawfile" 2>&1; then :; else
    echo "[command killed/timed out or failed — see partial output]" >> "$REPORT"
  fi
  cat "$RAW/$rawfile" >> "$REPORT"
}

# Extracts a field ONLY from system_profiler's "Current Network Information" block
# (avoids matching "Supported Channels/PHY Modes" or nearby networks)
sp_field() {
  system_profiler SPAirPortDataType 2>/dev/null | awk -v f="$1" '
    /Current Network Information:/ {inblk=1; next}
    /Other Local Wi-Fi Networks:/ {inblk=0}
    inblk {
      t=$0; sub(/^[ \t]+/,"",t)
      if (index(t, f ": ")==1) { v=t; sub(/^[^:]*: /,"",v); print v; exit }
    }'
}
# Robust SSID: networksetup fails on recent macOS ("not associated"); try several sources
current_ssid() {
  local s
  s="$(networksetup -getairportnetwork "$IFACE" 2>/dev/null | sed 's/^.*Network: //')"
  case "$s" in ""|*"not associated"*|*"not currently"*)
    s="$(ipconfig getsummary "$IFACE" 2>/dev/null | awk -F' : ' '/ SSID :/{print $2; exit}')"
    [ -z "$s" ] && s="$(system_profiler SPAirPortDataType 2>/dev/null | awk '/Current Network Information:/{getline; gsub(/^[ \t]+|:[ \t]*$/,""); print; exit}')"
    ;;
  esac
  [ -z "$s" ] && s="(SSID not readable — needs Location Services permission, or hotspot)"
  echo "$s"
}

HAVE_SUDO=0
if [ "$(id -u)" = "0" ]; then HAVE_SUDO=1; fi

# ----------------------------------------------------------------------------
# Header
# ----------------------------------------------------------------------------
{
  echo "################################################################"
  echo "#  WIFI DOCTOR — Diagnostic report"
  echo "#  Date:        $(date)"
  echo "#  Host:        $(hostname 2>/dev/null)"
  echo "#  macOS:       $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
  echo "#  Interface:   $IFACE"
  echo "#  Privileges:  $([ $HAVE_SUDO -eq 1 ] && echo 'root (maximum detail)' || echo 'user (some Wi-Fi data will be missing, re-run with sudo for full detail)')"
  echo "################################################################"
} > "$REPORT"

echo ""
step "Wi-Fi Doctor — collecting. No internet needed."
step "Output: $OUTDIR"
[ $HAVE_SUDO -eq 0 ] && warn "Tip: 'sudo bash $0' for full radio data (RSSI/noise/channel via wdutil)."
echo ""

# ----------------------------------------------------------------------------
# 1. Interface state / IP / current network
# ----------------------------------------------------------------------------
step "1/14  Interface state and IP"
cap "SSID / current network" "current_ssid.txt" networksetup -getairportnetwork "$IFACE"
cap "Interface IP config ($IFACE)" "ifconfig.txt" ifconfig "$IFACE"
cap "IP summary (ipconfig getsummary)" "ipsummary.txt" ipconfig getsummary "$IFACE"
cap "Router address / DHCP" "router.txt" ipconfig getpacket "$IFACE"

# ----------------------------------------------------------------------------
# 2. Wi-Fi radio detail (RSSI, noise, channel, tx rate, PHY)
# ----------------------------------------------------------------------------
step "2/14  Wi-Fi radio detail (signal, channel, noise)"
if [ $HAVE_SUDO -eq 1 ]; then
  cap "wdutil info (full radio detail)" "wdutil.txt" wdutil info
else
  sec "wdutil info"
  echo "[skipped: needs sudo — re-run with 'sudo bash $0' for precise RSSI/noise/channel]" >> "$REPORT"
fi
cap "system_profiler Wi-Fi (RSSI/noise/channel/visible networks)" "spairport.txt" system_profiler SPAirPortDataType

# ----------------------------------------------------------------------------
# 3. DNS
# ----------------------------------------------------------------------------
step "3/14  DNS configuration"
cap "Configured DNS (scutil)" "dns.txt" scutil --dns
cap "DNS via networksetup" "dns2.txt" networksetup -getdnsservers "$IFACE"
cap "/etc/resolv.conf" "resolv.txt" cat /etc/resolv.conf

# ----------------------------------------------------------------------------
# 4. Routing / ARP / gateway
# ----------------------------------------------------------------------------
step "4/14  Routing, gateway and neighbours (ARP)"
cap "Routing table" "route.txt" netstat -rn
cap "Default gateway" "gw.txt" sh -c "route -n get default 2>&1"
cap "ARP table (devices seen on the LAN)" "arp.txt" arp -a
cap "Interfaces (all)" "ifconfig_all.txt" ifconfig

# Find the gateway for the following pings
GW="$(route -n get default 2>/dev/null | awk '/gateway/{print $2; exit}')"
[ -z "$GW" ] && GW="$(netstat -rn 2>/dev/null | awk '/^default/{print $2; exit}')"

# ----------------------------------------------------------------------------
# 5. Connectivity: gateway -> internet -> DNS
# ----------------------------------------------------------------------------
step "5/14  Layered connectivity test (LAN -> Internet -> DNS)"
sec "Ping local GATEWAY ($GW) — does the LAN work?"
if [ -n "$GW" ]; then
  echo "\$ ping -c 5 -t $PING_TIMEOUT $GW" >> "$REPORT"
  run_to 15 ping -c 5 -t "$PING_TIMEOUT" "$GW" >> "$REPORT" 2>&1 || echo "[gateway NOT reachable]" >> "$REPORT"
else
  echo "[no default gateway found — DHCP/network configuration problem]" >> "$REPORT"
fi

sec "Ping INTERNET by IP (1.1.1.1 and 8.8.8.8) — is there an internet uplink? (bypasses DNS)"
for ip in 1.1.1.1 8.8.8.8; do
  echo "\$ ping -c 5 -t $PING_TIMEOUT $ip" >> "$REPORT"
  run_to 15 ping -c 5 -t "$PING_TIMEOUT" "$ip" >> "$REPORT" 2>&1 || echo "[$ip NOT reachable]" >> "$REPORT"
  echo "" >> "$REPORT"
done

sec "DNS resolution (does DNS answer?)"
for host in apple.com google.com cloudflare.com; do
  echo "\$ dig +time=3 +tries=1 $host" >> "$REPORT"
  run_to 10 dig +time=3 +tries=1 "$host" >> "$REPORT" 2>&1 || echo "[DNS lookup of $host failed/timed out]" >> "$REPORT"
  echo "----" >> "$REPORT"
done
sec "DNS test against an explicit public server (@1.1.1.1) — is the local DNS broken?"
echo "\$ dig +time=3 +tries=1 @1.1.1.1 apple.com" >> "$REPORT"
run_to 10 dig +time=3 +tries=1 @1.1.1.1 apple.com >> "$REPORT" 2>&1 || echo "[the public DNS does not answer either]" >> "$REPORT"

# ----------------------------------------------------------------------------
# 6. Captive portal (does the network ask for a login?)
# ----------------------------------------------------------------------------
step "6/14  Captive portal detection (hotel/public network with login)"
sec "Captive portal check (Apple)"
echo "\$ curl -sS -m 8 http://captive.apple.com/hotspot-detect.html" >> "$REPORT"
CAP_OUT="$(run_to 10 curl -sSL -m 8 -w '\n[HTTP_CODE:%{http_code}] [FINAL_URL:%{url_effective}]' http://captive.apple.com/hotspot-detect.html 2>&1)"
echo "$CAP_OUT" >> "$REPORT"
if echo "$CAP_OUT" | grep -qi "Success"; then
  echo ">> RESULT: no captive portal (correct 'Success' response)." >> "$REPORT"
elif echo "$CAP_OUT" | grep -qi "HTTP_CODE:0"; then
  echo ">> RESULT: no response — probably no internet uplink at all." >> "$REPORT"
else
  echo ">> RESULT: unexpected response — POSSIBLE captive portal / proxy intercepting traffic." >> "$REPORT"
fi

# ----------------------------------------------------------------------------
# 7. Traceroute (where does traffic stop?)
# ----------------------------------------------------------------------------
step "7/14  Traceroute to the internet (where the path breaks)"
sec "Traceroute 1.1.1.1 (by IP, max 15 hops)"
echo "\$ traceroute -w 2 -q 1 -m 15 1.1.1.1" >> "$REPORT"
run_to 40 traceroute -w 2 -q 1 -m 15 1.1.1.1 >> "$REPORT" 2>&1 || echo "[traceroute interrupted/timed out]" >> "$REPORT"

# ----------------------------------------------------------------------------
# 8. Monitoring over time (signal + packet loss + drops)
# ----------------------------------------------------------------------------
step "8/14  Monitoring signal and connectivity for ${SAMPLE_SECONDS}s (catches intermittent dips/drops)"
sec "Time series: RSSI + gateway ping + internet ping (every ${SAMPLE_INTERVAL}s for ${SAMPLE_SECONDS}s)"
{
  printf "%-21s %-8s %-8s %-14s %-14s\n" "timestamp" "RSSI" "Noise" "ping_gateway" "ping_1.1.1.1"
  printf "%-21s %-8s %-8s %-14s %-14s\n" "---------" "----" "-----" "------------" "------------"
} >> "$REPORT"

get_rssi_noise() {
  # Returns "RSSI NOISE" without sudo, via system_profiler
  system_profiler SPAirPortDataType 2>/dev/null | awk '
    /Signal \/ Noise/ { s=$0; sub(/.*: /,"",s); print s; found=1; exit }
    END { if(!found) print "n/a n/a" }
  ' | sed 's/ dBm//g; s/\// /g' | awk '{print $1, $2}'
}

ELAPSED=0
while [ "$ELAPSED" -lt "$SAMPLE_SECONDS" ]; do
  TS="$(date +%H:%M:%S)"
  RN="$(get_rssi_noise)"; R="$(echo "$RN" | awk '{print $1}')"; N="$(echo "$RN" | awk '{print $2}')"
  if [ -n "$GW" ]; then
    PG="$(run_to 4 ping -c 1 -t 2 "$GW" 2>/dev/null | awk -F'time=' '/time=/{print $2; exit}')"
    [ -z "$PG" ] && PG="TIMEOUT"
  else PG="no-gw"; fi
  PI="$(run_to 4 ping -c 1 -t 2 1.1.1.1 2>/dev/null | awk -F'time=' '/time=/{print $2; exit}')"
  [ -z "$PI" ] && PI="TIMEOUT"
  printf "%-21s %-8s %-8s %-14s %-14s\n" "$TS" "${R:-n/a}" "${N:-n/a}" "$PG" "$PI" >> "$REPORT"
  sleep "$SAMPLE_INTERVAL"
  ELAPSED=$((ELAPSED + SAMPLE_INTERVAL))
done
echo "(RSSI: closer to 0 = better. -30..-60 excellent, -60..-70 ok, -70..-80 weak, <-80 very poor. Lower noise = better.)" >> "$REPORT"

# ----------------------------------------------------------------------------
# 9. Nearby networks / channel congestion + interface errors
# ----------------------------------------------------------------------------
step "9/14  Nearby networks (channel congestion) and error statistics"
cap "Visible Wi-Fi networks + channels (from system_profiler)" "scan.txt" sh -c "system_profiler SPAirPortDataType 2>/dev/null | sed -n '/Other Local Wi-Fi Networks/,\$p'"
cap "Interface statistics (errors/collisions)" "netstat_i.txt" netstat -in
cap "Protocol statistics (TCP retransmissions, etc.)" "netstat_s.txt" sh -c "netstat -s 2>/dev/null | grep -iE 'retrans|dropped|bad|error|reset' | head -40"

# ----------------------------------------------------------------------------
# 10. Wi-Fi system log (GOLD for intermittent problems: disconnects, roaming, auth)
# ----------------------------------------------------------------------------
step "10/14  Wi-Fi system log, last 30 min (disconnects, deauth, roaming, DHCP)"
sec "Relevant Wi-Fi events (airportd / com.apple.wifi, last 30 min)"
echo "\$ log show --last 30m --predicate 'process==\"airportd\" OR subsystem==\"com.apple.wifi\"'" >> "$REPORT"
run_to 45 log show --last 30m --style compact \
  --predicate 'process == "airportd" OR subsystem == "com.apple.wifi"' \
  > "$RAW/wifilog.txt" 2>&1 || echo "[log show timed out/failed]" >> "$REPORT"
# Keep only lines that point to problems, otherwise it is huge
grep -iE 'disassoc|deauth|disconnect|assoc(iat)?|roam|auth|scan|beacon loss|link|reason|fail|error|timeout|dhcp|no.?internet|power' \
  "$RAW/wifilog.txt" 2>/dev/null | tail -120 >> "$REPORT" \
  || echo "[no relevant Wi-Fi events in the last 30 min — a good sign if the problem was happening just now]" >> "$REPORT"
echo "(full log saved in raw/wifilog.txt)" >> "$REPORT"

sec "DHCP/network config events (configd, last 30 min)"
run_to 30 log show --last 30m --style compact \
  --predicate 'process == "configd" OR process == "mDNSResponder"' 2>/dev/null \
  | grep -iE 'dhcp|lease|renew|no address|conflict|resolv|dns' | tail -60 >> "$REPORT" \
  || echo "[no relevant DHCP/DNS events]" >> "$REPORT"

# ----------------------------------------------------------------------------
# 11. Path MTU and extended packet loss (link quality)
# ----------------------------------------------------------------------------
step "11/14  Path MTU and extended packet loss"
sec "MTU test (don't-fragment pings of various sizes to the gateway)"
if [ -n "$GW" ]; then
  for sz in 1472 1400 1200 800; do
    echo "\$ ping -D -s $sz -c 2 -t 3 $GW  (payload $sz -> packet $((sz+28)) bytes)" >> "$REPORT"
    if run_to 8 ping -D -s "$sz" -c 2 -t 3 "$GW" >> "$REPORT" 2>&1; then
      echo ">> $((sz+28)) bytes PASS" >> "$REPORT"
    else
      echo ">> $((sz+28)) bytes FAIL (lower MTU or fragmentation required)" >> "$REPORT"
    fi
    echo "" >> "$REPORT"
  done
else
  echo "[no gateway]" >> "$REPORT"
fi

sec "Extended packet loss (30 pings to the gateway + 30 to the internet)"
if [ -n "$GW" ]; then
  echo "-- Gateway $GW --" >> "$REPORT"
  run_to 45 ping -c 30 -i 0.3 -t 2 "$GW" 2>&1 | tail -4 >> "$REPORT" || echo "[gateway unreachable]" >> "$REPORT"
fi
echo "-- Internet 1.1.1.1 --" >> "$REPORT"
run_to 45 ping -c 30 -i 0.3 -t 2 1.1.1.1 2>&1 | tail -4 >> "$REPORT" || echo "[internet unreachable]" >> "$REPORT"

# ----------------------------------------------------------------------------
# 12. TCP/HTTP reachability + proxy + IPv6 (beyond ICMP)
# ----------------------------------------------------------------------------
step "12/14  TCP/HTTP tests (many networks block ping but not real traffic) + proxy + IPv6"
sec "TCP connection to common ports (nc) — 80/443 to IP and hostname"
for target in "1.1.1.1 443" "8.8.8.8 53" "captive.apple.com 80" "www.google.com 443"; do
  set -- $target; H="$1"; P="$2"
  echo "\$ nc -z -G 4 -w 4 $H $P" >> "$REPORT"
  if run_to 8 nc -z -G 4 -w 4 "$H" "$P" >/dev/null 2>&1; then
    echo ">> TCP $H:$P OK" >> "$REPORT"
  else
    echo ">> TCP $H:$P FAILED (port blocked, DNS down if hostname, or no uplink)" >> "$REPORT"
  fi
done

sec "Real HTTP(S) reachability (curl, response codes)"
for url in "https://www.google.com/generate_204" "https://www.apple.com" "https://1.1.1.1" "http://neverssl.com"; do
  echo "\$ curl -sS -m 8 -o /dev/null -w '%{http_code} time=%{time_total}s' $url" >> "$REPORT"
  RES="$(run_to 10 curl -sS -m 8 -o /dev/null -w '%{http_code} time=%{time_total}s (final=%{url_effective})' "$url" 2>&1)"
  echo ">> $url  ->  ${RES:-no response}" >> "$REPORT"
done

sec "PROXY configuration (an enforced proxy can break everything)"
run_to 8 scutil --proxy >> "$REPORT" 2>&1 || echo "[error reading proxy settings]" >> "$REPORT"

sec "IPv6 (config and reachability)"
cap_inline() { echo "\$ $*" >> "$REPORT"; run_to 10 "$@" >> "$REPORT" 2>&1 || echo "[error/timeout]" >> "$REPORT"; }
echo "-- IPv6 addresses on $IFACE --" >> "$REPORT"
ifconfig "$IFACE" 2>/dev/null | grep inet6 >> "$REPORT" || echo "[no IPv6]" >> "$REPORT"
echo "-- Ping6 gateway/internet IPv6 --" >> "$REPORT"
run_to 12 ping6 -c 3 2606:4700:4700::1111 >> "$REPORT" 2>&1 || echo "[IPv6 internet unreachable or disabled]" >> "$REPORT"

# ----------------------------------------------------------------------------
# 13. Extended configuration (known networks, kernel parameters, active connections)
# ----------------------------------------------------------------------------
step "13/14  Extended configuration (known networks, network parameters, active connections)"
cap "Known/preferred Wi-Fi networks" "known.txt" networksetup -listpreferredwirelessnetworks "$IFACE"
cap "Wi-Fi power state" "power.txt" networksetup -getairportpower "$IFACE"
cap "All network hardware ports" "hwports.txt" networksetup -listallhardwareports
cap "Network service order" "svcorder.txt" networksetup -listnetworkserviceorder
cap "Configured interface MTU" "mtu.txt" sh -c "ifconfig $IFACE | grep -i mtu"
cap "Kernel network parameters (sysctl)" "sysctl.txt" sh -c "sysctl net.inet.tcp.mssdflt net.inet.ip.maxfragpackets net.inet.tcp.delayed_ack net.link.ether.inet.max_age 2>&1"
cap "Active connections (netstat -an, first 60)" "conns.txt" sh -c "netstat -an 2>/dev/null | head -60"
cap "mDNS/Bonjour local reachability" "mdns.txt" sh -c "dns-sd -t 2 -B _services._dns-sd._udp local. 2>&1 &  P=\$!; sleep 3; kill \$P 2>/dev/null; true"
if [ $HAVE_SUDO -eq 1 ]; then
  cap "Active pf firewall rules (status)" "pf.txt" sh -c "pfctl -s info 2>&1 | head -20"
fi

# ----------------------------------------------------------------------------
# 14. Speed / throughput (best effort: the internet part needs connectivity)
# ----------------------------------------------------------------------------
step "14/14  Speed: negotiated Wi-Fi link + internet throughput (if available)"
sec "Wi-Fi LINK speed (negotiated rate vs theoretical maximum)"
# Extract fields of the CURRENT network (always available without sudo)
LINKRATE="$(sp_field 'Transmit Rate')"
PHYMODE="$(sp_field 'PHY Mode')"
CHANNEL="$(sp_field 'Channel')"
{
  echo "Transmit Rate (negotiated link): ${LINKRATE:-n/a} Mbps"
  echo "PHY Mode:                       ${PHYMODE:-n/a}   (ax=Wi-Fi 6, ac=Wi-Fi 5, n=Wi-Fi 4)"
  echo "Channel:                        ${CHANNEL:-n/a}"
  echo ""
  echo "NOTE: 'Transmit Rate' is the Mac<->router radio speed, not the internet speed."
  echo "If it is low (<200 on 5GHz) with good RSSI -> interference/reduced channel width."
} >> "$REPORT"

sec "INTERNET throughput (real download/upload) — needs a working connection"
# Check for internet first, otherwise skip (pointless, and it would stall the script)
if run_to 6 curl -sS -m 5 -o /dev/null https://speed.cloudflare.com/__down?bytes=1000 2>/dev/null; then
  echo "[internet connection present: running Cloudflare speed test]" >> "$REPORT"
  # DOWNLOAD: 25 MB
  echo "-- DOWNLOAD (25 MB from Cloudflare) --" >> "$REPORT"
  DL="$(run_to 40 curl -sS -m 35 -o /dev/null -w '%{speed_download}' "https://speed.cloudflare.com/__down?bytes=25000000" 2>/dev/null)"
  if [ -n "$DL" ] && [ "$DL" != "0" ]; then
    DLM="$(awk -v b="$DL" 'BEGIN{printf "%.1f", b*8/1000000}')"
    echo "Download: ${DLM} Mbps  (${DL} byte/s)" >> "$REPORT"
  else
    echo "Download: failed/timed out" >> "$REPORT"
  fi
  # UPLOAD: 10 MB
  echo "-- UPLOAD (10 MB to Cloudflare) --" >> "$REPORT"
  UL="$(run_to 40 sh -c "head -c 10000000 /dev/zero | curl -sS -m 35 -o /dev/null -w '%{speed_upload}' --data-binary @- https://speed.cloudflare.com/__up 2>/dev/null")"
  if [ -n "$UL" ] && [ "$UL" != "0" ]; then
    ULM="$(awk -v b="$UL" 'BEGIN{printf "%.1f", b*8/1000000}')"
    echo "Upload: ${ULM} Mbps  (${UL} byte/s)" >> "$REPORT"
  else
    echo "Upload: failed/timed out" >> "$REPORT"
  fi
  # LATENCY (bufferbloat, simplified): idle ping
  echo "-- Idle latency to the internet (for bufferbloat comparison) --" >> "$REPORT"
  run_to 12 ping -c 8 -t 2 1.1.1.1 2>&1 | tail -2 >> "$REPORT"
else
  echo "[NO internet connection: speed test skipped.]" >> "$REPORT"
  echo "Re-run on a working network to measure real download/upload." >> "$REPORT"
fi

# ----------------------------------------------------------------------------
# Automatic summary
# ----------------------------------------------------------------------------
sec "AUTOMATIC SUMMARY (quick verdict)"
IP_LOCAL="$(ipconfig getifaddr "$IFACE" 2>/dev/null)"
{
  echo "SSID:            $(current_ssid)"
  echo "Local IP:        ${IP_LOCAL:-NONE (DHCP problem!)}"
  echo "Gateway:         ${GW:-NONE}"
  # Gateway reachable?
  if [ -n "$GW" ] && run_to 6 ping -c 2 -t 2 "$GW" >/dev/null 2>&1; then
    echo "Gateway ping:    OK (the LAN/router answers)"
    GWOK=1
  else
    echo "Gateway ping:    FAILED (problem between Mac and router: radio/DHCP/router)"
    GWOK=0
  fi
  # Internet reachable by IP?
  if run_to 6 ping -c 2 -t 2 1.1.1.1 >/dev/null 2>&1; then
    echo "Internet (IP):   OK (there is an internet uplink)"
    NETOK=1
  else
    echo "Internet (IP):   FAILED (no internet uplink beyond the router)"
    NETOK=0
  fi
  # DNS? Test several domains (do NOT use apple.com as the only canary: some networks
  # filter exactly the Apple domains used for captive-portal detection).
  DNS_OK_COUNT=0; DNS_TOT=0
  for d in google.com cloudflare.com apple.com; do
    DNS_TOT=$((DNS_TOT+1))
    [ -n "$(run_to 6 dig +short +time=3 +tries=1 "$d" 2>/dev/null)" ] && DNS_OK_COUNT=$((DNS_OK_COUNT+1))
  done
  if [ "$DNS_OK_COUNT" -eq "$DNS_TOT" ]; then
    echo "DNS:             OK ($DNS_OK_COUNT/$DNS_TOT domains resolved)"
    DNSOK=1
  elif [ "$DNS_OK_COUNT" -gt 0 ]; then
    echo "DNS:             PARTIAL ($DNS_OK_COUNT/$DNS_TOT — some domains blocked/filtered)"
    DNSOK=1
  else
    echo "DNS:             FAILED (no domain resolves)"
    DNSOK=0
  fi
  # Captive portal / walled garden? Is HTTP port 80 hijacked with a redirect?
  CAP302=0
  HCODE="$(run_to 10 curl -sS -m 8 -o /dev/null -w '%{http_code}' http://neverssl.com 2>/dev/null)"
  case "$HCODE" in 30[0-9]) CAP302=1 ;; esac
  echo "HTTP 80 (neverssl): ${HCODE:-no response}$([ $CAP302 -eq 1 ] && echo '  <- REDIRECT: likely captive portal/login')"

  echo ""
  echo "LIKELY DIAGNOSIS:"
  if [ -z "$IP_LOCAL" ]; then
    echo "  -> The Mac did not get an IP. DHCP/association problem (password? MAC filter? DHCP pool full?)."
  elif [ "${GWOK:-0}" = "0" ]; then
    echo "  -> Even the router is unreachable. Poor radio signal, congested channel, or a faulty router."
  elif [ "$CAP302" = "1" ] || { [ "${NETOK:-0}" = "0" ] && [ "${DNSOK:-0}" = "1" ]; }; then
    echo "  -> CAPTIVE PORTAL / FILTERED NETWORK: you are associated and DNS resolves, but the uplink is walled"
    echo "     off and HTTP is being hijacked. macOS may not show the login if the network blocks Apple's"
    echo "     detection domains. FIX: open http://neverssl.com in the browser (HTTP, not HTTPS)"
    echo "     to make the login/acceptance page appear."
  elif [ "${NETOK:-0}" = "0" ]; then
    echo "  -> You reach the router but NOT the internet. Upstream problem: modem/ISP, WAN, or router firewall."
  elif [ "${DNSOK:-0}" = "0" ]; then
    echo "  -> Internet works (IP ping ok) but DNS does not resolve. DNS problem: change DNS (1.1.1.1 / 8.8.8.8)."
  else
    echo "  -> All basic tests pass right now. If the problem is intermittent, check the time series (section 8) for drops/RSSI."
  fi

  # --- Automatic speed/signal optimisation tips ---
  echo ""
  echo "TIPS TO IMPROVE SPEED/SIGNAL:"
  RSSI_NOW="$(sp_field 'Signal / Noise' | awk '{print $1}')"
  CH_NOW="$(sp_field 'Channel')"
  RATE_NOW="$(sp_field 'Transmit Rate')"
  PHY_NOW="$(sp_field 'PHY Mode')"
  # RSSI (negative number)
  if [ -n "$RSSI_NOW" ]; then
    RVAL="${RSSI_NOW%% *}"
    case "$RVAL" in
      -[0-9]*)
        if [ "$RVAL" -le -75 ] 2>/dev/null; then
          echo "  - WEAK SIGNAL ($RSSI_NOW dBm): move closer to the router or use an extender/mesh. Below -75 speed collapses."
        elif [ "$RVAL" -le -67 ] 2>/dev/null; then
          echo "  - Medium signal ($RSSI_NOW dBm): fine for browsing, limiting for 4K streaming/large downloads."
        else
          echo "  - Good signal ($RSSI_NOW dBm): the radio is not the bottleneck."
        fi ;;
    esac
  fi
  # Band / channel
  case "$CH_NOW" in
    *2GHz*|*", 1"|*", 6"|*", 11"|*"(2"*)
      echo "  - You are on the 2.4 GHz band (channel $CH_NOW): slow and crowded. Switch to 5 GHz (or 6 GHz if supported) for more speed." ;;
    *5GHz*|*6GHz*)
      echo "  - You are on 5/6 GHz (channel $CH_NOW): the right band for speed." ;;
  esac
  # PHY mode
  case "$PHY_NOW" in
    *ax*|*be*) : ;;  # Wi-Fi 6/6E/7 ok
    *ac*) echo "  - PHY $PHY_NOW (Wi-Fi 5): ok, but a Wi-Fi 6 router would give more throughput and lower latency in crowded areas." ;;
    *n*|*g*|*a*) echo "  - PHY $PHY_NOW (old standard): outdated router, it is the main speed limit." ;;
  esac
  echo "  - Congestion: check the 'Visible Wi-Fi networks' section — if many networks share your channel, change the channel on the router."
  echo "  - Slow DNS? Set 1.1.1.1 / 8.8.8.8 in System Settings > Network > DNS to open sites faster."
  echo "  - Current negotiated link rate: ${RATE_NOW:-n/a} Mbps. If very low with good signal -> interference or a 20 MHz channel (widen to 80/160 MHz on the router in 5 GHz)."
} >> "$REPORT"

# ----------------------------------------------------------------------------
# Final bundle
# ----------------------------------------------------------------------------
TARBALL="$BASE/wifi-report-$STAMP.tgz"
run_to 20 tar -czf "$TARBALL" -C "$BASE" "RESULTS-$STAMP" 2>/dev/null

echo ""
ok "Collection complete."
echo ""
printf "${C_G}==> FILES TO READ OR SHARE:${C_0}\n"
printf "    Report file:  %s\n" "$REPORT"
printf "    Archive:      %s\n" "$TARBALL"
echo ""
printf "Next steps:\n"
printf "  1) Reconnect to a network that works.\n"
printf "  2) Read %s\n" "$REPORT"
printf "     (it contains SSID, IPs, MAC addresses and known networks: review before sharing).\n"
echo ""
