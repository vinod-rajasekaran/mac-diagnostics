#!/bin/bash
#
# mac-triage-diagnose.sh   READ-ONLY. Changes nothing.
#
# Measures this Mac and ends with one verdict for it. Tuned to the failure mode
# behind most "my Mac is slow" complaints on small-RAM Apple Silicon laptops:
# memory pressure forcing swap onto a disk with no room for it.
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

# ---------------------------------------------------------------- thresholds
#
# Every number this script judges by, in one place. They appear twice in the
# output — once in a [FLAG]/[WATCH] line, once in the verdict — and they must
# agree, or the report contradicts its own conclusion.
#
# Override any of them from the environment to suit a different set of machines:
#   T_SWAP_HIGH=10 ./mac-triage-diagnose.sh
# The defaults are documented in the threshold table in README.md; change one
# here and change it there.

T_UPTIME_DAYS=${T_UPTIME_DAYS:-14}      # restart overdue
T_AGE_VINTAGE=${T_AGE_VINTAGE:-5}       # Apple calls a product vintage at 5 years
T_AGE_OBSOLETE=${T_AGE_OBSOLETE:-7}     # ...and obsolete at 7
T_SWAP_WARN=${T_SWAP_WARN:-2}           # GB of swap: workload no longer fits
T_SWAP_HIGH=${T_SWAP_HIGH:-6}           # GB of swap: sustained paging
T_SWAPIN=${T_SWAPIN:-50}                # pages/sec read back: active thrashing
T_FREE_CRIT=${T_FREE_CRIT:-15}          # % free below which swap cannot grow cleanly
T_FREE_TARGET=${T_FREE_TARGET:-25}      # % free to reach before judging the machine
T_SMALL_DISK_GB=${T_SMALL_DISK_GB:-256} # volume at or under this is undersized, not untidy
T_SSD_WATCH=${T_SSD_WATCH:-20}          # % of write endurance used: worth watching
T_SSD_HIGH=${T_SSD_HIGH:-40}            # % of write endurance used: spent
T_BATT_CYCLES=${T_BATT_CYCLES:-800}     # charge cycles past rated life
T_BG_ITEMS=${T_BG_ITEMS:-15}            # third-party launch agents and daemons
T_BROWSERS=${T_BROWSERS:-2}             # browser engines resident at once
T_CHROME_PROCS=${T_CHROME_PROCS:-40}    # Chrome helper processes
T_SNAPSHOTS=${T_SNAPSHOTS:-3}           # local Time Machine snapshots
T_RECLAIM_GB=${T_RECLAIM_GB:-2}         # GB reclaimable before a cleanup is worth it
T_CLEAN_STALE_DAYS=${T_CLEAN_STALE_DAYS:-30}  # after this, a past cleanup says nothing
T_AI_ASSETS_GB=${T_AI_ASSETS_GB:-1}     # GB of Apple Intelligence models
T_PROC_CPU=${T_PROC_CPU:-20}            # % CPU for a stuck background daemon

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
[ "${UP_DAYS:-0}" -ge "$T_UPTIME_DAYS" ] && flag "Not restarted in ${UP_DAYS} days. Swap and leaked memory never come back on their own."
if [ -n "${AGE_YEARS:-}" ]; then
  # Apple treats a product as vintage at 5 years and obsolete at 7. Past 7 the
  # question stops being "what is wrong with it" and becomes "when do we
  # replace it", and cleanup buys progressively less time.
  [ "$AGE_YEARS" -ge "$T_AGE_OBSOLETE" ] && flag "${AGE_YEARS} years old (by ${AGE_BASIS}). Past Apple's obsolete threshold; budget a replacement rather than tuning this one."
  [ "$AGE_YEARS" -ge "$T_AGE_VINTAGE" ] && [ "$AGE_YEARS" -lt "$T_AGE_OBSOLETE" ] && warn "${AGE_YEARS} years old (by ${AGE_BASIS}). Vintage territory; plan for it in the next refresh cycle."
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
awk -v s="$SWAP_GB" -v h="$T_SWAP_HIGH" 'BEGIN{exit !(s>h)}' && flag "Swap is ${SWAP_GB} GB. Sustained paging at this level is the slowness people are reporting."
awk -v s="$SWAP_GB" -v w="$T_SWAP_WARN" -v h="$T_SWAP_HIGH" 'BEGIN{exit !(s>w && s<=h)}' && warn "Swap is ${SWAP_GB} GB. Workload does not fit comfortably in ${RAM_GB} GB."
[ "$SWAPIN_RATE" -gt "$T_SWAPIN" ] && flag "Pages are being read back from swap at ${SWAPIN_RATE}/sec. This is active thrashing, not just allocated swap."

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
[ "$BROWSERS" -ge "$T_BROWSERS" ] && flag "$BROWSERS browser engines are resident at once. On ${RAM_GB} GB this alone can account for the slowness."
[ "$CLAUDE_APP" = "1" ] && [ "$CLAUDE_CODE" = "1" ] && warn "Claude desktop app and Claude Code are both resident."

