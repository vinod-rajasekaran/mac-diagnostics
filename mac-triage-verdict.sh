#!/bin/bash
#
# mac-triage-verdict.sh   Turns collected rows into decisions.
#
#   ./mac-triage-diagnose.sh --csv --header >  fleet.csv     # first machine
#   ./mac-triage-diagnose.sh --csv          >> fleet.csv     # every machine after
#   ./mac-triage-verdict.sh fleet.csv
#
# Run it on rows collected AFTER cleanup and a restart. Rows taken from a
# machine that was never cleaned will overstate the case for replacement.
#
# If a host appears more than once, only its newest row is assessed. Collecting
# twice from the same machine must not inflate the fleet count.
#
# Five outcomes:
#   KEEP        within thresholds, nothing to do
#   FIX         the load is self-inflicted: two browsers, Rosetta builds,
#               no restart in weeks, disk still full. Cheaper than hardware.
#   REALLOCATE  hardware is sound but this machine does not fit this person's
#               work. Swap with someone whose work is lighter.
#   REFRESH     old enough that cleanup buys little time. Plan and budget the
#               replacement; it is not an emergency.
#   REPLACE     the SSD or the battery is spent. Workload is not the issue.

set -uo pipefail

CSV="${1:-}"
if [ -z "$CSV" ] || [ ! -f "$CSV" ]; then
  echo "usage: $0 fleet.csv" >&2; exit 1
fi

awk -F',' '
# awk returns an empty subscript for a header that is not present, and $("")
# resolves to $0 - a silently wrong value rather than an error. Every field is
# read through g() so a missing column reads as empty and stays honest.
function g(a, name) { return (name in col) ? a[col[name]] : "" }

