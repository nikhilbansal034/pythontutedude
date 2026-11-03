-- ==========================================================================
-- W6 / R12 - CROSS-REGION UNIQUENESS, WITH FULLY-QUALIFIED SEQUENCES
-- ==========================================================================
-- SUPERSEDES 06. Read R12_RESULTS_v2.md first.
--
-- WHY 06 HALTED. Its functions referenced the sequence UNQUALIFIED, on the
-- documented rule that "all unqualified objects in a view or UDF definition
-- will be resolved in the view's or UDF's schema only" (Name resolution).
-- THAT IS NOT WHAT SEQUENCES DO. 06 proved, with a prediction test, that an
-- unqualified SEQUENCE resolves in the CALLER'S current schema at run time
-- while a TABLE in the same body resolves in the FUNCTION'S schema. Calling
-- W6_RGN_NA's function from a schema with no same-named sequence failed with
-- invalid identifier, even though the function's own schema had one.
--
-- So all three regional functions silently drew from POC_SCHEMA's leftover
-- sequence, the regions never collided, and the T6.1 gate correctly stopped
-- the run before any uniqueness claim was made.
--
-- THE FIX: fully qualify the sequence inside the body. The reference then
-- travels with the function instead of following the session. That is also
-- what production already does -- Q2 line 50 writes
-- $$inout_param_hr_database_name.$$inout_param_hr_main_schema_name.EMPLOYEE_SEQ,
-- substituted by the orchestrator before Snowflake sees the SQL.
--
--   T7.0  REGRESSION - re-prove the qualified/unqualified asymmetry
--   T7.1  SENSITIVITY - do the three regions issue the SAME raw numbers?
--   T7.2  CALLER-SCHEMA INDEPENDENCE - same answer from any session
--   T7.3  Prefixed keys, three CONCURRENT sessions
--   T7.4  SENSITIVITY - was the prefix actually load-bearing?
--   T7.5  Does every key decode to its issuing region?           (R13)
--
-- NOTE ON NAMES: every object is suffixed _V7 so a leftover from an earlier
-- pack cannot be picked up by accident. 06's T6.1 only produced plausible
-- numbers because R2's leftover POC_SCHEMA.W6_EMPLOYEE_SEQ happened to exist.
--
-- Runtime: a few minutes. THREE SESSIONS for T7.3.
-- ==========================================================================

USE DATABASE LM_POC_DB;

-- ==========================================================================
-- CLEANUP FROM 06 - run first, so nothing from that run can interfere
-- ==========================================================================
DROP SCHEMA IF EXISTS W6_RGN_NA   CASCADE;
DROP SCHEMA IF EXISTS W6_RGN_EU   CASCADE;
DROP SCHEMA IF EXISTS W6_RGN_APAC CASCADE;
DROP TABLE  IF EXISTS LM_POC_DB.POC_SCHEMA.w6_global_keys;
DROP TABLE  IF EXISTS LM_POC_DB.POC_SCHEMA.w6_raw_probe;

-- ==========================================================================
-- SETUP - three schemas, each standing in for one region's deployment
-- ==========================================================================
CREATE SCHEMA IF NOT EXISTS W6V7_NA;
CREATE SCHEMA IF NOT EXISTS W6V7_EU;
CREATE SCHEMA IF NOT EXISTS W6V7_APAC;

USE SCHEMA POC_SCHEMA;
CREATE OR REPLACE TABLE w6v7_global_keys (
    K NUMBER(38,0), REGION VARCHAR(50), SESSION_TAG VARCHAR(50)
);
CREATE OR REPLACE TABLE w6v7_raw_probe (RAW_K NUMBER(38,0), REGION VARCHAR(50));

-- --------------------------------------------------------------------------
-- Three deployments. The sequence is FULLY QUALIFIED in every body; the region
-- map stays unqualified, which is the one case the docs get right.
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE W6V7_NA.emp_seq_v7   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE W6V7_EU.emp_seq_v7   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE W6V7_APAC.emp_seq_v7 START 1 INCREMENT 1;

