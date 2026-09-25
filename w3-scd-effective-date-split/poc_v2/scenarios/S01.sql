-- ===========================================================================
-- POC v2  —  S01  |  One source changes, the other does not
--
-- The core problem in one picture: SRC_1 is not touched at all, yet its target
-- rows still have to move, because neither source can decide the target's dates
-- alone.
--
-- HOW THIS SCENARIO IS STRUCTURED
--
-- The target is NEVER hand-seeded. TC01 loads an empty target through the real
-- pipeline, and every later test case is the NEXT RUN against whatever the
-- previous one left behind -- which is what a real ETL schedule does, and the
-- only way to test that older rows stay untouched.
--
-- There is ONE reset, at the top of this file. Test cases do not reset. They
-- must therefore be run IN ORDER, top to bottom; each is still a self-contained
-- section to execute and screenshot. Scenarios remain independent of each other.
--
-- TWO CLOCKS, kept in different months so they can never be confused:
--
--   BUSINESS TIME  ROW_EFF_DTE / ROW_EXP_DTE -- when the fact was true. AUGUST.
--   PROCESS TIME   GRS_REFINED_TIMESTAMP, windows, AUDIT_* -- when a row was
--                  loaded. SEPTEMBER. Three runs a day, 08:00 / 12:00 / 16:00.
--
--   TC01  D1R1  run 101   window  2026-09-01 00:00 -> 2026-09-21 08:00
--   TC02  D1R2  run 102   window  2026-09-21 08:00 -> 2026-09-21 12:00
--   TC03  D1R3  run 103   window  2026-09-21 08:00 -> 2026-09-21 12:00  (re-run)
--   TC04  D2R1  run 104   window  2026-09-21 12:00 -> 2026-09-22 08:00
--   TC05  D2R2  run 105   window  2026-09-22 08:00 -> 2026-09-22 12:00
--   TC06  D2R3  run 106   window  2026-09-22 12:00 -> 2026-09-22 16:00
--   TC07  D3R1  run 107   window  2026-09-22 16:00 -> 2026-09-23 08:00
--
-- Windows are half-open: GRS_REFINED_TIMESTAMP > WINDOW_START AND <= WINDOW_END.
--
-- Rules exercised : see ../TEST_PLAN.md
-- Prerequisite    : ../00_objects.sql has been run
-- ===========================================================================

USE ROLE      POC_ROLE;
USE WAREHOUSE POC_WH;
USE DATABASE  LM_POC_DB;
USE SCHEMA    POC_SCHEMA;


-- ###########################################################################
-- RESET -- the ONLY one in this file. Everything after this accumulates.
-- The surrogate-key sequence is deliberately NOT reset: production never
-- reuses a key, so neither do we. See ../TEST_PLAN.md.
-- ###########################################################################
TRUNCATE TABLE ETL_DATA_INGESTION_SOURCE_WINDOW;
TRUNCATE TABLE Z1_BROKER_PARTY_HIST;
TRUNCATE TABLE Z1_BROKER_COMMISSION_HIST;
TRUNCATE TABLE Z2_BROKER_PARTY_DIM;
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;

-- ###########################################################################
-- TC01  (D1R1)  |  POSITIVE  |  initial load into an empty target
--
-- WHAT   Zone1's first delivery. SRC_2 holds ONE version covering the whole period.
-- EXPECT 3 stage rows, all rule 17. Target 0 -> 3. Live view 3.
-- ###########################################################################

-- ---- the run window ------------------------------------------------------
INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (101,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  TIMESTAMP '2026-09-01 00:00', TIMESTAMP '2026-09-21 08:00','NEW','Completed'),
 (101,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  TIMESTAMP '2026-09-01 00:00', TIMESTAMP '2026-09-21 08:00','NEW','Completed');

-- ---- what Zone1 did between the last run and this one -------------------
INSERT INTO Z1_BROKER_PARTY_HIST
SELECT    'K1','A1',NULL,DATE '2026-08-10',DATE '2026-08-21','U-001',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K1','A2',NULL,DATE '2026-08-21',DATE '9999-12-31','U-002',TIMESTAMP '2026-09-21 08:00';

INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT    'K1','B1',NULL,DATE '2026-08-09',DATE '9999-12-31','U-101',TIMESTAMP '2026-09-21 08:00';

