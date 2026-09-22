# CLAUDE.md

Guidance for working in this repository.

## What this is

Two standalone bash scripts that triage **one Mac, the one they are running
on**. There is no build, no package manager, no dependency file, no test runner.
Each script is a single file that must run unmodified when copied onto someone
else's machine.

```
mac-triage-diagnose.sh   read-only measurement + one verdict for this machine
mac-triage-cleanup.sh    dry run by default, reclaims space with --apply
```

There is no fleet mode and no aggregation. A previous `mac-triage-verdict.sh`
read a CSV of many machines; it was deleted, and its decision tree now lives in
`diagnose` as a bash function reading live values. Do not reintroduce a
measure-then-parse round trip: the CSV is an *output*, never an input.

## Hard constraints

**macOS stock bash 3.2.** Not bash 5, not zsh. This rules out associative
arrays (`declare -A`), `${var,,}` / `${var^^}`, `mapfile`/`readarray`, `+=` on
arrays, and `**`. Array appends are written `ARR[$N]="x"; N=$((N+1))`
deliberately — don't "modernise" them.

**No `set -u` in `mac-triage-diagnose.sh`.** Under bash 3.2, expanding an empty
array with `-u` set aborts the script. The file uses `set -o pipefail` only, and
every variable carries its own `${var:-default}`. Keep it that way. The other
two scripts use `set -uo pipefail` and can keep it.

**No new runtime dependencies.** Stock macOS tools only. `smartctl` is the one
exception and is strictly optional — every path that uses it must degrade to a
`[WATCH]` line, never an error and never a hard exit.

**`sudo` is optional.** SSD wear is the only thing that needs root. It is
attempted with `sudo -n` (cached credential) first, prompts only on an
interactive tty in human mode, and is skipped entirely in CSV mode. Never add a
step that blocks an unattended run on a password prompt.

**Measure `/System/Volumes/Data`, never `/`.** `/` is the read-only system
volume and always reports healthy.

**The verdict reads live variables, not parsed text.** `PRESSURE`, `SWAP_GB`,
`FREE_SPACE_PCT`, `TOTAL_GB`, `AGE_YEARS` and the rest are already in scope
where the decision runs. Never serialise and re-read them — that round trip is
what the old CSV pipeline did, and a value that printed on two lines instead of
one silently corrupted a whole row.

## Safety model — do not weaken it

- `mac-triage-diagnose.sh` is **read-only**. It must never write, delete, kill a
  process, or change a setting — including running `cleanup.sh` on the user's
  behalf, however obvious the need looks. The only file it may write is the
  `--out` CSV. It only ever *reads* `~/.mac-triage/last-cleanup`.
- `mac-triage-cleanup.sh` is **dry run by default**. Everything destructive goes
  through `run "…"`, which prints `would run:` unless `--apply` was passed. Any
  new destructive step must use `run`, and must print its size first.
- Never add deletion of: Documents, Desktop, Downloads, iCloud, browser
  profiles/cookies/sessions, iOS device backups, launch agents, or Docker
  volumes. These are listed for a human to decide on, never removed.
- The test for whether something may go in a `run` line: **is it a cache, or is
  it the only copy of something?** `docker system prune --volumes` fails that
  test — a named volume is where a local database lives — so Docker is measured
  with `docker system df` and the command is printed, not run. Anything with the
  same shape belongs in the report-only section.
- Settings changes (Apple Intelligence, Login Items, iCloud optimisation,
  Chrome Memory Saver) are printed as instructions, never applied.

## Conventions

**Output.** Human mode uses three levels, and they mean different things:
`ok()` (green, informational), `warn()` (yellow `[WATCH]`, worth knowing, does
not count), `flag()` (red `[FLAG]`, crossed a threshold, counted into
`FLAG_COUNT` and the summary). Only `flag()` increments the counter. Colour is
emitted only when stdout is a tty and CSV mode is off.

**CSV mode is silent.** `say`, `sect`, `warn`, `ok`, `flag` all suppress output
when `CSV_MODE=1`. A stray bare `echo` in a measurement path corrupts the row —
if a new section prints, it must go through those helpers.

**Every field through `csv_safe`.** Free-text values (host, model, OS, battery
condition, Rosetta app list) must be passed through `csv_safe`, which strips
quotes and newlines and converts commas. Never emit a raw value.