CREATE OR REPLACE TABLE W6V7_NA.region_map_v7   (REGION_NAME VARCHAR(100), REGION_CODE NUMBER(9,0));
CREATE OR REPLACE TABLE W6V7_EU.region_map_v7   (REGION_NAME VARCHAR(100), REGION_CODE NUMBER(9,0));
CREATE OR REPLACE TABLE W6V7_APAC.region_map_v7 (REGION_NAME VARCHAR(100), REGION_CODE NUMBER(9,0));
INSERT INTO W6V7_NA.region_map_v7   VALUES ('North America', 1);
INSERT INTO W6V7_EU.region_map_v7   VALUES ('EU', 2);
INSERT INTO W6V7_APAC.region_map_v7 VALUES ('APAC', 3);

-- NORTH AMERICA
CREATE OR REPLACE FUNCTION W6V7_NA.regional_key_v7(region_name VARCHAR)
RETURNS NUMBER(38,0) VOLATILE
COMMENT = 'Sequence FULLY QUALIFIED: unqualified sequences follow the CALLER schema, not the function schema (06 F19).'
AS $$
    CAST((SELECT m.REGION_CODE FROM region_map_v7 m WHERE m.REGION_NAME = region_name)
         * 1000000000000000 + LM_POC_DB.W6V7_NA.emp_seq_v7.NEXTVAL AS NUMBER(38,0))
$$;
CREATE OR REPLACE FUNCTION W6V7_NA.raw_key_v7()
RETURNS NUMBER(38,0) VOLATILE
AS $$ LM_POC_DB.W6V7_NA.emp_seq_v7.NEXTVAL $$;
-- Deliberately UNQUALIFIED, kept only as the T7.0 regression control.
CREATE OR REPLACE FUNCTION W6V7_NA.raw_key_unqualified_v7()
RETURNS NUMBER(38,0) VOLATILE
COMMENT = 'CONTROL ONLY - demonstrates the caller-schema resolution defect. Never ship this form.'
AS $$ emp_seq_v7.NEXTVAL $$;

-- EU
CREATE OR REPLACE FUNCTION W6V7_EU.regional_key_v7(region_name VARCHAR)
RETURNS NUMBER(38,0) VOLATILE
COMMENT = 'Sequence FULLY QUALIFIED.'
AS $$
    CAST((SELECT m.REGION_CODE FROM region_map_v7 m WHERE m.REGION_NAME = region_name)
         * 1000000000000000 + LM_POC_DB.W6V7_EU.emp_seq_v7.NEXTVAL AS NUMBER(38,0))
$$;
CREATE OR REPLACE FUNCTION W6V7_EU.raw_key_v7()
RETURNS NUMBER(38,0) VOLATILE
AS $$ LM_POC_DB.W6V7_EU.emp_seq_v7.NEXTVAL $$;

-- APAC
CREATE OR REPLACE FUNCTION W6V7_APAC.regional_key_v7(region_name VARCHAR)
RETURNS NUMBER(38,0) VOLATILE
COMMENT = 'Sequence FULLY QUALIFIED.'
AS $$
    CAST((SELECT m.REGION_CODE FROM region_map_v7 m WHERE m.REGION_NAME = region_name)
         * 1000000000000000 + LM_POC_DB.W6V7_APAC.emp_seq_v7.NEXTVAL AS NUMBER(38,0))
$$;
CREATE OR REPLACE FUNCTION W6V7_APAC.raw_key_v7()
RETURNS NUMBER(38,0) VOLATILE
AS $$ LM_POC_DB.W6V7_APAC.emp_seq_v7.NEXTVAL $$;

