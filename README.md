# mac-diagnostics

Three shell scripts that decide, with evidence, whether a slow Mac needs a
cleanup, a different owner, or a replacement — and record the answer for a
whole fleet in a spreadsheet.

Built around one specific failure mode that accounts for most "my Mac is slow"
tickets on small-RAM Apple Silicon laptops: **memory pressure forcing swap onto
a disk that has no room for it.** An 8 GB MacBook Air with 6 % free storage and
two browsers open is not a broken machine. It is a machine being asked to do
something it cannot do, and no amount of new hardware fixes the habit.

The scripts separate the three things that usually get conflated:

| Script | Changes anything? | Answers |
|---|---|---|
| `mac-triage-diagnose.sh` | **No. Read-only.** | What is actually happening on this machine right now? |
| `mac-triage-cleanup.sh` | Only with `--apply` | How much of it is reclaimable without buying anything? |
| `mac-triage-verdict.sh` | No. Reads a CSV. | Across the fleet, which machines genuinely need money spent? |

---

## Quick start

One machine, one person, right now:

```bash
./mac-triage-diagnose.sh            # read-only report, ~20s
./mac-triage-cleanup.sh             # dry run: shows what it would reclaim
./mac-triage-cleanup.sh --apply     # actually reclaim it
# restart the Mac
./mac-triage-diagnose.sh            # confirm the numbers moved
```

A fleet:

```bash
# on the first machine
./mac-triage-diagnose.sh --csv --header >  fleet.csv
# on every machine after that
./mac-triage-diagnose.sh --csv          >> fleet.csv
#   (or, appending safely from each machine to a shared file:)
./mac-triage-diagnose.sh --out fleet.csv

# once the rows are collected — after cleanup and a restart
./mac-triage-verdict.sh fleet.csv
```

**Run the diagnostic during real work, not on a freshly booted idle machine.**
A Mac that has just rebooted with nothing open will look healthy no matter how
badly it performs at 3 pm with fourteen tabs and a video call.

---

## `mac-triage-diagnose.sh` — read-only

Changes nothing. No `sudo` required except to read SSD wear, which it will skip
rather than demand.

```
./mac-triage-diagnose.sh              human-readable report
./mac-triage-diagnose.sh --quick      5s sampling window instead of 20s
./mac-triage-diagnose.sh --csv        one CSV row, for the audit sheet
./mac-triage-diagnose.sh --csv --header
./mac-triage-diagnose.sh --out fleet.csv   append a row; writes the header if the file is new
./mac-triage-diagnose.sh --help
```

### What it looks at, and why

**Machine** — name, model, chip, macOS, RAM, uptime. Uptime matters: swap and
leaked memory do not come back on their own, so 14+ days without a restart is
flagged before anything else is believed.

**Age**, from two independent signals, because neither is complete alone:

- `model_year` — how old the hardware *design* is, from a `hw.model` lookup
  table (`Mac14,2` → 2022). A table is needed because Apple Silicon serial
  numbers are randomised and carry no manufacture date. An identifier that is
  not in the table returns empty; a guessed year would be worse than none.
- `in_service` — when this machine was first set up, read from the birth time of
  `/var/db/.AppleSetupDone`. A measured fact rather than a table, but it resets
  if the machine is ever wiped and rebuilt.

Age drives refresh planning, following Apple's own clock: **vintage at 5 years**
(`[WATCH]`, plan for it), **obsolete at 7** (`[FLAG]`, budget a replacement
rather than tuning this one).

**Memory** — the kernel's own pressure level
(`kern.memorystatus_vm_pressure_level`), free percentage, swap in use, and
**swap-ins per second sampled over a live window**. That last number is the one
that distinguishes *allocated* swap from *active thrashing*. 8 GB of swap
sitting idle is untidy; 50 pages/second being read back is the slowness the user
is describing.

**Apps in the pile** — which browsers and assistants are resident at once, how
many Chrome processes exist, and whether any installed app is an Intel-only
build running under Rosetta (checked with `lipo -archs`). Two browser engines on
8 GB is, on its own, enough to explain a slow machine.

**Disk** — measured on `/System/Volumes/Data`, not `/`. `/` is the read-only
system volume and always looks fine. Also counts local Time Machine snapshots,
which Finder reports as "purgeable" while they very much occupy the disk.
**Below 15 % free, macOS cannot grow swap cleanly and everything degrades at
once.** The target is 25 % free before any judgement about the machine is
trusted.

Total volume size is recorded too, not just free space, because the two mean
different things. A 256 GB volume still short of room after a cleanup is not
untidy — it is undersized for the role, and storage is not upgradeable on Apple
Silicon. That belongs in the refresh plan, not in a list of files to delete.

