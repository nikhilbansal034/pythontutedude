-- ===========================================================================
-- POC v2  —  S01  |  One source changes, the other does not
--
-- The core problem in one picture: SRC_1 is not touched at all on day 2, yet
-- its target rows still have to move, because neither source can decide the
-- target's dates alone.
--
-- Rules exercised : 1, 3, 7, 9, 13, 17     (../TEST_PLAN.md)
-- Prerequisite    : ../00_objects.sql has been run
--
-- Each TC section below is self-contained — reset, seed, run, verify — so it
-- can be executed and screenshotted on its own.
-- ===========================================================================

USE ROLE      POC_ROLE;
USE WAREHOUSE POC_WH;
USE DATABASE  LM_POC_DB;
USE SCHEMA    POC_SCHEMA;


-- ###########################################################################
-- TC01  |  POSITIVE  |  rules 1, 3, 7, 13, 17
--
-- WHAT   SRC_2 splits one version into three. SRC_1 is untouched.
-- STEPS  seed day-1 target (3 rows) -> run -> inspect stage -> MERGE -> inspect
-- EXPECT 6 stage rows. Target grows 3 -> 7. Live view = 5 rows, no gaps or
--        overlaps. SK 102 retired by delete indicator (its expiry was a real
--        date). SK 103 becomes a dead record (its expiry was 9999).
--        SK 101 is NOT touched — rule 1 emits no stage row at all.
-- ###########################################################################

-- ---- reset ---------------------------------------------------------------
TRUNCATE TABLE ETL_DATA_INGESTION_SOURCE_WINDOW;
TRUNCATE TABLE Z1_BROKER_PARTY_HIST;
TRUNCATE TABLE Z1_BROKER_COMMISSION_HIST;
TRUNCATE TABLE Z2_BROKER_PARTY_DIM;
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;

-- ---- seed : the sourcing window for run 102 ------------------------------
INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (102,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  '2026-09-21 08:00','2026-09-22 10:00','NEW','Completed'),
 (102,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  '2026-09-21 08:00','2026-09-22 10:00','NEW','Completed');

-- ---- seed : SRC_1, NOT touched on day 2 (timestamps stay at 21-Sep) ------
INSERT INTO Z1_BROKER_PARTY_HIST VALUES
 ('K1','A1',NULL,'2026-09-10','2026-09-21','U-001','2026-09-21 08:00'),
 ('K1','A2',NULL,'2026-09-21','9999-12-31','U-002','2026-09-21 08:00');

-- ---- seed : SRC_2, changed on day 2 (timestamps move to 22-Sep) ----------
INSERT INTO Z1_BROKER_COMMISSION_HIST VALUES
 ('K1','B1',NULL,'2026-09-09','2026-09-15','U-101','2026-09-22 08:00'),
 ('K1','B2',NULL,'2026-09-15','2026-09-22','U-102','2026-09-22 08:00'),
 ('K1','B3',NULL,'2026-09-22','9999-12-31','U-103','2026-09-22 08:00');

-- ---- seed : the target as day 1 left it ----------------------------------
INSERT INTO Z2_BROKER_PARTY_DIM VALUES
 (101,'K1','2026-09-09','2026-09-10',NULL,'B1','N',
  SHA2('~|B1',256),'T-001',101,1,CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP()),
 (102,'K1','2026-09-10','2026-09-21','A1','B1','N',
  SHA2('A1|B1',256),'T-002',101,1,CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP()),
 (103,'K1','2026-09-21','9999-12-31','A2','B1','N',
  SHA2('A2|B1',256),'T-003',101,1,CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP());

SELECT 'S01 TC01 — target BEFORE' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL
FROM   Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE;

-- ---- STEP 1 : build the instruction list ---------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S01 TC01 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
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

-- ---- verify --------------------------------------------------------------
SELECT 'S01 TC01 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL
FROM   Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S01 TC01 — what a consumer sees' AS EVIDENCE, BROKER_STATUS_CDE,
       COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY ROW_EFF_DTE;

