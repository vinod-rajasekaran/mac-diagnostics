#!/bin/bash
#
# mac-triage-diagnose.sh   READ-ONLY. Changes nothing.
#
# Fleet diagnostic tuned to the actual failure mode on an 8GB Apple Silicon
# Air: memory pressure forcing swap onto a disk with no room for it.
#
#   ./mac-triage-diagnose.sh                 human-readable report
#   ./mac-triage-diagnose.sh --quick         5s sampling window instead of 20s
#   ./mac-triage-diagnose.sh --csv           one CSV row for the audit sheet
#   ./mac-triage-diagnose.sh --csv --header  row preceded by the header
#   ./mac-triage-diagnose.sh --out fleet.csv append a row, writing the header if new
#
# Run it during real work, not on a freshly booted idle machine.
# smartctl (brew install smartmontools) adds SSD wear. Everything else is stock.

# No 'set -u'. macOS ships bash 3.2, where expanding an empty array under -u
# aborts the script. Every variable below carries its own default instead.
set -o pipefail

CSV_MODE=0
WANT_HEADER=0
SAMPLE_SECONDS=20
OUT_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --csv) CSV_MODE=1 ;;
    --header) WANT_HEADER=1 ;;
    --quick) SAMPLE_SECONDS=5 ;;
    --out) OUT_FILE="${2:-}"; CSV_MODE=1; shift ;;
    --out=*) OUT_FILE="${1#--out=}"; CSV_MODE=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -t 1 ] && [ "$CSV_MODE" -eq 0 ] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold); RED=$(tput setaf 1); YEL=$(tput setaf 3); GRN=$(tput setaf 2); RST=$(tput sgr0)
else
  BOLD=""; RED=""; YEL=""; GRN=""; RST=""
fi

FLAGS=()
FLAG_COUNT=0
csv_safe() { printf '%s' "${1:-}" | tr -d '"\r\n' | tr ',' '-' | tr -s ' ' | sed 's/^ *//; s/ *$//'; }
say()  { [ "$CSV_MODE" -eq 0 ] && echo "$1"; return 0; }
sect() { [ "$CSV_MODE" -eq 0 ] && { echo ""; echo "${BOLD}== $1 ==${RST}"; }; return 0; }
flag() { FLAGS[$FLAG_COUNT]="$1"; FLAG_COUNT=$(( FLAG_COUNT + 1 )); [ "$CSV_MODE" -eq 0 ] && echo "${RED}[FLAG]${RST} $1"; return 0; }
warn() { [ "$CSV_MODE" -eq 0 ] && echo "${YEL}[WATCH]${RST} $1"; return 0; }
ok()   { [ "$CSV_MODE" -eq 0 ] && echo "${GRN}[OK]${RST} $1"; return 0; }

# ---------------------------------------------------------------- identity

HOSTNAME_S=$(scutil --get ComputerName 2>/dev/null || hostname)
USER_S=$(id -un)
MODEL=$(sysctl -n hw.model 2>/dev/null)
CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
OS_VER=$(sw_vers -productVersion 2>/dev/null)
RAM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
TODAY=$(date +%Y-%m-%d)

