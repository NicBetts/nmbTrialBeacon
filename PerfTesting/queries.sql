.headers on
.mode line

SELECT '--- 1. list page (summaryColumns) ---' AS step;
SELECT trial_id, nct_id, brief_title, overall_status, status_display, phase_display, study_type_display, primary_condition, primary_country, last_update_post_date, condition_count, location_count, is_active, summary_snippet
FROM trial ORDER BY last_update_post_date DESC, trial_id DESC LIMIT 2;

.mode list
SELECT '--- 2. detail column list ---';
SELECT trial_id, nct_id, brief_title, overall_status, status_display, phase_display, study_type_display, primary_condition, primary_country, last_update_post_date, condition_count, location_count, is_active, summary_snippet,
       official_title, brief_summary_z, detailed_description_z,
       start_date_display, completion_date_display, first_posted_date_display,
       last_update_post_date_display, gender_eligibility_display,
       min_age_display, max_age_display, std_ages, healthy_volunteers,
       enrollment_count, why_stopped, lead_sponsor_name,
       has_results, fda_regulated_drug, has_expanded_access
FROM trial WHERE nct_id = 'NCT00000002' LIMIT 1;

SELECT '--- 3. locations with coordinates ---';
SELECT facility_name, city, state, country, postal_code, status, latitude, longitude
FROM location WHERE trial_id = 1 ORDER BY ordinal;

SELECT '--- 4. eligibility ---';
SELECT inclusion_z, exclusion_z, raw_text_z, study_population, sampling_method
FROM eligibility WHERE trial_id = 3 LIMIT 1;

SELECT '--- 5a. condition lookup (value -> value_norm) for the Unicode case ---';
SELECT value_norm, trial_count FROM lookup_condition WHERE value = 'Dyslipidemia (Fredrickson Type Ⅱa)' LIMIT 1;

SELECT '--- 5b. filter using the stored norm (expect NCT00000002) ---';
SELECT nct_id FROM trial
WHERE trial.trial_id IN (SELECT c.trial_id FROM condition c WHERE c.name_norm IN ('dyslipidemia (fredrickson type ⅱa)'));

SELECT '--- 5c. what SQL lower() would have produced (demonstrates the trap) ---';
SELECT lower('Dyslipidemia (Fredrickson Type Ⅱa)') AS sql_lower,
       CASE WHEN lower('Dyslipidemia (Fredrickson Type Ⅱa)') =
                 (SELECT value_norm FROM lookup_condition WHERE value = 'Dyslipidemia (Fredrickson Type Ⅱa)')
            THEN 'match' ELSE 'MISMATCH' END AS verdict;

SELECT '--- 5d. EXISTS form of the same filter ---';
SELECT nct_id FROM trial
WHERE EXISTS (SELECT 1 FROM condition c WHERE c.trial_id = trial.trial_id AND c.name_norm IN ('breast cancer'));

SELECT '--- 6. age bucket CHILD (0-17): expect NCT00000002 + NCT00000003 ---';
SELECT nct_id FROM trial
WHERE (max_age_years IS NULL OR max_age_years >= 0.0)
  AND (min_age_years IS NULL OR min_age_years <= 17.0)
ORDER BY trial_id;

SELECT '--- 6b. age bucket OLDER_ADULT (65+): expect NCT00000001 ---';
SELECT nct_id FROM trial
WHERE (max_age_years IS NULL OR max_age_years >= 65.0)
  AND (min_age_years IS NULL OR min_age_years <= 130.0)
ORDER BY trial_id;

SELECT '--- 7. FTS search (ftsQuery output for "breast canc") ---';
SELECT trial.nct_id, trial.brief_title
FROM trial_fts JOIN trial ON trial.trial_id = trial_fts.rowid
WHERE trial_fts MATCH '"breast"* "canc"*'
ORDER BY trial_fts.rank LIMIT 10 OFFSET 0;

SELECT '--- 7b. FTS + filter (country id-set form) ---';
SELECT trial.nct_id
FROM trial_fts JOIN trial ON trial.trial_id = trial_fts.rowid
WHERE trial_fts MATCH '"asthma"*'
  AND trial.trial_id IN (SELECT l.trial_id FROM location l WHERE l.country = 'United Kingdom')
ORDER BY trial_fts.rank LIMIT 10 OFFSET 0;

SELECT '--- 8. lookups ---';
SELECT value, display, trial_count FROM lookup_status ORDER BY sort_order, value;
SELECT value, value, trial_count FROM lookup_country ORDER BY trial_count DESC, value;
SELECT value, display, 0 FROM lookup_age_range ORDER BY sort_order, value;
SELECT value, value, trial_count FROM lookup_condition WHERE value LIKE '%ast%' ESCAPE '\' ORDER BY trial_count DESC, value LIMIT 10;
SELECT COUNT(*) AS condition_total FROM lookup_condition;

SELECT '--- 9. dashboard stats ---';
SELECT total_trials, recruiting_count, active_not_recruiting_count,
       recently_updated_count, created_at, source_snapshot_date,
       schema_version, generator_version, source, build_options
FROM db_metadata WHERE id = 1;

SELECT '--- 10. aggregates ---';
SELECT value, count FROM agg_dimension_count WHERE dimension = 'condition' AND scope = 'all' ORDER BY count DESC LIMIT 5;
SELECT year, count FROM agg_year_count WHERE scope = 'all' ORDER BY year;
SELECT year, condition, count FROM agg_condition_by_year WHERE rank = 1 ORDER BY year DESC;

SELECT '--- 11. watchlist resolve ---';
SELECT nct_id FROM trial WHERE nct_id IN ('NCT00000003','NCT00000001');

SELECT '--- 12. count with multiple dimensions ---';
SELECT COUNT(*) FROM trial WHERE overall_status = 'RECRUITING' AND phase = 'PHASE3';
