# mac-diagnostics

Two shell scripts you run on a slow Mac. The first measures it and ends with
**one verdict for that machine**. The second reclaims what can be reclaimed
without buying anything.

```bash
./mac-triage-diagnose.sh
```

```
VERDICT: OUT OF ROOM

  7.4 GB of swap on a volume with only 9% free. macOS is paging with
  nowhere to page to, which is why everything stalls at once rather than
  one app being slow.

Next:
  Free disk space first — that alone usually fixes the stalling. If it
  comes back, this workload needs more than 8 GB.
```

Built around the failure mode behind most "my Mac is slow" complaints on
small-RAM Apple Silicon laptops: **memory pressure forcing swap onto a disk that
has no room for it.** An 8 GB MacBook Air with 6 % free storage and two browsers
open is not a broken machine. It is a machine being asked to do something it
cannot do, and new hardware does not fix the habit.

| Script | Changes anything? | Answers |
|---|---|---|
| `mac-triage-diagnose.sh` | **No. Read-only.** | What is wrong with this Mac, and what should I do about it? |
| `mac-triage-cleanup.sh` | Only with `--apply` | How much of it goes away without spending money? |

---

## The loop

The diagnostic will not hand down a verdict on a machine that has never been
given a fair chance. That is the point of it.

```bash
./mac-triage-diagnose.sh            # 1. measure. Ends with a verdict.
```

If the verdict is `CLEAN FIRST`:

```bash
./mac-triage-cleanup.sh             # 2. dry run — see what it would take
./mac-triage-cleanup.sh --apply     # 3. take it
#                                     4. restart the Mac
./mac-triage-diagnose.sh            # 5. now the verdict means something
```

Steps 3–5 in one go, if you already know you want it:

```bash
./mac-triage-cleanup.sh --apply --recheck
```

**Run the diagnostic during real work, not on a freshly booted idle machine.** A
Mac that has just rebooted with nothing open looks healthy no matter how badly
it performs at 3 pm with fourteen tabs and a video call.

### Why the restart matters

`cleanup.sh --apply` records when it ran, in `~/.mac-triage/last-cleanup`. The
diagnostic reads that and compares it against boot time, so it can tell apart
three situations that look identical in the numbers alone:

| State | What the diagnostic does |
|---|---|
| Never cleaned up | Offers `CLEAN FIRST` if there is anything worth reclaiming |
| Cleaned up, not restarted | `RESTART FIRST` — swap survives until you reboot, so the numbers still describe the old load |
| Cleaned up and restarted | Judges the machine properly |

Spent hardware skips all of this. A battery at 998 cycles is a battery at 998
cycles whether or not you emptied the Trash, so that returns `REPLACE`
immediately.

---

## The verdicts

| Verdict | Meaning | Costs |
|---|---|---|
| `KEEP` | Within thresholds. Nothing here justifies spending money. | Nothing |
| `CLEAN FIRST` | Struggling, but full of reclaimable rubbish. Not judgeable yet. | Nothing |
| `RESTART FIRST` | Cleaned up but not rebooted. The numbers are stale. | Nothing |
| `OUT OF ROOM` | Swapping onto a nearly-full disk. The two numbers together are the problem. | Nothing |
| `FIX` | Out of RAM, but self-inflicted: two browsers, Rosetta builds, weeks without a restart. | Nothing |
| `REFRESH` | 7+ years old and still struggling after a cleanup. Tuning buys weeks, not years. | Budget it |
| `REALLOCATE` | Clean machine, sensible habits, still doesn't fit the work. | Swap machines |
| `REPLACE` | SSD or battery is spent, or the kernel is panicking. Workload is not the issue. | Buy now |

They are tested in that order of cheapness, with two exceptions that jump the
queue: **spent hardware first**, because nothing fixes it, and **age next**,
because on a nine-year-old machine fixing the habits is a delaying tactic.

If SSD wear or battery health could not be read, the verdict still prints, with
a line saying so. An unmeasured spent SSD cannot be ruled out, and the script
says that rather than quietly assuming health.

---

## `mac-triage-diagnose.sh` — read-only

Changes nothing. No `sudo` needed except to read SSD wear, which it skips rather
than demand.