# Hardware age. Two independent signals, because neither is complete on its own.
#
#   model_year   how old the hardware design is. Drives vintage/obsolete
#                planning. Needs a lookup table, because Apple Silicon serial
#                numbers are randomised and carry no manufacture date.
#   in_service   when this machine was first set up, read from the birth time
#                of /var/db/.AppleSetupDone. A measured fact rather than a
#                table, but it resets if the machine is ever wiped and rebuilt.
#
# Unknown model identifiers return empty and fall back to in_service. Add new
# identifiers here as they ship; an empty year is honest, a guessed one is not.
model_year() {
  case "$1" in
    # MacBook Air, Apple Silicon
    MacBookAir10,1)                          echo 2020 ;;
    Mac14,2)                                 echo 2022 ;;
    Mac14,15)                                echo 2023 ;;
    Mac15,12|Mac15,13)                       echo 2024 ;;
    Mac16,12|Mac16,13)                       echo 2025 ;;
    # MacBook Pro, Apple Silicon
    MacBookPro17,1)                          echo 2020 ;;
    MacBookPro18,1|MacBookPro18,2|MacBookPro18,3|MacBookPro18,4) echo 2021 ;;
    Mac14,7)                                 echo 2022 ;;
    Mac14,5|Mac14,6|Mac14,9|Mac14,10)        echo 2023 ;;
    Mac15,3|Mac15,6|Mac15,7|Mac15,8|Mac15,9|Mac15,10|Mac15,11) echo 2023 ;;
    Mac16,1|Mac16,5|Mac16,6|Mac16,7|Mac16,8) echo 2024 ;;
    # Mac mini / Studio / Pro / iMac, Apple Silicon
    Macmini9,1)                              echo 2020 ;;
    Mac14,3|Mac14,12)                        echo 2023 ;;
    Mac16,10|Mac16,11)                       echo 2024 ;;
    Mac13,1|Mac13,2)                         echo 2022 ;;
    Mac14,13|Mac14,14)                       echo 2023 ;;
    Mac15,14|Mac16,9)                        echo 2025 ;;
    Mac14,8)                                 echo 2023 ;;
    iMac21,1|iMac21,2)                       echo 2021 ;;
    Mac15,4|Mac15,5)                         echo 2023 ;;
    Mac16,2|Mac16,3)                         echo 2024 ;;
    # Intel, still common in fleets
    MacBookAir7,1|MacBookAir7,2)             echo 2015 ;;
    MacBookAir8,1)                           echo 2018 ;;
    MacBookAir8,2)                           echo 2019 ;;
    MacBookAir9,1)                           echo 2020 ;;
    MacBook9,1)                              echo 2016 ;;
    MacBook10,1)                             echo 2017 ;;
    MacBookPro12,1)                          echo 2015 ;;
    MacBookPro13,1|MacBookPro13,2|MacBookPro13,3) echo 2016 ;;
    MacBookPro14,1|MacBookPro14,2|MacBookPro14,3) echo 2017 ;;
    MacBookPro15,1|MacBookPro15,2|MacBookPro15,3) echo 2018 ;;
    MacBookPro15,4)                          echo 2019 ;;
    MacBookPro16,1|MacBookPro16,4)           echo 2019 ;;
    MacBookPro16,2|MacBookPro16,3)           echo 2020 ;;
    Macmini7,1)                              echo 2014 ;;
    Macmini8,1)                              echo 2018 ;;
    iMac17,1)                                echo 2015 ;;
    iMac18,1|iMac18,2|iMac18,3)              echo 2017 ;;
    iMac19,1|iMac19,2)                       echo 2019 ;;
    iMac20,1|iMac20,2)                       echo 2020 ;;
    iMacPro1,1)                              echo 2017 ;;
    MacPro7,1)                               echo 2019 ;;
    *)                                       echo "" ;;
  esac
}

CUR_YEAR=$(date +%Y)
MODEL_YEAR=$(model_year "${MODEL:-}")
IN_SERVICE=$(stat -f '%SB' -t '%Y-%m-%d' /var/db/.AppleSetupDone 2>/dev/null)
case "${IN_SERVICE:-}" in [0-9][0-9][0-9][0-9]-*) ;; *) IN_SERVICE="" ;; esac

AGE_YEARS=""
AGE_BASIS=""
if [ -n "${MODEL_YEAR:-}" ]; then
  AGE_YEARS=$(( CUR_YEAR - MODEL_YEAR ))
  AGE_BASIS="model year"
elif [ -n "${IN_SERVICE:-}" ]; then
  AGE_YEARS=$(( CUR_YEAR - ${IN_SERVICE%%-*} ))
  AGE_BASIS="first set up"
fi
case "${AGE_YEARS:-}" in ''|*[!0-9]*) AGE_YEARS="" ;; esac