**Empty ≠ zero.** A blank `SSD_PCT` or `CYCLES` means *not measured*, and the
verdict prints a `PROVISIONAL` line saying so rather than assuming health. Do
not default unmeasured hardware fields to `0` — that would silently read as
"healthy" and suppress a `REPLACE`.

**Parsing macOS output defensively.** Labels move between macOS releases and
units are not stable. Existing examples worth copying: `vm.swapusage` is parsed
for a `G`/`M`/`K` suffix rather than assumed to be `M`; `kern.boottime` is
anchored on `{ sec =` and stripped of leading zeros because zero-padded
microseconds are otherwise read as an invalid octal literal; battery cycle count
falls back from `system_profiler` to `ioreg`. New parsers should have a fallback
or a `[WATCH]` line, not an assumption.

**Comments explain *why*, not *what*.** The existing comments document macOS
quirks and the reasoning behind a threshold. Keep that register; don't add
narration of obvious code.

**Tone of user-facing strings.** Plain, specific, and about consequences, not
severity words — "Below this macOS cannot grow swap cleanly and everything
degrades at once", not "CRITICAL: low disk". Every flag should tell the reader
what it means for them.

## Thresholds

Currently inline literals
(swap 2/6 GB, 50 swap-ins/sec, 15 %/25 % free, SSD 20/40 %, 800 cycles, 14 days
uptime, 15 background items, 2 browsers, 5/7 years of age, 256 GB volume). Most
now appear twice inside `mac-triage-diagnose.sh`: once in the `flag`/`warn` lines
and once in the verdict block. **Change both, and the README threshold table.**

The age thresholds follow Apple's own definitions — vintage at 5 years, obsolete
at 7 — rather than numbers picked arbitrarily. Say so in any comment that
changes them.

## The CSV

`--csv` and `--out` are an *export* — a record of one run on one machine,
verdict included — not an interchange format and not an input to anything.
Nothing reads it back, so there is no compatibility burden: add, reorder or
rename columns as the measurements change.

To add one: measure it with a `${var:-}` default so an unmeasurable value gives
an empty field rather than a broken row, then append the name to `HEADER` **and**
the value to `ROW`, same position, same order. The `printf` format string has one
`%s` per column; count them. Empty means *not measured*, and never defaults to
`0` — that would read as "healthy".

Collected CSVs are gitignored: every row holds a real computer name, username
and battery health.

## Machine age

Two independent signals, neither complete on its own:

- **`model_year`** comes from the `model_year()` case statement, a `hw.model`
  lookup table. It exists because Apple Silicon serial numbers are randomised
  and carry no manufacture date, so there is nothing to parse. **An unknown
  identifier must return empty.** A guessed year silently produces a wrong
  verdict; an empty one produces an honest `n/a`. Add new identifiers as they
  ship.
- **`in_service`** is the birth time of `/var/db/.AppleSetupDone`
  (`stat -f '%SB' -t '%Y-%m-%d'`). Measured rather than tabulated, but it resets
  when a machine is wiped and rebuilt, so `model_year` wins when both exist.

`age_years` is derived from whichever was used, and `AGE_BASIS` records which,
so the flag text can say so out loud.

## Disk size vs disk fullness

`free_space_pct` alone cannot distinguish a machine full of junk from a machine
whose disk is simply too small, so `disk_total_gb` is recorded as well. In the
verdict, `undersized` (volume ≤ 256 GB and under 25 % free) **suppresses the
"still only N% free" self-inflicted item**, because on a 256 GB machine that is
a structural limit, not a housekeeping failure, and storage is not upgradeable
on Apple Silicon. Keep that suppression if you touch the blame logic — without
it, users get sent to delete files that cannot fix the problem.

## The verdict

One machine, one answer, in `mac-triage-diagnose.sh`. Ordering is the design:

1. **Spent hardware** (SSD ≥ 40 %, battery not `Normal` or ≥ 800 cycles, any
   kernel panic) → `REPLACE`, short-circuiting everything. Cleanup changes none
   of it, so making the user tidy up first would be dishonest.
2. **Cleanup state** → `RESTART FIRST` / `CLEAN FIRST`. See below.
3. **Age** → `REFRESH`, before habits, because on a nine-year-old machine fixing
   the habits is a delaying tactic.
4. Then swap-vs-disk, habits, and workload fit, cheapest true explanation first.

