# CLAUDE.md

Guidance for working in this repository.

## What this is

Three standalone bash scripts that triage slow Macs and produce a fleet-level
buy/don't-buy decision. There is no build, no package manager, no dependency
file, no test runner. Each script is a single file that must run unmodified when
copied onto someone else's machine.

```
mac-triage-diagnose.sh   read-only measurement  →  human report or one CSV row
mac-triage-cleanup.sh    dry run by default     →  reclaims space with --apply
mac-triage-verdict.sh    reads the CSV          →  KEEP / FIX / REALLOCATE /
                                                   REFRESH / REPLACE
```

The data contract between them is the CSV. `diagnose --csv` emits it,
`verdict` consumes it by column name. Changing one without the other breaks the
pipeline silently.

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
step that blocks a fleet run on a password prompt.

**Measure `/System/Volumes/Data`, never `/`.** `/` is the read-only system
volume and always reports healthy.

## Safety model — do not weaken it

- `mac-triage-diagnose.sh` is **read-only**. It must never write, delete, kill a
  process, or change a setting. The only file it may write is the `--out` CSV.
- `mac-triage-cleanup.sh` is **dry run by default**. Everything destructive goes
  through `run "…"`, which prints `would run:` unless `--apply` was passed. Any
  new destructive step must use `run`, and must print its size first.
- Never add deletion of: Documents, Desktop, Downloads, iCloud, browser
  profiles/cookies/sessions, iOS device backups, or launch agents. These are
  listed for a human to decide on, never removed.
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

**Empty ≠ zero in the CSV.** A blank `ssd_pct_used` or `batt_cycles` means *not
measured*, and `mac-triage-verdict.sh` marks such verdicts provisional. Do not
default unmeasured hardware fields to `0` — that would silently read as
"healthy".

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

Currently inline literals, duplicated between the diagnostic and the verdict
(swap 2/6 GB, 50 swap-ins/sec, 15 %/25 % free, SSD 20/40 %, 800 cycles, 14 days
uptime, 15 background items, 2 browsers, 5/7 years of age, 256 GB volume). They
are documented in the threshold table in `README.md`. **If you change one, change
it in `mac-triage-diagnose.sh`, in `mac-triage-verdict.sh`, and in the README
table**, or the two scripts will disagree about the same machine.

The age thresholds follow Apple's own definitions — vintage at 5 years, obsolete
at 7 — rather than a number picked for the fleet. Say so in any comment that
changes them.

## Changing the CSV schema

The schema is a contract. To add a column:

1. Add the measurement in `mac-triage-diagnose.sh`, with a `${var:-}` default so
   an unmeasurable value produces an empty field, not a broken row.
2. Append the name to `HEADER` **and** the value to `ROW` — same position,
   same order. The `printf` format string has one `%s` per column; count them.
3. In `mac-triage-verdict.sh`, read it via `col["name"]`, not by index.
4. **Append, never insert.** Existing `fleet.csv` files in the wild have the old
   column order; appending keeps them readable.

`awk`'s `col[]` lookup returns an empty index for a missing header, which
resolves to `$0` — a silently wrong value rather than an error. That is why
`mac-triage-verdict.sh` reads every field through `g(A, "name")`, which returns
empty for an absent column, and validates `host`/`date` in the header rule.
**Read new columns through `g()` too**; never index `A[]` directly.

This is what keeps old `fleet.csv` files working: a pre-age CSV has no
`age_years` or `disk_total_gb`, `g()` returns empty for both, and the machine is
assessed exactly as it would have been before those columns existed.

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

## Deduplication

`mac-triage-verdict.sh` keeps only the newest row per `host` (string compare on
the `YYYY-MM-DD` `date` column), in first-seen order, and reports how many rows
it collapsed. Rows are therefore buffered and assessed in `END`, not streamed.
Anything added to the per-row rule must preserve this; double-counting a host
inflates the "machines that need buying" percentage, which is the one number the
whole toolkit exists to produce.

## Testing

There is no harness. Verify by running:

```bash
bash -n mac-triage-diagnose.sh                    # syntax, all three files
./mac-triage-diagnose.sh --quick                  # human output, 5s window
./mac-triage-diagnose.sh --csv --header | column -t -s,
./mac-triage-cleanup.sh                           # MUST be a dry run
./mac-triage-verdict.sh fleet.csv
```

Check specifically that:
- the CSV row has exactly as many fields as the header, **and is one line** —
  `awk -F, 'NR==1{print NF} NR==2{print NF}' fleet.csv`. An embedded newline from
  a command that prints two lines (`grep -c` with a `|| echo 0` fallback did
  exactly this) splits the row silently;
- `--csv` prints nothing but the row (and the header, with `--header`),
- the cleanup script without `--apply` prints only `would run:` lines,
- the scripts still work with `smartctl` absent and without `sudo`,
- a CSV truncated to the old 21 columns (`cut -d, -f1-21`) still produces the
  verdicts it used to.

Test verdict logic against a hand-written CSV with rows engineered to hit each
branch — spent SSD, spent battery, old-and-strained, old-and-undersized,
clean-but-strained, small-disk-and-strained, tight-and-self-inflicted, blank
hardware fields, duplicate host — rather than waiting for real machines to
produce them. Every branch should be reachable from a twelve-row file.

## Git

Scripts must stay executable: `chmod +x` and `git update-index --chmod=+x` on
any new one. `.gitattributes` enforces LF normalisation.

**Never commit collected data.** `*.csv` is gitignored because every row holds a
real computer name, username, hardware identifier and battery health. Fixtures
for testing verdict branches belong in the scratch directory, not the repo; if
one ever needs to be committed, it must use invented hostnames and be named
something other than `.csv`.
