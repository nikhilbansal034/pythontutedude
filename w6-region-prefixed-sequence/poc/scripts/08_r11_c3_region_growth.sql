-- ==========================================================================
-- W6 / R11 + C3 - DOES THE DESIGN SURVIVE MORE REGIONS, AND WHICH SCHEME?
-- ==========================================================================
-- R11 is the ONLY requirement with no evidence behind it. Every run so far used
-- exactly North America, EU and APAC. Nobody has ever added a fourth region.
--
-- R11 and C3 are coupled, which is why one script settles both:
--   * while every region code is a SINGLE DIGIT, digit concatenation and
--     fixed-width offset are indistinguishable
--   * at a TWO-DIGIT code they diverge, because concat(1,11) and concat(11,1)
--     are both 111
-- So "will there ever be a tenth region?" decides whether C3 is cosmetic or
-- load-bearing. This script answers it with data instead of argument.
--
--   T8.1  R11 - add a FOURTH region as a DATA change only, no code change
--   T8.2  R11 - grow to TWELVE regions, including two-digit codes
--   T8.3  C3  - fixed-width offset at twelve regions
--   T8.4  C3  - digit concatenation at twelve regions   (expected to COLLIDE)
--   T8.5  C3  - decode correctness for both schemes at two-digit codes
--   T8.6  C3  - field width: headroom, and where it breaks
--
-- Runtime: about three minutes, single session. No concurrency needed - this
-- is about arithmetic and configuration, not parallelism.
--
-- LESSONS CARRIED FROM THE EARLIER PACKS:
--   * sequences FULLY QUALIFIED (R12 v3 F19/F23)
--   * functions created while the session is in their own schema (F23)
--   * run-scoped _V8 names and an opening cleanup block (F26)
--   * sensitivity gates before any "no duplicates" claim (F22)
--   * before/after comparisons, never absolute thresholds (F24)
-- ==========================================================================

USE DATABASE LM_POC_DB;

-- --------------------------------------------------------------------------
-- CLEANUP, then SETUP
-- --------------------------------------------------------------------------
DROP SCHEMA IF EXISTS W6V8 CASCADE;
CREATE SCHEMA W6V8;
USE SCHEMA W6V8;

-- One sequence per region, each starting at 1 - the production topology (D4).
-- Twelve of them, so the same objects serve T8.1 and T8.2.
CREATE OR REPLACE SEQUENCE seq_r01_v8 START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE seq_r02_v8 START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE seq_r03_v8 START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE seq_r04_v8 START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE seq_r05_v8 START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE seq_r06_v8 START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE seq_r07_v8 START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE seq_r08_v8 START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE seq_r09_v8 START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE seq_r10_v8 START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE seq_r11_v8 START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE seq_r12_v8 START 1 INCREMENT 1;

-- THE MAPPING TABLE - this is the only thing R11 says may change.
CREATE OR REPLACE TABLE region_map_v8 (REGION_NAME VARCHAR(100), REGION_CODE NUMBER(9,0));
INSERT INTO region_map_v8 VALUES
    ('North America', 1), ('EU', 2), ('APAC', 3);

CREATE OR REPLACE TABLE keys_v8 (
    K NUMBER(38,0), RAW_K NUMBER(38,0), REGION VARCHAR(100), SCHEME VARCHAR(20)
);

-- The region-code lookup. NOTE: this function is NOT touched again anywhere in
-- this script. If R11 holds, adding regions never requires editing it.
CREATE OR REPLACE FUNCTION region_code_v8(region_name VARCHAR)
RETURNS NUMBER(9,0)
VOLATILE
COMMENT = 'R11: adding a region must be an INSERT into region_map_v8, never a change here.'
AS $$
    (SELECT m.REGION_CODE FROM region_map_v8 m WHERE m.REGION_NAME = region_name)
$$;

-- ==========================================================================
-- T8.1  R11 - ADD A FOURTH REGION AS A DATA CHANGE ONLY
-- ==========================================================================
-- The whole of R11 in three statements: insert a row, draw keys, confirm the
-- function was never altered.
-- --------------------------------------------------------------------------
SELECT COUNT(*) AS regions_before FROM region_map_v8;
-- EXPECT: 3. ------------------------------------------------------- RECORD

INSERT INTO region_map_v8 VALUES ('LATAM', 4);     -- <<< the ONLY change made

SELECT 'LATAM' AS region, region_code_v8('LATAM') AS resolved_code,
       CASE WHEN region_code_v8('LATAM') = 4
            THEN 'PASS - a new region resolved with NO function change'
            WHEN region_code_v8('LATAM') IS NULL
            THEN 'FAIL - the new region did not resolve'
            ELSE 'FAIL - wrong code' END AS verdict;
