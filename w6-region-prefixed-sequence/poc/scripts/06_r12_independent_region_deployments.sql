-- ==========================================================================
-- W6 / R12 - CROSS-REGION UNIQUENESS, WITH THE PREFIX ACTUALLY LOAD-BEARING
-- ==========================================================================
-- SUPERSEDES 05. Read R12_RESULTS.md first.
--
-- 05 failed to create the condition it was testing. Its function named all
-- three region sequences in one CASE, so per R2's finding F4 every row
-- advanced all three. They moved in lockstep (all at NEXT_VALUE 2601 after
-- 1500 rows), drew disjoint ranges, never collided, and T5.2's PASS was
-- therefore vacuous - stripping the prefix would have changed nothing.
--
-- 04's T4.7 was vacuous for the opposite reason: one sequence shared by all
-- three regions. Twice now, an assertion has passed while being insensitive to
-- the thing under test.
--
-- THIS SCRIPT IS BUILT AROUND THAT LESSON. T6.1 and T6.3 are SENSITIVITY
-- CHECKS. If they do not establish that the raw values genuinely overlap, the
-- uniqueness result is reported as VACUOUS rather than PASS. Do not accept a
-- T6.2 pass without them.
--
-- WHY THREE SCHEMAS. In production each region runs its own Zone 2 deployment.
-- The same function text is deployed to each and, because the sequence
-- reference is UNQUALIFIED, it resolves "in the schema containing the
-- function" (R8, proven at 02's T2.1b). North America's function never names
-- EU's sequence. Three schemas reproduce that; one schema cannot.
--
--   T6.1  SENSITIVITY - do the three regions issue the SAME raw numbers?
--   T6.2  Prefixed keys, three CONCURRENT sessions, one target table
--   T6.3  SENSITIVITY - was the prefix actually load-bearing?
--   T6.4  Does every key decode to its issuing region?        (R13)
--   T6.5  Digit concatenation under the SAME real condition    (for C3)
--
-- Runtime: a few minutes. THREE SESSIONS for T6.2 and T6.5.
-- ==========================================================================

USE DATABASE LM_POC_DB;

-- ==========================================================================
-- SETUP - three schemas, each standing in for one region's deployment
-- ==========================================================================
CREATE SCHEMA IF NOT EXISTS W6_RGN_NA;
CREATE SCHEMA IF NOT EXISTS W6_RGN_EU;
CREATE SCHEMA IF NOT EXISTS W6_RGN_APAC;

-- Shared target, standing in for the global database the regions consolidate into.
CREATE OR REPLACE TABLE LM_POC_DB.POC_SCHEMA.w6_global_keys (
    K NUMBER(38,0), RAW_K NUMBER(38,0), REGION VARCHAR(50), SESSION_TAG VARCHAR(50)
);

-- --------------------------------------------------------------------------
-- NORTH AMERICA deployment
-- --------------------------------------------------------------------------
USE SCHEMA W6_RGN_NA;
CREATE OR REPLACE SEQUENCE w6_employee_seq START 1 INCREMENT 1;
CREATE OR REPLACE TABLE w6_region_map (REGION_NAME VARCHAR(100), REGION_CODE NUMBER(9,0));
INSERT INTO w6_region_map VALUES ('North America', 1);

-- NOTE: identical text in all three schemas. Unqualified names only.
CREATE OR REPLACE FUNCTION w6_regional_key(region_name VARCHAR)
RETURNS NUMBER(38,0) VOLATILE
COMMENT = 'Identical text in every region schema. Unqualified names resolve locally (R8).'
AS $$
    CAST((SELECT m.REGION_CODE FROM w6_region_map m WHERE m.REGION_NAME = region_name)
         * 1000000000000000 + w6_employee_seq.NEXTVAL AS NUMBER(38,0))
$$;
CREATE OR REPLACE FUNCTION w6_raw_key()
RETURNS NUMBER(38,0) VOLATILE
AS $$ w6_employee_seq.NEXTVAL $$;

-- --------------------------------------------------------------------------
-- EU deployment - same text, different schema, region code 2
-- --------------------------------------------------------------------------
USE SCHEMA W6_RGN_EU;
CREATE OR REPLACE SEQUENCE w6_employee_seq START 1 INCREMENT 1;
CREATE OR REPLACE TABLE w6_region_map (REGION_NAME VARCHAR(100), REGION_CODE NUMBER(9,0));
INSERT INTO w6_region_map VALUES ('EU', 2);
CREATE OR REPLACE FUNCTION w6_regional_key(region_name VARCHAR)
RETURNS NUMBER(38,0) VOLATILE
COMMENT = 'Identical text in every region schema. Unqualified names resolve locally (R8).'
AS $$
    CAST((SELECT m.REGION_CODE FROM w6_region_map m WHERE m.REGION_NAME = region_name)
         * 1000000000000000 + w6_employee_seq.NEXTVAL AS NUMBER(38,0))