NR==1 {
  for (i=1; i<=NF; i++) { gsub(/^ +| +$|"/,"",$i); col[$i]=i }
  if (!("host" in col) || !("date" in col)) {
    print "error: " FILENAME " has no host/date header. Regenerate it with: mac-triage-diagnose.sh --csv --header" > "/dev/stderr"
    bad = 1; exit 1
  }
  next
}
NF < 10 { next }
{
  # Keep only the newest row per host, in first-seen order.
  h = $(col["host"]); d = $(col["date"])
  if (!(h in seen)) { seen[h]=1; order[++n]=h }
  else dupes++
  if (!(h in bestdate) || d >= bestdate[h]) { bestdate[h]=d; row[h]=$0 }
}
END {
  if (bad) exit 1
  printf "%-18s %-6s %-7s %-9s %-7s %-7s %-6s %-6s %-5s %-11s %s\n", \
         "MACHINE","RAM","DISK","PRESSURE","SWAP","FREE","AGE","SSD","BATT","VERDICT","WHY"
  printf "%s\n", "---------------------------------------------------------------------------------------------------------------------"

  for (i=1; i<=n; i++) assess(row[order[i]])

  printf "\n%d machine(s) assessed", total
  if (dupes > 0) printf " (%d duplicate row(s) collapsed to the newest per host)", dupes
  printf "\n"
  printf "  KEEP        %3d   nothing to do\n", count["KEEP"]+0
  printf "  FIX         %3d   cleanup and user rules, no spend\n", count["FIX"]+0
  printf "  REALLOCATE  %3d   sound hardware, wrong person for it\n", count["REALLOCATE"]+0
  printf "  REFRESH     %3d   aged out, plan the replacement\n", count["REFRESH"]+0
  printf "  REPLACE     %3d   spent SSD or battery, buy now\n", count["REPLACE"]+0
  buy = count["REPLACE"]+0
  plan = count["REFRESH"]+0
  printf "\nMachines that need buying now: %d of %d (%.0f%%)\n", buy, total, (total? buy*100/total : 0)
  if (plan > 0)
    printf "Plus %d to budget for in the next refresh cycle.\n", plan
  if ((count["REALLOCATE"]+0) > 0)
    printf "Plus %d to move onto lighter roles before buying anything for them.\n", count["REALLOCATE"]+0
  if (prov > 0)
    printf "%d verdict(s) provisional: SSD or battery was never measured, so a spent one cannot be ruled out.\n", prov
  if (noage > 0)
    printf "%d machine(s) had no age: model not in the year table and first-setup date unreadable.\n", noage
}

function assess(line,   A, nf, host, ram, press, swap, swapin, freep, ssd, ssd_raw,
                        cyc, cyc_raw, cond, up, brow, ros, bg, age, disk,
                        hw, why, unknown, strained, tight, old, undersized,
                        selfinflicted, verdict) {
  nf = split(line, A, ",")

  host   = g(A,"host");            ram    = g(A,"ram_gb") + 0
  press  = g(A,"pressure");        swap   = g(A,"swap_gb") + 0
  swapin = g(A,"swapins_sec") + 0; freep  = g(A,"free_space_pct") + 0
  ssd_raw = g(A,"ssd_pct_used");   ssd    = ssd_raw + 0
  cyc_raw = g(A,"batt_cycles");    cyc    = cyc_raw + 0
  cond   = g(A,"batt_cond");       up     = g(A,"uptime_days") + 0
  brow   = g(A,"browsers_running") + 0
  ros    = g(A,"rosetta_apps");    gsub(/"/,"",ros)
  bg     = g(A,"bg_items") + 0
  age    = g(A,"age_years");       disk   = g(A,"disk_total_gb") + 0

  # --- hardware that is already spent. Nothing below can override this.
  hw = 0; why = ""; unknown = ""
  if (ssd_raw == "") unknown = "ssd"
  if (cond == "" && cyc_raw == "") unknown = unknown (unknown?"+":"") "battery"
  if (ssd_raw != "" && ssd >= 40) { hw=1; why = "SSD " ssd "% of write life used" }
  if (cond != "" && cond != "Normal") { hw=1; why = why (why?"; ":"") "battery " cond }
  if (cyc >= 800) { hw=1; why = why (why?"; ":"") cyc " battery cycles" }

  strained = (press=="critical" || swap > 6 || swapin > 50)
  tight    = (press=="warning"  || swap > 2)

  # --- age. Apple calls a product vintage at 5 years and obsolete at 7.
  old = (age != "" && age + 0 >= 7)
  if (age == "") noage++

  # --- storage that is structurally too small, as opposed to merely untidy.
  # Not upgradeable on Apple Silicon, so it is a purchase, not a chore. Rows
  # from older collections have no disk size; treat that as not-undersized
  # rather than guessing.
  undersized = (disk > 0 && disk <= 256 && freep < 25)

  selfinflicted = ""
  if (brow >= 2)   selfinflicted = brow " browser engines resident"
  if (ros != "")   selfinflicted = selfinflicted (selfinflicted?"; ":"") "Rosetta: " ros
  if (up >= 14)    selfinflicted = selfinflicted (selfinflicted?"; ":"") up " days without a restart"
  if (freep < 25 && !undersized)
                   selfinflicted = selfinflicted (selfinflicted?"; ":"") "still only " freep "% free"
  if (bg >= 15)    selfinflicted = selfinflicted (selfinflicted?"; ":"") bg " background items"

  if (hw) {
    verdict = "REPLACE"
  } else if (old && (strained || tight || undersized)) {
    verdict = "REFRESH"
    why = age " years old and still " (strained ? "paging hard" : (undersized ? "out of disk" : "tight"))
    if (selfinflicted != "") why = why "; also " selfinflicted
  } else if (strained && undersized) {
    verdict = "REALLOCATE"
    why = "only " disk "GB of disk at " freep "% free; paging with nowhere to page to"
  } else if (strained && selfinflicted != "") {
    verdict = "FIX";        why = selfinflicted
  } else if (strained) {
    verdict = "REALLOCATE"; why = "clean machine, still paging under this workload"
  } else if (tight && selfinflicted != "") {
    verdict = "FIX";        why = selfinflicted
  } else if (undersized) {
    verdict = "REALLOCATE"; why = "holding for now, but " disk "GB is undersized for this role"
  } else if (tight) {
    verdict = "KEEP";       why = "tight but holding; apply the user rules"
  } else {
    verdict = "KEEP";       why = (selfinflicted != "" ? selfinflicted : "within thresholds")
  }

  if (!hw && unknown != "") { why = why "; " unknown " unmeasured, verdict provisional"; prov++ }
  if (!hw && !old && age != "" && age + 0 >= 5)
    why = why "; " age " years old, due a refresh soon"

  count[verdict]++
  total++
  printf "%-18s %-6s %-7s %-9s %-7s %-7s %-6s %-6s %-5s %-11s %s\n", \
    substr(host,1,18), ram "GB", (disk > 0 ? disk "GB" : "n/a"), press, swap "GB", freep "%", \
    (age == "" ? "n/a" : age "y"), (ssd_raw == "" ? "n/a" : ssd "%"), (cyc_raw == "" ? "n/a" : cyc), \
    verdict, why
}
' "$CSV"