-- EXPECT: 4 / PASS. This is R11. ------------------------------------ PASS/FAIL

-- Prove the function really was untouched since creation.
SELECT FUNCTION_NAME, CREATED, LAST_ALTERED,
       CASE WHEN CREATED = LAST_ALTERED
            THEN 'PASS - function never altered; the region arrived as data'
            ELSE 'CHECK - function was altered during this run' END AS verdict
FROM INFORMATION_SCHEMA.FUNCTIONS
WHERE FUNCTION_SCHEMA = 'W6V8' AND FUNCTION_NAME = 'REGION_CODE_V8';
-- EXPECT: CREATED = LAST_ALTERED, PASS. ----------------------------- PASS/FAIL

-- ==========================================================================
-- T8.2  R11 - GROW TO TWELVE REGIONS, INCLUDING TWO-DIGIT CODES
-- ==========================================================================
-- Codes 10, 11 and 12 are the ones that matter. Everything before this point
-- behaves identically under both C3 candidates.
-- --------------------------------------------------------------------------
INSERT INTO region_map_v8 VALUES
    ('UK', 5), ('MEA', 6), ('ANZ', 7), ('Japan', 8), ('India', 9),
    ('Nordics', 10), ('Benelux', 11), ('Iberia', 12);

SELECT COUNT(*) AS regions_now,
       SUM(CASE WHEN REGION_CODE >= 10 THEN 1 ELSE 0 END) AS two_digit_codes,
       CASE WHEN COUNT(*) = 12 AND SUM(CASE WHEN REGION_CODE >= 10 THEN 1 ELSE 0 END) = 3
            THEN 'SENSITIVITY OK - two-digit codes present, so C3 can be discriminated'
            ELSE 'STOP - without two-digit codes T8.4 cannot fail and proves nothing'
       END AS verdict
FROM region_map_v8;
-- EXPECT: 12 / 3 / SENSITIVITY OK.
-- >>> IF THIS SAYS STOP, T8.4 WOULD BE VACUOUS. Do not continue. <<<
-- ------------------------------------------------------------------ PASS/FAIL

-- Draw 400 raw values from each of the twelve per-region sequences.
-- One statement per region, so no statement references two sequences (05's F14).
TRUNCATE TABLE keys_v8;
INSERT INTO keys_v8 (RAW_K, REGION, SCHEME) SELECT LM_POC_DB.W6V8.seq_r01_v8.NEXTVAL, 'North America', 'raw' FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v8 (RAW_K, REGION, SCHEME) SELECT LM_POC_DB.W6V8.seq_r02_v8.NEXTVAL, 'EU',            'raw' FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v8 (RAW_K, REGION, SCHEME) SELECT LM_POC_DB.W6V8.seq_r03_v8.NEXTVAL, 'APAC',          'raw' FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v8 (RAW_K, REGION, SCHEME) SELECT LM_POC_DB.W6V8.seq_r04_v8.NEXTVAL, 'LATAM',         'raw' FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v8 (RAW_K, REGION, SCHEME) SELECT LM_POC_DB.W6V8.seq_r05_v8.NEXTVAL, 'UK',            'raw' FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v8 (RAW_K, REGION, SCHEME) SELECT LM_POC_DB.W6V8.seq_r06_v8.NEXTVAL, 'MEA',           'raw' FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v8 (RAW_K, REGION, SCHEME) SELECT LM_POC_DB.W6V8.seq_r07_v8.NEXTVAL, 'ANZ',           'raw' FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v8 (RAW_K, REGION, SCHEME) SELECT LM_POC_DB.W6V8.seq_r08_v8.NEXTVAL, 'Japan',         'raw' FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v8 (RAW_K, REGION, SCHEME) SELECT LM_POC_DB.W6V8.seq_r09_v8.NEXTVAL, 'India',         'raw' FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v8 (RAW_K, REGION, SCHEME) SELECT LM_POC_DB.W6V8.seq_r10_v8.NEXTVAL, 'Nordics',       'raw' FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v8 (RAW_K, REGION, SCHEME) SELECT LM_POC_DB.W6V8.seq_r11_v8.NEXTVAL, 'Benelux',       'raw' FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v8 (RAW_K, REGION, SCHEME) SELECT LM_POC_DB.W6V8.seq_r12_v8.NEXTVAL, 'Iberia',        'raw' FROM TABLE(GENERATOR(ROWCOUNT => 400));

-- SENSITIVITY GATE: the regions must genuinely reuse each other's raw numbers.
SELECT COUNT(*) AS rows_out, COUNT(DISTINCT RAW_K) AS distinct_raw,
       COUNT(*) - COUNT(DISTINCT RAW_K) AS collisions,
       CASE WHEN COUNT(*) - COUNT(DISTINCT RAW_K) > 0
            THEN 'SENSITIVITY OK - raw values collide, so the prefix has real work to do'
            ELSE 'STOP - no collision; T8.3 and T8.4 would both be vacuous' END AS verdict
FROM keys_v8 WHERE SCHEME = 'raw';
-- EXPECT: 4800 / 400 / 4400 / SENSITIVITY OK. ----------------------- PASS/FAIL

-- ==========================================================================
-- T8.3  C3 CANDIDATE A - FIXED-WIDTH OFFSET AT TWELVE REGIONS
-- ==========================================================================
INSERT INTO keys_v8 (K, RAW_K, REGION, SCHEME)
SELECT CAST(m.REGION_CODE AS NUMBER(38,0)) * 1000000000000000 + r.RAW_K,
       r.RAW_K, r.REGION, 'offset'
FROM keys_v8 r JOIN region_map_v8 m ON m.REGION_NAME = r.REGION
WHERE r.SCHEME = 'raw';

SELECT COUNT(*) AS total, COUNT(DISTINCT K) AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT K) AS duplicates,
       MIN(LENGTH(CAST(K AS VARCHAR))) AS min_width,
       MAX(LENGTH(CAST(K AS VARCHAR))) AS max_width,
       CASE WHEN COUNT(*) = COUNT(DISTINCT K)
            THEN 'PASS - offset survives twelve regions including two-digit codes'
            ELSE 'FAIL - offset collided' END AS verdict