-- ==========================================================================
-- T7.0  REGRESSION - the asymmetry 06 discovered, pinned as a standing test
-- ==========================================================================
-- Call NA's two raw functions from a FOREIGN schema. The qualified one must
-- draw NA's sequence; the unqualified one must NOT.
-- --------------------------------------------------------------------------
USE SCHEMA W6V7_EU;
SELECT W6V7_NA.raw_key_v7() AS qualified_called_from_eu, CURRENT_SCHEMA() AS caller_schema;
-- EXPECT: 1 (NA's sequence, first draw). ---------------------------- RECORD

SELECT W6V7_NA.raw_key_unqualified_v7() AS unqualified_called_from_eu, CURRENT_SCHEMA() AS caller_schema;
-- EXPECT: a value from EU's sequence, NOT NA's - that is the defect. - RECORD

SELECT SEQUENCE_SCHEMA, SEQUENCE_NAME, NEXT_VALUE
FROM LM_POC_DB.INFORMATION_SCHEMA.SEQUENCES
WHERE SEQUENCE_NAME = 'EMP_SEQ_V7' ORDER BY SEQUENCE_SCHEMA;
SELECT CASE
    WHEN (SELECT TO_NUMBER(NEXT_VALUE) FROM LM_POC_DB.INFORMATION_SCHEMA.SEQUENCES
          WHERE SEQUENCE_SCHEMA='W6V7_NA' AND SEQUENCE_NAME='EMP_SEQ_V7') > 1
     AND (SELECT TO_NUMBER(NEXT_VALUE) FROM LM_POC_DB.INFORMATION_SCHEMA.SEQUENCES
          WHERE SEQUENCE_SCHEMA='W6V7_EU' AND SEQUENCE_NAME='EMP_SEQ_V7') > 1
    THEN 'CONFIRMED - qualified drew NA, unqualified drew EU. Asymmetry reproduced.'
    ELSE 'DID NOT REPRODUCE - re-check, and say so; 06 F19 may be version-specific.'
END AS verdict;
-- EXPECT: CONFIRMED. If it does not reproduce, that is itself important -
-- report it rather than proceeding quietly. ------------------------- RECORD

-- ==========================================================================
-- T7.1  SENSITIVITY GATE - do the three regions issue the SAME raw numbers?
-- ==========================================================================
-- 06 died here. If this does not collide, STOP.
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE W6V7_NA.emp_seq_v7   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE W6V7_EU.emp_seq_v7   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE W6V7_APAC.emp_seq_v7 START 1 INCREMENT 1;

USE SCHEMA POC_SCHEMA;
TRUNCATE TABLE w6v7_raw_probe;
INSERT INTO w6v7_raw_probe SELECT W6V7_NA.raw_key_v7(),   'North America' FROM TABLE(GENERATOR(ROWCOUNT => 500));
INSERT INTO w6v7_raw_probe SELECT W6V7_EU.raw_key_v7(),   'EU'            FROM TABLE(GENERATOR(ROWCOUNT => 500));
INSERT INTO w6v7_raw_probe SELECT W6V7_APAC.raw_key_v7(), 'APAC'          FROM TABLE(GENERATOR(ROWCOUNT => 500));

SELECT REGION, COUNT(*) AS n, MIN(RAW_K) AS min_raw, MAX(RAW_K) AS max_raw
FROM w6v7_raw_probe GROUP BY REGION ORDER BY REGION;
-- EXPECT: all three 1-500. 06 showed 101-600 / 701-1200 / 1301-1800, disjoint,
-- which was the failure. -------------------------------------------- RECORD

SELECT COUNT(*) AS rows_out, COUNT(DISTINCT RAW_K) AS distinct_raw,
       COUNT(*) - COUNT(DISTINCT RAW_K) AS collisions,
       CASE WHEN COUNT(*) - COUNT(DISTINCT RAW_K) > 0
            THEN 'SENSITIVITY OK - regions collide without a prefix, so the prefix can be tested'
            ELSE 'STOP - no collision. Do NOT run T7.3; it would be VACUOUS.' END AS verdict
FROM w6v7_raw_probe;
-- EXPECT: 1500 / 500 / 1000 / SENSITIVITY OK.
-- >>> IF THIS SAYS STOP, DO NOT CONTINUE. Report it. <<< ------------ PASS/FAIL

-- ==========================================================================
-- T7.2  CALLER-SCHEMA INDEPENDENCE - the property qualification buys us
-- ==========================================================================
-- Same function, three different caller schemas, must always draw its own.
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE W6V7_NA.emp_seq_v7 START 1 INCREMENT 1;

USE SCHEMA W6V7_EU;    SELECT W6V7_NA.raw_key_v7() AS from_eu;
USE SCHEMA W6V7_APAC;  SELECT W6V7_NA.raw_key_v7() AS from_apac;
USE SCHEMA POC_SCHEMA; SELECT W6V7_NA.raw_key_v7() AS from_poc;

SELECT SEQUENCE_SCHEMA, NEXT_VALUE,
       CASE WHEN SEQUENCE_SCHEMA = 'W6V7_NA' AND TO_NUMBER(NEXT_VALUE) = 4
            THEN 'PASS - all three calls drew NA''s own sequence regardless of caller'
            WHEN SEQUENCE_SCHEMA = 'W6V7_NA'
            THEN 'CHECK - expected NEXT_VALUE 4 after three calls'
            WHEN TO_NUMBER(NEXT_VALUE) > 1
            THEN 'FAIL - a foreign sequence advanced; qualification did not hold'
            ELSE 'ok - untouched' END AS verdict
FROM LM_POC_DB.INFORMATION_SCHEMA.SEQUENCES
WHERE SEQUENCE_NAME = 'EMP_SEQ_V7' ORDER BY SEQUENCE_SCHEMA;
-- EXPECT: W6V7_NA at 4 (allowing for block reservation, it may read higher -
-- what matters is that EU's and APAC's stay at 1). ------------------ PASS/FAIL

-- ==========================================================================
-- T7.3  PREFIXED KEYS, THREE CONCURRENT SESSIONS
-- ==========================================================================
-- >>> THREE SESSIONS, STARTED TOGETHER, OVERLAP MEASURED (T7.3b). <<<
-- Sessions connect up to 4 seconds apart while a 10k insert takes ~1s, so
-- clicking Run in three worksheets does NOT guarantee overlap. Use a barrier.
-- Each session may use ANY current schema - that is the point of T7.2.
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE W6V7_NA.emp_seq_v7   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE W6V7_EU.emp_seq_v7   START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE W6V7_APAC.emp_seq_v7 START 1 INCREMENT 1;
TRUNCATE TABLE LM_POC_DB.POC_SCHEMA.w6v7_global_keys;

-- >>> SESSION A <<<
INSERT INTO LM_POC_DB.POC_SCHEMA.w6v7_global_keys (K, REGION, SESSION_TAG)
SELECT W6V7_NA.regional_key_v7('North America'), 'North America', CURRENT_SESSION()
FROM TABLE(GENERATOR(ROWCOUNT => 10000));
-- >>> SESSION B <<<
INSERT INTO LM_POC_DB.POC_SCHEMA.w6v7_global_keys (K, REGION, SESSION_TAG)
SELECT W6V7_EU.regional_key_v7('EU'), 'EU', CURRENT_SESSION()
FROM TABLE(GENERATOR(ROWCOUNT => 10000));
-- >>> SESSION C <<<
INSERT INTO LM_POC_DB.POC_SCHEMA.w6v7_global_keys (K, REGION, SESSION_TAG)
SELECT W6V7_APAC.regional_key_v7('APAC'), 'APAC', CURRENT_SESSION()
FROM TABLE(GENERATOR(ROWCOUNT => 10000));

SELECT COUNT(*) AS total, COUNT(DISTINCT K) AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT K) AS duplicates,
       COUNT(DISTINCT SESSION_TAG) AS sessions_involved,
       CASE WHEN COUNT(DISTINCT SESSION_TAG) < 3 THEN 'INVALID - not three sessions'
            WHEN COUNT(*) = COUNT(DISTINCT K) THEN 'PASS - pending the T7.4 sensitivity check'
            ELSE 'FAIL - the prefix did not separate the regions' END AS verdict