```
./mac-triage-diagnose.sh              measure and give a verdict
./mac-triage-diagnose.sh --quick      5s sampling window instead of 20s
./mac-triage-diagnose.sh --csv        one CSV row instead of a report
./mac-triage-diagnose.sh --out log.csv  append a row to a file, keeping a history
./mac-triage-diagnose.sh --help
```

### What it looks at, and why

**Machine** — name, model, chip, macOS, RAM, uptime, and age. Uptime matters:
swap and leaked memory do not come back on their own, so 14+ days without a
restart is flagged before anything else is believed.

Age comes from two independent signals, because neither is complete alone:

- `model_year` — how old the hardware *design* is, from a `hw.model` lookup
  table (`Mac14,2` → 2022). A table is needed because Apple Silicon serial
  numbers are randomised and carry no manufacture date. An unknown identifier
  returns empty; a guessed year is worse than none.
- `in_service` — when this Mac was first set up, from the birth time of
  `/var/db/.AppleSetupDone`. Measured rather than tabulated, but it resets if
  the machine is wiped and rebuilt, so `model_year` wins when both exist.

Following Apple's own clock: **vintage at 5 years** (noted), **obsolete at 7**
(drives the `REFRESH` verdict).

**Memory** — the kernel's own pressure level
(`kern.memorystatus_vm_pressure_level`), free percentage, swap in use, and
**swap-ins per second sampled over a live window**. That last number
distinguishes *allocated* swap from *active thrashing*. 8 GB of swap sitting
idle is untidy; 50 pages/second being read back is the slowness being described.

**Apps in the pile** — which browsers and assistants are resident at once, how
many Chrome processes exist, and whether any installed app is an Intel-only
build under Rosetta (via `lipo -archs`). Two browser engines on 8 GB is, alone,
enough to explain a slow machine.

**Disk** — measured on `/System/Volumes/Data`, never `/`. `/` is the read-only
system volume and always looks fine. Counts local Time Machine snapshots, which
Finder reports as "purgeable" while they very much occupy the disk. **Below 15 %
free, macOS cannot grow swap cleanly and everything degrades at once.**

Total volume size is recorded too, not just free space, because the two mean
different things. A 256 GB volume still short of room after a cleanup is
undersized for the work rather than untidy, and storage is not upgradeable on
Apple Silicon.

**Swap against disk together.** This is the pair that produces `OUT OF ROOM`,
and it is invisible if you read either number alone: 2.6 GB of swap with 74 GB
free is fine and can be ignored; 8 GB of swap with 9 GB free is the failure mode.

**SSD wear** — `smartctl -a /dev/disk0` when `smartmontools` is installed
(`brew install smartmontools`). Years of swapping write through a finite
endurance budget; "Percentage Used" at 40 % is a hardware fact, not a habit.
Needs root, so it tries a cached `sudo -n` credential first and skips silently
in CSV mode rather than blocking on a password prompt.

**Background load** — third-party launch agents and daemons, Apple Intelligence
model assets (over 1 GB on a machine that cannot use them well), and the usual
stuck suspects: `mds_stores`, `mdworker`, `photoanalysisd`, `bird`, `cloudd`.

**Battery and stability** — cycle count, condition and maximum capacity (from
`system_profiler`, falling back to `ioreg` because the label moves between macOS
releases), plus kernel panic reports in the last 30 days. A panic is hardware or
a bad driver, never workload.

**Reclaimable space** — how much the cleanup script would actually free, counted
only over the paths it genuinely deletes, so the number is a promise it can keep.

### Thresholds

| Signal | `[WATCH]` | `[FLAG]` |
|---|---|---|
| Uptime | — | ≥ 14 days |
| Machine age | 5–6 years (vintage) | ≥ 7 years (obsolete) |
| Memory pressure | `warning` | `critical` |
| Swap in use | > 2 GB | > 6 GB |
| Swap-ins/sec | — | > 50 |
| Free space on Data | < 25 % | < 15 % |
| Volume ≤ 256 GB and < 25 % free | undersized for the work | — |
| Local TM snapshots | ≥ 3 | — |
| SSD life used | 20–39 % | ≥ 40 % |
| Battery cycles | ≥ 800 | — |
| Battery condition | — | anything but `Normal` |
| Third-party launch items | — | ≥ 15 |
| Browser engines resident | — | ≥ 2 |
| Rosetta builds | — | any |
| Kernel panics (30d) | — | any |