FROM keys_v8 WHERE SCHEME = 'offset';
-- EXPECT: 4800 / 4800 / 0 duplicates. Widths 16-17 (two-digit codes add one).
-- ------------------------------------------------------------------ PASS/FAIL

-- ==========================================================================
-- T8.4  C3 CANDIDATE B - DIGIT CONCATENATION AT TWELVE REGIONS
-- ==========================================================================
-- EXPECTED TO COLLIDE. This is the decisive C3 evidence, and it is the test
-- that could not be run until R11's two-digit codes existed.
-- --------------------------------------------------------------------------
INSERT INTO keys_v8 (K, RAW_K, REGION, SCHEME)
SELECT CAST(CAST(m.REGION_CODE AS VARCHAR) || CAST(r.RAW_K AS VARCHAR) AS NUMBER(38,0)),
       r.RAW_K, r.REGION, 'concat'
FROM keys_v8 r JOIN region_map_v8 m ON m.REGION_NAME = r.REGION
WHERE r.SCHEME = 'raw';

SELECT COUNT(*) AS total, COUNT(DISTINCT K) AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT K) AS duplicates,
       MIN(LENGTH(CAST(K AS VARCHAR))) AS min_width,
       MAX(LENGTH(CAST(K AS VARCHAR))) AS max_width,
       CASE WHEN COUNT(*) > COUNT(DISTINCT K)
            THEN 'CONFIRMED - concatenation COLLIDES once region codes reach two digits'
            ELSE 'UNEXPECTED - no collision; re-check that codes 10-12 were used' END AS verdict
FROM keys_v8 WHERE SCHEME = 'concat';
-- EXPECT: 4800 total, fewer distinct, duplicates > 0, widths varying.
-- ------------------------------------------------------------------ PASS/FAIL

-- Name the actual colliding pairs - this is the slide-worthy output.
SELECT K AS colliding_key,
       COUNT(*) AS times_issued,
       LISTAGG(REGION || ' raw=' || RAW_K, '  |  ') WITHIN GROUP (ORDER BY REGION) AS issued_to
FROM keys_v8 WHERE SCHEME = 'concat'
GROUP BY K HAVING COUNT(*) > 1
ORDER BY K LIMIT 10;
-- EXPECT: e.g. key 1101 issued to 'North America raw=101' and 'Benelux raw=1'.
-- Two different employees in two different regions, one primary key.
-- ------------------------------------------------------------------ RECORD

-- ==========================================================================
-- T8.5  C3 - DECODE CORRECTNESS AT TWO-DIGIT CODES  (R13 under growth)
-- ==========================================================================
-- Offset: decode by division. Concat: there is no correct decode, because
-- nothing marks where the region code ends. The naive "first character" rule
-- is shown failing.
-- --------------------------------------------------------------------------
SELECT 'offset' AS scheme, COUNT(*) AS keys_tested,
       SUM(CASE WHEN FLOOR(k.K / 1000000000000000) = m.REGION_CODE THEN 1 ELSE 0 END) AS decode_correct,
       CASE WHEN COUNT(*) = SUM(CASE WHEN FLOOR(k.K / 1000000000000000) = m.REGION_CODE THEN 1 ELSE 0 END)
            THEN 'PASS - every key decodes, two-digit codes included'
            ELSE 'FAIL' END AS verdict