SELECT 'S01 TC01' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)                       = 6
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM)                           = 7
             AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE)                    = 5
             AND (SELECT IS_DEL FROM Z2_BROKER_PARTY_DIM WHERE BROKER_PARTY_DIM_SK=102)= 'Y'
             AND (SELECT ROW_EXP_DTE FROM Z2_BROKER_PARTY_DIM WHERE BROKER_PARTY_DIM_SK=103)
                                                                          = DATE '2026-09-21'
             AND (SELECT IS_DEL FROM Z2_BROKER_PARTY_DIM WHERE BROKER_PARTY_DIM_SK=101)= 'N'
            THEN 'PASS' ELSE 'FAIL' END AS RESULT;

-- no gaps and no overlaps in the live timeline
SELECT 'S01 TC01 timeline' AS TEST,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS RESULT
FROM  (SELECT ROW_EXP_DTE,
              LEAD(ROW_EFF_DTE) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE) AS NXT
       FROM   V_Z2_BROKER_PARTY_DIM_LIVE)
WHERE NXT IS NOT NULL AND NXT <> ROW_EXP_DTE;


-- ###########################################################################
-- TC02  |  IDEMPOTENT  |  rules 1, 3
--
-- WHAT   Run again with the key STILL impacted — its GRS_REFINED_TIMESTAMP
--        falls inside the new window — but with no source change.
-- STEPS  add a later window, re-run step 1 and the MERGE. No reseeding.
-- EXPECT The logic RUNS and decides nothing needs writing: 0 stage rows,
--        target unchanged at 7 rows, live view unchanged at 5.
--        This is stronger than "the key was skipped" — it proves every
--        interval matched and fell to rule 1 or 3.
-- NOTE   Run TC01 first. This section deliberately does not reset.
-- ###########################################################################

INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (103,2,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  '2026-09-22 00:00','2026-09-23 10:00','NEW','Completed'),
 (103,2,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  '2026-09-22 00:00','2026-09-23 10:00','NEW','Completed');

TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S01 TC02 — stage must be EMPTY' AS EVIDENCE, count(*) AS STAGE_ROWS
FROM   STG_Z2_BROKER_PARTY_DIM;

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

SELECT 'S01 TC02' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)    = 0
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM)        = 7
             AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE) = 5
            THEN 'PASS' ELSE 'FAIL' END AS RESULT;


-- ###########################################################################
-- TC03  |  EDGE  |  rule 9
--
-- WHAT   SRC_2 changes its value EXACTLY on a date that is already a boundary
--        (21-Sep, where SRC_1 also changes). No new interval is created —
--        only the value at an existing effective date differs.
-- STEPS  full reset, seed, run, MERGE, verify.
-- EXPECT 2 stage rows. Rule 9 fires: the target row at 21-Sep sat at the high
--        end date and its hash changed, so it becomes a DEAD RECORD
--        (expiry pulled back to 21-Sep) and the new version is inserted.
--        SK 101 and SK 102 are untouched.
-- WHY    TC01 never reaches rule 9 — it produces rule 13 instead, because there
--        the expiry changed too. This is the expiry-unchanged variant.
-- ###########################################################################

TRUNCATE TABLE ETL_DATA_INGESTION_SOURCE_WINDOW;
TRUNCATE TABLE Z1_BROKER_PARTY_HIST;
TRUNCATE TABLE Z1_BROKER_COMMISSION_HIST;
TRUNCATE TABLE Z2_BROKER_PARTY_DIM;
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;

INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (102,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  '2026-09-21 08:00','2026-09-22 10:00','NEW','Completed'),
 (102,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  '2026-09-21 08:00','2026-09-22 10:00','NEW','Completed');

INSERT INTO Z1_BROKER_PARTY_HIST VALUES
 ('K1','A1',NULL,'2026-09-10','2026-09-21','U-001','2026-09-21 08:00'),
 ('K1','A2',NULL,'2026-09-21','9999-12-31','U-002','2026-09-21 08:00');

-- B1 now runs to 21-Sep and B9 takes over there: the SAME boundary SRC_1 uses
INSERT INTO Z1_BROKER_COMMISSION_HIST VALUES
 ('K1','B1',NULL,'2026-09-09','2026-09-21','U-101','2026-09-22 08:00'),
 ('K1','B9',NULL,'2026-09-21','9999-12-31','U-102','2026-09-22 08:00');

