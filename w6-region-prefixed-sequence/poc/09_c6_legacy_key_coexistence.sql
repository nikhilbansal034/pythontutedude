-- ==========================================================================
-- W6 / C6 - WHAT HAPPENS TO KEYS THAT ALREADY EXIST?
-- ==========================================================================
-- The EMPLOYEE target may already hold rows keyed with plain 1, 2, 3... from
-- before the prefix existed. C6 asks: leave them, giving two key formats in one
-- table, or backfill?
--
-- This script does not make that decision - it measures the consequences of
-- each option so the decision is made on evidence.
--
--   T9.1  SENSITIVITY - do legacy keys overlap the new key space at all?
--   T9.2  LEAVE THEM - can legacy and prefixed keys coexist without collision?
--   T9.3  LEAVE THEM - does decode logic misattribute a legacy key to a region?
--   T9.4  LEAVE THEM - can the two formats be told apart reliably?
--   T9.5  BACKFILL   - can legacy keys be migrated without collision?
--   T9.6  The same questions under digit concatenation, for the C3 comparison
--
-- Runtime: about two minutes, single session.
-- ==========================================================================

USE DATABASE LM_POC_DB;
DROP SCHEMA IF EXISTS W6V9 CASCADE;
CREATE SCHEMA W6V9;
USE SCHEMA W6V9;

CREATE OR REPLACE SEQUENCE emp_seq_v9 START 1 INCREMENT 1;
CREATE OR REPLACE TABLE region_map_v9 (REGION_NAME VARCHAR(100), REGION_CODE NUMBER(9,0));
INSERT INTO region_map_v9 VALUES ('North America', 1), ('EU', 2), ('APAC', 3);

-- The target as it would look mid-migration: legacy rows already present.
CREATE OR REPLACE TABLE employee_v9 (
    EMPLOYEE_ID NUMBER(38,0), EMPLOYEE_PIN VARCHAR(30), REGION VARCHAR(100), ERA VARCHAR(10)
);

-- 5,000 legacy rows with unprefixed keys 1..5000, as a single region's Zone 2
-- would have issued them before this change.
INSERT INTO employee_v9 (EMPLOYEE_ID, EMPLOYEE_PIN, REGION, ERA)
SELECT ROW_NUMBER() OVER (ORDER BY 1), 'LEGACY-' || ROW_NUMBER() OVER (ORDER BY 1),
       'North America', 'legacy'
FROM TABLE(GENERATOR(ROWCOUNT => 5000));

SELECT COUNT(*) AS legacy_rows, MIN(EMPLOYEE_ID) AS min_key, MAX(EMPLOYEE_ID) AS max_key
FROM employee_v9 WHERE ERA = 'legacy';
-- EXPECT: 5000 / 1 / 5000. ------------------------------------------ RECORD

-- ==========================================================================
-- T9.1  SENSITIVITY - is there any overlap to worry about?
-- ==========================================================================
-- If the new keys are always astronomically larger, C6 is trivial. If they can
-- land in legacy range, it is not. Establish which BEFORE testing coexistence,
-- so a "no collision" result is not vacuous.
-- --------------------------------------------------------------------------
SELECT (SELECT MAX(EMPLOYEE_ID) FROM employee_v9 WHERE ERA = 'legacy') AS max_legacy_key,
       1 * 1000000000000000 + 1                                        AS smallest_offset_key,
       CAST('1' || '1' AS NUMBER(38,0))                                AS smallest_concat_key,
       CASE WHEN (SELECT MAX(EMPLOYEE_ID) FROM employee_v9 WHERE ERA='legacy') < 1000000000000000
            THEN 'OFFSET: legacy range is strictly below the new key space - no overlap possible'
            ELSE 'OFFSET: ranges overlap - collision is possible' END AS offset_verdict,
       CASE WHEN CAST('1' || '1' AS NUMBER(38,0)) <= (SELECT MAX(EMPLOYEE_ID) FROM employee_v9 WHERE ERA='legacy')
            THEN 'CONCAT: new keys land INSIDE the legacy range - collision is possible'
            ELSE 'CONCAT: no overlap' END AS concat_verdict;
-- EXPECT: offset keys start at 10^15, far above legacy 5000 -> structurally
-- safe. Concat keys start at 11 -> INSIDE the legacy range. This asymmetry is
-- the heart of C6. ------------------------------------------------- RECORD

-- ==========================================================================
-- T9.2  OPTION "LEAVE THEM" - coexistence under the OFFSET scheme
-- ==========================================================================
CREATE OR REPLACE FUNCTION key_offset_v9(region_name VARCHAR)
RETURNS NUMBER(38,0) VOLATILE
COMMENT = 'VOLATILE required. Sequence fully qualified per R12 v3 F19.'
AS $$
    CAST((SELECT m.REGION_CODE FROM region_map_v9 m WHERE m.REGION_NAME = region_name)
         * 1000000000000000 + LM_POC_DB.W6V9.emp_seq_v9.NEXTVAL AS NUMBER(38,0))
