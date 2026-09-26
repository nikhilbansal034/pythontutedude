-- ===========================================================================
-- POC v2  —  S15  |  Many keys at once, and the invariants that must always hold
--
-- A hand-written case proves the rule you were thinking about. This one checks
-- the properties that must hold for EVERY key whatever the rules did:
--
--   * no two LIVE rows for one key may overlap
--   * a corrupt source row must never reach the target
--   * a duplicate (key, effective date) must never produce two live rows
--
-- Six keys with deliberately different shapes: single version, split on each
-- side, a gap, staggered starts, and both sources versioned at once.
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
-- section to execute and screenshot. Scenarios are independent of each other.
--
-- TWO CLOCKS:
--   BUSINESS TIME  ROW_EFF_DTE / ROW_EXP_DTE -- when the fact was true
--   PROCESS TIME   GRS_REFINED_TIMESTAMP, windows, AUDIT_* -- when it was loaded
--
-- Windows are half-open: GRS_REFINED_TIMESTAMP > WINDOW_START AND <= WINDOW_END.
-- Three runs a day, 08:00 / 12:00 / 16:00.
--
--   TC01  D1R1  run 101   window  2026-09-01 00:00 -> 2026-09-21 08:00
--   TC02  D1R2  run 102   window  2026-09-21 08:00 -> 2026-09-21 12:00
--   TC03  D1R3  run 103   window  2026-09-21 12:00 -> 2026-09-21 16:00
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
-- TC01  (D1R1)  |  VOLUME  |  six keys of different shapes, loaded at once
--
-- WHAT   K01 one interval, K02 and K03 two, K04 three (one is a gap), K05 two, K06 four.
-- EXPECT 14 stage rows, all rule 17. Target 0 -> 14, and no key overlaps itself.
-- ###########################################################################

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
SELECT    'K01','A1',NULL,DATE '2026-08-10',DATE '9999-12-31','U-011',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K02','A1',NULL,DATE '2026-08-10',DATE '2026-08-20','U-021',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K02','A2',NULL,DATE '2026-08-20',DATE '9999-12-31','U-022',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K03','A1',NULL,DATE '2026-08-10',DATE '9999-12-31','U-031',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K04','A1',NULL,DATE '2026-08-01',DATE '2026-08-10','U-041',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K04','A2',NULL,DATE '2026-08-20',DATE '9999-12-31','U-042',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K05','A1',NULL,DATE '2026-08-01',DATE '9999-12-31','U-051',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K06','A1',NULL,DATE '2026-08-05',DATE '2026-08-15','U-061',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K06','A2',NULL,DATE '2026-08-15',DATE '9999-12-31','U-062',TIMESTAMP '2026-09-21 08:00';
INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT    'K01','B1',NULL,DATE '2026-08-10',DATE '9999-12-31','U-111',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K02','B1',NULL,DATE '2026-08-10',DATE '9999-12-31','U-121',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K03','B1',NULL,DATE '2026-08-10',DATE '2026-08-15','U-131',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K03','B2',NULL,DATE '2026-08-15',DATE '9999-12-31','U-132',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K04','B1',NULL,DATE '2026-08-01',DATE '9999-12-31','U-141',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K05','B1',NULL,DATE '2026-08-10',DATE '9999-12-31','U-151',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K06','B1',NULL,DATE '2026-08-01',DATE '2026-08-10','U-161',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K06','B2',NULL,DATE '2026-08-10',DATE '9999-12-31','U-162',TIMESTAMP '2026-09-21 08:00';

SELECT 'S15 TC01 D1R1 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S15 TC01 D1R1 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S15 TC01 D1R1 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
       BROKER_PARTY_DIM_SK, BROKER_ID, BROKER_STATUS_CDE, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE
FROM   STG_Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, ACTION_FLAG;

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
SELECT 'S15 TC01 D1R1 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S15 TC01 D1R1 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S15 TC01 D1R1' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)  = 14
                   AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 17) = 14
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM) = 14
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE) = 14
            -- INVARIANT: no key overlaps itself
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE a
                   JOIN V_Z2_BROKER_PARTY_DIM_LIVE b
                     ON a.BROKER_ID          = b.BROKER_ID
                    AND a.BROKER_PARTY_DIM_SK < b.BROKER_PARTY_DIM_SK
                    AND a.ROW_EFF_DTE  < b.ROW_EXP_DTE
                    AND b.ROW_EFF_DTE  < a.ROW_EXP_DTE) = 0
            -- each key produced the shape its sources imply
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE WHERE BROKER_ID = 'K01') = 1
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE WHERE BROKER_ID = 'K04') = 3
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE WHERE BROKER_ID = 'K06') = 4
            -- K04's middle interval is the gap -- no status
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE WHERE BROKER_ID = 'K04' AND BROKER_STATUS_CDE IS NULL) = 1
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;


