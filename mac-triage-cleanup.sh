#!/bin/bash
#
# mac-triage-cleanup.sh   DRY RUN BY DEFAULT.
#
#   ./mac-triage-cleanup.sh                  show what would be reclaimed, change nothing
#   ./mac-triage-cleanup.sh --apply          do it
#   ./mac-triage-cleanup.sh --apply --dev    also clear developer caches
#   ./mac-triage-cleanup.sh --apply --recheck  ...then re-run the diagnostic
#
# Rules this script follows:
#   - It never deletes anything in Documents, Desktop, Downloads or iCloud.
#   - It never deletes a launch agent. It lists them and you decide.
#   - It never touches browser profiles, cookies or sessions.
#   - Every destructive step prints its size before it runs.
# Target: 25% of the Data volume free, which is about 64 GB on a 256 GB machine.

set -uo pipefail

APPLY=0; DEV=0; RECHECK=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --dev) DEV=1 ;;
    --recheck) RECHECK=1 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  esac
done

# mac-triage-diagnose.sh reads this to tell apart "never cleaned up", "cleaned
# up but not restarted yet" and "cleaned up and restarted". Only the last of
# those makes a REPLACE verdict trustworthy.
STATE_DIR="$HOME/.mac-triage"
STATE_FILE="$STATE_DIR/last-cleanup"

if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold); YEL=$(tput setaf 3); GRN=$(tput setaf 2); RST=$(tput sgr0)
else BOLD=""; YEL=""; GRN=""; RST=""; fi

DATA_VOL="/System/Volumes/Data"
free_gb() { df -k "$DATA_VOL" | tail -1 | awk '{printf "%.1f", $4/1048576}'; }
free_pct() { df -k "$DATA_VOL" | tail -1 | awk '{gsub("%","",$5); print 100-$5}'; }
size_of() { [ -e "$1" ] && du -sh "$1" 2>/dev/null | awk '{print $1}' || echo "-"; }

START_FREE=$(free_gb)
echo "${BOLD}Free before: ${START_FREE} GB ($(free_pct)% of the volume)${RST}"
[ "$APPLY" -eq 0 ] && echo "${YEL}DRY RUN. Nothing will be changed. Re-run with --apply to act.${RST}"

step() { echo ""; echo "${BOLD}-- $1${RST}"; }
run() {
  if [ "$APPLY" -eq 1 ]; then eval "$1"; else echo "   would run: $1"; fi
}

