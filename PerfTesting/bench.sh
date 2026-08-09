#!/bin/bash
# Times each query shape the app issues against the synthetic 500k fixture.
#
# Reports two numbers per query. "first" is the opening run on a fresh
# connection, which is what a user feels after a cold launch. "median" is the
# middle of 10 repeats on that same warm connection, which is what they feel
# while scrolling. Sub-millisecond results are real, not rounding — the timer
# below has microsecond resolution, unlike `/usr/bin/time -p`, whose 10 ms
# granularity and process-startup overhead used to swamp every fast query here.
cd "$(dirname "$0")"
DB=perf.sqlite
COLS="trial_id, nct_id, brief_title, overall_status, status_display, phase_display, study_type_display, primary_condition, primary_country, last_update_post_date, condition_count, location_count, is_active, summary_snippet"
# Joined queries must qualify the list, exactly as TrialStore.summaryColumns("trial.") does.
TCOLS=$(echo "$COLS" | sed 's/\([a-z_][a-z_]*\)/trial.\1/g')

run() {
  local label="$1"
  local sql="$2"
  LABEL="$label" SQL="$sql" DBPATH="$DB" python3 -c '
import os, sqlite3, time
label, sql, db = os.environ["LABEL"], os.environ["SQL"], os.environ["DBPATH"]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
con.execute("PRAGMA cache_size=-20000")
con.execute("PRAGMA mmap_size=268435456")
try:
    t = time.perf_counter(); rows = con.execute(sql).fetchall()
    first = (time.perf_counter() - t) * 1000
    ts = []
    for _ in range(10):
        t = time.perf_counter(); con.execute(sql).fetchall()
        ts.append((time.perf_counter() - t) * 1000)
    ts.sort()
    print(f"{label:<52} first {first:9.2f} ms   median {ts[len(ts)//2]:9.2f} ms  ({len(rows)} rows)")
except sqlite3.Error as e:
    print(f"{label:<52} ERROR: {e}")
'
}

# Times a batch of statements as one unit — the detail screen issues six
# queries back to back, and startup reads five lookup tables, so the total is
# the number that matters rather than any single statement.
run_multi() {
  local label="$1"
  local sql="$2"
  LABEL="$label" SQL="$sql" DBPATH="$DB" python3 -c '
import os, sqlite3, time
label, sql, db = os.environ["LABEL"], os.environ["SQL"], os.environ["DBPATH"]
stmts = [s.strip() for s in sql.split(";") if s.strip()]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
con.execute("PRAGMA cache_size=-20000")
con.execute("PRAGMA mmap_size=268435456")
def batch():
    return sum(len(con.execute(s).fetchall()) for s in stmts)
try:
    t = time.perf_counter(); n = batch(); first = (time.perf_counter() - t) * 1000
    ts = []
    for _ in range(10):
        t = time.perf_counter(); batch(); ts.append((time.perf_counter() - t) * 1000)
    ts.sort()
    print(f"{label:<52} first {first:9.2f} ms   median {ts[len(ts)//2]:9.2f} ms  ({n} rows, {len(stmts)} stmts)")
except sqlite3.Error as e:
    print(f"{label:<52} ERROR: {e}")
'
}

echo "=== paging (limit 40) ==="
run "unfiltered first page" \
  "SELECT $COLS FROM trial ORDER BY last_update_post_date DESC, trial_id DESC LIMIT 40;"

run "status = RECRUITING" \
  "SELECT $COLS FROM trial WHERE overall_status='RECRUITING' ORDER BY last_update_post_date DESC, trial_id DESC LIMIT 40;"

run "rare country (Iceland, IN form)" \
  "SELECT $COLS FROM trial WHERE trial.trial_id IN (SELECT l.trial_id FROM location l WHERE l.country='Iceland') ORDER BY last_update_post_date DESC, trial_id DESC LIMIT 40;"

run "rare country (Iceland, EXISTS form - wrong plan)" \
  "SELECT $COLS FROM trial WHERE EXISTS (SELECT 1 FROM location l WHERE l.trial_id=trial.trial_id AND l.country='Iceland') ORDER BY last_update_post_date DESC, trial_id DESC LIMIT 40;"

run "common country (United States, EXISTS form)" \
  "SELECT $COLS FROM trial WHERE EXISTS (SELECT 1 FROM location l WHERE l.trial_id=trial.trial_id AND l.country='United States') ORDER BY last_update_post_date DESC, trial_id DESC LIMIT 40;"

run "common country (United States, IN form - wrong plan)" \
  "SELECT $COLS FROM trial WHERE trial.trial_id IN (SELECT l.trial_id FROM location l WHERE l.country='United States') ORDER BY last_update_post_date DESC, trial_id DESC LIMIT 40;"

run "rare condition (ultra rare syndrome, IN form)" \
  "SELECT $COLS FROM trial WHERE trial.trial_id IN (SELECT c.trial_id FROM condition c WHERE c.name_norm IN ('ultra rare syndrome')) ORDER BY last_update_post_date DESC, trial_id DESC LIMIT 40;"

run "common condition (asthma, EXISTS form)" \
  "SELECT $COLS FROM trial WHERE EXISTS (SELECT 1 FROM condition c WHERE c.trial_id=trial.trial_id AND c.name_norm IN ('asthma')) ORDER BY last_update_post_date DESC, trial_id DESC LIMIT 40;"

