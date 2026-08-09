PRAGMA application_id = 0x54424541;
PRAGMA user_version = 1;

CREATE TABLE trial (
    trial_id                       INTEGER PRIMARY KEY,
    nct_id                         TEXT    NOT NULL UNIQUE,
    brief_title                    TEXT    NOT NULL,
    official_title                 TEXT,
    overall_status                 TEXT    NOT NULL,
    status_display                 TEXT    NOT NULL,
    study_type                     TEXT,
    study_type_display             TEXT,
    phase                          TEXT,
    phase_display                  TEXT,
    summary_snippet                TEXT,
    brief_summary_z                BLOB,
    detailed_description_z         BLOB,
    start_date                     INTEGER,
    start_date_display             TEXT,
    completion_date                INTEGER,
    completion_date_display        TEXT,
    first_posted_date              INTEGER,
    first_posted_date_display      TEXT,
    last_update_post_date          INTEGER NOT NULL,
    last_update_post_date_display  TEXT,
    gender_eligibility             TEXT,
    gender_eligibility_display     TEXT,
    min_age_display                TEXT,
    max_age_display                TEXT,
    min_age_years                  REAL,
    max_age_years                  REAL,
    healthy_volunteers             INTEGER,
    enrollment_count               INTEGER,
    why_stopped                    TEXT,
    std_ages                       TEXT,
    has_results                    INTEGER NOT NULL DEFAULT 0,
    fda_regulated_drug             INTEGER NOT NULL DEFAULT 0,
    has_expanded_access            INTEGER NOT NULL DEFAULT 0,
    primary_condition              TEXT,
    primary_country                TEXT,
    primary_state                  TEXT,
    lead_sponsor_name              TEXT,
    lead_sponsor_class             TEXT,
    condition_count                INTEGER NOT NULL DEFAULT 0,
    location_count                 INTEGER NOT NULL DEFAULT 0,
    intervention_count             INTEGER NOT NULL DEFAULT 0,
    outcome_count                  INTEGER NOT NULL DEFAULT 0,
    sponsor_count                  INTEGER NOT NULL DEFAULT 0,
    is_active                      INTEGER NOT NULL DEFAULT 0,
    start_year                     INTEGER
);