# kern.boottime prints "{ sec = 1756186847, usec = 048592 } Tue Aug 26 ...".
# A leading .* in the pattern matches the "sec" inside "usec", and those
# zero-padded microseconds are then read as an octal literal, which fails.
# Anchor on the opening brace and force base 10.
uptime_seconds() {
  local raw sec
  raw=$(sysctl -n kern.boottime 2>/dev/null)
  sec=$(printf '%s' "$raw" | sed -E 's/^\{[[:space:]]*sec[[:space:]]*=[[:space:]]*([0-9]+).*/\1/')
  case "$sec" in
    ''|*[!0-9]*) sec="" ;;
  esac
  sec=$(printf '%s' "$sec" | sed 's/^0*//')
  if [ -n "$sec" ]; then
    echo $(( $(date +%s) - sec ))
    return
  fi
  # Fallback: parse the uptime line. Handles "up 27 days,", "up 4:12", "up 36 mins".
  uptime | awk '
    { line = $0 }
    /day/  { match(line, /[0-9]+ day/);  d = substr(line, RSTART, RLENGTH) + 0 }
    /min/  { match(line, /[0-9]+ min/);  m = substr(line, RSTART, RLENGTH) + 0 }
    /[0-9]+:[0-9][0-9]/ { match(line, /[0-9]+:[0-9][0-9]/); split(substr(line, RSTART, RLENGTH), t, ":"); h = t[1]+0; mm = t[2]+0 }
    END { print d*86400 + h*3600 + (mm+m)*60 }'
}

UP_SECS=$(uptime_seconds)
case "$UP_SECS" in ''|*[!0-9]*) UP_SECS=0 ;; esac
UP_DAYS=$(( UP_SECS / 86400 ))
UP_HOURS=$(( (UP_SECS % 86400) / 3600 ))

sect "Machine"
say "Name:    $HOSTNAME_S ($USER_S)"
say "Model:   ${MODEL:-unknown}  ${CHIP:-}"
say "macOS:   ${OS_VER:-unknown}     RAM: ${RAM_GB} GB"
if [ -n "${MODEL_YEAR:-}" ] || [ -n "${IN_SERVICE:-}" ]; then
  say "Age:     ${MODEL_YEAR:-year unknown}${AGE_YEARS:+ model, ${AGE_YEARS} years old}${IN_SERVICE:+, in service since ${IN_SERVICE}}"
else
  say "Age:     not determined (model ${MODEL:-unknown} is not in the year table)"
fi
if [ "$UP_SECS" -eq 0 ]; then
  say "Uptime:  could not be read"
else
  say "Uptime:  ${UP_DAYS} days ${UP_HOURS} hours (last restart $(date -r $(( $(date +%s) - UP_SECS )) '+%a %d %b %H:%M' 2>/dev/null))"
fi
[ "${UP_DAYS:-0}" -ge 14 ] && flag "Not restarted in ${UP_DAYS} days. Swap and leaked memory never come back on their own."
if [ -n "${AGE_YEARS:-}" ]; then
  # Apple treats a product as vintage at 5 years and obsolete at 7. Past 7 the
  # question stops being "what is wrong with it" and becomes "when do we
  # replace it", and cleanup buys progressively less time.
  [ "$AGE_YEARS" -ge 7 ] && flag "${AGE_YEARS} years old (by ${AGE_BASIS}). Past Apple's obsolete threshold; budget a replacement rather than tuning this one."
  [ "$AGE_YEARS" -ge 5 ] && [ "$AGE_YEARS" -lt 7 ] && warn "${AGE_YEARS} years old (by ${AGE_BASIS}). Vintage territory; plan for it in the next refresh cycle."
fi

# ------------------------------------------------------------------ memory
# On Apple Silicon the useful signals are the kernel's own pressure level and
# whether pages are moving in and out of swap right now, not raw "free" RAM.

sect "Memory"

PRESSURE_RAW=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo "")
case "${PRESSURE_RAW:-}" in
  1) PRESSURE="normal" ;;
  2) PRESSURE="warning" ;;
  4) PRESSURE="critical" ;;
  *) PRESSURE="unknown" ;;
