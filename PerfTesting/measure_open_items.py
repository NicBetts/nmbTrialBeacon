#!/usr/bin/env python3
"""Definitive numbers for the two open change requests in DB_GENERATOR_SPEC.md §11.

Run against perf.sqlite (500k synthetic trials). Reports the first query on a
fresh connection and the warm median of 10 repeats, plus the match count and
the chosen query plan, so the claims in the spec can be re-derived.
"""
import sqlite3, statistics, sys, time

DB = sys.argv[1] if len(sys.argv) > 1 else "perf.sqlite"

COLS = ("trial_id, nct_id, brief_title, overall_status, status_display, phase_display, "
        "study_type_display, primary_condition, primary_country, last_update_post_date, "
        "condition_count, location_count, is_active, summary_snippet")
TCOLS = ", ".join(f"trial.{c.strip()}" for c in COLS.split(","))


def connect():
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    con.execute("PRAGMA cache_size=-20000")
    con.execute("PRAGMA mmap_size=268435456")
    return con


def measure(label, sql, repeats=10):
    con = connect()
    t = time.perf_counter(); rows = con.execute(sql).fetchall()
    first = (time.perf_counter() - t) * 1000
    ts = []
    for _ in range(repeats):
        t = time.perf_counter(); con.execute(sql).fetchall()
        ts.append((time.perf_counter() - t) * 1000)
    plan = " / ".join(r[3] for r in con.execute("EXPLAIN QUERY PLAN " + sql))
    print(f"{label:<44} first {first:8.2f} ms   median {statistics.median(ts):8.2f} ms   rows={len(rows)}")
    print(f"{'':<44} plan: {plan}")
    con.close()


def scalar(sql):
    con = connect()
    v = con.execute(sql).fetchone()[0]
    con.close()
    return v


title_sql = f"SELECT {COLS} FROM trial ORDER BY brief_title ASC, trial_id ASC LIMIT 40;"
fts_broad = (f"SELECT {TCOLS} FROM trial_fts JOIN trial ON trial.trial_id = trial_fts.rowid "
             f"WHERE trial_fts MATCH '\"cancer\"*' ORDER BY trial_fts.rank LIMIT 40;")
fts_two = (f"SELECT {TCOLS} FROM trial_fts JOIN trial ON trial.trial_id = trial_fts.rowid "
           f"WHERE trial_fts MATCH '\"breast\"* \"canc\"*' ORDER BY trial_fts.rank LIMIT 40;")
fts_nct = (f"SELECT {TCOLS} FROM trial_fts JOIN trial ON trial.trial_id = trial_fts.rowid "
           f"WHERE trial_fts MATCH '\"nct00250000\"*' LIMIT 40;")

has_index = scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_trial_title'")
print(f"database: {DB}   trials={scalar('SELECT COUNT(*) FROM trial')}   "
      f"idx_trial_title={'present' if has_index else 'absent'}\n")

print("=== 11.1  Title A-Z first page ===")
measure("title sort", title_sql)

broad_matches = scalar("SELECT COUNT(*) FROM trial_fts WHERE trial_fts MATCH '\"cancer\"*'")
print(f"\n=== 11.5  FTS  (broad term matches {broad_matches} rows) ===")
measure("FTS broad single term", fts_broad)
measure("FTS two terms", fts_two)
measure("FTS NCT id (selective)", fts_nct)