$$;
CREATE OR REPLACE FUNCTION w6_raw_key()
RETURNS NUMBER(38,0) VOLATILE
AS $$ w6_employee_seq.NEXTVAL $$;

-- --------------------------------------------------------------------------
-- APAC deployment - same text, different schema, region code 3
-- --------------------------------------------------------------------------
USE SCHEMA W6_RGN_APAC;
CREATE OR REPLACE SEQUENCE w6_employee_seq START 1 INCREMENT 1;
CREATE OR REPLACE TABLE w6_region_map (REGION_NAME VARCHAR(100), REGION_CODE NUMBER(9,0));
INSERT INTO w6_region_map VALUES ('APAC', 3);
CREATE OR REPLACE FUNCTION w6_regional_key(region_name VARCHAR)
RETURNS NUMBER(38,0) VOLATILE
COMMENT = 'Identical text in every region schema. Unqualified names resolve locally (R8).'
AS $$
    CAST((SELECT m.REGION_CODE FROM w6_region_map m WHERE m.REGION_NAME = region_name)
         * 1000000000000000 + w6_employee_seq.NEXTVAL AS NUMBER(38,0))
$$;
CREATE OR REPLACE FUNCTION w6_raw_key()
RETURNS NUMBER(38,0) VOLATILE
AS $$ w6_employee_seq.NEXTVAL $$;

-- ==========================================================================
-- T6.1  SENSITIVITY CHECK - do the three regions issue the SAME raw numbers?
-- ==========================================================================
-- 05 died here. If this does not collide, STOP: the deployments are not
-- independent and nothing below can prove anything.
-- --------------------------------------------------------------------------
USE SCHEMA POC_SCHEMA;
CREATE OR REPLACE TABLE w6_raw_probe (RAW_K NUMBER(38,0), REGION VARCHAR(50));

INSERT INTO w6_raw_probe SELECT W6_RGN_NA.w6_raw_key(),   'North America' FROM TABLE(GENERATOR(ROWCOUNT => 500));
INSERT INTO w6_raw_probe SELECT W6_RGN_EU.w6_raw_key(),   'EU'            FROM TABLE(GENERATOR(ROWCOUNT => 500));
INSERT INTO w6_raw_probe SELECT W6_RGN_APAC.w6_raw_key(), 'APAC'          FROM TABLE(GENERATOR(ROWCOUNT => 500));

SELECT REGION, COUNT(*) AS n, MIN(RAW_K) AS min_raw, MAX(RAW_K) AS max_raw
FROM w6_raw_probe GROUP BY REGION ORDER BY REGION;
-- EXPECT: all three spanning a SIMILAR low range, each starting at or near 1.
-- 05 showed 1-500 / 601-1100 / 1101-1600, which was the failure. ---- RECORD

SELECT COUNT(*) AS rows_out,
       COUNT(DISTINCT RAW_K) AS distinct_raw,
       COUNT(*) - COUNT(DISTINCT RAW_K) AS collisions,
       CASE WHEN COUNT(*) - COUNT(DISTINCT RAW_K) > 0
            THEN 'SENSITIVITY OK - regions collide without a prefix, so the prefix can be tested'
            ELSE 'STOP - no collision. Deployments are not independent; T6.2 would be VACUOUS.'
       END AS verdict;
-- EXPECT: 1500 rows, ~500 distinct, ~1000 collisions.
-- >>> IF THIS SAYS STOP, DO NOT RUN T6.2. Report it and investigate. <<<
-- ------------------------------------------------------------------ PASS/FAIL

-- ==========================================================================
-- T6.2  PREFIXED KEYS, THREE CONCURRENT SESSIONS
-- ==========================================================================
-- >>> THREE SESSIONS, STARTED TOGETHER, WITH OVERLAP MEASURED (T6.2b). <<<
-- Sessions connect up to 4 seconds apart while a 10k insert takes ~1s, so
-- clicking Run in three worksheets does NOT guarantee overlap. Use a barrier.
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE W6_RGN_NA.w6_employee_seq   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE W6_RGN_EU.w6_employee_seq   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE W6_RGN_APAC.w6_employee_seq START 1 INCREMENT 1;
TRUNCATE TABLE LM_POC_DB.POC_SCHEMA.w6_global_keys;

