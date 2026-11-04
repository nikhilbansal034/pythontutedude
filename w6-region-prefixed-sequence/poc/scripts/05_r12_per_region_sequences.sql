-- ==========================================================================
-- W6 / R12 - CROSS-REGION UNIQUENESS WHEN THE PREFIX IS LOAD-BEARING
-- ==========================================================================
-- WHY THIS EXISTS. 04_r10_concurrency.sql gave all three regions ONE shared
-- sequence, so T4.7's zero duplicates were guaranteed by the sequence itself -
-- the prefix contributed nothing to uniqueness. That is NOT the production
-- topology.
--
-- Per decision D4, each table has its own sequence PER REGION, and every one
-- starts at 1. North America's employee 1 and EU's employee 1 both exist, and
-- the region prefix is the ONLY thing separating them. That case has never run
-- in Snowflake.
--
--   T5.1  Confirm the regions really do collide without a prefix
--   T5.2  Fixed-width offset, three per-region sequences, CONCURRENT
--   T5.3  Does every key decode to its issuing region?
--   T5.4  Digit concatenation under the same conditions, for the C3 decision
--
-- Runtime: a few minutes. THREE SESSIONS NEEDED for T5.2 and T5.4.
-- ==========================================================================

USE DATABASE LM_POC_DB;
USE SCHEMA POC_SCHEMA;

-- --------------------------------------------------------------------------
-- SETUP - three sequences, one per region, EACH STARTING AT 1
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE w6_emp_seq_na   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE w6_emp_seq_eu   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE w6_emp_seq_apac START 1 INCREMENT 1;

CREATE OR REPLACE TABLE w6_region_map2 (REGION_NAME VARCHAR(100), REGION_CODE NUMBER(9,0));
INSERT INTO w6_region_map2 VALUES ('North America', 1), ('EU', 2), ('APAC', 3);

-- One function per region-sequence pairing, mirroring the branch-selector
-- shape R2 settled on. Unqualified names, for R8. VOLATILE, never IMMUTABLE.
CREATE OR REPLACE FUNCTION w6_key_per_region(region_name VARCHAR)
RETURNS NUMBER(38,0)
VOLATILE
COMMENT = 'VOLATILE required. Per-region sequences: the prefix is load-bearing for uniqueness.'
AS
$$
    CAST(
        (SELECT m.REGION_CODE FROM w6_region_map2 m WHERE m.REGION_NAME = region_name)
        * 1000000000000000
        + CASE region_name
              WHEN 'North America' THEN w6_emp_seq_na.NEXTVAL
              WHEN 'EU'            THEN w6_emp_seq_eu.NEXTVAL
              WHEN 'APAC'          THEN w6_emp_seq_apac.NEXTVAL
          END
    AS NUMBER(38,0))
$$;

-- The raw (unprefixed) value, to prove the collision the prefix prevents.
CREATE OR REPLACE FUNCTION w6_raw_per_region(region_name VARCHAR)
RETURNS NUMBER(38,0)
VOLATILE
AS
$$
    CASE region_name
        WHEN 'North America' THEN w6_emp_seq_na.NEXTVAL
        WHEN 'EU'            THEN w6_emp_seq_eu.NEXTVAL
        WHEN 'APAC'          THEN w6_emp_seq_apac.NEXTVAL
    END
$$;

CREATE OR REPLACE TABLE w6_keys_perregion (K NUMBER(38,0), RAW_K NUMBER(38,0), REGION VARCHAR(50), SESSION_TAG VARCHAR(50));

-- ==========================================================================
-- T5.1  WITHOUT A PREFIX, DO THE REGIONS COLLIDE?
-- ==========================================================================
-- Single session is fine here - this establishes the baseline the prefix fixes.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE w6_raw_probe (RAW_K NUMBER(38,0), REGION VARCHAR(50));
INSERT INTO w6_raw_probe
SELECT w6_raw_per_region('North America'), 'North America' FROM TABLE(GENERATOR(ROWCOUNT => 500))
UNION ALL
SELECT w6_raw_per_region('EU'), 'EU' FROM TABLE(GENERATOR(ROWCOUNT => 500))
UNION ALL
SELECT w6_raw_per_region('APAC'), 'APAC' FROM TABLE(GENERATOR(ROWCOUNT => 500));