Every branch sets three variables, and all three are mandatory: `VERDICT` (the
label), `WHY` (what was measured, in consequences rather than severity words)
and `NEXT` (the literal next command or action). A verdict with no `NEXT` is a
bug — the person running this wants to know what to do, not how to feel.

Float comparisons go through `gt()`, which wraps the `awk -v ... BEGIN{exit !(...)}`
idiom, because bash 3.2 cannot compare `2.59 > 2` on its own.

## Cleanup state, and why it gates the verdict

`cleanup.sh --apply` writes a Unix timestamp to `~/.mac-triage/last-cleanup`.
`diagnose` reads it and derives `CLEAN_STATE`:

| Value | Condition | Verdict effect |
|---|---|---|
| `never` | no state file | `CLEAN FIRST`, if anything is worth reclaiming |
| `stale` | over 30 days old | treated as `never`; an old cleanup says nothing about today |
| `no-restart` | timestamp is *after* boot time | `RESTART FIRST` |
| `done` | cleaned, then rebooted | the machine is judged properly |

The restart check is the important one. Swap and leaked memory survive until a
reboot, so a machine cleaned but not restarted still reports the old load, and
judging it then produces a `REPLACE` that a reboot would have disproved.

`CLEAN FIRST` is also gated on there being something to reclaim — `RECLAIM_GB`
over 2, or 3+ local snapshots — measured by `du` over **exactly the paths
`cleanup.sh` deletes**. If you add a path to one, add it to the other, or the
diagnostic promises space the cleanup cannot deliver.

**Never make `diagnose` run the cleanup.** It is read-only; that is the whole
contract. It prints the command. The one-touch path is `cleanup --apply
--recheck`, which keeps the destructive step in the script where the user
already typed `--apply`.

## Testing

There is no harness. Verify by running:

```bash
bash -n mac-triage-diagnose.sh                    # syntax, both files
./mac-triage-diagnose.sh --quick                  # report + verdict, 5s window
./mac-triage-diagnose.sh --csv --header | column -t -s,
./mac-triage-cleanup.sh                           # MUST be a dry run
```

Check specifically that:
- the CSV row has exactly as many fields as the header, **and is one line** —
  `awk -F, 'NR==1{print NF} NR==2{print NF}' out.csv`. An embedded newline from a
  command that prints two lines (`grep -c` with a `|| echo 0` fallback did
  exactly this) splits the row silently;
- `--csv` prints nothing but the row (and the header, with `--header`);
- the cleanup script without `--apply` prints only `would run:` lines **and
  writes no state file** — a dry run that records a cleanup would make the next
  verdict lie;
- the scripts still work with `smartctl` absent and without `sudo`.

### Testing the verdict without the hardware

Most branches are unreachable on whatever Mac you are sitting at. Extract the
decision block and drive it with synthetic values instead:

```bash
python3 -c 's=open("mac-triage-diagnose.sh").read();
a=s.index("# ---- verdict"[:20]); b=s.index("# ---- summary"[:20]);
open("/tmp/v.sh","w").write(s[a:b])'

( PRESSURE=critical SWAP_GB=8 FREE_SPACE_PCT=9 TOTAL_GB=256 RAM_GB=8 \
  BROWSERS=1 ROSETTA_APPS="" UP_DAYS=1 THIRD_PARTY=5 SNAPS=0 RECLAIM_GB=0 \
  AGE_YEARS=3 SSD_PCT=5 CYCLES=100 COND=Normal PANICS=0 CLEAN_STATE=done
  . /tmp/v.sh; echo "$VERDICT | $WHY" )
```

Every verdict must be reachable this way, including each `CLEAN_STATE` value.
The state block is separately extractable and worth testing against a sandboxed
`HOME` so you never write to your own `~/.mac-triage`:

```bash
HOME=/tmp/fakehome ./mac-triage-diagnose.sh --quick
```

## Git

Scripts must stay executable: `chmod +x` and `git update-index --chmod=+x` on
any new one. `.gitattributes` enforces LF normalisation.

**Never commit collected data.** `*.csv` is gitignored because every row holds a
real computer name, username, hardware identifier and battery health. Fixtures
for testing verdict branches belong in the scratch directory, not the repo; if
one ever needs to be committed, it must use invented hostnames and be named
something other than `.csv`.