SELECT 'S01 TC01 D1R1 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S01 TC01 D1R1 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S01 TC01 D1R1 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
       BROKER_PARTY_DIM_SK, BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   STG_Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, ACTION_FLAG;

-- ---- STEP 2 : apply, one atomic MERGE ------------------------------------
MERGE INTO Z2_BROKER_PARTY_DIM T
USING STG_Z2_BROKER_PARTY_DIM S
   ON  T.BROKER_PARTY_DIM_SK = S.BROKER_PARTY_DIM_SK
   AND S.ACTION_FLAG <> 'I'          -- 'I' rows can never match, whatever SK they carry
WHEN MATCHED AND S.ACTION_FLAG = 'U' THEN UPDATE SET
     T.ROW_EXP_DTE           = S.ROW_EXP_DTE,
     T.UUID                  = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN MATCHED AND S.ACTION_FLAG = 'D' THEN UPDATE SET
     T.IS_DEL      = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.IS_DEL ELSE 'Y' END,
     T.ROW_EXP_DTE = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.ROW_EFF_DTE ELSE T.ROW_EXP_DTE END,
     T.UUID        = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
     BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
     BROKER_STATUS_CDE, COMMISSION_TIER_CDE, IS_DEL, ROW_HASH, UUID,
     AUDIT_BATCH_ID, AUDIT_JOB_ID, AUDIT_CREATE_DATETIME, AUDIT_UPDATE_DATETIME)
VALUES (
     S.BROKER_PARTY_DIM_SK, S.BROKER_ID, S.ROW_EFF_DTE, S.ROW_EXP_DTE,
     S.BROKER_STATUS_CDE, S.COMMISSION_TIER_CDE, 'N', S.ROW_HASH, S.UUID,
     S.AUDIT_BATCH_ID, S.AUDIT_JOB_ID, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- ---- verify ---------------------------------------------------------------
SELECT 'S01 TC01 D1R1 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S01 TC01 D1R1 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY ROW_EFF_DTE;

SELECT 'S01 TC01 D1R1' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)                      = 3
             AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 17)    = 3
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM)                           = 3
             AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE)                    = 3
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE AUDIT_BATCH_ID = 101) = 3
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;

-- ###########################################################################
-- TC02  (D1R2)  |  POSITIVE  |  SRC_2 splits one version into three
--
-- WHAT   Zone1 closes B1 early and adds B2 and B3. SRC_1 is NOT touched -- its timestamps stay at D1R1.
-- EXPECT 6 stage rows: rules 3, 7, 13, 17. Target 3 -> 7. Live 5. SK from run 101 at 08-09 untouched.
-- ###########################################################################

-- ---- the run window ------------------------------------------------------
INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (102,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  TIMESTAMP '2026-09-21 08:00', TIMESTAMP '2026-09-21 12:00','NEW','Completed'),
 (102,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  TIMESTAMP '2026-09-21 08:00', TIMESTAMP '2026-09-21 12:00','NEW','Completed');

-- ---- what Zone1 did between the last run and this one -------------------
UPDATE Z1_BROKER_COMMISSION_HIST
SET    ROW_EXP_DTE = DATE '2026-08-15', GRS_REFINED_TIMESTAMP = TIMESTAMP '2026-09-21 12:00'
WHERE  BROKER_ID = 'K1' AND ROW_EFF_DTE = DATE '2026-08-09';

INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT    'K1','B2',NULL,DATE '2026-08-15',DATE '2026-08-22','U-102',TIMESTAMP '2026-09-21 12:00'
UNION ALL SELECT 'K1','B3',NULL,DATE '2026-08-22',DATE '9999-12-31','U-103',TIMESTAMP '2026-09-21 12:00';

SELECT 'S01 TC02 D1R2 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S01 TC02 D1R2 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S01 TC02 D1R2 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
       BROKER_PARTY_DIM_SK, BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   STG_Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, ACTION_FLAG;

-- ---- STEP 2 : apply, one atomic MERGE ------------------------------------
MERGE INTO Z2_BROKER_PARTY_DIM T
USING STG_Z2_BROKER_PARTY_DIM S
   ON  T.BROKER_PARTY_DIM_SK = S.BROKER_PARTY_DIM_SK
   AND S.ACTION_FLAG <> 'I'          -- 'I' rows can never match, whatever SK they carry