### Keeping a history

`--csv` prints the whole run — measurements *and* the verdict — as one row.
`--out log.csv` appends it, writing the header if the file is new. Useful for
watching one machine over months, or for collecting rows from several machines
if you want to, though nothing in these scripts aggregates them for you.

```
date, host, user, model, ram_gb, os, uptime_days, pressure, free_mem_pct,
swap_gb, swapins_sec, free_space_pct, free_gb, snapshots, ssd_pct_used,
batt_cycles, batt_cond, bg_items, browsers_running, rosetta_apps, flags,
model_year, age_years, in_service, disk_total_gb, verdict, why,
cleanup_state, reclaimable_gb
```

An empty field means *not measured*, which is not the same as zero.

CSV output is gitignored — every row holds a real computer name, username and
battery health.

---

## `mac-triage-cleanup.sh` — dry run by default

```
./mac-triage-cleanup.sh                     show what would be reclaimed, change nothing
./mac-triage-cleanup.sh --apply             do it
./mac-triage-cleanup.sh --apply --dev       also clear developer caches
./mac-triage-cleanup.sh --apply --recheck   ...then re-run the diagnostic
```

Every destructive step prints its size before it runs, and prints
`would run: …` instead of running in dry-run mode.

### Rules it will not break

- Never deletes anything in Documents, Desktop, Downloads or iCloud.
- Never deletes a launch agent. It lists them; a human decides.
- Never touches browser profiles, cookies or sessions.
- Never deletes an iOS device backup — it prints the size and says out loud that
  this is the only copy of someone's phone.

### What it does clear

1. **Local Time Machine snapshots** via `tmutil thinlocalsnapshots` — usually
   the single largest hidden consumer. Needs root, and says so.
2. **Application caches** — Xcode, Playwright, Homebrew, pip, Slack Service
   Worker, VS Code extension VSIXs.
3. **Developer caches**, only with `--dev` — DerivedData, iOS DeviceSupport,
   CoreSimulator caches, and `brew` / `npm` / `yarn` / `pnpm` prunes.
4. **Trash.**

### What it only reports

The 12 largest items in the home folder, Downloads over 200 MB, every
third-party launch agent and daemon, and — with `--dev` — what Docker is
holding. These are decisions, not cleanups.

**Docker is never pruned**, only measured. `docker system prune --volumes`
removes named volumes, and a named volume is where a local database keeps its
data, not a cache. The script prints `docker system df` and the command to
reclaim images and build cache (`docker system prune -af`, no `--volumes`), and
leaves you to run it.

### And what it refuses to do for you

It ends by printing the settings that matter more than anything it just deleted,
because a script should not silently flip them:

- Apple Intelligence & Siri — off on 8 GB machines
- Login Items — cut to the minimum
- iCloud Drive and Photos — Optimise Mac Storage on
- Chrome — Memory Saver on
- One browser. Chrome or Atlas, not both.

---

## Requirements

- macOS on Apple Silicon (works on Intel; the memory-pressure reasoning is tuned
  for Apple Silicon).
- Stock `bash` 3.2 — the scripts are written for it deliberately. No Homebrew
  bash, no `zsh`-isms.
- Everything used is stock macOS except `smartctl`
  (`brew install smartmontools`), which is optional and only adds SSD wear.
- `sudo` is optional, for SSD wear and for thinning snapshots.

---

## Known gaps

- **The model-year table needs maintaining.** New `hw.model` identifiers must be
  added to `model_year()` as they ship. An unknown model falls back to the
  first-setup date; if that is unreadable too, the machine is judged without an
  age rather than with a guessed one.
- **No macOS-support horizon.** Whether a model still takes the current macOS is
  often the real deciding factor in a replacement, and is not checked — only age.
- **Thresholds are inline literals**, documented in the table above. Change one,
  change the table.
- **The reclaimable-space estimate runs `du`** over a handful of cache paths,
  which adds a second or two on machines with very large caches.

---

## Licence

MIT. See `LICENSE`.
