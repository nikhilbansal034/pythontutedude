-- ==========================================================================
-- W6 / C4 - MINT THE KEY IN Q1 OR Q2?
-- ==========================================================================
-- >>> THIS IS NOT A VALIDATION. C4 IS A QUESTION FOR NIDWIKA. <<<
-- The script cannot decide where the key should be minted. What it can do is
-- QUANTIFY the difference, so the decision is made on numbers rather than on
-- recollection of what was meant in the meeting.
--
-- Where things stand: R9 asks that the key be region-qualified while moving
-- Zone 1 -> Zone 2. Q1 (Zone 1 -> staging) and Q2 (staging -> Zone 2) are BOTH
-- inside that journey, and Q2 line 50 already mints the key before anything
-- reaches Zone 3. So on the letter of R9, nothing needs to move. C4 exists
-- only because "Zone 1 -> Zone 2" could have meant Q1 specifically.
--
--   T11.1  Rebuild the real staging shape - flags 0, 1, 3, 4
--   T11.2  Q2 placement (today): keys only for rows actually inserted
--   T11.3  Q1 placement: keys for every staged row
--   T11.4  The cost - allocated vs used, and orphaned keys
--   T11.5  The flag-4 correction path, which is where Q1 gets genuinely hard
--   T11.6  Does either placement change what §3 actually asked for?
--
-- Runtime: about two minutes, single session.
-- ==========================================================================

USE DATABASE LM_POC_DB;
DROP SCHEMA IF EXISTS W6V11 CASCADE;
CREATE SCHEMA W6V11;
USE SCHEMA W6V11;

CREATE OR REPLACE SEQUENCE emp_seq_q2_v11 START 1 INCREMENT 1;
CREATE OR REPLACE SEQUENCE emp_seq_q1_v11 START 1 INCREMENT 1;
CREATE OR REPLACE TABLE region_map_v11 (REGION_NAME VARCHAR(100), REGION_CODE NUMBER(9,0));
INSERT INTO region_map_v11 VALUES ('North America', 1);

CREATE OR REPLACE FUNCTION key_q2_v11(region_name VARCHAR)
RETURNS NUMBER(38,0) VOLATILE
AS $$ CAST((SELECT m.REGION_CODE FROM region_map_v11 m WHERE m.REGION_NAME = region_name)
       * 1000000000000000 + LM_POC_DB.W6V11.emp_seq_q2_v11.NEXTVAL AS NUMBER(38,0)) $$;

CREATE OR REPLACE FUNCTION key_q1_v11(region_name VARCHAR)
RETURNS NUMBER(38,0) VOLATILE
AS $$ CAST((SELECT m.REGION_CODE FROM region_map_v11 m WHERE m.REGION_NAME = region_name)
       * 1000000000000000 + LM_POC_DB.W6V11.emp_seq_q1_v11.NEXTVAL AS NUMBER(38,0)) $$;

-- ==========================================================================
-- T11.1  THE REAL STAGING SHAPE
-- ==========================================================================
-- Proportions mirror a catch-up load on an established target: mostly no-ops,
-- some updates, a few inserts and corrections. Adjust to your own profile and
-- re-run - the ratio is what drives the answer.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_employee_v11 (
    EMPLOYEE_PIN VARCHAR(30), CHANGE_FLAG VARCHAR(1), EMPLOYEE_ID NUMBER(38,0)
);

INSERT INTO stg_employee_v11 (EMPLOYEE_PIN, CHANGE_FLAG, EMPLOYEE_ID)
SELECT 'PIN-' || SEQ4(), '0', NULL  FROM TABLE(GENERATOR(ROWCOUNT => 1000));   -- new
INSERT INTO stg_employee_v11 (EMPLOYEE_PIN, CHANGE_FLAG, EMPLOYEE_ID)
SELECT 'PIN-U' || SEQ4(), '1', 900000000000000 + SEQ4() FROM TABLE(GENERATOR(ROWCOUNT => 2000)); -- update
INSERT INTO stg_employee_v11 (EMPLOYEE_PIN, CHANGE_FLAG, EMPLOYEE_ID)
SELECT 'PIN-N' || SEQ4(), '3', 800000000000000 + SEQ4() FROM TABLE(GENERATOR(ROWCOUNT => 6000)); -- no-op
INSERT INTO stg_employee_v11 (EMPLOYEE_PIN, CHANGE_FLAG, EMPLOYEE_ID)
SELECT 'PIN-C' || SEQ4(), '4', 700000000000000 + SEQ4() FROM TABLE(GENERATOR(ROWCOUNT => 500));  -- retire
INSERT INTO stg_employee_v11 (EMPLOYEE_PIN, CHANGE_FLAG, EMPLOYEE_ID)
SELECT 'PIN-C' || SEQ4(), '0', NULL  FROM TABLE(GENERATOR(ROWCOUNT => 500));   -- its replacement