CHROME_PROCS=$(pgrep -fc "Google Chrome" 2>/dev/null | head -1)
case "${CHROME_PROCS:-}" in ''|*[!0-9]*) CHROME_PROCS=0 ;; esac
[ "$CHROME_PROCS" -gt "$T_CHROME_PROCS" ] && warn "$CHROME_PROCS Chrome processes. Tab count is out of hand; turn on Memory Saver."

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

if [ "$FREE_SPACE_PCT" -lt "$T_FREE_CRIT" ]; then
  flag "Only ${FREE_SPACE_PCT}% free. Below this macOS cannot grow swap cleanly and everything degrades at once."
elif [ "$FREE_SPACE_PCT" -lt "$T_FREE_TARGET" ]; then
  warn "${FREE_SPACE_PCT}% free. Target is ${T_FREE_TARGET}% before judging this machine."
else
  ok "Free space is above the ${T_FREE_TARGET}% floor."
fi

# A 256 GB volume that is short of space after a cleanup is not a housekeeping
# problem. Storage is not upgradeable on Apple Silicon, so this belongs in the
# refresh plan rather than in a list of things the user should delete.
if [ "${TOTAL_GB:-0}" -le "$T_SMALL_DISK_GB" ] && [ "$FREE_SPACE_PCT" -lt "$T_FREE_TARGET" ]; then
  warn "${TOTAL_GB} GB volume with ${FREE_SPACE_PCT}% free. If this persists after cleanup, the disk is undersized for this role, not untidy."
fi

# grep -c prints 0 AND exits 1 when it matches nothing, so a trailing '|| echo 0'
# appends a second line and the value becomes "0\n0". Normalise to digits instead.
SNAPS=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' | head -1 | tr -cd '0-9')
[ -z "$SNAPS" ] && SNAPS=0
say "Local Time Machine snapshots: ${SNAPS}"
[ "${SNAPS:-0}" -ge "$T_SNAPSHOTS" ] && warn "${SNAPS} local snapshots are holding disk space that Finder reports as purgeable."

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
  [ "$SSD_PCT" -ge "$T_SSD_HIGH" ] && flag "SSD is ${SSD_PCT}% through its write endurance. Years of swap have already been written to it."
  [ "$SSD_PCT" -ge "$T_SSD_WATCH" ] && [ "$SSD_PCT" -lt "$T_SSD_HIGH" ] && warn "SSD is ${SSD_PCT}% used. Worth watching."
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
[ "$THIRD_PARTY" -ge "$T_BG_ITEMS" ] && flag "${THIRD_PARTY} third-party background items load at boot. Most belong to software nobody uses any more."
[ "$CSV_MODE" -eq 0 ] && for d in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
  [ -d "$d" ] && ls -1 "$d" 2>/dev/null | sed "s|^|  $d/|"
done

