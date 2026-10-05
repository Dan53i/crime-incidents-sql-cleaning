/* =====================================================================
   Crime Incidents - Complete PostgreSQL Cleaning Script
   Source file : data/crime_incidents_messy.csv (5,250 rows x 33 columns)
   Run with    : psql  (uses \set and \copy, which are psql-only)
                 Run from the REPOSITORY ROOT so the relative CSV path works:
                 psql -d yourdb -f sql/crime_incidents_cleaning.sql

   Layers
     crime_incidents_messy        raw audit layer (all TEXT, never edited)
     crime_incidents_clean        typed + validated analytical table
     crime_incidents_cleaning_log every raw value that was rejected (-> NULL)
     crime_type_map               reviewed spelling-fix mapping

   Transaction plan
     PART A  one transaction : create raw table, load CSV, verify count
     PART B  one transaction : helpers, clean table, constraints, QC,
                               then COMMIT (any QC failure aborts -> rollback)
     PART C  outside a transaction : VACUUM ANALYZE
   ===================================================================== */

\set ON_ERROR_STOP on
-- >>> EDIT THIS PATH if your CSV lives elsewhere (use forward slashes, even on Windows) <<<
\set csv_path 'data/crime_incidents_messy.csv'


/* =====================================================================
   PART A - LOAD RAW DATA (all-or-nothing)
   ===================================================================== */
BEGIN;

-- Deliberately NOT "DROP TABLE IF EXISTS": the raw layer is your audit
-- source and must never be dropped by accident. To reload, run
--   TRUNCATE crime_incidents_messy;  (and remove the row_id column first)
CREATE TABLE crime_incidents_messy (
    incident_id text, crime_type text, district text, city text, state text,
    address text, latitude text, longitude text, incident_datetime text,
    officer_id text, officer_first_name text, officer_last_name text,
    badge_number text, suspect_id text, suspect_first_name text,
    suspect_last_name text, suspect_age text, suspect_gender text,
    suspect_race text, victim_id text, victim_first_name text,
    victim_last_name text, victim_age text, victim_gender text,
    victim_phone text, weapon_used text, severity text, case_status text,
    resolution text, num_arrests text, property_loss_usd text,
    reported_online text, notes text
);

\copy crime_incidents_messy FROM :'csv_path' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- Row identifier added AFTER the load (existing rows are numbered
-- automatically). Needed because incident_id is not guaranteed unique.
ALTER TABLE crime_incidents_messy
    ADD COLUMN row_id bigint GENERATED ALWAYS AS IDENTITY;

-- Guard: stop (and roll back) if the load is not the expected size
DO $$
DECLARE n bigint;
BEGIN
    SELECT COUNT(*) INTO n FROM crime_incidents_messy;
    IF n <> 5250 THEN
        RAISE EXCEPTION 'Load check failed: expected 5250 rows, got %', n;
    END IF;
END $$;

COMMIT;   -- (if you are running statements by hand and the count looks wrong: ROLLBACK;)


/* =====================================================================
   PROFILING (read-only, no transaction needed). Review before PART B.
   ===================================================================== */
SELECT COUNT(*)                                   AS total_rows,
       COUNT(DISTINCT incident_id)                AS unique_incidents,
       COUNT(*) - COUNT(DISTINCT incident_id)     AS duplicate_ids
FROM crime_incidents_messy;

SELECT crime_type, COUNT(*) FROM crime_incidents_messy GROUP BY 1 ORDER BY 2 DESC;
SELECT district,   COUNT(*) FROM crime_incidents_messy GROUP BY 1 ORDER BY 2 DESC;
SELECT suspect_gender, COUNT(*) FROM crime_incidents_messy GROUP BY 1 ORDER BY 2 DESC;
SELECT suspect_age, COUNT(*) FROM crime_incidents_messy GROUP BY 1 ORDER BY 2 DESC LIMIT 20;
SELECT reported_online, COUNT(*) FROM crime_incidents_messy GROUP BY 1 ORDER BY 2 DESC;