FROM LM_POC_DB.POC_SCHEMA.w6v7_global_keys;
-- EXPECT: 30000 / 30000 / 0 / 3. NOT a pass on its own - T7.4 decides.
-- ------------------------------------------------------------------ PASS/FAIL

-- T7.3b  OVERLAP - mandatory. Record each session's start and end and confirm
--        the windows intersect. sessions_involved = 3 does NOT prove overlap.
-- ------------------------------------------------------------------ RECORD

-- ==========================================================================
-- T7.4  SENSITIVITY - WAS THE PREFIX ACTUALLY LOAD-BEARING?
-- ==========================================================================
WITH parts AS (
    SELECT REGION, K % 1000000000000000 AS seq_part FROM LM_POC_DB.POC_SCHEMA.w6v7_global_keys
),
shared AS (
    SELECT seq_part, COUNT(DISTINCT REGION) AS region_count FROM parts GROUP BY seq_part
)
SELECT (SELECT COUNT(*) FROM parts)                         AS total_keys,
       (SELECT COUNT(*) FROM shared WHERE region_count > 1) AS raw_values_shared,
       (SELECT MAX(region_count) FROM shared)               AS max_regions_per_raw_value,
       CASE WHEN (SELECT COUNT(*) FROM shared WHERE region_count > 1) = 0
            THEN 'VACUOUS - no raw value reused; the prefix was NOT load-bearing. R12 still unproven.'
            ELSE 'SOUND - raw values WERE reused across regions and the prefixed keys are still unique. R12 PROVEN.'
       END AS verdict;