AI_ASSETS=$(du -sk /System/Library/AssetsV2/com_apple_MobileAsset_UAF_* 2>/dev/null | awk '{s+=$1} END {printf "%.1f", s/1048576}')
if [ -n "${AI_ASSETS:-}" ] && awk -v g="${AI_ASSETS:-0}" -v t="$T_AI_ASSETS_GB" 'BEGIN{exit !(g>t)}'; then
  warn "Apple Intelligence models are using ${AI_ASSETS} GB on a machine that does not need them."
fi

for p in mds_stores mdworker photoanalysisd bird cloudd; do
  if pgrep -qx "$p" 2>/dev/null; then
    C=$(ps -o pcpu= -p "$(pgrep -x "$p" | head -1)" 2>/dev/null | tr -d ' ')
    awk -v c="${C:-0}" -v t="$T_PROC_CPU" 'BEGIN{exit !(c>t)}' && warn "$p is at ${C}% CPU. Stuck Spotlight index or a jammed iCloud sync will do that."
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
[ -n "${CYCLES:-}" ] && [ "${CYCLES}" -ge "$T_BATT_CYCLES" ] && warn "${CYCLES} charge cycles. Past the rated life."

PANICS=$(find /Library/Logs/DiagnosticReports -name "*panic*" -mtime -30 2>/dev/null | wc -l | tr -d ' ')
[ "${PANICS:-0}" -gt 0 ] && flag "${PANICS} kernel panic report(s) in the last 30 days. That is hardware or a bad driver, not workload."

# ------------------------------------------------------- cleanup state

# Three situations that otherwise look identical from the numbers alone:
# never cleaned up, cleaned up but not restarted, cleaned up and restarted.
# Only the last one makes a verdict about the machine itself trustworthy,
# because swap and leaked memory survive until a restart.
STATE_FILE="$HOME/.mac-triage/last-cleanup"
CLEANED_AT=$(cat "$STATE_FILE" 2>/dev/null | head -1 | tr -cd '0-9')
if [ -z "${CLEANED_AT:-}" ]; then
  CLEAN_STATE="never"
elif [ "$(( $(date +%s) - CLEANED_AT ))" -gt "$(( T_CLEAN_STALE_DAYS * 86400 ))" ]; then
  CLEAN_STATE="stale"          # over 30 days ago; no longer says anything
elif [ "$CLEANED_AT" -gt "$(( $(date +%s) - UP_SECS ))" ]; then
  CLEAN_STATE="no-restart"     # cleaned up after the machine last booted
else
  CLEAN_STATE="done"
fi

# What a cleanup would still reclaim. Only the paths mac-triage-cleanup.sh
# actually removes, so the number is a promise it can keep.
RECLAIM_KB=0
for c in \
  "$HOME/.Trash" \
  "$HOME/Library/Caches/com.apple.dt.Xcode" \
  "$HOME/Library/Caches/ms-playwright" \
  "$HOME/Library/Caches/Homebrew" \
  "$HOME/Library/Caches/pip" \
  "$HOME/Library/Application Support/Slack/Service Worker/CacheStorage" \
  "$HOME/Library/Application Support/Code/CachedExtensionVSIXs" ; do
  [ -e "$c" ] || continue
  K=$(du -sk "$c" 2>/dev/null | awk '{print $1+0; exit}')
  RECLAIM_KB=$(( RECLAIM_KB + ${K:-0} ))
done
RECLAIM_GB=$(awk -v k="$RECLAIM_KB" 'BEGIN{printf "%.1f", k/1048576}')

# ----------------------------------------------------------------- verdict
#
# One machine, one answer. Ordered so that the cheapest true explanation wins:
# spent hardware first because nothing fixes it, then age, then whether the
# machine has even been given a fair chance, then habits, then workload fit.

VERDICT=""; WHY=""; NEXT=""

gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }   # float compare

