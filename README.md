# wifi-doctor

Two Bash scripts for diagnosing a broken Wi-Fi network on macOS while you are stuck on
it and cannot look anything up. `wifi-diag.sh` runs a layered set of tests, writes
everything to one text report and ends with a verdict; you read the report later from
a working network. `wifi-monitor.sh` logs a CSV row every few seconds for problems
that come and go. Only tools shipped with macOS, and every probe has a timeout so a
dead network never hangs the script.

## Usage

```sh
# 1. connect to the problematic network, then
sudo bash wifi-diag.sh

# 2. reconnect to a working network and read the report
less RESULTS-<timestamp>/REPORT.txt
```

`sudo` is optional; without it `wdutil info` and the `pf` status are skipped and the
report says so. Results go next to the script (or into `$WIFI_DOCTOR_DIR`):
`RESULTS-<timestamp>/REPORT.txt`, the raw output of each command in
`RESULTS-<timestamp>/raw/`, and both compressed in `wifi-report-<timestamp>.tgz`.
Options: `WIFI_IFACE=en1` (default `en0`), `SAMPLE_SECONDS=90`, `SAMPLE_INTERVAL=2`.

For intermittent problems:

```sh
bash wifi-monitor.sh                                  # every 5 s until Ctrl-C
INTERVAL=10 DURATION=1800 bash wifi-monitor.sh        # every 10 s for 30 min
```

This writes `monitor-<timestamp>.csv` with columns
`timestamp, ssid, rssi_dBm, noise_dBm, gateway_ms, internet_ms, dns_ok`.

## How the verdict is computed

`wifi-diag.sh` runs 14 stages from the bottom of the stack up, from interface, DHCP
and radio (RSSI, noise, channel, PHY) through DNS, routing, a captive-portal probe,
traceroute, a time series of signal and RTT, 30 minutes of airportd and configd logs,
path MTU, TCP and HTTP(S) checks, to link rate and a Cloudflare speed test if online.
The summary then re-runs four cheap probes and reduces them to booleans:

| Symbol | Probe | True when |
|---|---|---|
| $I$ | `ipconfig getifaddr $IFACE` | the interface has an IPv4 address |
| $G$ | `ping -c 2` default gateway | the router answers |
| $N$ | `ping -c 2 1.1.1.1` | there is an IP path to the internet |
| $D$ | `dig +short` google.com, cloudflare.com, apple.com | at least one of the three resolves |
| $C$ | `curl http://neverssl.com` | the HTTP status is 3xx (plain HTTP is being redirected) |

The first matching rule wins:

1. not $I$: DHCP or association problem
2. not $G$: radio, channel or router problem
3. $C \lor (\lnot N \land D)$: captive portal or filtered network, open http://neverssl.com
4. not $N$: upstream (modem, ISP, WAN, router firewall)
5. not $D$: DNS problem
6. otherwise all basic tests pass now, so look at the time series

A walled garden usually lets DNS through (the portal hostname has to resolve) and
drops everything else, so "names resolve but no IP is reachable" is read as a portal.
DNS uses three domains because some networks filter exactly the Apple domains macOS
uses for portal detection, which is also why the login sheet sometimes never appears.

The tips call RSSI $r$ weak for $r \le -75$ dBm, medium for $-75 < r \le -67$ and good
above; noise $n$ is recorded alongside, so $\text{SNR} = r - n$. The MTU test sends
don't-fragment pings with payloads of 1472, 1400, 1200 and 800 bytes, i.e. IP packets
of $s + 28$ bytes (1500 down to 828). Throughput is curl's `speed_download` /
`speed_upload` converted as $\text{Mbps} = 8\,B / 10^6$, for a 25 MB download and a
10 MB upload against `speed.cloudflare.com`.

macOS has no `timeout(1)`, so each probe runs in the background next to a subshell
that sleeps $t$ seconds and `kill -9`s it; whichever finishes first wins.

## Limitations

- macOS only. On recent versions `networksetup -getairportnetwork` often reports
  "not associated", hence the SSID fallbacks; without Location Services permission the
  SSID may be unreadable.
- $N$ uses ICMP. A network that blocks ping but passes TCP is classified as a captive
  portal or upstream failure; the stage 12 TCP and HTTP results catch that case in the
  report but do not feed the verdict.
- The time series loop counts only the sleep interval, so it runs longer than
  `SAMPLE_SECONDS`.
- `wifi-monitor.sh` checks DNS with `apple.com` only.
- The heuristics are rules of thumb, not a packet capture.
- The report is personal (SSID, known networks, hostname, IPs, MAC addresses, open
  sockets, 30 minutes of Wi-Fi logs). Read it before sharing it. `.gitignore` excludes
  `RESULTS-*/`, `wifi-report-*.tgz` and `monitor-*.csv`.

## License

MIT, see [LICENSE](LICENSE).