WHEN MATCHED AND S.ACTION_FLAG = 'U' THEN UPDATE SET
     T.ROW_EXP_DTE           = S.ROW_EXP_DTE,
     T.UUID                  = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN MATCHED AND S.ACTION_FLAG = 'D' THEN UPDATE SET
     T.IS_DEL      = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.IS_DEL ELSE 'Y' END,
     T.ROW_EXP_DTE = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.ROW_EFF_DTE ELSE T.ROW_EXP_DTE END,
     T.UUID        = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
     BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
     BROKER_STATUS_CDE, COMMISSION_TIER_CDE, IS_DEL, ROW_HASH, UUID,
     AUDIT_BATCH_ID, AUDIT_JOB_ID, AUDIT_CREATE_DATETIME, AUDIT_UPDATE_DATETIME)
VALUES (
     S.BROKER_PARTY_DIM_SK, S.BROKER_ID, S.ROW_EFF_DTE, S.ROW_EXP_DTE,
     S.BROKER_STATUS_CDE, S.COMMISSION_TIER_CDE, 'N', S.ROW_HASH, S.UUID,
     S.AUDIT_BATCH_ID, S.AUDIT_JOB_ID, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- ---- verify ---------------------------------------------------------------
SELECT 'S01 TC02 D1R2 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S01 TC02 D1R2 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY ROW_EFF_DTE;

SELECT 'S01 TC02 D1R2' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)                       = 6
             AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE ACTION_FLAG = 'D') = 2
             AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE ACTION_FLAG = 'I') = 4
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM)                            = 7
             AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE)                     = 5
             -- retired by DELETE INDICATOR: its expiry was a real date
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM
                  WHERE ROW_EFF_DTE = DATE '2026-08-10' AND IS_DEL = 'Y'
                    AND ROW_EXP_DTE = DATE '2026-08-21')                               = 1
             -- retired as a DEAD RECORD: its expiry was the high end date
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM
                  WHERE ROW_EFF_DTE = DATE '2026-08-21' AND IS_DEL = 'N'
                    AND ROW_EXP_DTE = DATE '2026-08-21')                               = 1
             -- OLDER ROW UNTOUCHED: still run 101's, still live, dates unchanged
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM
                  WHERE AUDIT_BATCH_ID = 101 AND ROW_EFF_DTE = DATE '2026-08-09'
                    AND ROW_EXP_DTE = DATE '2026-08-10' AND IS_DEL = 'N')              = 1
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;

-- ###########################################################################
-- TC03  (D1R3)  |  IDEMPOTENT  |  re-run of the same window, nothing changed
--
-- WHAT   Same window as D1R2, so K1 is STILL impacted and the diff really does look at it.
-- EXPECT 0 stage rows. MERGE writes nothing. Target stays 7, live stays 5.
-- ###########################################################################

-- ---- the run window ------------------------------------------------------
INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (103,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  TIMESTAMP '2026-09-21 08:00', TIMESTAMP '2026-09-21 12:00','NEW','Completed'),
 (103,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  TIMESTAMP '2026-09-21 08:00', TIMESTAMP '2026-09-21 12:00','NEW','Completed');

-- ---- NO source change. This run re-reads the same window ----------------

SELECT 'S01 TC03 D1R3 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S01 TC03 D1R3 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S01 TC03 D1R3 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
       BROKER_PARTY_DIM_SK, BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   STG_Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, ACTION_FLAG;

-- ---- STEP 2 : apply, one atomic MERGE ------------------------------------
MERGE INTO Z2_BROKER_PARTY_DIM T
USING STG_Z2_BROKER_PARTY_DIM S
   ON  T.BROKER_PARTY_DIM_SK = S.BROKER_PARTY_DIM_SK
   AND S.ACTION_FLAG <> 'I'          -- 'I' rows can never match, whatever SK they carry