$$;

INSERT INTO employee_v9 (EMPLOYEE_ID, EMPLOYEE_PIN, REGION, ERA)
SELECT key_offset_v9('North America'), 'NEW-NA-' || SEQ4(), 'North America', 'prefixed'
FROM TABLE(GENERATOR(ROWCOUNT => 3000));
INSERT INTO employee_v9 (EMPLOYEE_ID, EMPLOYEE_PIN, REGION, ERA)
SELECT key_offset_v9('EU'), 'NEW-EU-' || SEQ4(), 'EU', 'prefixed'
FROM TABLE(GENERATOR(ROWCOUNT => 3000));

SELECT COUNT(*) AS total_rows, COUNT(DISTINCT EMPLOYEE_ID) AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT EMPLOYEE_ID) AS duplicates,
       CASE WHEN COUNT(*) = COUNT(DISTINCT EMPLOYEE_ID)
            THEN 'PASS - legacy and prefixed keys coexist with no collision'
            ELSE 'FAIL - a prefixed key collided with a legacy key' END AS verdict
FROM employee_v9;
-- EXPECT: 11000 / 11000 / 0 / PASS. --------------------------------- PASS/FAIL

-- ==========================================================================
-- T9.3  OPTION "LEAVE THEM" - does decode misattribute a legacy key?
-- ==========================================================================
-- R13 says the region is recoverable by division. Apply that rule to a LEGACY
-- key and see what comes back. If it silently returns a valid region code, the
-- two formats are dangerous together.
-- --------------------------------------------------------------------------
SELECT ERA,
       COUNT(*) AS rows_checked,
       MIN(FLOOR(EMPLOYEE_ID / 1000000000000000)) AS min_decoded_code,
       MAX(FLOOR(EMPLOYEE_ID / 1000000000000000)) AS max_decoded_code,
       SUM(CASE WHEN FLOOR(EMPLOYEE_ID / 1000000000000000) = 0 THEN 1 ELSE 0 END) AS decoded_as_zero,
       CASE WHEN ERA = 'legacy'
                 AND SUM(CASE WHEN FLOOR(EMPLOYEE_ID / 1000000000000000) = 0 THEN 1 ELSE 0 END) = COUNT(*)
            THEN 'SAFE - every legacy key decodes to 0, which is not a valid region. Detectable.'
            WHEN ERA = 'legacy'
            THEN 'DANGEROUS - some legacy keys decode to a REAL region code'
            ELSE 'prefixed rows - decode handled by T9.4' END AS verdict
FROM employee_v9 GROUP BY ERA ORDER BY ERA;
-- EXPECT: legacy rows all decode to 0. Region 0 does not exist in the mapping,
-- so a legacy key is self-identifying rather than silently misattributed.
-- THAT is the argument for "leave them" being safe under offset.
-- ------------------------------------------------------------------ PASS/FAIL

-- ==========================================================================
-- T9.4  OPTION "LEAVE THEM" - can the two formats be told apart reliably?
-- ==========================================================================
-- A single predicate must classify every row correctly, or reporting cannot
-- trust the column.
-- --------------------------------------------------------------------------
SELECT COUNT(*) AS total,
       SUM(CASE WHEN EMPLOYEE_ID >= 1000000000000000 THEN 1 ELSE 0 END) AS classified_prefixed,
       SUM(CASE WHEN EMPLOYEE_ID <  1000000000000000 THEN 1 ELSE 0 END) AS classified_legacy,
       SUM(CASE WHEN (EMPLOYEE_ID >= 1000000000000000) <> (ERA = 'prefixed') THEN 1 ELSE 0 END) AS misclassified,
       CASE WHEN SUM(CASE WHEN (EMPLOYEE_ID >= 1000000000000000) <> (ERA = 'prefixed') THEN 1 ELSE 0 END) = 0
            THEN 'PASS - a single magnitude test separates the two eras perfectly'
            ELSE 'FAIL - the eras cannot be separated by magnitude' END AS verdict
FROM employee_v9;
-- EXPECT: 11000 / 6000 / 5000 / 0 misclassified / PASS.
-- This gives reporting a clean rule: EMPLOYEE_ID >= 10^15 means prefixed.
-- ------------------------------------------------------------------ PASS/FAIL

-- ==========================================================================
-- T9.5  OPTION "BACKFILL" - can legacy keys be migrated without collision?
-- ==========================================================================
-- Rewrite every legacy key into the prefixed form for its region, and test
-- whether the result collides with the keys already issued.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE backfill_probe_v9 AS
SELECT EMPLOYEE_ID AS old_key,
       CASE WHEN ERA = 'legacy'
            THEN (SELECT m.REGION_CODE FROM region_map_v9 m WHERE m.REGION_NAME = employee_v9.REGION)
                 * 1000000000000000 + EMPLOYEE_ID
            ELSE EMPLOYEE_ID END AS new_key,
       REGION, ERA