-- >>> SESSION A <<<
INSERT INTO LM_POC_DB.POC_SCHEMA.w6_global_keys (K, RAW_K, REGION, SESSION_TAG)
SELECT W6_RGN_NA.w6_regional_key('North America'), NULL, 'North America', CURRENT_SESSION()
FROM TABLE(GENERATOR(ROWCOUNT => 10000));
-- >>> SESSION B <<<
INSERT INTO LM_POC_DB.POC_SCHEMA.w6_global_keys (K, RAW_K, REGION, SESSION_TAG)
SELECT W6_RGN_EU.w6_regional_key('EU'), NULL, 'EU', CURRENT_SESSION()
FROM TABLE(GENERATOR(ROWCOUNT => 10000));
-- >>> SESSION C <<<
INSERT INTO LM_POC_DB.POC_SCHEMA.w6_global_keys (K, RAW_K, REGION, SESSION_TAG)
SELECT W6_RGN_APAC.w6_regional_key('APAC'), NULL, 'APAC', CURRENT_SESSION()
FROM TABLE(GENERATOR(ROWCOUNT => 10000));

-- T6.2a  The uniqueness assertion.
SELECT COUNT(*) AS total, COUNT(DISTINCT K) AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT K) AS duplicates,
       COUNT(DISTINCT SESSION_TAG) AS sessions_involved,
       CASE WHEN COUNT(DISTINCT SESSION_TAG) < 3 THEN 'INVALID - not three sessions'
            WHEN COUNT(*) = COUNT(DISTINCT K) THEN 'PASS - pending the T6.3 sensitivity check'
            ELSE 'FAIL - the prefix did not separate the regions' END AS verdict
FROM LM_POC_DB.POC_SCHEMA.w6_global_keys;
-- EXPECT: 30000 / 30000 / 0 / 3.
-- NOTE the verdict wording: this is NOT a pass on its own. T6.3 decides.
-- ------------------------------------------------------------------ PASS/FAIL

-- T6.2b  OVERLAP - mandatory. Record each session's start and end and confirm
--        the windows intersect. sessions_involved = 3 does NOT prove overlap.
-- ------------------------------------------------------------------ RECORD

-- ==========================================================================
-- T6.3  SENSITIVITY CHECK - WAS THE PREFIX ACTUALLY LOAD-BEARING?
-- ==========================================================================
-- THE TEST THAT 04 AND 05 BOTH LACKED. If no raw value was issued to more than
-- one region, the prefix contributed nothing and T6.2 proved nothing.
-- --------------------------------------------------------------------------
WITH parts AS (
    SELECT REGION, K % 1000000000000000 AS seq_part FROM LM_POC_DB.POC_SCHEMA.w6_global_keys
),
shared AS (
    SELECT seq_part, COUNT(DISTINCT REGION) AS region_count FROM parts GROUP BY seq_part
)
SELECT (SELECT COUNT(*) FROM parts)                                   AS total_keys,
       (SELECT COUNT(*) FROM shared WHERE region_count > 1)           AS raw_values_shared_by_regions,
       (SELECT MAX(region_count) FROM shared)                         AS max_regions_per_raw_value,
       CASE WHEN (SELECT COUNT(*) FROM shared WHERE region_count > 1) = 0
            THEN 'VACUOUS - no raw value was reused, so the prefix was NOT load-bearing. R12 still unproven.'
            ELSE 'SOUND - raw values WERE reused across regions, and the prefixed keys are still unique. R12 PROVEN.'
       END AS verdict;
-- EXPECT: ~10,000 raw values shared, max_regions_per_raw_value = 3.
-- >>> THIS IS THE RESULT THAT DECIDES R12, NOT T6.2. <<<
-- ------------------------------------------------------------------ PASS/FAIL

-- ==========================================================================
-- T6.4  DOES EVERY KEY DECODE TO ITS ISSUING REGION?  (R13)
-- ==========================================================================
WITH codes AS (
    SELECT 'North America' AS region_name, 1 AS region_code
    UNION ALL SELECT 'EU', 2 UNION ALL SELECT 'APAC', 3
)
SELECT g.REGION, COUNT(*) AS keys_issued,
       SUM(CASE WHEN FLOOR(g.K / 1000000000000000) = c.region_code THEN 1 ELSE 0 END) AS decode_correct,
       CASE WHEN COUNT(*) = SUM(CASE WHEN FLOOR(g.K / 1000000000000000) = c.region_code THEN 1 ELSE 0 END)
            THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM LM_POC_DB.POC_SCHEMA.w6_global_keys g
