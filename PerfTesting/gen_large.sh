#!/bin/bash
# Builds a ~500k-trial fixture matching the schema contract, for query planning
# and timing checks only (text payloads are synthetic and small).
set -e
cd "$(dirname "$0")"
rm -f perf.sqlite
sqlite3 perf.sqlite < schema.sql

sqlite3 perf.sqlite <<'SQL'
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;

WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 500000)
INSERT INTO trial (
  trial_id, nct_id, brief_title, official_title, overall_status, status_display,
  study_type, study_type_display, phase, phase_display, summary_snippet,
  last_update_post_date, gender_eligibility, gender_eligibility_display,
  min_age_years, max_age_years, std_ages,
  has_results, fda_regulated_drug, has_expanded_access,
  primary_condition, primary_country, lead_sponsor_name,
  condition_count, location_count, intervention_count, outcome_count, sponsor_count,
  is_active, start_year)
SELECT
  n,
  'NCT' || printf('%08d', n),
  CASE n % 7
    WHEN 0 THEN 'A Study of Breast Cancer Immunotherapy '
    WHEN 1 THEN 'Evaluation of Diabetes Management '
    WHEN 2 THEN 'Asthma Inhaler Efficacy Trial '
    WHEN 3 THEN 'Hypertension Combination Therapy '
    WHEN 4 THEN 'Alzheimer Disease Prevention Study '
    WHEN 5 THEN 'Depression Cognitive Therapy '
    ELSE 'Rheumatoid Arthritis Biologic ' END || n,
  'Official title for study ' || n,
  CASE n % 9 WHEN 0 THEN 'RECRUITING' WHEN 1 THEN 'COMPLETED' WHEN 2 THEN 'ACTIVE_NOT_RECRUITING'
             WHEN 3 THEN 'TERMINATED' WHEN 4 THEN 'NOT_YET_RECRUITING' WHEN 5 THEN 'WITHDRAWN'
             WHEN 6 THEN 'SUSPENDED' WHEN 7 THEN 'UNKNOWN' ELSE 'ENROLLING_BY_INVITATION' END,
  'Status ' || (n % 9),
  CASE n % 3 WHEN 0 THEN 'INTERVENTIONAL' WHEN 1 THEN 'OBSERVATIONAL' ELSE 'EXPANDED_ACCESS' END,
  'Type ' || (n % 3),
  CASE n % 8 WHEN 0 THEN 'PHASE1' WHEN 1 THEN 'PHASE2' WHEN 2 THEN 'PHASE3' WHEN 3 THEN 'PHASE4'
             WHEN 4 THEN 'EARLY_PHASE1' WHEN 5 THEN 'PHASE1_PHASE2' WHEN 6 THEN 'PHASE2_PHASE3' ELSE NULL END,
  'Phase ' || (n % 8),
  'Synthetic summary snippet for trial ' || n || ' describing the study design and endpoints.',
  1500000000 + (n * 37) % 300000000,
  CASE n % 3 WHEN 0 THEN 'ALL' WHEN 1 THEN 'MALE' ELSE 'FEMALE' END,
  'Sex ' || (n % 3),
  CASE n % 4 WHEN 0 THEN 0.0 WHEN 1 THEN 18.0 WHEN 2 THEN 12.0 ELSE 65.0 END,
  CASE n % 4 WHEN 0 THEN 17.0 WHEN 1 THEN 64.0 WHEN 2 THEN 99.0 ELSE NULL END,
  CASE n % 4 WHEN 0 THEN 'CHILD' WHEN 1 THEN 'ADULT' WHEN 2 THEN 'CHILD,ADULT,OLDER_ADULT' ELSE 'OLDER_ADULT' END,
  n % 2, n % 3 = 0, 0,
  CASE n % 7
    WHEN 0 THEN 'Breast Cancer' WHEN 1 THEN 'Diabetes Mellitus' WHEN 2 THEN 'Asthma'
    WHEN 3 THEN 'Hypertension' WHEN 4 THEN 












  'Alzheimer Disease' WHEN 5 THEN 'Depression' ELSE 'Rheumatoid Arthritis' END,
  CASE WHEN n % 5000 = 0 THEN 'Iceland'
       WHEN n % 1000 = 0 THEN 'New Zealand'
       WHEN n % 3 = 0 THEN 'United States'
       WHEN n % 3 = 1 THEN 'China' ELSE 'Germany' END,
  'Sponsor ' || (n % 5000),
  2, 3, 1, 2, 1,
  CASE WHEN n % 9 IN (0,2,4,8) THEN 1 ELSE 0 END,
  1999 + (n % 27)