CREATE TABLE condition (
    condition_id INTEGER PRIMARY KEY,
    trial_id     INTEGER NOT NULL REFERENCES trial(trial_id),
    name         TEXT NOT NULL,
    name_norm    TEXT NOT NULL,
    ordinal      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE location (
    location_id   INTEGER PRIMARY KEY,
    trial_id      INTEGER NOT NULL REFERENCES trial(trial_id),
    facility_name TEXT, city TEXT, state TEXT, country TEXT, postal_code TEXT,
    status        TEXT,
    latitude      REAL, longitude REAL,
    ordinal       INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE intervention (
    intervention_id INTEGER PRIMARY KEY,
    trial_id        INTEGER NOT NULL REFERENCES trial(trial_id),
    type            TEXT,
    type_display    TEXT,
    name            TEXT NOT NULL,
    description     TEXT,
    ordinal         INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE outcome (
    outcome_id  INTEGER PRIMARY KEY,
    trial_id    INTEGER NOT NULL REFERENCES trial(trial_id),
    type        TEXT NOT NULL,
    measure     TEXT NOT NULL,
    time_frame  TEXT,
    description TEXT,
    ordinal     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE sponsor (
    sponsor_id   INTEGER PRIMARY KEY,
    trial_id     INTEGER NOT NULL REFERENCES trial(trial_id),
    name         TEXT NOT NULL,
    agency_class TEXT,
    role         TEXT,
    ordinal      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE eligibility (
    trial_id         INTEGER PRIMARY KEY REFERENCES trial(trial_id),
    inclusion_z      BLOB,
    exclusion_z      BLOB,
    raw_text_z       BLOB,
    study_population TEXT,
    sampling_method  TEXT
);

CREATE VIRTUAL TABLE trial_fts USING fts5(
    nct_id, brief_title, official_title, conditions, interventions,
    content = '',
    tokenize = 'porter unicode61 remove_diacritics 2'
);

CREATE TABLE lookup_status     (value TEXT PRIMARY KEY, display TEXT NOT NULL, trial_count INTEGER, sort_order INTEGER);
CREATE TABLE lookup_phase      (value TEXT PRIMARY KEY, display TEXT NOT NULL, trial_count INTEGER, sort_order INTEGER);
CREATE TABLE lookup_study_type (value TEXT PRIMARY KEY, display TEXT NOT NULL, trial_count INTEGER, sort_order INTEGER);
CREATE TABLE lookup_gender     (value TEXT PRIMARY KEY, display TEXT NOT NULL, trial_count INTEGER, sort_order INTEGER);
CREATE TABLE lookup_country    (value TEXT PRIMARY KEY, trial_count INTEGER);
CREATE TABLE lookup_condition  (value TEXT PRIMARY KEY, value_norm TEXT NOT NULL, trial_count INTEGER);
CREATE TABLE lookup_age_range  (value TEXT PRIMARY KEY, display TEXT NOT NULL, sort_order INTEGER);

CREATE TABLE agg_dimension_count (
    dimension TEXT NOT NULL, value TEXT NOT NULL,
    scope     TEXT NOT NULL,
    count     INTEGER NOT NULL,
    PRIMARY KEY (dimension, value, scope)
);
CREATE TABLE agg_year_count (
    year INTEGER NOT NULL, scope TEXT NOT NULL, count INTEGER NOT NULL,
    PRIMARY KEY (year, scope)
);
CREATE TABLE agg_condition_by_year (
    year INTEGER NOT NULL, condition TEXT NOT NULL,
    count INTEGER NOT NULL, rank INTEGER NOT NULL,
    PRIMARY KEY (year, condition)
);

CREATE TABLE db_metadata (
    id                          INTEGER PRIMARY KEY CHECK (id = 1),
    schema_version              INTEGER NOT NULL,
    generator_version           TEXT    NOT NULL,
    source                      TEXT    NOT NULL,
    source_snapshot_date        INTEGER NOT NULL,
    created_at                  INTEGER NOT NULL,
    total_trials                INTEGER NOT NULL,
    recruiting_count            INTEGER NOT NULL,
    active_not_recruiting_count INTEGER NOT NULL,
    recently_updated_count      INTEGER NOT NULL,
    build_options               TEXT
);

CREATE INDEX idx_trial_lu   ON trial(last_update_post_date DESC);
CREATE INDEX idx_trial_st   ON trial(overall_status, last_update_post_date DESC);
CREATE INDEX idx_trial_act  ON trial(is_active, last_update_post_date DESC);
CREATE INDEX idx_trial_ph   ON trial(phase);
CREATE INDEX idx_trial_ty   ON trial(study_type);
CREATE INDEX idx_trial_ge   ON trial(gender_eligibility);
CREATE INDEX idx_trial_pc   ON trial(primary_country);
CREATE INDEX idx_trial_pcond ON trial(primary_condition);
CREATE INDEX idx_trial_sy   ON trial(start_year);
CREATE INDEX idx_trial_mina ON trial(min_age_years);
CREATE INDEX idx_trial_maxa ON trial(max_age_years);
CREATE INDEX idx_cond_trial ON condition(trial_id);
CREATE INDEX idx_cond_norm  ON condition(name_norm);
CREATE INDEX idx_loc_trial  ON location(trial_id);
CREATE INDEX idx_loc_country ON location(country);
CREATE INDEX idx_int_trial  ON intervention(trial_id);
CREATE INDEX idx_out_trial  ON outcome(trial_id);
CREATE INDEX idx_spo_trial  ON sponsor(trial_id);