INSERT INTO Z2_BROKER_PARTY_DIM VALUES
 (101,'K1','2026-09-09','2026-09-10',NULL,'B1','N',
  SHA2('~|B1',256),'T-001',101,1,CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP()),
 (102,'K1','2026-09-10','2026-09-21','A1','B1','N',
  SHA2('A1|B1',256),'T-002',101,1,CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP()),
 (103,'K1','2026-09-21','9999-12-31','A2','B1','N',
  SHA2('A2|B1',256),'T-003',101,1,CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP());

TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S01 TC03 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
       BROKER_PARTY_DIM_SK, BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   STG_Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, ACTION_FLAG;

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

SELECT 'S01 TC03 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL
FROM   Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S01 TC03' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)                        = 2
             AND (SELECT count(DISTINCT RULE_NO) FROM STG_Z2_BROKER_PARTY_DIM)         = 1
             AND (SELECT MAX(RULE_NO) FROM STG_Z2_BROKER_PARTY_DIM)                    = 9
             AND (SELECT ROW_EXP_DTE FROM Z2_BROKER_PARTY_DIM WHERE BROKER_PARTY_DIM_SK=103)
                                                                           = DATE '2026-09-21'
             AND (SELECT IS_DEL FROM Z2_BROKER_PARTY_DIM WHERE BROKER_PARTY_DIM_SK=103) = 'N'
             AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE)                      = 3
            THEN 'PASS' ELSE 'FAIL' END AS RESULT;


-- ###########################################################################
-- TC04  |  CORRUPT  |  no rule should fire for the bad row
--
-- WHAT   SRC_2 carries a row with a NULL business key alongside a good key.
-- STEPS  full reset, seed K1 plus one NULL-key row, run, MERGE, verify.
-- EXPECT The NULL-key row produces NOTHING — it cannot join to itself, so it
--        never becomes an impacted key and never reaches the target. K1 is
--        rebuilt, matches what is already there, and falls to rule 1, so the
--        stage is empty and the target is untouched at 1 row.
--
-- FINDING TO RECORD: the bad row is dropped SILENTLY. Nothing errors and
--        nothing is logged. If Zone1 can emit a NULL key, this design will
--        quietly ignore it. Worth a data-quality check upstream rather than
--        relying on this behaviour.
-- ###########################################################################

TRUNCATE TABLE ETL_DATA_INGESTION_SOURCE_WINDOW;
TRUNCATE TABLE Z1_BROKER_PARTY_HIST;
TRUNCATE TABLE Z1_BROKER_COMMISSION_HIST;
TRUNCATE TABLE Z2_BROKER_PARTY_DIM;
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;

INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (102,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  '2026-09-21 08:00','2026-09-22 10:00','NEW','Completed'),
 (102,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  '2026-09-21 08:00','2026-09-22 10:00','NEW','Completed');

INSERT INTO Z1_BROKER_PARTY_HIST VALUES
 ('K1','A1',NULL,'2026-09-10','9999-12-31','U-001','2026-09-21 08:00');

INSERT INTO Z1_BROKER_COMMISSION_HIST VALUES
 ('K1', 'B1',NULL,'2026-09-10','9999-12-31','U-101','2026-09-22 08:00'),
 (NULL, 'B9',NULL,'2026-09-10','9999-12-31','U-999','2026-09-22 08:00');   -- corrupt

INSERT INTO Z2_BROKER_PARTY_DIM VALUES
 (101,'K1','2026-09-10','9999-12-31','A1','B1','N',
  SHA2('A1|B1',256),'T-001',101,1,CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP());

TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S01 TC04 — stage' AS EVIDENCE, count(*) AS STAGE_ROWS,
       count_if(BROKER_ID IS NULL) AS NULL_KEY_ROWS
FROM   STG_Z2_BROKER_PARTY_DIM;

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

SELECT 'S01 TC04 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL
FROM   Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE;

SELECT 'S01 TC04' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)                = 0
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM)                    = 1
             AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID IS NULL) = 0
             AND (SELECT COMMISSION_TIER_CDE FROM Z2_BROKER_PARTY_DIM
                  WHERE BROKER_PARTY_DIM_SK = 101)                             = 'B1'
            THEN 'PASS' ELSE 'FAIL' END AS RESULT;