STRAINED=0; TIGHT=0
[ "$PRESSURE" = "critical" ] && STRAINED=1
gt "$SWAP_GB" "$T_SWAP_HIGH" && STRAINED=1
[ "${SWAPIN_RATE:-0}" -gt "$T_SWAPIN" ] && STRAINED=1
[ "$PRESSURE" = "warning" ] && TIGHT=1
gt "$SWAP_GB" "$T_SWAP_WARN" && TIGHT=1

# Swap needs somewhere to live. This pair is the actual failure mode, and it
# is invisible if you read either number on its own.
SWAP_SQUEEZE=0
gt "$SWAP_GB" "$T_SWAP_WARN" && [ "$FREE_SPACE_PCT" -lt "$T_FREE_CRIT" ] && SWAP_SQUEEZE=1

OLD=0
[ -n "${AGE_YEARS:-}" ] && [ "$AGE_YEARS" -ge "$T_AGE_OBSOLETE" ] && OLD=1

# A volume this small, still short of room after a cleanup, is undersized for
# the work rather than untidy. Storage is not upgradeable on Apple Silicon.
UNDERSIZED=0
[ "${TOTAL_GB:-0}" -le "$T_SMALL_DISK_GB" ] && [ "$FREE_SPACE_PCT" -lt "$T_FREE_TARGET" ] && UNDERSIZED=1

HABITS=""
[ "$BROWSERS" -ge "$T_BROWSERS" ] && HABITS="${BROWSERS} browser engines resident"
[ -n "$ROSETTA_APPS" ] && HABITS="${HABITS:+$HABITS; }Rosetta builds: ${ROSETTA_APPS}"
[ "${UP_DAYS:-0}" -ge "$T_UPTIME_DAYS" ] && HABITS="${HABITS:+$HABITS; }${UP_DAYS} days without a restart"
[ "$THIRD_PARTY" -ge "$T_BG_ITEMS" ] && HABITS="${HABITS:+$HABITS; }${THIRD_PARTY} background items at boot"
[ "$FREE_SPACE_PCT" -lt "$T_FREE_TARGET" ] && [ "$UNDERSIZED" -eq 0 ] && HABITS="${HABITS:+$HABITS; }only ${FREE_SPACE_PCT}% disk free"

# Has this machine been given a fair chance? Worth saying only when it is
# actually struggling and there is something left to reclaim.
WORTH_CLEANING=0
if [ "$STRAINED" -eq 1 ] || [ "$TIGHT" -eq 1 ] || [ "$FREE_SPACE_PCT" -lt "$T_FREE_TARGET" ]; then
  { gt "$RECLAIM_GB" "$T_RECLAIM_GB" || [ "${SNAPS:-0}" -ge "$T_SNAPSHOTS" ]; } && WORTH_CLEANING=1
fi

HW=""
[ -n "${SSD_PCT:-}" ] && [ "$SSD_PCT" -ge "$T_SSD_HIGH" ] && HW="SSD is ${SSD_PCT}% through its write endurance"
[ -n "${COND:-}" ] && [ "$COND" != "Normal" ] && HW="${HW:+$HW; }battery condition is ${COND}"
[ -n "${CYCLES:-}" ] && [ "$CYCLES" -ge "$T_BATT_CYCLES" ] && HW="${HW:+$HW; }${CYCLES} battery cycles"
[ "${PANICS:-0}" -gt 0 ] && HW="${HW:+$HW; }${PANICS} kernel panic(s) in 30 days"

if [ -n "$HW" ]; then
  VERDICT="REPLACE"
  WHY="$HW. No amount of cleanup or restraint touches this."
  NEXT="Get a quote for the repair, and price it against a replacement before paying it."
elif [ "$CLEAN_STATE" = "no-restart" ]; then
  VERDICT="RESTART FIRST"
  WHY="Cleanup has run, but this Mac has not restarted since. Swap and leaked memory survive until it does, so these numbers still describe the old load."
  NEXT="Restart, work normally for an hour, then run this again."
