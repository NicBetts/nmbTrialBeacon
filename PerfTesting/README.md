# PerfTesting

Query-level benchmarks for the bundled trial database. Nothing here ships in the
app — the folder sits outside `nmbTrialBeacon/nmbTrialBeacon/`, so the target's
file-system synchronized group never picks it up.

These scripts produced the numbers quoted in `DB_GENERATOR_SPEC.md` §11.

## Files

| File | What it does |
|---|---|
| `schema.sql` | Schema v1 DDL, matching the contract including `lookup_condition.value_norm`. |
| `seed.sql` | A handful of rows for correctness checks. |
| `gen_large.sh` | Builds `perf.sqlite`: 500k synthetic trials, ~600 MB, about 20 seconds. |
| `bench.sh` | Times every query shape the app issues against `perf.sqlite`. |
| `measure_open_items.py` | Focused measurement of the two open change requests, with match counts and query plans. |
| `queries.sql` | The raw query shapes, for reading or pasting into a `sqlite3` shell. |
| `inflate_check.swift` | Decodes every compressed `*_z` blob in a real database using the same routine as `TrialStore.inflate`. |

## Usage

```bash
./gen_large.sh                      # writes perf.sqlite (~600 MB, gitignore it)
./bench.sh                          # full sweep
python3 measure_open_items.py perf.sqlite
```

To check a real generator build end to end:

```bash
swiftc -O inflate_check.swift -o inflate_check
./inflate_check ../nmbTrialBeacon/trialbeacon.sqlite
```

## Reading the numbers

Each row reports two timings. **first** is the opening query on a fresh
connection, which approximates what a user feels right after launch; it swings
with OS page-cache state, sometimes by 2× between runs. **median** is the middle
of ten repeats on that warm connection, which is what scrolling and filtering
feel like, and it is the stable number to compare against.

Timing goes through Python's `perf_counter` around a `sqlite3` connection rather
than `/usr/bin/time` around the CLI. The earlier CLI approach resolved only to
10 ms and included process startup, which made every fast query read as "0 ms"
and hid two queries that were erroring outright.

The synthetic corpus has short, repetitive titles and summaries, so absolute
times are optimistic against the real registry. Use it to compare query plans
and relative costs, not as a device-performance prediction — and note that
device I/O is slower than a Mac SSD.