JOIN codes c ON c.region_name = g.REGION
GROUP BY g.REGION ORDER BY g.REGION;
-- EXPECT: decode_correct = keys_issued for all three. --------------- PASS/FAIL

-- ==========================================================================
-- T6.5  DIGIT CONCATENATION UNDER THE SAME REAL CONDITION  (for C3)
-- ==========================================================================
-- NOW meaningful, because the raw values genuinely overlap. At three
-- single-digit codes concatenation should still pass - record the WIDTH
-- SPREAD, which is what separates the two schemes at a tenth region.
-- Single session is fine; this measures width, not concurrency.
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE W6_RGN_NA.w6_employee_seq   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE W6_RGN_EU.w6_employee_seq   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE W6_RGN_APAC.w6_employee_seq START 1 INCREMENT 1;
CREATE OR REPLACE TABLE LM_POC_DB.POC_SCHEMA.w6_concat_keys (K NUMBER(38,0), REGION VARCHAR(50));

INSERT INTO LM_POC_DB.POC_SCHEMA.w6_concat_keys
SELECT CAST('1' || CAST(W6_RGN_NA.w6_raw_key() AS VARCHAR) AS NUMBER(38,0)), 'North America'
FROM TABLE(GENERATOR(ROWCOUNT => 2000));
INSERT INTO LM_POC_DB.POC_SCHEMA.w6_concat_keys
SELECT CAST('2' || CAST(W6_RGN_EU.w6_raw_key() AS VARCHAR) AS NUMBER(38,0)), 'EU'
FROM TABLE(GENERATOR(ROWCOUNT => 2000));
INSERT INTO LM_POC_DB.POC_SCHEMA.w6_concat_keys
SELECT CAST('3' || CAST(W6_RGN_APAC.w6_raw_key() AS VARCHAR) AS NUMBER(38,0)), 'APAC'
FROM TABLE(GENERATOR(ROWCOUNT => 2000));

SELECT COUNT(*) AS total, COUNT(DISTINCT K) AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT K) AS duplicates,
       MIN(LENGTH(CAST(K AS VARCHAR))) AS min_width,
       MAX(LENGTH(CAST(K AS VARCHAR))) AS max_width,
       CASE WHEN COUNT(*) = COUNT(DISTINCT K)
            THEN 'PASS at 3 single-digit codes - note the width spread'
            ELSE 'FAIL' END AS verdict
FROM LM_POC_DB.POC_SCHEMA.w6_concat_keys;
-- EXPECT: 6000 / 6000 / 0, and min_width != max_width.
-- Compare against T6.2's keys, every one of which is 16 digits wide. Variable
-- width is what becomes a collision at a two-digit region code:
-- concat(1,11) and concat(11,1) are both 111. ----------------------- RECORD

-- --------------------------------------------------------------------------
-- TEARDOWN - only when every session has finished
-- --------------------------------------------------------------------------
DROP TABLE  IF EXISTS LM_POC_DB.POC_SCHEMA.w6_global_keys;
DROP TABLE  IF EXISTS LM_POC_DB.POC_SCHEMA.w6_concat_keys;
DROP TABLE  IF EXISTS LM_POC_DB.POC_SCHEMA.w6_raw_probe;
DROP SCHEMA IF EXISTS W6_RGN_NA   CASCADE;
DROP SCHEMA IF EXISTS W6_RGN_EU   CASCADE;
DROP SCHEMA IF EXISTS W6_RGN_APAC CASCADE;

-- ==========================================================================
-- WHAT THIS CLOSES
-- ==========================================================================
-- T6.1 collides AND T6.3 reports SOUND AND T6.2 shows 0 duplicates
--      -> R12 PROVEN under the real topology. The prefix, not the sequence,
--         is what keeps the regions apart.
-- T6.1 does NOT collide  -> stop. The deployments are not independent and the
--      run proves nothing. Do not report T6.2 as a pass.
-- T6.3 reports VACUOUS   -> same. This is the check 04 and 05 both lacked.
-- T6.4 passes            -> R13 reconfirmed under the real topology.
-- T6.5 passes            -> expected, and NOT an argument for concatenation.
--      Record the width spread; C3 turns on the tenth region.
--
-- As a side effect, the three identical function bodies in three schemas also
-- demonstrate R8: the same text binds its own local objects in each.
-- ==========================================================================