elif [ "$WORTH_CLEANING" -eq 1 ] && [ "$CLEAN_STATE" != "done" ]; then
  VERDICT="CLEAN FIRST"
  SNAP_CLAUSE=""
  [ "${SNAPS:-0}" -gt 0 ] && SNAP_CLAUSE=" and ${SNAPS} local snapshot(s)"
  WHY="Struggling, but it has not been given a fair chance: ${RECLAIM_GB} GB of caches and rubbish${SNAP_CLAUSE} still here. Judging the machine now would blame hardware for housekeeping."
  NEXT="./mac-triage-cleanup.sh          (dry run, shows what it would take)
      ./mac-triage-cleanup.sh --apply  then restart, then run this again"
elif [ "$OLD" -eq 1 ] && { [ "$STRAINED" -eq 1 ] || [ "$TIGHT" -eq 1 ] || [ "$UNDERSIZED" -eq 1 ]; }; then
  VERDICT="REFRESH"
  WHY="${AGE_YEARS} years old and still struggling after a clean-up. Tuning it further buys weeks, not years."
  NEXT="Budget a replacement in the next cycle. It is not an emergency; plan it."
elif [ "$SWAP_SQUEEZE" -eq 1 ]; then
  VERDICT="OUT OF ROOM"
  WHY="${SWAP_GB} GB of swap on a volume with only ${FREE_SPACE_PCT}% free. macOS is paging with nowhere to page to, which is why everything stalls at once rather than one app being slow."
  NEXT="Free disk space first — that alone usually fixes the stalling. If it comes back, this workload needs more than ${RAM_GB} GB."
elif [ "$STRAINED" -eq 1 ] && [ -n "$HABITS" ]; then
  VERDICT="FIX"
  WHY="Out of RAM, but the load is self-inflicted: ${HABITS}."
  NEXT="Work through the list above. It costs nothing and usually ends the problem."
elif [ "$STRAINED" -eq 1 ] && [ "$UNDERSIZED" -eq 1 ]; then
  VERDICT="REALLOCATE"
  WHY="Paging hard on a ${TOTAL_GB} GB disk at ${FREE_SPACE_PCT}% free, with nothing obvious left to clean. The disk cannot be enlarged."
  NEXT="Move this work to a machine with more RAM and disk, and give this one to someone whose work is lighter."
elif [ "$STRAINED" -eq 1 ]; then
  VERDICT="REALLOCATE"
  WHY="Clean machine, sensible habits, still out of RAM under this workload. ${RAM_GB} GB does not fit the work being asked of it."
  NEXT="Swap machines with someone whose work is lighter, before buying anything."
elif [ "$TIGHT" -eq 1 ] && [ -n "$HABITS" ]; then
  VERDICT="FIX"
  WHY="Close to the edge, and the reasons are all changeable: ${HABITS}."
  NEXT="Work through the list above before concluding anything about the hardware."
elif [ "$UNDERSIZED" -eq 1 ]; then
  VERDICT="REALLOCATE"
  WHY="Holding for now, but ${TOTAL_GB} GB is undersized for this work and cannot be enlarged."
  NEXT="Plan to move this person onto a bigger disk; this machine suits lighter work."
elif [ "$TIGHT" -eq 1 ]; then
  VERDICT="KEEP"
  WHY="Tight but holding. Nothing here justifies spending money."
  NEXT="Keep one browser open and restart weekly, and it will stay this side of the line."
elif [ -n "$HABITS" ]; then
  VERDICT="KEEP"
  WHY="Comfortable right now, though: ${HABITS}."
  NEXT="Worth tidying before it becomes a complaint, but nothing is wrong today."
else
  VERDICT="KEEP"
  WHY="Everything is within thresholds."
  NEXT="If it still feels slow, watch the memory list above while it is happening. The cause is one app, not the machine."
fi

# Say out loud what was not measured, rather than quietly assuming health.
PROVISIONAL=""; PROV_N=0
if [ -z "${SSD_PCT:-}" ]; then PROVISIONAL="SSD wear"; PROV_N=1; fi
if [ -z "${CYCLES:-}" ] && [ -z "${COND:-}" ]; then
  PROVISIONAL="${PROVISIONAL:+$PROVISIONAL and }battery health"; PROV_N=$(( PROV_N + 1 ))