# 1 ------------------------------------------------- local Time Machine snapshots
step "Local Time Machine snapshots"
# grep -c prints 0 AND exits 1 when it matches nothing, so a trailing '|| echo 0'
# appends a second line and the value becomes "0\n0". Normalise to digits instead.
SNAPS=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' | head -1 | tr -cd '0-9')
[ -z "$SNAPS" ] && SNAPS=0
echo "   ${SNAPS} snapshot(s) present. These are usually the largest hidden consumer."
if [ "${SNAPS:-0}" -gt 0 ]; then
  # thinlocalsnapshots needs root. Without it the command returns success while
  # reclaiming nothing, which looks like a cleanup that did not help.
  if [ "$APPLY" -eq 1 ] && [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    echo "   ${YEL}Needs root. You will be asked for your password.${RST}"
  fi
  run "sudo tmutil thinlocalsnapshots / 50000000000 4"
fi

# 2 ---------------------------------------------------------- user-level caches
step "Application caches"
for c in \
  "$HOME/Library/Caches/com.apple.dt.Xcode" \
  "$HOME/Library/Caches/ms-playwright" \
  "$HOME/Library/Caches/Homebrew" \
  "$HOME/Library/Caches/pip" \
  "$HOME/Library/Application Support/Slack/Service Worker/CacheStorage" \
  "$HOME/Library/Application Support/Code/CachedExtensionVSIXs" ; do
  [ -e "$c" ] || continue
  echo "   $(size_of "$c")  $c"
  run "rm -rf \"$c\""
done

# 3 ------------------------------------------------------------ developer waste
if [ "$DEV" -eq 1 ]; then
  step "Developer caches"
  for d in \
    "$HOME/Library/Developer/Xcode/DerivedData" \
    "$HOME/Library/Developer/Xcode/iOS DeviceSupport" \
    "$HOME/Library/Developer/CoreSimulator/Caches" ; do
    [ -e "$d" ] || continue
    echo "   $(size_of "$d")  $d"
    run "rm -rf \"$d\""
  done
  command -v brew   >/dev/null 2>&1 && run "brew cleanup -s"
  command -v npm    >/dev/null 2>&1 && run "npm cache clean --force"
  command -v yarn   >/dev/null 2>&1 && run "yarn cache clean"
  command -v pnpm   >/dev/null 2>&1 && run "pnpm store prune"
  command -v docker >/dev/null 2>&1 && run "docker system prune -af --volumes"
else
  echo ""
  echo "   (developer caches skipped; add --dev on machines that write code)"
fi

# 4 ------------------------------------------------------------ old iOS backups
step "iOS device backups"
MS="$HOME/Library/Application Support/MobileSync/Backup"
if [ -d "$MS" ]; then
  echo "   $(size_of "$MS")  $MS"
  echo "   ${YEL}Review before deleting. These are the only copy of someone's phone.${RST}"
  ls -1 "$MS" 2>/dev/null | sed 's/^/     /'
else
  echo "   none"
fi

# 5 -------------------------------------------------------------------- trash
step "Trash"
echo "   $(size_of "$HOME/.Trash")"
run "rm -rf \"$HOME/.Trash/\"*"

# 6 ------------------------------------------------- report only, never delete
step "Largest items in the home folder (report only)"
du -sk "$HOME"/* 2>/dev/null | sort -rn | head -12 | awk '{printf "   %7.1f GB  %s\n", $1/1048576, substr($0, index($0,$2))}'

step "Downloads over 200 MB (report only)"
find "$HOME/Downloads" -type f -size +200M 2>/dev/null -exec du -h {} + 2>/dev/null | sort -rh | head -10 | sed 's/^/   /'

step "Third-party launch agents and daemons (report only, delete by hand)"
for d in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
  [ -d "$d" ] && ls -1 "$d" 2>/dev/null | sed "s|^|   $d/|"
done
echo "   ${YEL}Anything here from software that is no longer installed should go.${RST}"

# 7 -------------------------------------------------------- settings to change
step "Settings a script should not change for you"
echo "   System Settings > Apple Intelligence & Siri       turn it off on 8 GB machines"
echo "   System Settings > General > Login Items           cut to the minimum"
echo "   iCloud Drive and Photos                           turn on Optimise Mac Storage"
echo "   Chrome > Performance                              turn on Memory Saver"
echo "   Uninstall the second browser. Chrome or Atlas, not both."

# ---------------------------------------------------------------------- result
echo ""
END_FREE=$(free_gb)
if [ "$APPLY" -eq 1 ]; then
  echo "${GRN}${BOLD}Free after: ${END_FREE} GB ($(free_pct)% of the volume)${RST}"
  awk -v a="$START_FREE" -v b="$END_FREE" 'BEGIN{printf "Reclaimed: %.1f GB\n", b-a}'
  mkdir -p "$STATE_DIR" 2>/dev/null && date +%s > "$STATE_FILE" 2>/dev/null
  echo ""
  echo "${BOLD}Now restart the Mac, then run ./mac-triage-diagnose.sh for the verdict.${RST}"
  echo "Swap does not come back on its own; without the restart the numbers still"
  echo "show the old load and the verdict stays provisional."
  if [ "$RECHECK" -eq 1 ]; then
    D="$(dirname "$0")/mac-triage-diagnose.sh"
    if [ -x "$D" ]; then
      echo ""
      echo "${YEL}--recheck: running the diagnostic now. This is BEFORE a restart,${RST}"
      echo "${YEL}so treat it as a progress check, not the verdict.${RST}"
      exec "$D"
    fi
  fi
else
  echo "${YEL}Dry run finished. Nothing changed. Re-run with --apply.${RST}"
fi