SELECT COUNT(*) AS rows_out, COUNT(DISTINCT RAW_K) AS distinct_raw,
       COUNT(*) - COUNT(DISTINCT RAW_K) AS collisions,
       CASE WHEN COUNT(*) > COUNT(DISTINCT RAW_K)
            THEN 'CONFIRMED - regions collide without a prefix. This is what the prefix prevents.'
            ELSE 'UNEXPECTED - no collision; check the sequences really start at 1' END AS verdict
FROM w6_raw_probe;
-- EXPECT: 1500 rows, ~500 distinct, ~1000 collisions. If there is no collision,
-- the per-region sequences are not independent - stop and investigate.
-- ------------------------------------------------------------------ PASS/FAIL

-- ==========================================================================
-- T5.2  FIXED-WIDTH OFFSET, PER-REGION SEQUENCES, CONCURRENT
-- ==========================================================================
-- >>> THREE SESSIONS. Start them together, and MEASURE THE OVERLAP (T5.2b). <<<
-- Launching three worksheets by hand is NOT enough - R10's run showed sessions
-- connecting up to 4 seconds apart while the insert takes ~1.5s.
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE w6_emp_seq_na   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE w6_emp_seq_eu   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE w6_emp_seq_apac START 1 INCREMENT 1;
TRUNCATE TABLE w6_keys_perregion;

-- >>> SESSION A <<<
INSERT INTO w6_keys_perregion (K, RAW_K, REGION, SESSION_TAG)
SELECT w6_key_per_region('North America'), NULL, 'North America', CURRENT_SESSION()
FROM TABLE(GENERATOR(ROWCOUNT => 10000));
-- >>> SESSION B <<<
INSERT INTO w6_keys_perregion (K, RAW_K, REGION, SESSION_TAG)
SELECT w6_key_per_region('EU'), NULL, 'EU', CURRENT_SESSION()
FROM TABLE(GENERATOR(ROWCOUNT => 10000));
-- >>> SESSION C <<<
INSERT INTO w6_keys_perregion (K, RAW_K, REGION, SESSION_TAG)
SELECT w6_key_per_region('APAC'), NULL, 'APAC', CURRENT_SESSION()
FROM TABLE(GENERATOR(ROWCOUNT => 10000));

-- T5.2a  The assertion.
SELECT COUNT(*) AS total, COUNT(DISTINCT K) AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT K) AS duplicates,
       COUNT(DISTINCT SESSION_TAG) AS sessions_involved,
       CASE WHEN COUNT(DISTINCT SESSION_TAG) < 3
            THEN 'INVALID - not three sessions, redo'
            WHEN COUNT(*) = COUNT(DISTINCT K)
            THEN 'PASS - prefix keeps per-region sequences apart under concurrency'
            ELSE 'FAIL - the prefix did not separate the regions' END AS verdict
FROM w6_keys_perregion;
-- EXPECT: 30000 / 30000 / 0 / 3 / PASS. ----------------------------- PASS/FAIL

-- T5.2b  OVERLAP CHECK - mandatory, not optional.
--        sessions_involved = 3 does NOT prove the loads overlapped.
--        Record each session's start and end, and confirm the windows intersect.
--        If you cannot measure it, say so rather than claiming concurrency.
-- ------------------------------------------------------------------ RECORD

-- T5.2c  Proof the regions really did reuse the same sequence numbers.
SELECT REGION, COUNT(*) AS keys_issued,
       MIN(K % 1000000000000000) AS min_seq_part,
       MAX(K % 1000000000000000) AS max_seq_part
FROM w6_keys_perregion GROUP BY REGION ORDER BY REGION;
-- EXPECT: all three regions span a SIMILAR sequence_part range, each starting
-- near 1. That is the whole point - the raw numbers overlap, and only the
-- prefix separates them. --------------------------------------------- RECORD

-- ==========================================================================
-- T5.3  DOES EVERY KEY DECODE TO ITS ISSUING REGION?  (R13)
-- ==========================================================================
SELECT k.REGION, COUNT(*) AS keys_issued,
       SUM(CASE WHEN FLOOR(K / 1000000000000000) = m.REGION_CODE THEN 1 ELSE 0 END) AS decode_correct,
       CASE WHEN COUNT(*) = SUM(CASE WHEN FLOOR(K / 1000000000000000) = m.REGION_CODE THEN 1 ELSE 0 END)
            THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM w6_keys_perregion k