FROM seq;
SQL

echo "trials inserted"

sqlite3 perf.sqlite <<'SQL'
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;

INSERT INTO condition (trial_id, name, name_norm, ordinal)
SELECT trial_id, primary_condition, lower(primary_condition), 0 FROM trial;

INSERT INTO condition (trial_id, name, name_norm, ordinal)
SELECT trial_id,
       CASE WHEN trial_id % 2000 = 0 THEN 'Ultra Rare Syndrome' ELSE 'Secondary ' || (trial_id % 50) END,
       CASE WHEN trial_id % 2000 = 0 THEN 'ultra rare syndrome' ELSE 'secondary ' || (trial_id % 50) END,
       1
FROM trial;

INSERT INTO location (trial_id, facility_name, city, state, country, postal_code, status, latitude, longitude, ordinal)
SELECT trial_id, 'Site ' || trial_id, 'City ' || (trial_id % 900), NULL, primary_country,
       printf('%05d', trial_id % 99999), 'RECRUITING',
       -60.0 + (trial_id % 12000) / 100.0, -170.0 + (trial_id % 34000) / 100.0, 0
FROM trial;

INSERT INTO location (trial_id, facility_name, city, country, status, ordinal)
SELECT trial_id, 'Second Site ' || trial_id, 'City ' || (trial_id % 700),
       CASE WHEN trial_id % 4 = 0 THEN 'Canada' ELSE 'France' END, NULL, 1
FROM trial;

INSERT INTO intervention (trial_id, type, type_display, name, ordinal)
SELECT trial_id, 'DRUG', 'Drug', 'Compound ' || (trial_id % 8000), 0 FROM trial;

INSERT INTO outcome (trial_id, type, measure, time_frame, ordinal)
SELECT trial_id, 'PRIMARY', 'Primary endpoint ' || (trial_id % 100), '12 months', 0 FROM trial;

INSERT INTO sponsor (trial_id, name, agency_class, role, ordinal)
SELECT trial_id, lead_sponsor_name, 'OTHER', 'LEAD', 0 FROM trial;

INSERT INTO eligibility (trial_id, study_population, sampling_method)
SELECT trial_id, NULL, NULL FROM trial WHERE trial_id % 3 = 1;
SQL

echo "children inserted"

sqlite3 perf.sqlite <<'SQL'
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;

INSERT INTO trial_fts (rowid, nct_id, brief_title, official_title, conditions, interventions)
SELECT t.trial_id, t.nct_id, t.brief_title, t.official_title, t.primary_condition, 'Compound ' || (t.trial_id % 8000)
FROM trial t;

INSERT INTO lookup_status SELECT overall_status, 'Status', COUNT(*), 0 FROM trial GROUP BY overall_status;
INSERT INTO lookup_phase SELECT phase, 'Phase', COUNT(*), 0 FROM trial WHERE phase IS NOT NULL GROUP BY phase;
INSERT INTO lookup_study_type SELECT study_type, 'Type', COUNT(*), 0 FROM trial GROUP BY study_type;
INSERT INTO lookup_gender SELECT gender_eligibility, 'Sex', COUNT(*), 0 FROM trial GROUP BY gender_eligibility;
INSERT INTO lookup_country SELECT country, COUNT(DISTINCT trial_id) FROM location GROUP BY country;
INSERT INTO lookup_condition SELECT name, name_norm, COUNT(DISTINCT trial_id) FROM condition GROUP BY name, name_norm;
INSERT INTO lookup_age_range VALUES ('CHILD','0-17',0),('ADULT','18-64',1),('OLDER_ADULT','65+',2);

INSERT INTO agg_dimension_count
SELECT 'condition', name, 'all', COUNT(DISTINCT trial_id) FROM condition GROUP BY name;
INSERT INTO agg_year_count SELECT start_year, 'all', COUNT(*) FROM trial GROUP BY start_year;
INSERT INTO agg_condition_by_year
SELECT t.start_year, t.primary_condition, COUNT(*), 1 FROM trial t GROUP BY t.start_year, t.primary_condition;

INSERT INTO db_metadata VALUES (1,1,'gen-perf','synthetic',1753747200,1753833600,
  (SELECT COUNT(*) FROM trial),
  (SELECT COUNT(*) FROM trial WHERE overall_status='RECRUITING'),
  (SELECT COUNT(*) FROM trial WHERE overall_status='ACTIVE_NOT_RECRUITING'),
  0, 'synthetic perf fixture');

ANALYZE;
SQL

echo "done"
ls -lh perf.sqlite