-- ###########################################################################
-- TC02  (D1R2)  |  VOLUME  |  several keys change at once, in different ways
--
-- WHAT   K02's SRC_2 splits (rules 5 and 17). K03's SRC_2 is restated in place (rule 9). Four other keys are not impacted at all.
-- EXPECT 4 stage rows across two keys. Target 14 -> 16, live 15. The four quiet keys are untouched.
-- ###########################################################################

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
SET    ROW_EXP_DTE = DATE '2026-08-25', GRS_REFINED_TIMESTAMP = TIMESTAMP '2026-09-21 12:00'
WHERE  BROKER_ID = 'K02' AND ROW_EFF_DTE = DATE '2026-08-10';
INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT    'K02','B2',NULL,DATE '2026-08-25',DATE '9999-12-31','U-122',TIMESTAMP '2026-09-21 12:00';
UPDATE Z1_BROKER_COMMISSION_HIST
SET    COMMISSION_TIER_CDE = 'B9', GRS_REFINED_TIMESTAMP = TIMESTAMP '2026-09-21 12:00'
WHERE  BROKER_ID = 'K03' AND ROW_EFF_DTE = DATE '2026-08-15';

SELECT 'S15 TC02 D1R2 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S15 TC02 D1R2 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S15 TC02 D1R2 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
       BROKER_PARTY_DIM_SK, BROKER_ID, BROKER_STATUS_CDE, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE
FROM   STG_Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, ACTION_FLAG;

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
SELECT 'S15 TC02 D1R2 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S15 TC02 D1R2 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S15 TC02 D1R2' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)  = 4
                   AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 5) = 1
                   AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 17) = 1
                   AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 9) = 2
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM) = 16
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE) = 15
            -- INVARIANT: still no key overlaps itself
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE a
                   JOIN V_Z2_BROKER_PARTY_DIM_LIVE b
                     ON a.BROKER_ID          = b.BROKER_ID
                    AND a.BROKER_PARTY_DIM_SK < b.BROKER_PARTY_DIM_SK
                    AND a.ROW_EFF_DTE  < b.ROW_EXP_DTE
                    AND b.ROW_EFF_DTE  < a.ROW_EXP_DTE) = 0
            -- the four quiet keys are byte-for-byte what run 101 wrote
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID IN ('K01','K04','K05','K06') AND AUDIT_BATCH_ID = 101) = 10
            -- and nothing at all was written for them
                   AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM
                  WHERE BROKER_ID IN ('K01','K04','K05','K06')) = 0
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;


-- ###########################################################################
-- TC03  (D1R3)  |  CORRUPT  |  corrupt rows arrive alongside good ones
--
-- WHAT   A NULL business key, and a duplicate (key, effective date) on K01 carrying the SAME timestamp as the row it duplicates, so there is no tie-break.
-- EXPECT Neither corrupts the target. The NULL key is dropped silently. The duplicate yields exactly ONE live row -- but WHICH value wins is arbitrary, so the target lands on 16 or 17. De-duplication belongs upstream.
-- ###########################################################################

INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (103,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  TIMESTAMP '2026-09-21 12:00', TIMESTAMP '2026-09-21 16:00','NEW','Completed'),
 (103,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  TIMESTAMP '2026-09-21 12:00', TIMESTAMP '2026-09-21 16:00','NEW','Completed');

-- ---- what Zone1 did between the last run and this one -------------------
INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT    NULL,'BX',NULL,DATE '2026-08-10',DATE '9999-12-31','U-999',TIMESTAMP '2026-09-21 16:00';
-- make K01's existing row and the duplicate indistinguishable
UPDATE Z1_BROKER_COMMISSION_HIST
SET    GRS_REFINED_TIMESTAMP = TIMESTAMP '2026-09-21 16:00'
WHERE  BROKER_ID = 'K01' AND ROW_EFF_DTE = DATE '2026-08-10';

INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT 'K01','BZ',NULL,DATE '2026-08-10',DATE '9999-12-31','U-119',TIMESTAMP '2026-09-21 16:00';

SELECT 'S15 TC03 D1R3 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S15 TC03 D1R3 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S15 TC03 D1R3 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
       BROKER_PARTY_DIM_SK, BROKER_ID, BROKER_STATUS_CDE, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE
FROM   STG_Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, ACTION_FLAG;

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
SELECT 'S15 TC03 D1R3 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S15 TC03 D1R3 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S15 TC03 D1R3' AS TEST,
            -- INVARIANT: no key overlaps itself, corrupt input or not
       CASE WHEN (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE a
                   JOIN V_Z2_BROKER_PARTY_DIM_LIVE b
                     ON a.BROKER_ID          = b.BROKER_ID
                    AND a.BROKER_PARTY_DIM_SK < b.BROKER_PARTY_DIM_SK
                    AND a.ROW_EFF_DTE  < b.ROW_EXP_DTE
                    AND b.ROW_EFF_DTE  < a.ROW_EXP_DTE) = 0
            -- the NULL key NEVER reaches the target
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID IS NULL) = 0
            -- exactly ONE live row for the duplicated (key, effective date)
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE WHERE BROKER_ID = 'K01' AND ROW_EFF_DTE = DATE '2026-08-10') = 1
            -- the winner is arbitrary -- accept either
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE WHERE BROKER_ID = 'K01' AND COMMISSION_TIER_CDE IN ('B1','BZ')) = 1
            -- 16 if the original won and nothing was written, 17 if the duplicate did
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM) IN (16, 17)
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE) = 15
            -- and every other key is still untouched
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID IN ('K04','K05','K06') AND AUDIT_BATCH_ID = 101) = 9
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;