JOIN w6_region_map2 m ON m.REGION_NAME = k.REGION
GROUP BY k.REGION ORDER BY k.REGION;
-- EXPECT: decode_correct = keys_issued for all three. --------------- PASS/FAIL

-- ==========================================================================
-- T5.4  DIGIT CONCATENATION UNDER THE SAME CONDITIONS  (for C3)
-- ==========================================================================
-- At three single-digit region codes concatenation should ALSO pass. Running it
-- is still worth it: it shows the two schemes are indistinguishable today, which
-- is exactly why the choice has to be made on what happens at a tenth region
-- rather than on a passing test.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION w6_key_concat_per_region(region_name VARCHAR)
RETURNS NUMBER(38,0)
VOLATILE
AS
$$
    CAST(
        (SELECT CAST(m.REGION_CODE AS VARCHAR) FROM w6_region_map2 m WHERE m.REGION_NAME = region_name)
        || CAST(CASE region_name
                    WHEN 'North America' THEN w6_emp_seq_na.NEXTVAL
                    WHEN 'EU'            THEN w6_emp_seq_eu.NEXTVAL
                    WHEN 'APAC'          THEN w6_emp_seq_apac.NEXTVAL
                END AS VARCHAR)
    AS NUMBER(38,0))
$$;

CREATE OR REPLACE SEQUENCE w6_emp_seq_na   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE w6_emp_seq_eu   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE w6_emp_seq_apac START 1 INCREMENT 1;
CREATE OR REPLACE TABLE w6_keys_concat (K NUMBER(38,0), REGION VARCHAR(50));

INSERT INTO w6_keys_concat
SELECT w6_key_concat_per_region('North America'), 'North America' FROM TABLE(GENERATOR(ROWCOUNT => 2000))
UNION ALL
SELECT w6_key_concat_per_region('EU'), 'EU' FROM TABLE(GENERATOR(ROWCOUNT => 2000))
UNION ALL
SELECT w6_key_concat_per_region('APAC'), 'APAC' FROM TABLE(GENERATOR(ROWCOUNT => 2000));

SELECT COUNT(*) AS total, COUNT(DISTINCT K) AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT K) AS duplicates,
       MIN(LENGTH(CAST(K AS VARCHAR))) AS min_key_width,
       MAX(LENGTH(CAST(K AS VARCHAR))) AS max_key_width,
       CASE WHEN COUNT(*) = COUNT(DISTINCT K)
            THEN 'PASS at 3 single-digit codes - but see min/max width'
            ELSE 'FAIL' END AS verdict
FROM w6_keys_concat;
-- EXPECT: 6000 / 6000 / 0, and min_key_width != max_key_width.
-- THE WIDTH SPREAD IS THE POINT. Compare against T5.2, where every key is the
-- same width. Variable width is what becomes a collision at a two-digit region
-- code: concat(1,11) and concat(11,1) are both 111. ----------------- RECORD

-- --------------------------------------------------------------------------
-- TEARDOWN - run only when every session has finished
-- --------------------------------------------------------------------------
DROP FUNCTION IF EXISTS w6_key_per_region(VARCHAR);
DROP FUNCTION IF EXISTS w6_raw_per_region(VARCHAR);
DROP FUNCTION IF EXISTS w6_key_concat_per_region(VARCHAR);
DROP TABLE    IF EXISTS w6_keys_perregion;
DROP TABLE    IF EXISTS w6_keys_concat;
DROP TABLE    IF EXISTS w6_raw_probe;
DROP TABLE    IF EXISTS w6_region_map2;
DROP SEQUENCE IF EXISTS w6_emp_seq_na;
DROP SEQUENCE IF EXISTS w6_emp_seq_eu;
DROP SEQUENCE IF EXISTS w6_emp_seq_apac;

-- ==========================================================================
-- WHAT THIS CLOSES
-- ==========================================================================
-- T5.1 collides + T5.2 passes -> R12 proven under the REAL topology: the
--      prefix, not the sequence, is what keeps regions apart. Closes the gap
--      left by 04's T4.7.
-- T5.3 passes -> R13 proven under the same conditions.
-- T5.4 passes too -> expected, and NOT an argument for concatenation. Record
--      the width spread; the C3 decision turns on the tenth region, not on
--      whether three regions pass today.
-- ==========================================================================
