INSERT INTO trial (
  trial_id, nct_id, brief_title, official_title, overall_status, status_display,
  study_type, study_type_display, phase, phase_display, summary_snippet,
  start_date_display, completion_date_display, first_posted_date_display,
  last_update_post_date, last_update_post_date_display,
  gender_eligibility, gender_eligibility_display, min_age_display, max_age_display,
  min_age_years, max_age_years, healthy_volunteers, enrollment_count, why_stopped,
  std_ages, has_results, fda_regulated_drug, has_expanded_access,
  primary_condition, primary_country, primary_state, lead_sponsor_name, lead_sponsor_class,
  condition_count, location_count, intervention_count, outcome_count, sponsor_count,
  is_active, start_year
) VALUES
 (1,'NCT00000001','Breast Cancer Immunotherapy Study','A Phase 3 Study','RECRUITING','Recruiting',
  'INTERVENTIONAL','Interventional','PHASE3','Phase 3','A study of immunotherapy in breast cancer.',
  '2021-03','2026-01','2021-01-15',1750000000,'Jun 15, 2025',
  'ALL','All','18 Years','75 Years',18.0,75.0,0,420,NULL,
  'ADULT,OLDER_ADULT',0,1,0,
  'Breast Cancer','United States','MA','Dana-Farber','OTHER',
  2,3,1,2,1,1,2021),
 (2,'NCT00000002','Dyslipidemia (Fredrickson Type Ⅱa) Trial','Official Two','TERMINATED','Terminated',
  'INTERVENTIONAL','Interventional','PHASE2','Phase 2','Lipid lowering study.',
  '2019','2022','2019-02-01',1700000000,'Nov 14, 2023',
  'MALE','Male','12 Years','17 Years',12.0,17.0,1,80,'Insufficient enrollment',
  'CHILD',0,0,0,
  'Dyslipidemia (Fredrickson Type Ⅱa)','Iceland',NULL,'Reykjavik University','OTHER',
  1,1,1,1,1,0,2019),
 (3,'NCT00000003','Paediatric Asthma Inhaler Study','Official Three','ACTIVE_NOT_RECRUITING','Active, not recruiting',
  'OBSERVATIONAL','Observational',NULL,NULL,'Observational asthma cohort.',
  '2023-06',NULL,'2023-05-01',1740000000,'Feb 19, 2025',
  'ALL','All','2 Years','11 Years',2.0,11.0,1,1500,NULL,
  'CHILD',1,0,0,
  'Asthma','United Kingdom',NULL,'NHS Trust','OTHER',
  1,2,0,1,1,1,2023);

INSERT INTO condition (condition_id, trial_id, name, name_norm, ordinal) VALUES
 (1,1,'Breast Cancer','breast cancer',0),
 (2,1,'Triple Negative Breast Cancer','triple negative breast cancer',1),
 (3,2,'Dyslipidemia (Fredrickson Type Ⅱa)','dyslipidemia (fredrickson type ⅱa)',0),
 (4,3,'Asthma','asthma',0);

INSERT INTO location (location_id, trial_id, facility_name, city, state, country, postal_code, status, latitude, longitude, ordinal) VALUES
 (1,1,'Dana-Farber Cancer Institute','Boston','MA','United States','02215','RECRUITING',42.3376,-71.1073,0),
 (2,1,'MD Anderson','Houston','TX','United States','77030','RECRUITING',29.7070,-95.3975,1),
 (3,1,'Princess Margaret','Toronto','ON','Canada','M5G 2C1','NOT_YET_RECRUITING',43.6596,-79.3896,2),
 (4,2,'Landspitali','Reykjavik',NULL,'Iceland','101',NULL,NULL,NULL,0),
 (5,3,'Royal Brompton','London',NULL,'United Kingdom','SW3 6NP','ACTIVE_NOT_RECRUITING',51.4877,-0.1730,0),
 (6,3,'Alder Hey','Liverpool',NULL,'United Kingdom','L12 2AP',NULL,53.4186,-2.8967,1);