WHEN MATCHED AND S.ACTION_FLAG = 'U' THEN UPDATE SET
     T.ROW_EXP_DTE           = S.ROW_EXP_DTE,
     T.UUID                  = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN MATCHED AND S.ACTION_FLAG = 'D' THEN UPDATE SET
     T.IS_DEL      = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.IS_DEL ELSE 'Y' END,
     T.ROW_EXP_DTE = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.ROW_EFF_DTE ELSE T.ROW_EXP_DTE END,
     T.UUID        = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
     BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
     BROKER_STATUS_CDE, COMMISSION_TIER_CDE, IS_DEL, ROW_HASH, UUID,
     AUDIT_BATCH_ID, AUDIT_JOB_ID, AUDIT_CREATE_DATETIME, AUDIT_UPDATE_DATETIME)
VALUES (
     S.BROKER_PARTY_DIM_SK, S.BROKER_ID, S.ROW_EFF_DTE, S.ROW_EXP_DTE,
     S.BROKER_STATUS_CDE, S.COMMISSION_TIER_CDE, 'N', S.ROW_HASH, S.UUID,
     S.AUDIT_BATCH_ID, S.AUDIT_JOB_ID, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- ---- verify ---------------------------------------------------------------
SELECT 'S01 TC03 D1R3 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S01 TC03 D1R3 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY ROW_EFF_DTE;

SELECT 'S01 TC03 D1R3' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)                        = 0
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM)                             = 7
             AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE)                      = 5
             -- nothing was created by this run
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE AUDIT_BATCH_ID = 103)  = 0
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;

-- ###########################################################################
-- TC04  (D2R1)  |  EDGE  |  SRC_2 splits on a boundary SRC_1 already uses
--
-- WHAT   B2 is split at 2026-08-21 -- the date SRC_1 already changes on -- so NO new interval appears.
-- EXPECT 2 stage rows, rule 11. Target 7 -> 8. Live stays 5.
-- ###########################################################################

-- ---- the run window ------------------------------------------------------
INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (104,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  TIMESTAMP '2026-09-21 12:00', TIMESTAMP '2026-09-22 08:00','NEW','Completed'),
 (104,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  TIMESTAMP '2026-09-21 12:00', TIMESTAMP '2026-09-22 08:00','NEW','Completed');

-- ---- what Zone1 did between the last run and this one -------------------
UPDATE Z1_BROKER_COMMISSION_HIST
SET    ROW_EXP_DTE = DATE '2026-08-21', GRS_REFINED_TIMESTAMP = TIMESTAMP '2026-09-22 08:00'
WHERE  BROKER_ID = 'K1' AND ROW_EFF_DTE = DATE '2026-08-15';

INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT 'K1','B9',NULL,DATE '2026-08-21',DATE '2026-08-22','U-104',TIMESTAMP '2026-09-22 08:00';

SELECT 'S01 TC04 D2R1 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S01 TC04 D2R1 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S01 TC04 D2R1 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
       BROKER_PARTY_DIM_SK, BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   STG_Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, ACTION_FLAG;

-- ---- STEP 2 : apply, one atomic MERGE ------------------------------------
MERGE INTO Z2_BROKER_PARTY_DIM T
USING STG_Z2_BROKER_PARTY_DIM S
   ON  T.BROKER_PARTY_DIM_SK = S.BROKER_PARTY_DIM_SK
   AND S.ACTION_FLAG <> 'I'          -- 'I' rows can never match, whatever SK they carry
WHEN MATCHED AND S.ACTION_FLAG = 'U' THEN UPDATE SET
     T.ROW_EXP_DTE           = S.ROW_EXP_DTE,
     T.UUID                  = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN MATCHED AND S.ACTION_FLAG = 'D' THEN UPDATE SET
     T.IS_DEL      = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.IS_DEL ELSE 'Y' END,
     T.ROW_EXP_DTE = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.ROW_EFF_DTE ELSE T.ROW_EXP_DTE END,
     T.UUID        = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
     BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
     BROKER_STATUS_CDE, COMMISSION_TIER_CDE, IS_DEL, ROW_HASH, UUID,
     AUDIT_BATCH_ID, AUDIT_JOB_ID, AUDIT_CREATE_DATETIME, AUDIT_UPDATE_DATETIME)