esac

FREE_PCT=$(memory_pressure 2>/dev/null | awk -F': *' '/free percentage/ {gsub("%","",$2); print $2; exit}')
FREE_PCT=${FREE_PCT:-}

# swapusage is formatted with a unit suffix that is not always M. Read both.
SWAP_GB=$(sysctl -n vm.swapusage 2>/dev/null | awk '
  { for (i=1;i<=NF;i++) if ($i=="used") {
      v=$(i+2); u=substr(v,length(v)); sub(/[A-Za-z]$/,"",v);
      if (u=="G") printf "%.2f", v; else if (u=="M") printf "%.2f", v/1024;
      else if (u=="K") printf "%.2f", v/1048576; else printf "%.2f", v/1073741824; exit } }')
SWAP_GB=${SWAP_GB:-0.00}

SWAPIN_1=$(vm_stat | awk '/Swapins/ {gsub("\\.","",$2); print $2}')
sleep "$SAMPLE_SECONDS"
SWAPIN_2=$(vm_stat | awk '/Swapins/ {gsub("\\.","",$2); print $2}')
SWAPIN_RATE=$(( ( ${SWAPIN_2:-0} - ${SWAPIN_1:-0} ) / SAMPLE_SECONDS ))

say "Pressure level:   $PRESSURE"
say "Free memory:      ${FREE_PCT:-?}%"
say "Swap in use:      ${SWAP_GB} GB"
say "Swap-ins/sec:     ${SWAPIN_RATE} (over ${SAMPLE_SECONDS}s)"

[ "$PRESSURE" = "critical" ] && flag "Memory pressure is critical. The machine is out of RAM right now."
[ "$PRESSURE" = "warning" ] && warn "Memory pressure is at warning. Close to the edge under this workload."
awk -v s="$SWAP_GB" 'BEGIN{exit !(s>6)}' && flag "Swap is ${SWAP_GB} GB. Sustained paging at this level is the slowness people are reporting."
awk -v s="$SWAP_GB" 'BEGIN{exit !(s>2 && s<=6)}' && warn "Swap is ${SWAP_GB} GB. Workload does not fit comfortably in ${RAM_GB} GB."
[ "$SWAPIN_RATE" -gt 50 ] && flag "Pages are being read back from swap at ${SWAPIN_RATE}/sec. This is active thrashing, not just allocated swap."

say ""
say "Top 8 by memory:"
[ "$CSV_MODE" -eq 0 ] && ps -Ao pmem,rss,comm -m | head -n 9 | awk 'NR==1{print "  %MEM   RSS(KB)  PROCESS"; next} {printf "  %-6s %-9s %s\n", $1, $2, substr($0, index($0,$3))}'

# ---------------------------------------------------------- app pile-up

sect "Apps in the pile"

running_app() { pgrep -qf "$1" 2>/dev/null && echo 1 || echo 0; }
CHROME=$(running_app "Google Chrome")
ATLAS=$(running_app "ChatGPT")
SAFARI=$(running_app "Safari")
GRANOLA=$(running_app "Granola")
CLAUDE_APP=$(running_app "Claude.app")
CLAUDE_CODE=$(running_app "claude-code\|claude$")
WHATSAPP=$(running_app "WhatsApp")

for pair in "Chrome:$CHROME" "ChatGPT/Atlas:$ATLAS" "Safari:$SAFARI" "WhatsApp:$WHATSAPP" "Granola:$GRANOLA" "Claude app:$CLAUDE_APP" "Claude Code:$CLAUDE_CODE"; do
  n=${pair%%:*}; v=${pair##*:}
  [ "$v" = "1" ] && say "  running: $n"
done

BROWSERS=$(( CHROME + ATLAS + SAFARI ))
[ "$BROWSERS" -ge 2 ] && flag "$BROWSERS browser engines are resident at once. On ${RAM_GB} GB this alone can account for the slowness."
[ "$CLAUDE_APP" = "1" ] && [ "$CLAUDE_CODE" = "1" ] && warn "Claude desktop app and Claude Code are both resident."

CHROME_PROCS=$(pgrep -fc "Google Chrome" 2>/dev/null | head -1)
case "${CHROME_PROCS:-}" in ''|*[!0-9]*) CHROME_PROCS=0 ;; esac
[ "$CHROME_PROCS" -gt 40 ] && warn "$CHROME_PROCS Chrome processes. Tab count is out of hand; turn on Memory Saver."

# Rosetta builds use more memory than native ones.
ROSETTA_APPS=""
for app in "Google Chrome" "WhatsApp" "Slack" "zoom.us" "Granola" "Claude"; do
  P="/Applications/${app}.app/Contents/MacOS/${app}"
  [ -f "$P" ] || continue
  if command -v lipo >/dev/null 2>&1 && ! lipo -archs "$P" 2>/dev/null | grep -q arm64; then
    ROSETTA_APPS="${ROSETTA_APPS}${app} "
  fi
done
if [ -n "$ROSETTA_APPS" ]; then
  flag "Intel-only builds running under Rosetta: ${ROSETTA_APPS}. Reinstall the Apple Silicon versions."
else
  ok "Installed apps checked are native Apple Silicon builds."
fi

# -------------------------------------------------------------------- disk
# / is the read-only system volume. Everything that fills up lives on Data.

sect "Disk"

DATA_VOL="/System/Volumes/Data"
read -r D_TOTAL D_USED D_AVAIL D_PCT < <(df -k "$DATA_VOL" | tail -1 | awk '{print $2, $3, $4, $5}')
D_PCT=${D_PCT%\%}
FREE_GB=$(awk -v a="${D_AVAIL:-0}" 'BEGIN{printf "%.1f", a/1048576}')
TOTAL_GB=$(awk -v t="${D_TOTAL:-0}" 'BEGIN{printf "%.0f", t/1048576}')
FREE_SPACE_PCT=$(( 100 - ${D_PCT:-0} ))

say "Data volume: ${TOTAL_GB} GB total, ${FREE_GB} GB free (${FREE_SPACE_PCT}% free)"

if [ "$FREE_SPACE_PCT" -lt 15 ]; then
  flag "Only ${FREE_SPACE_PCT}% free. Below this macOS cannot grow swap cleanly and everything degrades at once."
elif [ "$FREE_SPACE_PCT" -lt 25 ]; then
  warn "${FREE_SPACE_PCT}% free. Target is 25% before judging this machine."
else
  ok "Free space is above the 25% floor."
fi

# A 256 GB volume that is short of space after a cleanup is not a housekeeping
# problem. Storage is not upgradeable on Apple Silicon, so this belongs in the
# refresh plan rather than in a list of things the user should delete.
if [ "${TOTAL_GB:-0}" -le 256 ] && [ "$FREE_SPACE_PCT" -lt 25 ]; then
  warn "${TOTAL_GB} GB volume with ${FREE_SPACE_PCT}% free. If this persists after cleanup, the disk is undersized for this role, not untidy."
fi

# grep -c prints 0 AND exits 1 when it matches nothing, so a trailing '|| echo 0'
# appends a second line and the value becomes "0\n0". Normalise to digits instead.
SNAPS=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' | head -1 | tr -cd '0-9')
[ -z "$SNAPS" ] && SNAPS=0
say "Local Time Machine snapshots: ${SNAPS}"
[ "${SNAPS:-0}" -ge 3 ] && warn "${SNAPS} local snapshots are holding disk space that Finder reports as purgeable."

PURGEABLE=$(diskutil info "$DATA_VOL" 2>/dev/null | awk -F': *' '/Volume Free Space|Container Free Space/ {print $2; exit}')
[ -n "${PURGEABLE:-}" ] && say "Container free space: ${PURGEABLE}"

SSD_PCT=""
SSD_TBW=""
if command -v smartctl >/dev/null 2>&1; then
  # Apple's NVMe controller exposes wear only through the SMART log, and reading
  # it needs root. sudo -n succeeds only if a credential is already cached, so
  # try that first and fall back to an interactive prompt when there is a tty.
  SMART_OUT=$(sudo -n smartctl -a /dev/disk0 2>/dev/null)
  if [ -z "$SMART_OUT" ] && [ -t 0 ] && [ "$CSV_MODE" -eq 0 ]; then
    say "SSD wear needs root. Enter your password, or press ctrl-c to skip."
    SMART_OUT=$(sudo smartctl -a /dev/disk0 2>/dev/null)
  fi
  if [ -n "$SMART_OUT" ]; then
    SSD_PCT=$(printf '%s' "$SMART_OUT" | awk -F': *' '/Percentage Used/ {gsub("%","",$2); print $2+0; exit}')
    SSD_TBW=$(printf '%s' "$SMART_OUT" | awk -F': *' '/Data Units Written/ {print $2; exit}')
  fi
fi

if [ -n "$SSD_PCT" ]; then
  say "SSD life used: ${SSD_PCT}%${SSD_TBW:+  (written: $SSD_TBW)}"
  [ "$SSD_PCT" -ge 40 ] && flag "SSD is ${SSD_PCT}% through its write endurance. Years of swap have already been written to it."
  [ "$SSD_PCT" -ge 20 ] && [ "$SSD_PCT" -lt 40 ] && warn "SSD is ${SSD_PCT}% used. Worth watching."
elif command -v smartctl >/dev/null 2>&1; then
  warn "SSD wear not read. Run: sudo smartctl -a /dev/disk0 | grep 'Percentage Used'"
else
  warn "SSD wear not measured. Install it once: brew install smartmontools, then re-run."
fi

# ------------------------------------------------- background and startup

sect "Background load"

count_dir() { [ -d "$1" ] && ls -1 "$1" 2>/dev/null | wc -l | tr -d ' ' || echo 0; }
UA=$(count_dir "$HOME/Library/LaunchAgents")
SA=$(count_dir "/Library/LaunchAgents")
SD=$(count_dir "/Library/LaunchDaemons")
THIRD_PARTY=$(( UA + SA + SD ))

say "Launch agents/daemons outside macOS itself: ${THIRD_PARTY} (user ${UA}, system ${SA}, daemons ${SD})"
[ "$THIRD_PARTY" -ge 15 ] && flag "${THIRD_PARTY} third-party background items load at boot. Most belong to software nobody uses any more."
[ "$CSV_MODE" -eq 0 ] && for d in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
  [ -d "$d" ] && ls -1 "$d" 2>/dev/null | sed "s|^|  $d/|"
done

AI_ASSETS=$(du -sk /System/Library/AssetsV2/com_apple_MobileAsset_UAF_* 2>/dev/null | awk '{s+=$1} END {printf "%.1f", s/1048576}')
if [ -n "${AI_ASSETS:-}" ] && awk -v g="${AI_ASSETS:-0}" 'BEGIN{exit !(g>1)}'; then
  warn "Apple Intelligence models are using ${AI_ASSETS} GB on a machine that does not need them."
fi

for p in mds_stores mdworker photoanalysisd bird cloudd; do
  if pgrep -qx "$p" 2>/dev/null; then
    C=$(ps -o pcpu= -p "$(pgrep -x "$p" | head -1)" 2>/dev/null | tr -d ' ')
    awk -v c="${C:-0}" 'BEGIN{exit !(c>20)}' && warn "$p is at ${C}% CPU. Stuck Spotlight index or a jammed iCloud sync will do that."
  fi
done

# ------------------------------------------------------------ power, panics

sect "Battery and stability"

PWR=$(system_profiler SPPowerDataType 2>/dev/null)
CYCLES=$(printf '%s' "$PWR" | awk -F': *' '/Cycle Count/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
COND=$(printf '%s' "$PWR"   | awk -F': *' '/Condition/ {print $2; exit}')
MAXCAP=$(printf '%s' "$PWR" | awk -F': *' '/Maximum Capacity/ {print $2; exit}')

# system_profiler output labels have moved between macOS releases. ioreg reads
# the same counter straight off the battery controller and never needs root.
if [ -z "${CYCLES:-}" ] && command -v ioreg >/dev/null 2>&1; then
  CYCLES=$(ioreg -r -c AppleSmartBattery -d 1 2>/dev/null | awk -F'= *' '/"CycleCount"/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
fi
case "${CYCLES:-}" in ''|*[!0-9]*) CYCLES="" ;; esac

if [ -n "${CYCLES:-}" ] || [ -n "${COND:-}" ]; then
  say "Battery: ${COND:-condition unreported}, ${CYCLES:-?} cycles, capacity ${MAXCAP:-?}"
else
  warn "Battery not read. Check by hand: system_profiler SPPowerDataType | grep -A4 'Health Information'"
fi
[ -n "${COND:-}" ] && [ "${COND}" != "Normal" ] && flag "Battery condition is '${COND}'. Replace the battery or the machine."
[ -n "${CYCLES:-}" ] && [ "${CYCLES}" -ge 800 ] && warn "${CYCLES} charge cycles. Past the rated life."

PANICS=$(find /Library/Logs/DiagnosticReports -name "*panic*" -mtime -30 2>/dev/null | wc -l | tr -d ' ')
[ "${PANICS:-0}" -gt 0 ] && flag "${PANICS} kernel panic report(s) in the last 30 days. That is hardware or a bad driver, not workload."

# ----------------------------------------------------------------- summary

if [ "$CSV_MODE" -eq 1 ]; then
  HEADER="date,host,user,model,ram_gb,os,uptime_days,pressure,free_mem_pct,swap_gb,swapins_sec,free_space_pct,free_gb,snapshots,ssd_pct_used,batt_cycles,batt_cond,bg_items,browsers_running,rosetta_apps,flags,model_year,age_years,in_service,disk_total_gb"
  ROW=$(printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$TODAY" "$(csv_safe "$HOSTNAME_S")" "$(csv_safe "$USER_S")" "$(csv_safe "${MODEL:-}")" \
    "$RAM_GB" "$(csv_safe "${OS_VER:-}")" "$UP_DAYS" \
    "$PRESSURE" "${FREE_PCT:-}" "$SWAP_GB" "$SWAPIN_RATE" "$FREE_SPACE_PCT" "$FREE_GB" \
    "${SNAPS:-0}" "${SSD_PCT:-}" "${CYCLES:-}" "$(csv_safe "${COND:-}")" "$THIRD_PARTY" "$BROWSERS" \
    "$(csv_safe "$ROSETTA_APPS")" "$FLAG_COUNT" \
    "${MODEL_YEAR:-}" "${AGE_YEARS:-}" "${IN_SERVICE:-}" "${TOTAL_GB:-}")

  if [ -n "$OUT_FILE" ]; then
    if [ ! -s "$OUT_FILE" ]; then echo "$HEADER" > "$OUT_FILE" || exit 1; fi
    echo "$ROW" >> "$OUT_FILE" || exit 1
    echo "Appended 1 row for $HOSTNAME_S to $OUT_FILE ($(( $(wc -l < "$OUT_FILE") - 1 )) machine(s) recorded)." >&2
  else
    [ "$WANT_HEADER" -eq 1 ] && echo "$HEADER"
    echo "$ROW"
  fi
  exit 0
fi

sect "Summary"
if [ "$FLAG_COUNT" -eq 0 ]; then
  echo "${GRN}Nothing crossed a threshold.${RST} If it still feels slow, watch the memory list above while it happens; the cause is one app, not the machine."
else
  echo "${YEL}${FLAG_COUNT} thing(s) to act on:${RST}"
  i=1
  while [ "$i" -le "$FLAG_COUNT" ]; do echo "  $i. ${FLAGS[$(( i - 1 ))]}"; i=$(( i + 1 )); done
fi
echo ""
echo "Read-only. Nothing on this Mac was changed."
echo "Next: run mac-triage-cleanup.sh, then re-run this with --csv and feed the row to mac-triage-verdict.sh."