**SSD wear** — `smartctl -a /dev/disk0` if `smartmontools` is installed
(`brew install smartmontools`). Years of swapping write through a finite
endurance budget; "Percentage Used" at 40 % is a hardware fact, not a habit.
Requires root, so it is attempted with a cached `sudo -n` credential first and
skipped silently in CSV mode rather than blocking a fleet run.

**Background load** — third-party launch agents and daemons, Apple Intelligence
model assets (over 1 GB on a machine that cannot use them well), and the usual
stuck suspects: `mds_stores`, `mdworker`, `photoanalysisd`, `bird`, `cloudd`.

**Battery and stability** — cycle count, condition, maximum capacity (read from
`system_profiler`, falling back to `ioreg` because the label moves between
macOS releases), plus any kernel panic reports in the last 30 days. A panic is
hardware or a bad driver, never workload.

### Thresholds it flags on

| Signal | `[WATCH]` | `[FLAG]` |
|---|---|---|
| Uptime | — | ≥ 14 days |
| Machine age | 5–6 years (vintage) | ≥ 7 years (obsolete) |
| Memory pressure | `warning` | `critical` |
| Swap in use | > 2 GB | > 6 GB |
| Swap-ins/sec | — | > 50 |
| Free space on Data | < 25 % | < 15 % |
| Volume ≤ 256 GB and < 25 % free | undersized for the role | — |
| Local TM snapshots | ≥ 3 | — |
| SSD life used | 20–39 % | ≥ 40 % |
| Battery cycles | ≥ 800 | — |
| Battery condition | — | anything but `Normal` |
| Third-party launch items | — | ≥ 15 |
| Browser engines resident | — | ≥ 2 |
| Rosetta builds | — | any |
| Kernel panics (30d) | — | any |

### CSV columns

```
date, host, user, model, ram_gb, os, uptime_days, pressure, free_mem_pct,
swap_gb, swapins_sec, free_space_pct, free_gb, snapshots, ssd_pct_used,
batt_cycles, batt_cond, bg_items, browsers_running, rosetta_apps, flags,
model_year, age_years, in_service, disk_total_gb
```

Empty means *not measured*, which is not the same as zero — the verdict script
treats `ssd_pct_used` and `batt_cycles` blanks as unknowns and marks the verdict
provisional rather than assuming health.

Columns are only ever appended, never inserted, so a `fleet.csv` collected by an
older version still reads correctly. `mac-triage-verdict.sh` looks columns up by
name and treats any it does not find as unmeasured — a pre-age CSV simply shows
`n/a` under AGE and DISK and gets the verdict it would have got before.

---

## `mac-triage-cleanup.sh` — dry run by default

```
./mac-triage-cleanup.sh                 show what would be reclaimed, change nothing
./mac-triage-cleanup.sh --apply         do it
./mac-triage-cleanup.sh --apply --dev   also clear developer caches
```

Every destructive step prints its size before it runs, and prints
`would run: …` instead of running in dry-run mode.

### Rules it will not break

- Never deletes anything in Documents, Desktop, Downloads or iCloud.
- Never deletes a launch agent. It lists them; a human decides.
- Never touches browser profiles, cookies or sessions.
- Never deletes an iOS device backup — it prints the size and says out loud
  that this is the only copy of someone's phone.

### What it does clear

1. **Local Time Machine snapshots** via `tmutil thinlocalsnapshots` — usually
   the single largest hidden consumer.
2. **Application caches** — Xcode, Playwright, Homebrew, pip, Slack Service
   Worker, VS Code extension VSIXs.
3. **Developer caches**, only with `--dev` — DerivedData, iOS DeviceSupport,
   CoreSimulator caches, and `brew` / `npm` / `yarn` / `pnpm` / `docker` prunes.
4. **Trash.**

### What it only reports

The 12 largest items in the home folder, Downloads over 200 MB, and every
third-party launch agent and daemon. These are decisions, not cleanups.

### And what it refuses to do for you

It ends by printing the settings changes that matter more than anything it just
deleted, because a script should not silently flip them:

- Apple Intelligence & Siri — off on 8 GB machines
- Login Items — cut to the minimum
- iCloud Drive and Photos — Optimise Mac Storage on
- Chrome — Memory Saver on
- One browser. Chrome or Atlas, not both.

---

## `mac-triage-verdict.sh` — the decision

```
./mac-triage-verdict.sh fleet.csv
```

Reads the collected rows and prints one line per machine plus a fleet summary.

**Run it on rows collected _after_ cleanup and a restart.** Rows from a machine
that was never cleaned will overstate the case for replacement, which is exactly
the error this tool exists to prevent.

If a host appears more than once, **only its newest row is assessed.** Collecting
twice from the same machine must not inflate the fleet count, or the percentage
at the bottom of the report — the number the whole exercise exists to produce
— is wrong.

### The five outcomes