VALUES (
     S.BROKER_PARTY_DIM_SK, S.BROKER_ID, S.ROW_EFF_DTE, S.ROW_EXP_DTE,
     S.BROKER_STATUS_CDE, S.COMMISSION_TIER_CDE, 'N', S.ROW_HASH, S.UUID,
     S.AUDIT_BATCH_ID, S.AUDIT_JOB_ID, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- ---- verify ---------------------------------------------------------------
SELECT 'S01 TC04 D2R1 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S01 TC04 D2R1 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY ROW_EFF_DTE;

SELECT 'S01 TC04 D2R1' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)                        = 2
             AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 11)      = 2
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM)                             = 8
             AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE)                      = 5
             AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE
                  WHERE ROW_EFF_DTE = DATE '2026-08-21'
                    AND COMMISSION_TIER_CDE = 'B9')                                     = 1
             -- OLDER ROWS UNTOUCHED: run 101's row and the run-102 rows this
             -- change does not concern are all still exactly as they were
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM
                  WHERE AUDIT_BATCH_ID = 101 AND ROW_EFF_DTE = DATE '2026-08-09'
                    AND ROW_EXP_DTE = DATE '2026-08-10' AND IS_DEL = 'N')               = 1
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM
                  WHERE AUDIT_BATCH_ID = 102 AND IS_DEL = 'N'
                    AND ROW_EFF_DTE IN (DATE '2026-08-10', DATE '2026-08-15',
                                        DATE '2026-08-22'))                             = 3
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;

-- ###########################################################################
-- TC05  (D2R2)  |  EDGE  |  a value corrected in place, dates unchanged
--
-- WHAT   Zone1 restates B3 as B7 over the SAME interval. Hash changes, both dates stay, target sits at the high end date.
-- EXPECT 2 stage rows, rule 9 -- dead record plus insert. Target 8 -> 9. Live stays 5.
-- ###########################################################################

-- ---- the run window ------------------------------------------------------
INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (105,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  TIMESTAMP '2026-09-22 08:00', TIMESTAMP '2026-09-22 12:00','NEW','Completed'),
 (105,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  TIMESTAMP '2026-09-22 08:00', TIMESTAMP '2026-09-22 12:00','NEW','Completed');

-- ---- what Zone1 did between the last run and this one -------------------
UPDATE Z1_BROKER_COMMISSION_HIST
SET    COMMISSION_TIER_CDE = 'B7', GRS_REFINED_TIMESTAMP = TIMESTAMP '2026-09-22 12:00'
WHERE  BROKER_ID = 'K1' AND ROW_EFF_DTE = DATE '2026-08-22';

SELECT 'S01 TC05 D2R2 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S01 TC05 D2R2 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S01 TC05 D2R2 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
       BROKER_PARTY_DIM_SK, BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   STG_Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, ACTION_FLAG;

-- ---- STEP 2 : apply, one atomic MERGE ------------------------------------
MERGE INTO Z2_BROKER_PARTY_DIM T
USING STG_Z2_BROKER_PARTY_DIM S
   ON  T.BROKER_PARTY_DIM_SK = S.BROKER_PARTY_DIM_SK
   AND S.ACTION_FLAG <> 'I'          -- 'I' rows can never match, whatever SK they carry
WHEN MATCHED AND S.ACTION_FLAG = 'U' THEN UPDATE SET
     T.ROW_EXP_DTE           = S.ROW_EXP_DTE,
     T.UUID                  = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN MATCHED AND S.ACTION_FLAG = 'D' THEN UPDATE SET
     T.IS_DEL      = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.IS_DEL ELSE 'Y' END,
     T.ROW_EXP_DTE = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.ROW_EFF_DTE ELSE T.ROW_EXP_DTE END,
     T.UUID        = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
     BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
     BROKER_STATUS_CDE, COMMISSION_TIER_CDE, IS_DEL, ROW_HASH, UUID,
     AUDIT_BATCH_ID, AUDIT_JOB_ID, AUDIT_CREATE_DATETIME, AUDIT_UPDATE_DATETIME)