echo
echo "=== new in this pass: age bucket filter ==="
run "age bucket ADULT (18-64)" \
  "SELECT $COLS FROM trial WHERE (max_age_years IS NULL OR max_age_years >= 18.0) AND (min_age_years IS NULL OR min_age_years <= 64.0) ORDER BY last_update_post_date DESC, trial_id DESC LIMIT 40;"

run "age bucket CHILD (0-17)" \
  "SELECT $COLS FROM trial WHERE (max_age_years IS NULL OR max_age_years >= 0.0) AND (min_age_years IS NULL OR min_age_years <= 17.0) ORDER BY last_update_post_date DESC, trial_id DESC LIMIT 40;"

run "age bucket OLDER_ADULT + status + phase" \
  "SELECT $COLS FROM trial WHERE overall_status='RECRUITING' AND phase='PHASE3' AND (max_age_years IS NULL OR max_age_years >= 65.0) AND (min_age_years IS NULL OR min_age_years <= 130.0) ORDER BY last_update_post_date DESC, trial_id DESC LIMIT 40;"

run "age bucket + rare country" \
  "SELECT $COLS FROM trial WHERE trial.trial_id IN (SELECT l.trial_id FROM location l WHERE l.country='Iceland') AND (max_age_years IS NULL OR max_age_years >= 18.0) AND (min_age_years IS NULL OR min_age_years <= 64.0) ORDER BY last_update_post_date DESC, trial_id DESC LIMIT 40;"

echo
echo "=== search ==="
run "FTS broad term (cancer)" \
  "SELECT $TCOLS FROM trial_fts JOIN trial ON trial.trial_id=trial_fts.rowid WHERE trial_fts MATCH '\"cancer\"*' ORDER BY trial_fts.rank LIMIT 40 OFFSET 0;"

run "FTS two terms (breast canc)" \
  "SELECT $TCOLS FROM trial_fts JOIN trial ON trial.trial_id=trial_fts.rowid WHERE trial_fts MATCH '\"breast\"* \"canc\"*' ORDER BY trial_fts.rank LIMIT 40 OFFSET 0;"

run "FTS + status filter" \
  "SELECT $TCOLS FROM trial_fts JOIN trial ON trial.trial_id=trial_fts.rowid WHERE trial_fts MATCH '\"asthma\"*' AND overall_status='RECRUITING' ORDER BY trial_fts.rank LIMIT 40 OFFSET 0;"

echo
echo "=== detail + lookups ==="
run "detail: trial row" \
  "SELECT * FROM trial WHERE nct_id='NCT00250000' LIMIT 1;"
run_multi "detail: all 6 child queries" \
  "SELECT * FROM condition WHERE trial_id=250000 ORDER BY ordinal; SELECT * FROM location WHERE trial_id=250000 ORDER BY ordinal; SELECT * FROM intervention WHERE trial_id=250000 ORDER BY ordinal; SELECT * FROM outcome WHERE trial_id=250000 ORDER BY ordinal; SELECT * FROM sponsor WHERE trial_id=250000 ORDER BY ordinal; SELECT * FROM eligibility WHERE trial_id=250000;"
run "condition lookup by value (memoized once)" \
  "SELECT value_norm, trial_count FROM lookup_condition WHERE value='Asthma' LIMIT 1;"
run "condition menu search (value_norm LIKE)" \
  "SELECT value, value, trial_count FROM lookup_condition WHERE value_norm LIKE '%card%' ESCAPE '\\' ORDER BY trial_count DESC, value LIMIT 200;"
run_multi "startup: selectivity stats (5 lookup tables)" \
  "SELECT value,trial_count FROM lookup_status; SELECT value,trial_count FROM lookup_phase; SELECT value,trial_count FROM lookup_study_type; SELECT value,trial_count FROM lookup_gender; SELECT value,trial_count FROM lookup_country;"

echo
echo "=== counts ==="
run "count: multi-dimension (status+phase)" \
  "SELECT COUNT(*) FROM trial WHERE overall_status='RECRUITING' AND phase='PHASE3';"
run "count: status + common country" \
  "SELECT COUNT(*) FROM trial WHERE overall_status='RECRUITING' AND trial.trial_id IN (SELECT l.trial_id FROM location l WHERE l.country='United States');"

echo
echo "=== title sort: the open change request (11.1) ==="
run "Title A-Z first page (NO idx_trial_title)" \
  "SELECT $COLS FROM trial ORDER BY brief_title ASC, trial_id ASC LIMIT 40;"
sqlite3 $DB "CREATE INDEX IF NOT EXISTS idx_trial_title ON trial(brief_title, trial_id);" >/dev/null
run "Title A-Z first page (WITH idx_trial_title)" \
  "SELECT $COLS FROM trial ORDER BY brief_title ASC, trial_id ASC LIMIT 40;"
run "Title A-Z page 2 keyset (WITH index)" \
  "SELECT $COLS FROM trial WHERE (brief_title > 'A Study of Breast Cancer Immunotherapy 100000' OR (brief_title = 'A Study of Breast Cancer Immunotherapy 100000' AND trial_id > 100000)) ORDER BY brief_title ASC, trial_id ASC LIMIT 40;"
echo
echo "index size:"
sqlite3 $DB "SELECT 'idx_trial_title = ' || printf('%.1f MB', SUM(pgsize)/1048576.0) FROM dbstat WHERE name='idx_trial_title';"