| Verdict | Meaning | Spend |
|---|---|---|
| `KEEP` | Within thresholds. Nothing to do. | None |
| `FIX` | The load is self-inflicted: two browsers, Rosetta builds, weeks without a restart, disk still full, fifteen background items. | None |
| `REALLOCATE` | Hardware is sound, but this machine does not fit this person's work. Swap with someone whose work is lighter. | None |
| `REFRESH` | Seven years or older and still struggling. Cleanup buys little time here. Plan and budget it; it is not an emergency. | Budget |
| `REPLACE` | The SSD or the battery is spent. Workload is not the issue. | Buy now |

### How it decides

1. **Hardware first.** SSD ≥ 40 % of write life used, battery condition not
   `Normal`, or ≥ 800 cycles → `REPLACE`. Nothing else can override this,
   because no cleanup fixes it.
2. Otherwise, is the machine **strained** (`critical` pressure, > 6 GB swap, or
   > 50 swap-ins/sec), merely **tight** (`warning` pressure, > 2 GB swap), or
   **undersized** (volume ≤ 256 GB and under 25 % free)?
3. **Old and struggling** — 7+ years and strained, tight or undersized →
   `REFRESH`. Age is checked before habits, because on a machine this old, fixing
   the habits is a delaying tactic.
4. Strained *and* undersized → `REALLOCATE`: it is paging with nowhere to page
   to, and the disk cannot be enlarged.
5. Strained *and* self-inflicted → `FIX`. Strained on a clean machine →
   `REALLOCATE`.
6. Tight and self-inflicted → `FIX`. Undersized but otherwise holding →
   `REALLOCATE`. Tight and clean → `KEEP`.
7. If SSD wear or battery data was never captured, the verdict is printed with
   `verdict provisional` and counted in the summary — an unmeasured spent SSD
   cannot be ruled out. A machine at 5–6 years carries a `due a refresh soon`
   note without changing its verdict.

Note the interaction between age, disk size and blame: **"still only 9 % free" is
only counted as self-inflicted when the volume is bigger than 256 GB.** On a
256 GB machine that is a structural limit, and calling it a user's fault sends
them off to delete files that will not fix anything.

### Example

```
MACHINE            RAM    DISK    PRESSURE  SWAP    FREE    AGE    SSD    BATT  VERDICT     WHY
spent-ssd          8GB    512GB   warning   3GB     40%     4y     52%    220   REPLACE     SSD 52% of write life used
old-tired          16GB   512GB   critical  7.5GB   30%     9y     12%    300   REFRESH     9 years old and still paging hard
self-harm          8GB    512GB   critical  8.1GB   35%     4y     4%     120   FIX         3 browser engines resident; Rosetta: ...
small-disk         8GB    256GB   critical  6.5GB   9%      4y     2%     80    REALLOCATE  only 256GB of disk at 9% free; paging
clean-strain       8GB    512GB   critical  7.2GB   45%     4y     3%     90    REALLOCATE  clean machine, still paging
all-good           24GB   1024GB  normal    0GB     70%     1y     0%     30    KEEP        within thresholds
```

The summary ends with the number that justifies the whole exercise: *machines
that need buying now, out of machines assessed*, with the refresh budget and the
reallocation list kept separate from it.

---

## Requirements

- macOS on Apple Silicon (works on Intel; the memory-pressure reasoning is tuned
  for Apple Silicon).
- Stock `bash` 3.2 — the scripts are written for it deliberately. No Homebrew
  bash, no `zsh`-isms.
- Everything used is stock macOS except `smartctl`
  (`brew install smartmontools`), which is optional and only adds SSD wear.
- `sudo` is optional, and only for SSD wear.

---

## Known gaps

Honest list of what these scripts do not yet do:

- **The model-year table needs maintaining.** New `hw.model` identifiers have to
  be added to `model_year()` in `mac-triage-diagnose.sh` as they ship. An unknown
  model falls back to the first-setup date, and if that is unreadable too the
  machine is assessed without an age rather than with a guessed one.
- **`in_service` resets on a wipe.** A rebuilt machine looks new by that signal.
  The model year is the more reliable of the two and is preferred when known.
- **No macOS-support horizon.** Whether a model still takes the current macOS is
  often the real deciding factor in a refresh plan, and is not checked — only
  age is.
- **Thresholds are inline literals**, repeated between the diagnostic and the
  verdict, so the two can drift apart.
- **Cleanup's `--dev` includes `docker system prune --volumes`**, which removes
  named volumes — that is data, not cache. It should be behind its own flag.
- **`tmutil thinlocalsnapshots` usually needs root**, and the script does not say
  so; without `sudo` it can appear to succeed while reclaiming nothing.
- **The `flags` column is collected but never read** by the verdict script.

## Licence

MIT. See `LICENSE`.