VALUES (
     S.BROKER_PARTY_DIM_SK, S.BROKER_ID, S.ROW_EFF_DTE, S.ROW_EXP_DTE,
     S.BROKER_STATUS_CDE, S.COMMISSION_TIER_CDE, 'N', S.ROW_HASH, S.UUID,
     S.AUDIT_BATCH_ID, S.AUDIT_JOB_ID, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- ---- verify ---------------------------------------------------------------
SELECT 'S01 TC05 D2R2 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S01 TC05 D2R2 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY ROW_EFF_DTE;

SELECT 'S01 TC05 D2R2' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)                        = 2
             AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 9)       = 2
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM)                             = 9
             AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE)                      = 5
             -- the replaced row became a DEAD RECORD, not a delete indicator
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM
                  WHERE ROW_EFF_DTE = DATE '2026-08-22' AND ROW_EXP_DTE = DATE '2026-08-22'
                    AND IS_DEL = 'N')                                                   = 1
             AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE
                  WHERE ROW_EFF_DTE = DATE '2026-08-22'
                    AND COMMISSION_TIER_CDE = 'B7')                                     = 1
             -- OLDER ROW UNTOUCHED
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM
                  WHERE AUDIT_BATCH_ID = 101 AND ROW_EFF_DTE = DATE '2026-08-09'
                    AND ROW_EXP_DTE = DATE '2026-08-10' AND IS_DEL = 'N')               = 1
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;

-- ###########################################################################
-- TC06  (D2R3)  |  CORRUPT  |  a NULL business key arrives
--
-- WHAT   Zone1 delivers a row with no BROKER_ID. Nothing else changes in this window.
-- EXPECT The NULL key is dropped SILENTLY -- 0 stage rows, MERGE writes nothing, target stays 9.
-- ###########################################################################

-- ---- the run window ------------------------------------------------------
INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (106,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  TIMESTAMP '2026-09-22 12:00', TIMESTAMP '2026-09-22 16:00','NEW','Completed'),
 (106,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  TIMESTAMP '2026-09-22 12:00', TIMESTAMP '2026-09-22 16:00','NEW','Completed');

-- ---- what Zone1 did between the last run and this one -------------------
INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT NULL,'BX',NULL,DATE '2026-08-10',DATE '9999-12-31','U-999',TIMESTAMP '2026-09-22 16:00';

SELECT 'S01 TC06 D2R3 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S01 TC06 D2R3 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S01 TC06 D2R3 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
       BROKER_PARTY_DIM_SK, BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   STG_Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, ACTION_FLAG;

-- ---- STEP 2 : apply, one atomic MERGE ------------------------------------
MERGE INTO Z2_BROKER_PARTY_DIM T
USING STG_Z2_BROKER_PARTY_DIM S
   ON  T.BROKER_PARTY_DIM_SK = S.BROKER_PARTY_DIM_SK
   AND S.ACTION_FLAG <> 'I'          -- 'I' rows can never match, whatever SK they carry
WHEN MATCHED AND S.ACTION_FLAG = 'U' THEN UPDATE SET
     T.ROW_EXP_DTE           = S.ROW_EXP_DTE,
     T.UUID                  = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN MATCHED AND S.ACTION_FLAG = 'D' THEN UPDATE SET
     T.IS_DEL      = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.IS_DEL ELSE 'Y' END,
     T.ROW_EXP_DTE = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.ROW_EFF_DTE ELSE T.ROW_EXP_DTE END,
     T.UUID        = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
     BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
     BROKER_STATUS_CDE, COMMISSION_TIER_CDE, IS_DEL, ROW_HASH, UUID,
     AUDIT_BATCH_ID, AUDIT_JOB_ID, AUDIT_CREATE_DATETIME, AUDIT_UPDATE_DATETIME)
VALUES (
     S.BROKER_PARTY_DIM_SK, S.BROKER_ID, S.ROW_EFF_DTE, S.ROW_EXP_DTE,
     S.BROKER_STATUS_CDE, S.COMMISSION_TIER_CDE, 'N', S.ROW_HASH, S.UUID,
     S.AUDIT_BATCH_ID, S.AUDIT_JOB_ID, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- ---- verify ---------------------------------------------------------------
SELECT 'S01 TC06 D2R3 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S01 TC06 D2R3 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY ROW_EFF_DTE;

SELECT 'S01 TC06 D2R3' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)                        = 0
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM)                             = 9
             AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE)                      = 5
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID IS NULL)     = 0
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE AUDIT_BATCH_ID = 106)  = 0
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;

-- ###########################################################################
-- TC07  (D3R1)  |  POSITIVE  |  a new version arrives ahead of the open row
--
-- WHAT   B7 is closed at 2026-08-25 and B8 takes over. The open target row's VALUES do not change -- only its expiry.
-- EXPECT 2 stage rows: rule 5 (expire in place) and rule 17. The surrogate key SURVIVES -- no retire, no replacement row at 08-22. Target 9 -> 10, live 5 -> 6.
-- ###########################################################################