-- EXPECT: ~10,000 shared, max 3.
-- >>> THIS DECIDES R12, NOT T7.3. <<< ------------------------------- PASS/FAIL

-- ==========================================================================
-- T7.5  DOES EVERY KEY DECODE TO ITS ISSUING REGION?  (R13)
-- ==========================================================================
WITH codes AS (
    SELECT 'North America' AS region_name, 1 AS region_code
    UNION ALL SELECT 'EU', 2 UNION ALL SELECT 'APAC', 3
)
SELECT g.REGION, COUNT(*) AS keys_issued,
       SUM(CASE WHEN FLOOR(g.K / 1000000000000000) = c.region_code THEN 1 ELSE 0 END) AS decode_correct,
       CASE WHEN COUNT(*) = SUM(CASE WHEN FLOOR(g.K / 1000000000000000) = c.region_code THEN 1 ELSE 0 END)
            THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM LM_POC_DB.POC_SCHEMA.w6v7_global_keys g
JOIN codes c ON c.region_name = g.REGION
GROUP BY g.REGION ORDER BY g.REGION;
-- EXPECT: decode_correct = keys_issued for all three. --------------- PASS/FAIL

-- --------------------------------------------------------------------------
-- TEARDOWN - only when every session has finished. Removes 06's leftovers too.
-- --------------------------------------------------------------------------
DROP TABLE  IF EXISTS LM_POC_DB.POC_SCHEMA.w6v7_global_keys;
DROP TABLE  IF EXISTS LM_POC_DB.POC_SCHEMA.w6v7_raw_probe;
DROP SCHEMA IF EXISTS W6V7_NA   CASCADE;
DROP SCHEMA IF EXISTS W6V7_EU   CASCADE;
DROP SCHEMA IF EXISTS W6V7_APAC CASCADE;
DROP SCHEMA IF EXISTS W6_RGN_NA   CASCADE;
DROP SCHEMA IF EXISTS W6_RGN_EU   CASCADE;
DROP SCHEMA IF EXISTS W6_RGN_APAC CASCADE;

-- ==========================================================================
-- WHAT THIS CLOSES
-- ==========================================================================
-- T7.0 CONFIRMED          -> the asymmetry is real and pinned as a regression.
--                            Build standard: ALWAYS fully qualify sequences
--                            inside a UDF body.
-- T7.1 collides AND T7.4 SOUND AND T7.3 shows 0 duplicates
--                         -> R12 PROVEN under the real topology.
-- T7.1 does NOT collide   -> stop and report. Do not claim a pass.
-- T7.2 passes             -> the key no longer depends on session state, which
--                            is the property that makes this safe to ship.
-- T7.5 passes             -> R13 reconfirmed.
-- ==========================================================================