FROM employee_v9;

SELECT COUNT(*) AS rows_after_backfill,
       COUNT(DISTINCT new_key) AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT new_key) AS duplicates,
       CASE WHEN COUNT(*) = COUNT(DISTINCT new_key)
            THEN 'PASS - backfill is collision-free; migrating is viable'
            ELSE 'FAIL - backfilling would create duplicate primary keys' END AS verdict
FROM backfill_probe_v9;
-- EXPECT: 11000 / 11000 / 0 / PASS... BUT SEE THE NEXT QUERY. ------- PASS/FAIL

-- THE CATCH: a backfilled legacy key and a newly issued key can claim the same
-- slot, because both are region_code * 10^15 + a small integer.
SELECT COUNT(*) AS overlapping_slots,
       CASE WHEN COUNT(*) > 0
            THEN 'WARNING - backfilled keys occupy slots the live sequence will reach later'
            ELSE 'SAFE - no overlap between backfilled range and future sequence values' END AS verdict
FROM (
    SELECT b.new_key FROM backfill_probe_v9 b WHERE b.ERA = 'legacy'
    INTERSECT
    SELECT 1 * 1000000000000000 + s.n
    FROM (SELECT SEQ4() + 1 AS n FROM TABLE(GENERATOR(ROWCOUNT => 20000))) s
);
-- EXPECT: a large number. Legacy keys 1..5000 become 1000000000000001..
-- 1000000000000005000, which the LIVE sequence will also produce as it counts
-- up. BACKFILL IS THEREFORE NOT SAFE unless the sequence is first advanced past
-- the highest backfilled value. ------------------------------------- RECORD

-- The fix, if backfill is chosen: advance the sequence beyond the legacy max.
SELECT (SELECT MAX(EMPLOYEE_ID) FROM employee_v9 WHERE ERA = 'legacy') AS legacy_max,
       'ALTER SEQUENCE emp_seq_v9 SET START = <legacy_max + margin>, then recreate' AS required_step,
       'Without this, newly issued keys WILL collide with backfilled ones' AS why;
-- ------------------------------------------------------------- CONSTRAINT ONLY

-- ==========================================================================
-- T9.6  THE SAME QUESTIONS UNDER DIGIT CONCATENATION  (C3 comparison)
-- ==========================================================================
CREATE OR REPLACE TABLE concat_probe_v9 (K NUMBER(38,0), ERA VARCHAR(10));
INSERT INTO concat_probe_v9
SELECT EMPLOYEE_ID, 'legacy' FROM employee_v9 WHERE ERA = 'legacy';
INSERT INTO concat_probe_v9
SELECT CAST('1' || CAST(SEQ4() + 1 AS VARCHAR) AS NUMBER(38,0)), 'prefixed'
FROM TABLE(GENERATOR(ROWCOUNT => 3000));

SELECT COUNT(*) AS total, COUNT(DISTINCT K) AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT K) AS duplicates,
       CASE WHEN COUNT(*) > COUNT(DISTINCT K)
            THEN 'CONFIRMED - under concatenation, new keys COLLIDE with legacy keys'
            ELSE 'no collision in this sample - widen the range and retry' END AS verdict
FROM concat_probe_v9;
-- EXPECT: duplicates > 0. Concat key for region 1, raw 1 is 11 - which is also
-- a legacy key. The two eras are NOT separable, and coexistence is unsafe.
-- ------------------------------------------------------------------ PASS/FAIL

SELECT K AS colliding_key, COUNT(*) AS times_used,
       LISTAGG(DISTINCT ERA, ' + ') AS eras
FROM concat_probe_v9 GROUP BY K HAVING COUNT(*) > 1 ORDER BY K LIMIT 10;
-- EXPECT: keys appearing as both 'legacy' and 'prefixed'. ---------- RECORD

-- --------------------------------------------------------------------------
-- TEARDOWN
-- --------------------------------------------------------------------------
DROP SCHEMA IF EXISTS W6V9 CASCADE;

-- ==========================================================================
-- WHAT THIS DECIDES FOR C6
-- ==========================================================================
-- Under FIXED-WIDTH OFFSET:
--   T9.2 PASS + T9.3 all-zero + T9.4 zero misclassified
--     -> "LEAVE THEM" is SAFE. Legacy keys sit strictly below 10^15, decode to
--        region 0 which does not exist, and one magnitude test separates the
--        eras. No backfill needed.
--   T9.5 shows BACKFILL is possible but NOT free: the sequence must first be
--        advanced past the highest backfilled value, or new keys collide with
--        migrated ones.
--
-- Under DIGIT CONCATENATION:
--   T9.6 shows new keys land INSIDE the legacy range and collide. Neither
--        option is clean - coexistence is unsafe and backfill is mandatory.
--
-- So C6's answer depends on C3, and under the recommended scheme the cheapest
-- option - change nothing - is also the correct one.
-- ==========================================================================