INSERT INTO intervention (intervention_id, trial_id, type, type_display, name, description, ordinal) VALUES
 (1,1,'DRUG','Drug','Pembrolizumab','200 mg IV q3w',0),
 (2,2,'DRUG','Drug','Statin X',NULL,0);

INSERT INTO outcome (outcome_id, trial_id, type, measure, time_frame, description, ordinal) VALUES
 (1,1,'PRIMARY','Overall survival','5 years',NULL,0),
 (2,1,'SECONDARY','Progression-free survival','3 years',NULL,1),
 (3,2,'PRIMARY','LDL reduction','12 weeks',NULL,0),
 (4,3,'PRIMARY','Exacerbation rate','1 year',NULL,0);

INSERT INTO sponsor (sponsor_id, trial_id, name, agency_class, role, ordinal) VALUES
 (1,1,'Dana-Farber','OTHER','LEAD',0),
 (2,2,'Reykjavik University','OTHER','LEAD',0),
 (3,3,'NHS Trust','OTHER','LEAD',0);

INSERT INTO eligibility (trial_id, inclusion_z, exclusion_z, raw_text_z, study_population, sampling_method) VALUES
 (1,NULL,NULL,NULL,NULL,NULL),
 (3,NULL,NULL,NULL,'Children aged 2-11 with physician-diagnosed asthma','NON_PROBABILITY_SAMPLE');

INSERT INTO trial_fts (rowid, nct_id, brief_title, official_title, conditions, interventions) VALUES
 (1,'NCT00000001','Breast Cancer Immunotherapy Study','A Phase 3 Study','Breast Cancer
Triple Negative Breast Cancer','Pembrolizumab'),
 (2,'NCT00000002','Dyslipidemia (Fredrickson Type Ⅱa) Trial','Official Two','Dyslipidemia (Fredrickson Type Ⅱa)','Statin X'),
 (3,'NCT00000003','Paediatric Asthma Inhaler Study','Official Three','Asthma','');

INSERT INTO lookup_status VALUES ('RECRUITING','Recruiting',1,0),('ACTIVE_NOT_RECRUITING','Active, not recruiting',1,1),('TERMINATED','Terminated',1,2);
INSERT INTO lookup_phase VALUES ('PHASE2','Phase 2',1,0),('PHASE3','Phase 3',1,1);
INSERT INTO lookup_study_type VALUES ('INTERVENTIONAL','Interventional',2,0),('OBSERVATIONAL','Observational',1,1);
INSERT INTO lookup_gender VALUES ('ALL','All',2,0),('MALE','Male',1,1);
INSERT INTO lookup_country VALUES ('United States',1),('Canada',1),('Iceland',1),('United Kingdom',1);
INSERT INTO lookup_condition VALUES
 ('Breast Cancer','breast cancer',1),
 ('Triple Negative Breast Cancer','triple negative breast cancer',1),
 ('Dyslipidemia (Fredrickson Type Ⅱa)','dyslipidemia (fredrickson type ⅱa)',1),
 ('Asthma','asthma',1);
INSERT INTO lookup_age_range VALUES ('CHILD','0–17',0),('ADULT','18–64',1),('OLDER_ADULT','65+',2);

INSERT INTO agg_dimension_count VALUES
 ('condition','Breast Cancer','all',1),('condition','Asthma','all',1),
 ('country','United States','all',1),('country','United Kingdom','all',1),
 ('status','RECRUITING','all',1),('phase','PHASE3','all',1),
 ('study_type','INTERVENTIONAL','all',2),('gender','ALL','all',2),
 ('condition','Breast Cancer','active',1),('country','United States','active',1);
INSERT INTO agg_year_count VALUES (2019,'all',1),(2021,'all',1),(2023,'all',1),(2021,'active',1),(2023,'active',1);
INSERT INTO agg_condition_by_year VALUES (2021,'Breast Cancer',1,1),(2023,'Asthma',1,1),(2019,'Dyslipidemia (Fredrickson Type Ⅱa)',1,1);

INSERT INTO db_metadata VALUES (1,1,'gen-2026.07.29','ClinicalTrials.gov API v2',1753747200,1753833600,3,1,1,2,'full corpus; detailed descriptions omitted for inactive trials before 2015');