-- ---- the run window ------------------------------------------------------
INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (107,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  TIMESTAMP '2026-09-22 16:00', TIMESTAMP '2026-09-23 08:00','NEW','Completed'),
 (107,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  TIMESTAMP '2026-09-22 16:00', TIMESTAMP '2026-09-23 08:00','NEW','Completed');

-- ---- what Zone1 did between the last run and this one -------------------
UPDATE Z1_BROKER_COMMISSION_HIST
SET    ROW_EXP_DTE = DATE '2026-08-25', GRS_REFINED_TIMESTAMP = TIMESTAMP '2026-09-23 08:00'
WHERE  BROKER_ID = 'K1' AND ROW_EFF_DTE = DATE '2026-08-22';

INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT 'K1','B8',NULL,DATE '2026-08-25',DATE '9999-12-31','U-107',TIMESTAMP '2026-09-23 08:00';

SELECT 'S01 TC07 D3R1 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S01 TC07 D3R1 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S01 TC07 D3R1 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
       BROKER_PARTY_DIM_SK, BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   STG_Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, ACTION_FLAG;

-- ---- STEP 2 : apply, one atomic MERGE ------------------------------------
MERGE INTO Z2_BROKER_PARTY_DIM T
USING STG_Z2_BROKER_PARTY_DIM S
   ON  T.BROKER_PARTY_DIM_SK = S.BROKER_PARTY_DIM_SK
   AND S.ACTION_FLAG <> 'I'          -- 'I' rows can never match, whatever SK they carry
WHEN MATCHED AND S.ACTION_FLAG = 'U' THEN UPDATE SET
     T.ROW_EXP_DTE           = S.ROW_EXP_DTE,
     T.UUID                  = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN MATCHED AND S.ACTION_FLAG = 'D' THEN UPDATE SET
     T.IS_DEL      = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.IS_DEL ELSE 'Y' END,
     T.ROW_EXP_DTE = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.ROW_EFF_DTE ELSE T.ROW_EXP_DTE END,
     T.UUID        = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
     BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
     BROKER_STATUS_CDE, COMMISSION_TIER_CDE, IS_DEL, ROW_HASH, UUID,
     AUDIT_BATCH_ID, AUDIT_JOB_ID, AUDIT_CREATE_DATETIME, AUDIT_UPDATE_DATETIME)
VALUES (
     S.BROKER_PARTY_DIM_SK, S.BROKER_ID, S.ROW_EFF_DTE, S.ROW_EXP_DTE,
     S.BROKER_STATUS_CDE, S.COMMISSION_TIER_CDE, 'N', S.ROW_HASH, S.UUID,
     S.AUDIT_BATCH_ID, S.AUDIT_JOB_ID, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- ---- verify ---------------------------------------------------------------
SELECT 'S01 TC07 D3R1 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S01 TC07 D3R1 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY ROW_EFF_DTE;

SELECT 'S01 TC07 D3R1' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)                        = 2
             AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE ACTION_FLAG = 'U') = 1
             AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 5)       = 1
             AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 17)      = 1
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM)                             = 10
             AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE)                      = 6
             -- EXPIRED IN PLACE: exactly ONE LIVE row at 08-22, still the row
             -- run 105 created, expiry moved and nothing else changed.
             -- (The table also holds TC05's DEAD RECORD at 08-22 -- eff = exp, so
             --  the live view correctly hides it. Counting the base table here
             --  finds 2 rows and says nothing about expire-in-place.)
             AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE
                  WHERE ROW_EFF_DTE = DATE '2026-08-22')                                = 1
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM
                  WHERE ROW_EFF_DTE = DATE '2026-08-22' AND ROW_EXP_DTE = DATE '2026-08-25'
                    AND IS_DEL = 'N' AND COMMISSION_TIER_CDE = 'B7'
                    AND AUDIT_BATCH_ID = 105)                                            = 1
             -- and NOTHING was retired by this run
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM
                  WHERE ROW_EFF_DTE = DATE '2026-08-22' AND IS_DEL = 'Y')               = 0
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;