fi
if [ -n "$PROVISIONAL" ] && [ "$VERDICT" != "REPLACE" ]; then
  if [ "$PROV_N" -gt 1 ]; then
    PROVISIONAL="${PROVISIONAL} were not measured, so a spent one cannot be ruled out."
  else
    PROVISIONAL="${PROVISIONAL} was not measured, so a spent one cannot be ruled out."
  fi
else
  PROVISIONAL=""
fi

# ----------------------------------------------------------------- summary

if [ "$CSV_MODE" -eq 1 ]; then
  HEADER="date,host,user,model,ram_gb,os,uptime_days,pressure,free_mem_pct,swap_gb,swapins_sec,free_space_pct,free_gb,snapshots,ssd_pct_used,batt_cycles,batt_cond,bg_items,browsers_running,rosetta_apps,flags,model_year,age_years,in_service,disk_total_gb,verdict,why,cleanup_state,reclaimable_gb"
  ROW=$(printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$TODAY" "$(csv_safe "$HOSTNAME_S")" "$(csv_safe "$USER_S")" "$(csv_safe "${MODEL:-}")" \
    "$RAM_GB" "$(csv_safe "${OS_VER:-}")" "$UP_DAYS" \
    "$PRESSURE" "${FREE_PCT:-}" "$SWAP_GB" "$SWAPIN_RATE" "$FREE_SPACE_PCT" "$FREE_GB" \
    "${SNAPS:-0}" "${SSD_PCT:-}" "${CYCLES:-}" "$(csv_safe "${COND:-}")" "$THIRD_PARTY" "$BROWSERS" \
    "$(csv_safe "$ROSETTA_APPS")" "$FLAG_COUNT" \
    "${MODEL_YEAR:-}" "${AGE_YEARS:-}" "${IN_SERVICE:-}" "${TOTAL_GB:-}" \
    "$(csv_safe "$VERDICT")" "$(csv_safe "$WHY")" "$CLEAN_STATE" "$RECLAIM_GB")

  if [ -n "$OUT_FILE" ]; then
    if [ ! -s "$OUT_FILE" ]; then echo "$HEADER" > "$OUT_FILE" || exit 1; fi
    echo "$ROW" >> "$OUT_FILE" || exit 1
    echo "Appended 1 row for $HOSTNAME_S to $OUT_FILE ($(( $(wc -l < "$OUT_FILE") - 1 )) run(s) recorded)." >&2
  else
    [ "$WANT_HEADER" -eq 1 ] && echo "$HEADER"
    echo "$ROW"
  fi
  exit 0
fi

sect "Summary"
if [ "$FLAG_COUNT" -eq 0 ]; then
  echo "${GRN}Nothing crossed a threshold.${RST}"
else
  echo "${YEL}${FLAG_COUNT} thing(s) crossed a threshold:${RST}"
  i=1
  while [ "$i" -le "$FLAG_COUNT" ]; do echo "  $i. ${FLAGS[$(( i - 1 ))]}"; i=$(( i + 1 )); done
fi

case "$VERDICT" in
  REPLACE|"OUT OF ROOM")       VC="$RED" ;;
  "CLEAN FIRST"|"RESTART FIRST"|FIX|REFRESH|REALLOCATE) VC="$YEL" ;;
  *)                            VC="$GRN" ;;
esac

echo ""
echo "${BOLD}${VC}VERDICT: ${VERDICT}${RST}"
echo ""
echo "$WHY" | fold -s -w 76 | sed 's/^/  /'
[ -n "$PROVISIONAL" ] && echo "$PROVISIONAL" | fold -s -w 76 | sed 's/^/  (/;s/$/)/'
echo ""
echo "${BOLD}Next:${RST}"
echo "$NEXT" | sed 's/^/  /'
echo ""
echo "Read-only. Nothing on this Mac was changed."