SELECT CHANGE_FLAG, COUNT(*) AS rows,
       CASE CHANGE_FLAG WHEN '0' THEN 'INSERT - needs a new key'
                        WHEN '1' THEN 'UPDATE - keeps its existing key'
                        WHEN '3' THEN 'NO-OP - untouched'
                        WHEN '4' THEN 'RETIRE - keeps its existing key' END AS meaning
FROM stg_employee_v11 GROUP BY CHANGE_FLAG ORDER BY CHANGE_FLAG;
-- EXPECT: 1500 flag-0 (1000 new + 500 replacements), 2000 flag-1, 6000 flag-3,
-- 500 flag-4. 10,000 staged rows, of which only 1,500 need a new key.
-- ------------------------------------------------------------------ RECORD

-- ==========================================================================
-- T11.2  Q2 PLACEMENT - TODAY'S BEHAVIOUR
-- ==========================================================================
-- Q2 line 50: mint only when CHANGE_FLAG = '0'.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE q2_result_v11 AS
SELECT EMPLOYEE_PIN, CHANGE_FLAG,
       CASE WHEN CHANGE_FLAG = '0' THEN key_q2_v11('North America') ELSE EMPLOYEE_ID END AS EMPLOYEE_ID
FROM stg_employee_v11;

SELECT COUNT(*) AS staged_rows,
       SUM(CASE WHEN CHANGE_FLAG = '0' THEN 1 ELSE 0 END) AS keys_minted,
       (SELECT TO_NUMBER(NEXT_VALUE) - 1 FROM INFORMATION_SCHEMA.SEQUENCES
        WHERE SEQUENCE_SCHEMA='W6V11' AND SEQUENCE_NAME='EMP_SEQ_Q2_V11') AS sequence_consumed
FROM q2_result_v11;
-- EXPECT: 10000 staged, 1500 keys minted. Consumption is higher than 1500
-- because of block reservation - that is expected, not waste from placement.
-- ------------------------------------------------------------------ RECORD

-- ==========================================================================
-- T11.3  Q1 PLACEMENT - A KEY FOR EVERY STAGED ROW
-- ==========================================================================
-- Q1 runs before the MERGE has decided anything, so it cannot know which rows
-- will be inserted. Every staged row must get a key.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE q1_result_v11 AS
SELECT EMPLOYEE_PIN, CHANGE_FLAG, EMPLOYEE_ID AS EXISTING_ID,
       key_q1_v11('North America') AS Q1_MINTED_ID
FROM stg_employee_v11;

SELECT COUNT(*) AS staged_rows, COUNT(Q1_MINTED_ID) AS keys_minted,
       (SELECT TO_NUMBER(NEXT_VALUE) - 1 FROM INFORMATION_SCHEMA.SEQUENCES
        WHERE SEQUENCE_SCHEMA='W6V11' AND SEQUENCE_NAME='EMP_SEQ_Q1_V11') AS sequence_consumed
FROM q1_result_v11;
-- EXPECT: 10000 staged, 10000 keys minted. ------------------------- RECORD

-- ==========================================================================
-- T11.4  THE COST - ALLOCATED vs USED, AND ORPHANED KEYS
-- ==========================================================================
SELECT
    (SELECT COUNT(*) FROM q1_result_v11)                                        AS q1_keys_minted,
    (SELECT COUNT(*) FROM q1_result_v11 WHERE CHANGE_FLAG = '0')                AS q1_keys_actually_used,
    (SELECT COUNT(*) FROM q1_result_v11 WHERE CHANGE_FLAG <> '0')               AS q1_keys_ORPHANED,
    ROUND(100.0 * (SELECT COUNT(*) FROM q1_result_v11 WHERE CHANGE_FLAG <> '0')
                / (SELECT COUNT(*) FROM q1_result_v11), 1)                      AS pct_wasted,
    (SELECT COUNT(*) FROM q2_result_v11 WHERE CHANGE_FLAG = '0')                AS q2_keys_minted,
    'Q1 mints a key for every staged row; only the flag-0 rows keep theirs'     AS note;
-- EXPECT: 10000 minted, 1500 used, 8500 orphaned, 85% wasted.
-- The waste is NOT the real objection - the key space is 10^15 per region, so
-- burning 8500 keys per load is immaterial. The objections are T11.5 and the
-- gap it creates in the audit trail. ------------------------------- RECORD

-- Orphaned keys are not just unused: they are issued, then discarded. Anyone
-- reconciling "keys issued" against "rows in the target" sees an 85% shortfall.
SELECT 'keys issued by Q1'    AS measure, COUNT(*) AS value FROM q1_result_v11
UNION ALL
SELECT 'rows that reach the target', COUNT(*) FROM q1_result_v11 WHERE CHANGE_FLAG = '0'
UNION ALL
SELECT 'unexplained difference', (SELECT COUNT(*) FROM q1_result_v11)
                                 - (SELECT COUNT(*) FROM q1_result_v11 WHERE CHANGE_FLAG = '0');
-- ------------------------------------------------------------------ RECORD