FROM keys_v8 k JOIN region_map_v8 m ON m.REGION_NAME = k.REGION
WHERE k.SCHEME = 'offset'
UNION ALL
SELECT 'concat', COUNT(*),
       SUM(CASE WHEN TO_NUMBER(LEFT(CAST(k.K AS VARCHAR), 1)) = m.REGION_CODE THEN 1 ELSE 0 END),
       CASE WHEN COUNT(*) = SUM(CASE WHEN TO_NUMBER(LEFT(CAST(k.K AS VARCHAR), 1)) = m.REGION_CODE THEN 1 ELSE 0 END)
            THEN 'PASS' ELSE 'FAIL - first-character decode is wrong for two-digit codes' END
FROM keys_v8 k JOIN region_map_v8 m ON m.REGION_NAME = k.REGION
WHERE k.SCHEME = 'concat';
-- EXPECT: offset PASS; concat FAIL for every key whose region code is 10-12.
-- ------------------------------------------------------------------ PASS/FAIL

-- ==========================================================================
-- T8.6  C3 - FIELD WIDTH: HEADROOM AND WHERE IT BREAKS
-- ==========================================================================
-- The width must be fixed once and never changed. This records the ceiling so
-- the choice is made on numbers.
-- --------------------------------------------------------------------------
WITH widths AS (
    SELECT 12 AS w UNION ALL SELECT 15 UNION ALL SELECT 18 UNION ALL SELECT 19
),
codes AS (SELECT 9 AS max_code UNION ALL SELECT 99 UNION ALL SELECT 999)
SELECT w.w                                         AS field_width_digits,
       c.max_code                                  AS max_region_code,
       POWER(10, w.w) - 1                          AS keys_per_region,
       LENGTH(CAST(CAST(c.max_code AS NUMBER(38,0)) * POWER(10, w.w) AS VARCHAR)) AS largest_key_digits,
       CASE WHEN c.max_code * POWER(10, w.w) < POWER(10, 38)
            THEN 'fits NUMBER(38,0)' ELSE 'OVERFLOWS NUMBER(38,0)' END AS number_38_check,
       CASE WHEN POWER(10, w.w) < 9223372036854775807
            THEN 'sequence half fits 64-bit' ELSE 'EXCEEDS the 64-bit sequence ceiling' END AS seq_64bit_check
FROM widths w CROSS JOIN codes c ORDER BY w.w, c.max_code;
-- EXPECT: every row fits NUMBER(38,0). Width 19 EXCEEDS the 64-bit sequence
-- ceiling (9.22e18), which is the real constraint - not NUMBER(38,0).
-- RECOMMENDATION going in: width 15. A quadrillion keys per region, comfortable
-- margin under the 64-bit sequence limit, room for a 3-digit region code.
-- ------------------------------------------------------------------ RECORD

-- Does a downstream 64-bit consumer survive the chosen width?
SELECT 1000000000000000 * 12 + 400                 AS sample_key_width15,
       9223372036854775807                          AS bigint_max,
       CASE WHEN 1000000000000000 * 12 + 400 < 9223372036854775807
            THEN 'PASS - a 15-digit field with 2-digit codes still fits a signed 64-bit consumer'
            ELSE 'FAIL - would overflow a Java long / BIGINT downstream' END AS verdict;
-- EXPECT: PASS. At width 18 with a 2-digit code this FAILS, which is why 15 is
-- recommended over 18. ---------------------------------------------- PASS/FAIL

-- --------------------------------------------------------------------------
-- TEARDOWN
-- --------------------------------------------------------------------------
DROP SCHEMA IF EXISTS W6V8 CASCADE;

-- ==========================================================================
-- WHAT THIS CLOSES
-- ==========================================================================
-- T8.1 PASS + function unaltered -> R11 PROVEN. A new region is a data change.
-- T8.2 SENSITIVITY OK            -> two-digit codes present, so T8.4 can fail.
-- T8.3 0 duplicates              -> offset survives growth.
-- T8.4 duplicates > 0            -> concatenation does NOT. This is the C3
--                                   decision, settled by data.
-- T8.5 offset PASS, concat FAIL  -> R13 only holds under offset once codes
--                                   reach two digits.
-- T8.6                           -> pins the field width. The binding
--                                   constraint is the 64-bit SEQUENCE ceiling
--                                   and any downstream 64-bit consumer, NOT
--                                   NUMBER(38,0).
--
-- If T8.4 does NOT collide, stop and re-check that codes 10-12 were really
-- used - the test is designed to fail and a pass means it did not run properly.
-- ==========================================================================