/* =====================================================================
   PART B - BUILD, VALIDATE, COMMIT
   ===================================================================== */
BEGIN;

/* ---------------------------------------------------------------------
   B1. Helper functions (CASE inside a function guarantees the regex test
       runs BEFORE the cast, so bad text can never raise a cast error)
   --------------------------------------------------------------------- */

-- Trim + turn empty / n/a / na / null / '-' into NULL.
-- 'Unknown' is intentionally NOT nulled here (it may be a real category).
CREATE OR REPLACE FUNCTION fn_clean_text(t text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN LOWER(BTRIM(t)) IN ('', 'n/a', 'na', 'null', '-') THEN NULL
        ELSE BTRIM(t)
    END
$$;

-- Text -> numeric, or NULL if it is not a plain number.
-- Accepts 51, 51.0, -3, +7.25 ; limited to 15 integer digits (no overflow).
CREATE OR REPLACE FUNCTION fn_to_num(t text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN BTRIM(t) ~ '^[+-]?[0-9]{1,15}(\.[0-9]+)?$' THEN BTRIM(t)::numeric
    END
$$;

-- Age: numeric, 0..120, returned as integer
CREATE OR REPLACE FUNCTION fn_age(t text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN fn_to_num(t) BETWEEN 0 AND 120 THEN ROUND(fn_to_num(t))::integer
    END
$$;

-- Coordinates
CREATE OR REPLACE FUNCTION fn_lat(t text) RETURNS numeric(9,6)
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN fn_to_num(t) BETWEEN -90 AND 90 THEN ROUND(fn_to_num(t), 6)::numeric(9,6)
    END
$$;

CREATE OR REPLACE FUNCTION fn_lon(t text) RETURNS numeric(9,6)
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN fn_to_num(t) BETWEEN -180 AND 180 THEN ROUND(fn_to_num(t), 6)::numeric(9,6)
    END
$$;

-- Arrest count: whole number >= 0 (3 and 3.0 accepted, 3.5 and -1 rejected)
CREATE OR REPLACE FUNCTION fn_arrests(t text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN fn_to_num(t) >= 0
         AND fn_to_num(t) = TRUNC(fn_to_num(t))
         AND fn_to_num(t) <= 2147483647
        THEN fn_to_num(t)::integer
    END
$$;

-- Property loss: >= 0, 2 decimals
CREATE OR REPLACE FUNCTION fn_loss(t text) RETURNS numeric(14,2)
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN fn_to_num(t) >= 0 AND fn_to_num(t) < 1000000000000
        THEN ROUND(fn_to_num(t), 2)::numeric(14,2)
    END
$$;

-- Gender (suspect and victim)
CREATE OR REPLACE FUNCTION fn_gender(t text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN LOWER(BTRIM(t)) IN ('m', 'male')   THEN 'Male'
        WHEN LOWER(BTRIM(t)) IN ('f', 'female') THEN 'Female'
        WHEN LOWER(BTRIM(t)) = 'other'          THEN 'Other'
        WHEN LOWER(BTRIM(t)) IN ('unknown', 'n/a', 'na', 'null', '', '-') THEN NULL
        ELSE INITCAP(BTRIM(t))
    END
$$;

-- District: explicit mapping for known abbreviations
CREATE OR REPLACE FUNCTION fn_district(t text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN LOWER(BTRIM(t)) IN ('nor', 'north')  THEN 'North'
        WHEN LOWER(BTRIM(t)) IN ('sou', 'south')  THEN 'South'
        WHEN LOWER(BTRIM(t)) = 'east'             THEN 'East'
        WHEN LOWER(BTRIM(t)) = 'west'             THEN 'West'
        WHEN LOWER(BTRIM(t)) = 'southwest'        THEN 'Southwest'
        WHEN LOWER(BTRIM(t)) = 'southeast'        THEN 'Southeast'
        WHEN LOWER(BTRIM(t)) = 'northwest'        THEN 'Northwest'
        WHEN LOWER(BTRIM(t)) = 'northeast'        THEN 'Northeast'
        WHEN LOWER(BTRIM(t)) = 'central'          THEN 'Central'
        WHEN LOWER(BTRIM(t)) IN ('', 'n/a', 'na', 'null', '-') THEN NULL
        ELSE INITCAP(BTRIM(t))
    END
$$;

-- Suspect race
CREATE OR REPLACE FUNCTION fn_race(t text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN LOWER(BTRIM(t)) IN ('unknown', 'na', 'n/a', 'null', '', '-') THEN NULL
        WHEN LOWER(BTRIM(t)) = 'white'    THEN 'White'
        WHEN LOWER(BTRIM(t)) = 'black'    THEN 'Black'
        WHEN LOWER(BTRIM(t)) = 'hispanic' THEN 'Hispanic'
        WHEN LOWER(BTRIM(t)) = 'asian'    THEN 'Asian'
        ELSE INITCAP(BTRIM(t))
    END
$$;

-- Boolean
CREATE OR REPLACE FUNCTION fn_bool(t text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN LOWER(BTRIM(t)) IN ('true',  't', 'yes', 'y', '1') THEN TRUE
        WHEN LOWER(BTRIM(t)) IN ('false', 'f', 'no',  'n', '0') THEN FALSE
    END
$$;

-- Timestamp: every known format is recognised explicitly, then rewritten to
-- ISO (YYYY-MM-DD HH:MI:SS) and cast. DD comes before MM for slash/dash
-- formats. Impossible dates (e.g. 31-02-2023, hour 25) raise inside the cast
-- and are caught below -> NULL.
--   YYYY-MM-DD | YYYY-MM-DD HH:MI | YYYY-MM-DD HH:MI:SS
--   DD-MM-YYYY | DD-MM-YYYY HH:MI[:SS]
--   DD/MM/YYYY | DD/MM/YYYY HH:MI[:SS]
-- (Casting a plain ISO string avoids any time-zone / DST side effects that
--  TO_TIMESTAMP() can introduce.)
CREATE OR REPLACE FUNCTION fn_ts(t text) RETURNS timestamp
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE s text := BTRIM(t);
BEGIN
    IF s IS NULL OR s = '' THEN
        RETURN NULL;
    ELSIF s ~ '^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2})?)?$' THEN
        RETURN s::timestamp;
    ELSIF s ~ '^\d{2}[-/]\d{2}[-/]\d{4}( \d{2}:\d{2}(:\d{2})?)?$' THEN
        RETURN REGEXP_REPLACE(s, '^(\d{2})[-/](\d{2})[-/](\d{4})', '\3-\2-\1')::timestamp;
    END IF;
    RETURN NULL;
EXCEPTION WHEN others THEN
    RETURN NULL;   -- impossible calendar date etc.
END $$;


/* ---------------------------------------------------------------------
   B2. Reviewed mapping table for crime_type spelling errors.
       Only add rows you have verified. Anything not listed falls back
       to INITCAP(trimmed value) - it is NOT guessed.
       Check the profiling output above and extend this list.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS crime_type_map;
CREATE TABLE crime_type_map (
    raw_value     text PRIMARY KEY,   -- lower-cased, trimmed
    standard_name text NOT NULL
);
INSERT INTO crime_type_map (raw_value, standard_name) VALUES
    ('roberry',  'Robbery'),
    ('homocide', 'Homicide');
-- ('burglery', 'Burglary'),  -- example: add only after confirming in the data


/* ---------------------------------------------------------------------
   B3. Build the clean table (raw table is only read, never changed)
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS crime_incidents_cleaning_log;
DROP TABLE IF EXISTS crime_incidents_clean;

CREATE TABLE crime_incidents_clean AS
SELECT
    r.row_id,
    fn_clean_text(r.incident_id)                 AS incident_id,
    COALESCE(m.standard_name,
             INITCAP(fn_clean_text(r.crime_type))) AS crime_type,
    fn_district(r.district)                      AS district,
    fn_clean_text(r.city)                        AS city,
    fn_clean_text(r.state)                       AS state,
    fn_clean_text(r.address)                     AS address,
    fn_lat(r.latitude)                           AS latitude,
    fn_lon(r.longitude)                          AS longitude,
    fn_ts(r.incident_datetime)                   AS incident_datetime,
    fn_clean_text(r.officer_id)                  AS officer_id,
    fn_clean_text(r.officer_first_name)          AS officer_first_name,
    fn_clean_text(r.officer_last_name)           AS officer_last_name,
    fn_clean_text(r.badge_number)                AS badge_number,
    fn_clean_text(r.suspect_id)                  AS suspect_id,
    fn_clean_text(r.suspect_first_name)          AS suspect_first_name,
    fn_clean_text(r.suspect_last_name)           AS suspect_last_name,
    fn_age(r.suspect_age)                        AS suspect_age,
    fn_gender(r.suspect_gender)                  AS suspect_gender,
    fn_race(r.suspect_race)                      AS suspect_race,
    fn_clean_text(r.victim_id)                   AS victim_id,
    fn_clean_text(r.victim_first_name)           AS victim_first_name,
    fn_clean_text(r.victim_last_name)            AS victim_last_name,
    fn_age(r.victim_age)                         AS victim_age,
    fn_gender(r.victim_gender)                   AS victim_gender,
    fn_clean_text(r.victim_phone)                AS victim_phone,
    fn_clean_text(r.weapon_used)                 AS weapon_used,
    fn_clean_text(r.severity)                    AS severity,
    fn_clean_text(r.case_status)                 AS case_status,
    fn_clean_text(r.resolution)                  AS resolution,
    fn_arrests(r.num_arrests)                    AS num_arrests,
    fn_loss(r.property_loss_usd)                 AS property_loss_usd,
    fn_bool(r.reported_online)                   AS reported_online,
    fn_clean_text(r.notes)                       AS notes
FROM crime_incidents_messy r
LEFT JOIN crime_type_map m
       ON m.raw_value = LOWER(BTRIM(r.crime_type));

SAVEPOINT after_build;   -- ROLLBACK TO SAVEPOINT after_build; undoes only later steps


/* ---------------------------------------------------------------------
   B4. Constraints: the database itself now enforces the rules.
       If any row violates one, this fails and the transaction aborts.
   --------------------------------------------------------------------- */
ALTER TABLE crime_incidents_clean
    ADD PRIMARY KEY (row_id),
    ADD CONSTRAINT chk_suspect_age CHECK (suspect_age BETWEEN 0 AND 120),
    ADD CONSTRAINT chk_victim_age  CHECK (victim_age  BETWEEN 0 AND 120),
    ADD CONSTRAINT chk_latitude    CHECK (latitude    BETWEEN -90  AND 90),
    ADD CONSTRAINT chk_longitude   CHECK (longitude   BETWEEN -180 AND 180),
    ADD CONSTRAINT chk_arrests     CHECK (num_arrests >= 0),
    ADD CONSTRAINT chk_loss        CHECK (property_loss_usd >= 0);

CREATE INDEX idx_clean_incident_id ON crime_incidents_clean (incident_id);


/* ---------------------------------------------------------------------
   B5. Cleaning log: every raw value that was rejected and set to NULL
   --------------------------------------------------------------------- */
CREATE TABLE crime_incidents_cleaning_log AS
SELECT r.row_id, r.incident_id, 'suspect_age'::text AS column_name,
       r.suspect_age AS raw_value, 'not numeric or outside 0-120'::text AS reason
FROM crime_incidents_messy r JOIN crime_incidents_clean c USING (row_id)
WHERE fn_clean_text(r.suspect_age) IS NOT NULL AND c.suspect_age IS NULL
UNION ALL
SELECT r.row_id, r.incident_id, 'victim_age', r.victim_age,
       'not numeric or outside 0-120'
FROM crime_incidents_messy r JOIN crime_incidents_clean c USING (row_id)
WHERE fn_clean_text(r.victim_age) IS NOT NULL AND c.victim_age IS NULL
UNION ALL
SELECT r.row_id, r.incident_id, 'latitude', r.latitude,
       'not numeric or outside -90..90'
FROM crime_incidents_messy r JOIN crime_incidents_clean c USING (row_id)
WHERE fn_clean_text(r.latitude) IS NOT NULL AND c.latitude IS NULL
UNION ALL
SELECT r.row_id, r.incident_id, 'longitude', r.longitude,
       'not numeric or outside -180..180'
FROM crime_incidents_messy r JOIN crime_incidents_clean c USING (row_id)
WHERE fn_clean_text(r.longitude) IS NOT NULL AND c.longitude IS NULL
UNION ALL
SELECT r.row_id, r.incident_id, 'incident_datetime', r.incident_datetime,
       'unrecognised format or impossible date'
FROM crime_incidents_messy r JOIN crime_incidents_clean c USING (row_id)
WHERE fn_clean_text(r.incident_datetime) IS NOT NULL AND c.incident_datetime IS NULL
UNION ALL
SELECT r.row_id, r.incident_id, 'num_arrests', r.num_arrests,
       'negative, fractional or not numeric'
FROM crime_incidents_messy r JOIN crime_incidents_clean c USING (row_id)
WHERE fn_clean_text(r.num_arrests) IS NOT NULL AND c.num_arrests IS NULL
UNION ALL
SELECT r.row_id, r.incident_id, 'property_loss_usd', r.property_loss_usd,
       'negative or not numeric'
FROM crime_incidents_messy r JOIN crime_incidents_clean c USING (row_id)
WHERE fn_clean_text(r.property_loss_usd) IS NOT NULL AND c.property_loss_usd IS NULL
UNION ALL
SELECT r.row_id, r.incident_id, 'reported_online', r.reported_online,
       'not a recognised boolean value'
FROM crime_incidents_messy r JOIN crime_incidents_clean c USING (row_id)
WHERE fn_clean_text(r.reported_online) IS NOT NULL AND c.reported_online IS NULL;

CREATE INDEX idx_cleaning_log_col ON crime_incidents_cleaning_log (column_name);


/* ---------------------------------------------------------------------
   B6. Automatic quality gates. Any failure raises an exception; with
       ON_ERROR_STOP the script halts and the open transaction is rolled
       back, so a bad build is never committed.
   --------------------------------------------------------------------- */
DO $$
DECLARE
    raw_n bigint;  clean_n bigint;  bad bigint;
BEGIN
    SELECT COUNT(*) INTO raw_n   FROM crime_incidents_messy;
    SELECT COUNT(*) INTO clean_n FROM crime_incidents_clean;
    IF raw_n <> clean_n THEN
        RAISE EXCEPTION 'Row count mismatch: raw=% clean=%', raw_n, clean_n;
    END IF;

    SELECT COUNT(*) INTO bad FROM crime_incidents_clean
    WHERE suspect_age NOT BETWEEN 0 AND 120 OR victim_age NOT BETWEEN 0 AND 120;
    IF bad > 0 THEN RAISE EXCEPTION 'QC failed: % rows with invalid age', bad; END IF;

    SELECT COUNT(*) INTO bad FROM crime_incidents_clean
    WHERE latitude NOT BETWEEN -90 AND 90 OR longitude NOT BETWEEN -180 AND 180;
    IF bad > 0 THEN RAISE EXCEPTION 'QC failed: % rows with invalid coordinates', bad; END IF;

    SELECT COUNT(*) INTO bad FROM crime_incidents_clean
    WHERE num_arrests < 0 OR property_loss_usd < 0;
    IF bad > 0 THEN RAISE EXCEPTION 'QC failed: % rows with negative values', bad; END IF;

    SELECT COUNT(*) INTO bad FROM crime_incidents_clean
    WHERE suspect_gender NOT IN ('Male','Female','Other')
       OR victim_gender  NOT IN ('Male','Female','Other');
    IF bad > 0 THEN
        RAISE WARNING 'QC note: % rows have unexpected gender values (review below)', bad;
    END IF;

    RAISE NOTICE 'QC passed: % rows cleaned', clean_n;
END $$;


/* ---------------------------------------------------------------------
   B7. Review output
       (When run with -f the script commits automatically if QC passed.
        To inspect BEFORE committing, run the statements by hand in psql
        and issue ROLLBACK; instead of COMMIT; if anything looks wrong.)
   --------------------------------------------------------------------- */
-- What was rejected, per column
SELECT column_name, COUNT(*) AS values_set_to_null
FROM crime_incidents_cleaning_log
GROUP BY column_name ORDER BY values_set_to_null DESC;

-- Duplicate incident IDs (reported, not deleted)
SELECT incident_id, COUNT(*) AS row_count
FROM crime_incidents_clean
GROUP BY incident_id HAVING COUNT(*) > 1
ORDER BY row_count DESC;

-- Categories after standardisation: confirm nothing odd is left
SELECT crime_type,     COUNT(*) FROM crime_incidents_clean GROUP BY 1 ORDER BY 1;
SELECT district,       COUNT(*) FROM crime_incidents_clean GROUP BY 1 ORDER BY 1;
SELECT suspect_gender, COUNT(*) FROM crime_incidents_clean GROUP BY 1 ORDER BY 1;
SELECT victim_gender,  COUNT(*) FROM crime_incidents_clean GROUP BY 1 ORDER BY 1;
SELECT severity,       COUNT(*) FROM crime_incidents_clean GROUP BY 1 ORDER BY 1;
SELECT case_status,    COUNT(*) FROM crime_incidents_clean GROUP BY 1 ORDER BY 1;

-- Date sanity
SELECT MIN(incident_datetime), MAX(incident_datetime),
       COUNT(*) FILTER (WHERE incident_datetime IS NULL) AS null_dates
FROM crime_incidents_clean;


/* Everything above looks right?  -> COMMIT.
   Something wrong, and you are running by hand?  -> ROLLBACK; instead. */
COMMIT;


/* =====================================================================
   PART C - AFTER COMMIT (cannot run inside a transaction)
   ===================================================================== */
VACUUM ANALYZE crime_incidents_clean;
VACUUM ANALYZE crime_incidents_cleaning_log;


/* =====================================================================
   OPTIONAL - later manual fixes, always inside a transaction
   ===================================================================== */
-- BEGIN;
--   INSERT INTO crime_type_map VALUES ('burglery', 'Burglary');
--   UPDATE crime_incidents_clean SET crime_type = 'Burglary'
--    WHERE row_id IN (SELECT row_id FROM crime_incidents_messy
--                      WHERE LOWER(BTRIM(crime_type)) = 'burglery');
--   -- check the row count reported by UPDATE, then:
-- COMMIT;   -- or ROLLBACK;

/* =====================================================================
   OPTIONAL - one row per incident_id (keeps the lowest row_id)
   Decide your duplicate policy first; the raw and clean tables keep all rows.
   ===================================================================== */
-- CREATE OR REPLACE VIEW crime_incidents_deduped AS
-- SELECT DISTINCT ON (incident_id) *
-- FROM crime_incidents_clean
-- ORDER BY incident_id, row_id;