-- ==========================================================================
-- T11.5  THE FLAG-4 CORRECTION PATH - WHERE Q1 GETS GENUINELY HARD
-- ==========================================================================
-- A flag-4 correction emits TWO staged rows: the retirement, which must KEEP
-- the incumbent key, and the replacement, which must get a NEW one. In Q2 the
-- MERGE already knows which is which. In Q1 it does not.
-- --------------------------------------------------------------------------
SELECT EMPLOYEE_PIN, CHANGE_FLAG, EXISTING_ID, Q1_MINTED_ID,
       CASE WHEN CHANGE_FLAG = '4' AND Q1_MINTED_ID IS NOT NULL
            THEN 'PROBLEM - a retirement row was given a new key it must not use'
            WHEN CHANGE_FLAG = '0' THEN 'correct - replacement needs a new key'
            ELSE 'key minted but discarded' END AS q1_issue
FROM q1_result_v11
WHERE EMPLOYEE_PIN LIKE 'PIN-C%'
ORDER BY EMPLOYEE_PIN, CHANGE_FLAG LIMIT 10;
-- EXPECT: flag-4 rows carry BOTH an EXISTING_ID they must keep and a freshly
-- minted Q1 key they must ignore. Q1 would have to mint conditionally - which
-- means Q1 needs the change-flag logic that currently lives in Q2.
-- ------------------------------------------------------------------ RECORD

SELECT COUNT(*) AS flag4_rows_with_two_candidate_keys,
       CASE WHEN COUNT(*) > 0
            THEN 'CONFIRMED - moving the mint to Q1 requires moving the change-flag decision too'
            ELSE 'no flag-4 rows in this sample' END AS verdict
FROM q1_result_v11 WHERE CHANGE_FLAG = '4' AND Q1_MINTED_ID IS NOT NULL AND EXISTING_ID IS NOT NULL;
-- EXPECT: 500 / CONFIRMED. This is the substantive argument against Q1: it is
-- not a relocation, it is a redesign of where the SCD-2 decision is made.
-- ------------------------------------------------------------------ PASS/FAIL

-- ==========================================================================
-- T11.6  DOES EITHER PLACEMENT CHANGE WHAT §3 ASKED FOR?
-- ==========================================================================
-- §3's goal: the identifier stored in Zone 2 must survive consolidation. Test
-- the property that actually matters, for both placements.
-- --------------------------------------------------------------------------
SELECT 'Q2 placement (today)' AS placement,
       COUNT(*) AS rows_in_target,
       SUM(CASE WHEN FLOOR(EMPLOYEE_ID / 1000000000000000) = 1 THEN 1 ELSE 0 END) AS region_qualified,
       CASE WHEN COUNT(*) = SUM(CASE WHEN FLOOR(EMPLOYEE_ID / 1000000000000000) = 1 THEN 1 ELSE 0 END)
            THEN 'PASS - every inserted row is region-qualified before Zone 3'
            ELSE 'FAIL' END AS meets_section_3
FROM q2_result_v11 WHERE CHANGE_FLAG = '0'
UNION ALL
SELECT 'Q1 placement',
       COUNT(*),
       SUM(CASE WHEN FLOOR(Q1_MINTED_ID / 1000000000000000) = 1 THEN 1 ELSE 0 END),
       CASE WHEN COUNT(*) = SUM(CASE WHEN FLOOR(Q1_MINTED_ID / 1000000000000000) = 1 THEN 1 ELSE 0 END)
            THEN 'PASS - also region-qualified before Zone 3'
            ELSE 'FAIL' END
FROM q1_result_v11 WHERE CHANGE_FLAG = '0';
-- EXPECT: BOTH PASS.
-- >>> THE KEY RESULT. §3's requirement is satisfied either way, because both
-- Q1 and Q2 sit inside the Zone 1 -> Zone 2 journey. So C4 is not a
-- correctness question - it is a cost and complexity question. <<<
-- ------------------------------------------------------------------ PASS/FAIL

-- --------------------------------------------------------------------------
-- TEARDOWN
-- --------------------------------------------------------------------------
DROP SCHEMA IF EXISTS W6V11 CASCADE;

-- ==========================================================================
-- WHAT TO PUT TO NIDWIKA
-- ==========================================================================
-- Both placements satisfy §3 (T11.6). The identifier is region-qualified
-- before Zone 3 either way, so neither is "wrong" against the requirement as
-- stated. The differences are:
--
--   Q2 (today)  - keys minted only for rows actually inserted. No change
--                 needed to anything. The change-flag decision stays where it
--                 already is.
--   Q1          - a key for every staged row, of which ~85% are discarded on
--                 this profile (T11.4). Harmless for the key space, but it
--                 breaks the simple reconciliation "keys issued = rows landed".
--                 More importantly, flag-4 corrections carry two candidate
--                 keys (T11.5), so Q1 would need the SCD-2 change-flag logic
--                 that currently lives in Q2. That is a redesign, not a move.
--
-- RECOMMENDATION: keep the mint in Q2 and close C4 as "already satisfied",
-- unless Nidwika had a specific reason for Q1 that is not captured in the
-- transcript. The question to ask is narrow: "was Q1 meant specifically, and
-- if so, what does it buy that Q2 does not?"
-- ==========================================================================
