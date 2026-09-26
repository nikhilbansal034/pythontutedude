-- ===========================================================================
-- POC v2  —  S14  |  The hash definition itself changes
--
-- When the hash is redefined, EVERY hash moves without any data moving. The
-- design says this is handled GRADUALLY -- keys re-derive as they become
-- impacted, under rules 9-16 -- never by truncate and reload. See
-- solution_design.md section 15.
--
-- This scenario really does redefine the hash, by replacing the Step 1 view
-- with one whose hash expression is prefixed. Nothing else about it changes.
-- TC04 puts the original definition back.
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
--   TC03  D1R3  run 103   window  2026-09-21 08:00 -> 2026-09-21 12:00  (re-run)
--   TC04  D2R1  run 104   window  2026-09-21 16:00 -> 2026-09-22 08:00
--   TC05  D2R2  run 105   window  2026-09-22 08:00 -> 2026-09-22 12:00
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
-- TC01  (D1R1)  |  POSITIVE  |  initial load of two independent keys
--
-- WHAT   K1 and K2 each arrive with two intervals.
-- EXPECT 4 stage rows, rule 17. Target 0 -> 4.
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
SELECT    'K1','A1',NULL,DATE '2026-08-10',DATE '2026-08-20','U-001',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K1','A2',NULL,DATE '2026-08-20',DATE '9999-12-31','U-002',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K2','C1',NULL,DATE '2026-08-10',DATE '2026-08-20','U-201',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K2','C2',NULL,DATE '2026-08-20',DATE '9999-12-31','U-202',TIMESTAMP '2026-09-21 08:00';
INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT    'K1','B1',NULL,DATE '2026-08-10',DATE '9999-12-31','U-101',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K2','D1',NULL,DATE '2026-08-10',DATE '9999-12-31','U-301',TIMESTAMP '2026-09-21 08:00';

SELECT 'S14 TC01 D1R1 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S14 TC01 D1R1 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S14 TC01 D1R1 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
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
SELECT 'S14 TC01 D1R1 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S14 TC01 D1R1 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S14 TC01 D1R1' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)  = 4
                   AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 17) = 4
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM) = 4
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE) = 4
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'K1') = 2
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'K2') = 2
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;


-- ###########################################################################
-- TC02  (D1R2)  |  POSITIVE  |  the hash definition changes -- and only K1 is impacted
--
-- WHAT   The Step 1 view is replaced with one whose hash expression differs. NO DATA CHANGED. Only K1 is impacted this run.
-- EXPECT K1's two intervals both re-derive: rule 9 at the high end date, rule 11 on the closed one. 4 stage rows. K2 is NOT rewritten -- that is the gradual migration. Target 4 -> 6.
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
-- ---- THE HASH DEFINITION CHANGES HERE -------------------------------------
CREATE OR REPLACE VIEW V_STEP1_BROKER_PARTY_DIM_DIFF AS
WITH
-- the run being processed.  NOTE: filtered on TARGET_TABLE_NAME. Without that
-- filter a busier table's run id wins and this job silently does nothing.
cur_run AS (
    SELECT MAX(EXECUTION_RUN_ID) AS EXECUTION_RUN_ID
    FROM   ETL_DATA_INGESTION_SOURCE_WINDOW
    WHERE  TARGET_TABLE_NAME = 'Z2_BROKER_PARTY_DIM'
),
win AS (
    SELECT w.SOURCE_TABLE_NAME, w.WINDOW_START, w.WINDOW_END,
           w.EXECUTION_RUN_ID, w.JOB_RUN_ID, w.EXECUTION_TYPE
    FROM   ETL_DATA_INGESTION_SOURCE_WINDOW w
    JOIN   cur_run r ON r.EXECUTION_RUN_ID = w.EXECUTION_RUN_ID
    WHERE  w.TARGET_TABLE_NAME = 'Z2_BROKER_PARTY_DIM'
      AND  w.JOB_STATUS        = 'Completed'
),
run_meta AS (SELECT MAX(EXECUTION_RUN_ID) AS BATCH_ID, MAX(JOB_RUN_ID) AS JOB_ID,
                    MAX(EXECUTION_TYPE)   AS EXECUTION_TYPE FROM win),

-- stage 1 — impacted keys: GRS_REFINED_TIMESTAMP moved in EITHER source
impacted AS (
    SELECT DISTINCT s.BROKER_ID
    FROM   Z1_BROKER_PARTY_HIST s
    JOIN   win w ON w.SOURCE_TABLE_NAME = 'Z1_BROKER_PARTY_HIST'
    WHERE  s.GRS_REFINED_TIMESTAMP >  w.WINDOW_START
      AND  s.GRS_REFINED_TIMESTAMP <= w.WINDOW_END
    UNION
    SELECT DISTINCT s.BROKER_ID
    FROM   Z1_BROKER_COMMISSION_HIST s
    JOIN   win w ON w.SOURCE_TABLE_NAME = 'Z1_BROKER_COMMISSION_HIST'
    WHERE  s.GRS_REFINED_TIMESTAMP >  w.WINDOW_START
      AND  s.GRS_REFINED_TIMESTAMP <= w.WINDOW_END
),

-- stages 2+3 — full history of those keys, projected to target-bound columns,
-- latest per (key, eff date). NOTE_TEXT is dropped here, which is what makes S03 work.
s1_dedup AS (
    SELECT s.BROKER_ID, s.BROKER_STATUS_CDE AS VAL, s.ROW_EFF_DTE, s.ROW_EXP_DTE
    FROM   Z1_BROKER_PARTY_HIST s JOIN impacted i ON i.BROKER_ID = s.BROKER_ID
    QUALIFY ROW_NUMBER() OVER (PARTITION BY s.BROKER_ID, s.ROW_EFF_DTE
                               ORDER BY s.GRS_REFINED_TIMESTAMP DESC) = 1
),
s2_dedup AS (
    SELECT s.BROKER_ID, s.COMMISSION_TIER_CDE AS VAL, s.ROW_EFF_DTE, s.ROW_EXP_DTE
    FROM   Z1_BROKER_COMMISSION_HIST s JOIN impacted i ON i.BROKER_ID = s.BROKER_ID
    QUALIFY ROW_NUMBER() OVER (PARTITION BY s.BROKER_ID, s.ROW_EFF_DTE
                               ORDER BY s.GRS_REFINED_TIMESTAMP DESC) = 1
),

-- stage 3 continued — collapse CONSECUTIVE identical versions.
-- A new island starts when the value changes OR the previous row's expiry does
-- not meet this row's effective date. The second test is what preserves the
-- gap in S05 — without it two A1 versions either side of a gap would merge.
s1_flag AS (
    SELECT *, CASE WHEN LAG(VAL)         OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE)
                        IS NOT DISTINCT FROM VAL
                    AND LAG(ROW_EXP_DTE) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE)
                        = ROW_EFF_DTE
                   THEN 0 ELSE 1 END AS NEW_ISLAND
    FROM s1_dedup
),
s2_flag AS (
    SELECT *, CASE WHEN LAG(VAL)         OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE)
                        IS NOT DISTINCT FROM VAL
                    AND LAG(ROW_EXP_DTE) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE)
                        = ROW_EFF_DTE
                   THEN 0 ELSE 1 END AS NEW_ISLAND
    FROM s2_dedup
),
s1 AS (
    SELECT BROKER_ID, MAX(VAL) AS VAL, MIN(ROW_EFF_DTE) AS ROW_EFF_DTE, MAX(ROW_EXP_DTE) AS ROW_EXP_DTE
    FROM  (SELECT *, SUM(NEW_ISLAND) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE
                                           ROWS UNBOUNDED PRECEDING) AS ISL FROM s1_flag)
    GROUP BY BROKER_ID, ISL
),
s2 AS (
    SELECT BROKER_ID, MAX(VAL) AS VAL, MIN(ROW_EFF_DTE) AS ROW_EFF_DTE, MAX(ROW_EXP_DTE) AS ROW_EXP_DTE
    FROM  (SELECT *, SUM(NEW_ISLAND) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE
                                           ROWS UNBOUNDED PRECEDING) AS ISL FROM s2_flag)
    GROUP BY BROKER_ID, ISL
),

-- stage 4 — every eff AND exp date from both cleaned sources
bounds AS (
    SELECT BROKER_ID, ROW_EFF_DTE AS D FROM s1
    UNION SELECT BROKER_ID, ROW_EXP_DTE FROM s1
    UNION SELECT BROKER_ID, ROW_EFF_DTE FROM s2
    UNION SELECT BROKER_ID, ROW_EXP_DTE FROM s2
),

-- stage 5 — each interval's expiry is the NEXT boundary. This is why LEAD is
-- used, and why it operates on business dates and not on GRS_REFINED_TIMESTAMP.
ivals AS (
    SELECT BROKER_ID, D AS ROW_EFF_DTE,
           LEAD(D) OVER (PARTITION BY BROKER_ID ORDER BY D) AS ROW_EXP_DTE
    FROM   bounds
    QUALIFY ROW_EXP_DTE IS NOT NULL
),

-- stage 6 — fill each interval from whichever source version contains it
new_rows AS (
    SELECT i.BROKER_ID, i.ROW_EFF_DTE, i.ROW_EXP_DTE,
           a.VAL AS BROKER_STATUS_CDE,
           b.VAL AS COMMISSION_TIER_CDE,
           SHA2('v2|' || COALESCE(a.VAL,'~') || '|' || COALESCE(b.VAL,'~'), 256) AS ROW_HASH
    FROM   ivals i
    LEFT JOIN s1 a ON a.BROKER_ID = i.BROKER_ID
                  AND a.ROW_EFF_DTE <= i.ROW_EFF_DTE AND i.ROW_EXP_DTE <= a.ROW_EXP_DTE
    LEFT JOIN s2 b ON b.BROKER_ID = i.BROKER_ID
                  AND b.ROW_EFF_DTE <= i.ROW_EFF_DTE AND i.ROW_EXP_DTE <= b.ROW_EXP_DTE
),

-- stage 7 — the target, live rows only, for the impacted keys
cur_tgt AS (
    SELECT t.BROKER_PARTY_DIM_SK, t.BROKER_ID, t.ROW_EFF_DTE, t.ROW_EXP_DTE,
           t.BROKER_STATUS_CDE, t.COMMISSION_TIER_CDE, t.ROW_HASH
    FROM   V_Z2_BROKER_PARTY_DIM_LIVE t
    JOIN   impacted i ON i.BROKER_ID = t.BROKER_ID
),

-- stage 8 — classify. One row per (key, eff date) — rule 18 rows are simply
-- absent from new_rows and are deliberately NOT emitted, so the orphan is left
-- live and untouched. See solution_design.md section 14.
classified AS (
    SELECT n.BROKER_ID, n.ROW_EFF_DTE, n.ROW_EXP_DTE,
           n.BROKER_STATUS_CDE, n.COMMISSION_TIER_CDE, n.ROW_HASH,
           t.BROKER_PARTY_DIM_SK    AS TGT_SK,
           t.ROW_EXP_DTE            AS TGT_EXP,
           t.ROW_HASH               AS TGT_HASH,
           t.BROKER_STATUS_CDE      AS TGT_STATUS,
           t.COMMISSION_TIER_CDE    AS TGT_TIER,
           m.EXECUTION_TYPE, m.BATCH_ID, m.JOB_ID,
           -- The rerun +1 applies ONLY to the MATCHED rules, 1-16. Adding it to
           -- rule 17 would produce 18 -- which means something else entirely
           -- ("this target row is gone from the timeline, do nothing") and is
           -- not selected by the 'I' branch. A genuinely new interval arriving
           -- during a Z1_RERUN would then be silently DROPPED, leaving the
           -- target with no cover from that date on. Caught by S12 TC03.
           CASE
             WHEN t.BROKER_PARTY_DIM_SK IS NULL THEN 17
             ELSE
               CASE
                 WHEN t.ROW_HASH = n.ROW_HASH AND t.ROW_EXP_DTE = n.ROW_EXP_DTE
                      THEN CASE WHEN t.ROW_EXP_DTE = DATE '9999-12-31' THEN 1 ELSE 3 END
                 WHEN t.ROW_HASH = n.ROW_HASH
                      THEN CASE WHEN t.ROW_EXP_DTE = DATE '9999-12-31' THEN 5 ELSE 7 END
                 WHEN t.ROW_EXP_DTE = n.ROW_EXP_DTE
                      THEN CASE WHEN t.ROW_EXP_DTE = DATE '9999-12-31' THEN 9 ELSE 11 END
                 ELSE CASE WHEN t.ROW_EXP_DTE = DATE '9999-12-31' THEN 13 ELSE 15 END
               END
               + CASE WHEN m.EXECUTION_TYPE = 'Z1_RERUN' THEN 1 ELSE 0 END
           END AS RULE_NO
    FROM      new_rows n
    LEFT JOIN cur_tgt  t ON t.BROKER_ID = n.BROKER_ID AND t.ROW_EFF_DTE = n.ROW_EFF_DTE
    CROSS JOIN run_meta m
)

-- ---- the 'U' branch: rules 5,6 -------------------------------------------
SELECT TGT_SK AS BROKER_PARTY_DIM_SK, 'U' AS ACTION_FLAG, NULL AS DEL_IND,
       BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH,
       UUID_STRING() AS UUID, RULE_NO, BATCH_ID, JOB_ID
FROM   classified WHERE RULE_NO IN (5,6)

UNION ALL
-- ---- the 'U' branch: rules 2,4 — rerun, nothing changed but the UUID -------
SELECT TGT_SK, 'U', NULL, BROKER_ID, ROW_EFF_DTE, TGT_EXP,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH,
       UUID_STRING(), RULE_NO, BATCH_ID, JOB_ID
FROM   classified WHERE RULE_NO IN (2,4)

UNION ALL
-- ---- the 'D' branch: rules 7-16, the retire half --------------------------
SELECT TGT_SK, 'D',
       CASE WHEN TGT_EXP = DATE '9999-12-31' THEN NULL ELSE 'Y' END,   -- lineage only
       BROKER_ID, ROW_EFF_DTE, TGT_EXP,
       TGT_STATUS, TGT_TIER, TGT_HASH,          -- the row being RETIRED, not the new one
       NULL, RULE_NO, BATCH_ID, JOB_ID
FROM   classified WHERE RULE_NO BETWEEN 7 AND 16

UNION ALL
-- ---- the 'I' branch: rule 17, and the insert half of rules 7-16 -----------
-- These reach WHEN NOT MATCHED because the MERGE's ON clause excludes
-- ACTION_FLAG = 'I' outright -- it does NOT rely on the new SK being absent
-- from the target, so a reset or externally-seeded sequence cannot break it. NEXTVAL is consumed ONCE, in the inner SELECT,
-- then referenced twice -- never call NEXTVAL twice on one row and assume the
-- two references agree.
SELECT NEW_SK, 'I', 'N',
       BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH,
       UUID_STRING(), RULE_NO, BATCH_ID, JOB_ID
FROM  (SELECT SEQ_BROKER_PARTY_DIM_SK.NEXTVAL AS NEW_SK, c.*
       FROM   classified c
       WHERE  c.RULE_NO = 17 OR c.RULE_NO BETWEEN 7 AND 16);

UPDATE Z1_BROKER_COMMISSION_HIST
SET    NOTE_TEXT = 'impacted, so it re-derives', GRS_REFINED_TIMESTAMP = TIMESTAMP '2026-09-21 12:00'
WHERE  BROKER_ID = 'K1' AND ROW_EFF_DTE = DATE '2026-08-10';

SELECT 'S14 TC02 D1R2 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S14 TC02 D1R2 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S14 TC02 D1R2 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
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
SELECT 'S14 TC02 D1R2 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S14 TC02 D1R2 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S14 TC02 D1R2' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)  = 4
                   AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 9) = 2
                   AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 11) = 2
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM) = 6
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE) = 4
            -- K1 re-derived: the closed row retired by DELETE INDICATOR
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'K1' AND IS_DEL = 'Y') = 1
            -- and the open row by DEAD RECORD
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'K1' AND ROW_EFF_DTE = ROW_EXP_DTE) = 1
            -- K2 UNTOUCHED -- still exactly what run 101 wrote. No truncate, no reload.
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'K2' AND AUDIT_BATCH_ID = 101) = 2
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'K2') = 2
            -- surrogate-key churn: 2 new keys for K1, none for K2
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE AUDIT_BATCH_ID = 102) = 2
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;


-- ###########################################################################
-- TC03  (D1R3)  |  IDEMPOTENT  |  re-run under the NEW definition
--
-- WHAT   K1 is impacted again. Its target rows now carry the new hash, so nothing should move.
-- EXPECT 0 stage rows. The migration is not repeated.
-- ###########################################################################

INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (103,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  TIMESTAMP '2026-09-21 08:00', TIMESTAMP '2026-09-21 12:00','NEW','Completed'),
 (103,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  TIMESTAMP '2026-09-21 08:00', TIMESTAMP '2026-09-21 12:00','NEW','Completed');

-- ---- NO source change. This run re-reads the same window ----------------

SELECT 'S14 TC03 D1R3 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S14 TC03 D1R3 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S14 TC03 D1R3 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
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
SELECT 'S14 TC03 D1R3 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S14 TC03 D1R3 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S14 TC03 D1R3' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)  = 0
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM) = 6
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE) = 4
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE AUDIT_BATCH_ID = 103) = 0
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;


-- ###########################################################################
-- TC04  (D2R1)  |  POSITIVE  |  K2 becomes impacted, and re-derives in its turn
--
-- WHAT   K2 is touched for the first time since the hash changed. This is the gradual migration completing.
-- EXPECT 4 stage rows, rules 9 and 11 again, for K2 this time. Target 6 -> 8. Every key now carries the new hash.
-- ###########################################################################

INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (104,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  TIMESTAMP '2026-09-21 16:00', TIMESTAMP '2026-09-22 08:00','NEW','Completed'),
 (104,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  TIMESTAMP '2026-09-21 16:00', TIMESTAMP '2026-09-22 08:00','NEW','Completed');

-- ---- what Zone1 did between the last run and this one -------------------
UPDATE Z1_BROKER_COMMISSION_HIST
SET    NOTE_TEXT = 'impacted at last', GRS_REFINED_TIMESTAMP = TIMESTAMP '2026-09-22 08:00'
WHERE  BROKER_ID = 'K2' AND ROW_EFF_DTE = DATE '2026-08-10';

SELECT 'S14 TC04 D2R1 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S14 TC04 D2R1 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S14 TC04 D2R1 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
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
SELECT 'S14 TC04 D2R1 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S14 TC04 D2R1 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S14 TC04 D2R1' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)  = 4
                   AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 9) = 2
                   AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = 11) = 2
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM) = 8
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE) = 4
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'K2' AND IS_DEL = 'Y') = 1
            -- total churn across the migration: 4 rows retired, 4 written
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE IS_DEL = 'Y' OR ROW_EFF_DTE = ROW_EXP_DTE) = 4
            -- and the live timeline is unchanged in SHAPE -- same 4 intervals as day 1
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE) = 4
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;


-- ###########################################################################
-- TC05  (D2R2)  |  POSITIVE  |  restore the original hash definition
--
-- WHAT   Housekeeping so this file leaves the objects as it found them. The keys re-derive once more, back to the original hash.
-- EXPECT K1 re-derives; K2 stays until it is impacted. The point is that the file is repeatable, not the rule.
-- ###########################################################################

INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (105,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  TIMESTAMP '2026-09-22 08:00', TIMESTAMP '2026-09-22 12:00','NEW','Completed'),
 (105,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  TIMESTAMP '2026-09-22 08:00', TIMESTAMP '2026-09-22 12:00','NEW','Completed');

-- ---- what Zone1 did between the last run and this one -------------------
-- ---- PUT THE ORIGINAL DEFINITION BACK -------------------------------------
CREATE OR REPLACE VIEW V_STEP1_BROKER_PARTY_DIM_DIFF AS
WITH
-- the run being processed.  NOTE: filtered on TARGET_TABLE_NAME. Without that
-- filter a busier table's run id wins and this job silently does nothing.
cur_run AS (
    SELECT MAX(EXECUTION_RUN_ID) AS EXECUTION_RUN_ID
    FROM   ETL_DATA_INGESTION_SOURCE_WINDOW
    WHERE  TARGET_TABLE_NAME = 'Z2_BROKER_PARTY_DIM'
),
win AS (
    SELECT w.SOURCE_TABLE_NAME, w.WINDOW_START, w.WINDOW_END,
           w.EXECUTION_RUN_ID, w.JOB_RUN_ID, w.EXECUTION_TYPE
    FROM   ETL_DATA_INGESTION_SOURCE_WINDOW w
    JOIN   cur_run r ON r.EXECUTION_RUN_ID = w.EXECUTION_RUN_ID
    WHERE  w.TARGET_TABLE_NAME = 'Z2_BROKER_PARTY_DIM'
      AND  w.JOB_STATUS        = 'Completed'
),
run_meta AS (SELECT MAX(EXECUTION_RUN_ID) AS BATCH_ID, MAX(JOB_RUN_ID) AS JOB_ID,
                    MAX(EXECUTION_TYPE)   AS EXECUTION_TYPE FROM win),

-- stage 1 — impacted keys: GRS_REFINED_TIMESTAMP moved in EITHER source
impacted AS (
    SELECT DISTINCT s.BROKER_ID
    FROM   Z1_BROKER_PARTY_HIST s
    JOIN   win w ON w.SOURCE_TABLE_NAME = 'Z1_BROKER_PARTY_HIST'
    WHERE  s.GRS_REFINED_TIMESTAMP >  w.WINDOW_START
      AND  s.GRS_REFINED_TIMESTAMP <= w.WINDOW_END
    UNION
    SELECT DISTINCT s.BROKER_ID
    FROM   Z1_BROKER_COMMISSION_HIST s
    JOIN   win w ON w.SOURCE_TABLE_NAME = 'Z1_BROKER_COMMISSION_HIST'
    WHERE  s.GRS_REFINED_TIMESTAMP >  w.WINDOW_START
      AND  s.GRS_REFINED_TIMESTAMP <= w.WINDOW_END
),

-- stages 2+3 — full history of those keys, projected to target-bound columns,
-- latest per (key, eff date). NOTE_TEXT is dropped here, which is what makes S03 work.
s1_dedup AS (
    SELECT s.BROKER_ID, s.BROKER_STATUS_CDE AS VAL, s.ROW_EFF_DTE, s.ROW_EXP_DTE
    FROM   Z1_BROKER_PARTY_HIST s JOIN impacted i ON i.BROKER_ID = s.BROKER_ID
    QUALIFY ROW_NUMBER() OVER (PARTITION BY s.BROKER_ID, s.ROW_EFF_DTE
                               ORDER BY s.GRS_REFINED_TIMESTAMP DESC) = 1
),
s2_dedup AS (
    SELECT s.BROKER_ID, s.COMMISSION_TIER_CDE AS VAL, s.ROW_EFF_DTE, s.ROW_EXP_DTE
    FROM   Z1_BROKER_COMMISSION_HIST s JOIN impacted i ON i.BROKER_ID = s.BROKER_ID
    QUALIFY ROW_NUMBER() OVER (PARTITION BY s.BROKER_ID, s.ROW_EFF_DTE
                               ORDER BY s.GRS_REFINED_TIMESTAMP DESC) = 1
),

-- stage 3 continued — collapse CONSECUTIVE identical versions.
-- A new island starts when the value changes OR the previous row's expiry does
-- not meet this row's effective date. The second test is what preserves the
-- gap in S05 — without it two A1 versions either side of a gap would merge.
s1_flag AS (
    SELECT *, CASE WHEN LAG(VAL)         OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE)
                        IS NOT DISTINCT FROM VAL
                    AND LAG(ROW_EXP_DTE) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE)
                        = ROW_EFF_DTE
                   THEN 0 ELSE 1 END AS NEW_ISLAND
    FROM s1_dedup
),
s2_flag AS (
    SELECT *, CASE WHEN LAG(VAL)         OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE)
                        IS NOT DISTINCT FROM VAL
                    AND LAG(ROW_EXP_DTE) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE)
                        = ROW_EFF_DTE
                   THEN 0 ELSE 1 END AS NEW_ISLAND
    FROM s2_dedup
),
s1 AS (
    SELECT BROKER_ID, MAX(VAL) AS VAL, MIN(ROW_EFF_DTE) AS ROW_EFF_DTE, MAX(ROW_EXP_DTE) AS ROW_EXP_DTE
    FROM  (SELECT *, SUM(NEW_ISLAND) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE
                                           ROWS UNBOUNDED PRECEDING) AS ISL FROM s1_flag)
    GROUP BY BROKER_ID, ISL
),
s2 AS (
    SELECT BROKER_ID, MAX(VAL) AS VAL, MIN(ROW_EFF_DTE) AS ROW_EFF_DTE, MAX(ROW_EXP_DTE) AS ROW_EXP_DTE
    FROM  (SELECT *, SUM(NEW_ISLAND) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE
                                           ROWS UNBOUNDED PRECEDING) AS ISL FROM s2_flag)
    GROUP BY BROKER_ID, ISL
),

-- stage 4 — every eff AND exp date from both cleaned sources
bounds AS (
    SELECT BROKER_ID, ROW_EFF_DTE AS D FROM s1
    UNION SELECT BROKER_ID, ROW_EXP_DTE FROM s1
    UNION SELECT BROKER_ID, ROW_EFF_DTE FROM s2
    UNION SELECT BROKER_ID, ROW_EXP_DTE FROM s2
),

-- stage 5 — each interval's expiry is the NEXT boundary. This is why LEAD is
-- used, and why it operates on business dates and not on GRS_REFINED_TIMESTAMP.
ivals AS (
    SELECT BROKER_ID, D AS ROW_EFF_DTE,
           LEAD(D) OVER (PARTITION BY BROKER_ID ORDER BY D) AS ROW_EXP_DTE
    FROM   bounds
    QUALIFY ROW_EXP_DTE IS NOT NULL
),

-- stage 6 — fill each interval from whichever source version contains it
new_rows AS (
    SELECT i.BROKER_ID, i.ROW_EFF_DTE, i.ROW_EXP_DTE,
           a.VAL AS BROKER_STATUS_CDE,
           b.VAL AS COMMISSION_TIER_CDE,
           SHA2(COALESCE(a.VAL,'~') || '|' || COALESCE(b.VAL,'~'), 256) AS ROW_HASH
    FROM   ivals i
    LEFT JOIN s1 a ON a.BROKER_ID = i.BROKER_ID
                  AND a.ROW_EFF_DTE <= i.ROW_EFF_DTE AND i.ROW_EXP_DTE <= a.ROW_EXP_DTE
    LEFT JOIN s2 b ON b.BROKER_ID = i.BROKER_ID
                  AND b.ROW_EFF_DTE <= i.ROW_EFF_DTE AND i.ROW_EXP_DTE <= b.ROW_EXP_DTE
),

-- stage 7 — the target, live rows only, for the impacted keys
cur_tgt AS (
    SELECT t.BROKER_PARTY_DIM_SK, t.BROKER_ID, t.ROW_EFF_DTE, t.ROW_EXP_DTE,
           t.BROKER_STATUS_CDE, t.COMMISSION_TIER_CDE, t.ROW_HASH
    FROM   V_Z2_BROKER_PARTY_DIM_LIVE t
    JOIN   impacted i ON i.BROKER_ID = t.BROKER_ID
),

-- stage 8 — classify. One row per (key, eff date) — rule 18 rows are simply
-- absent from new_rows and are deliberately NOT emitted, so the orphan is left
-- live and untouched. See solution_design.md section 14.
classified AS (
    SELECT n.BROKER_ID, n.ROW_EFF_DTE, n.ROW_EXP_DTE,
           n.BROKER_STATUS_CDE, n.COMMISSION_TIER_CDE, n.ROW_HASH,
           t.BROKER_PARTY_DIM_SK    AS TGT_SK,
           t.ROW_EXP_DTE            AS TGT_EXP,
           t.ROW_HASH               AS TGT_HASH,
           t.BROKER_STATUS_CDE      AS TGT_STATUS,
           t.COMMISSION_TIER_CDE    AS TGT_TIER,
           m.EXECUTION_TYPE, m.BATCH_ID, m.JOB_ID,
           -- The rerun +1 applies ONLY to the MATCHED rules, 1-16. Adding it to
           -- rule 17 would produce 18 -- which means something else entirely
           -- ("this target row is gone from the timeline, do nothing") and is
           -- not selected by the 'I' branch. A genuinely new interval arriving
           -- during a Z1_RERUN would then be silently DROPPED, leaving the
           -- target with no cover from that date on. Caught by S12 TC03.
           CASE
             WHEN t.BROKER_PARTY_DIM_SK IS NULL THEN 17
             ELSE
               CASE
                 WHEN t.ROW_HASH = n.ROW_HASH AND t.ROW_EXP_DTE = n.ROW_EXP_DTE
                      THEN CASE WHEN t.ROW_EXP_DTE = DATE '9999-12-31' THEN 1 ELSE 3 END
                 WHEN t.ROW_HASH = n.ROW_HASH
                      THEN CASE WHEN t.ROW_EXP_DTE = DATE '9999-12-31' THEN 5 ELSE 7 END
                 WHEN t.ROW_EXP_DTE = n.ROW_EXP_DTE
                      THEN CASE WHEN t.ROW_EXP_DTE = DATE '9999-12-31' THEN 9 ELSE 11 END
                 ELSE CASE WHEN t.ROW_EXP_DTE = DATE '9999-12-31' THEN 13 ELSE 15 END
               END
               + CASE WHEN m.EXECUTION_TYPE = 'Z1_RERUN' THEN 1 ELSE 0 END
           END AS RULE_NO
    FROM      new_rows n
    LEFT JOIN cur_tgt  t ON t.BROKER_ID = n.BROKER_ID AND t.ROW_EFF_DTE = n.ROW_EFF_DTE
    CROSS JOIN run_meta m
)

-- ---- the 'U' branch: rules 5,6 -------------------------------------------
SELECT TGT_SK AS BROKER_PARTY_DIM_SK, 'U' AS ACTION_FLAG, NULL AS DEL_IND,
       BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH,
       UUID_STRING() AS UUID, RULE_NO, BATCH_ID, JOB_ID
FROM   classified WHERE RULE_NO IN (5,6)

UNION ALL
-- ---- the 'U' branch: rules 2,4 — rerun, nothing changed but the UUID -------
SELECT TGT_SK, 'U', NULL, BROKER_ID, ROW_EFF_DTE, TGT_EXP,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH,
       UUID_STRING(), RULE_NO, BATCH_ID, JOB_ID
FROM   classified WHERE RULE_NO IN (2,4)

UNION ALL
-- ---- the 'D' branch: rules 7-16, the retire half --------------------------
SELECT TGT_SK, 'D',
       CASE WHEN TGT_EXP = DATE '9999-12-31' THEN NULL ELSE 'Y' END,   -- lineage only
       BROKER_ID, ROW_EFF_DTE, TGT_EXP,
       TGT_STATUS, TGT_TIER, TGT_HASH,          -- the row being RETIRED, not the new one
       NULL, RULE_NO, BATCH_ID, JOB_ID
FROM   classified WHERE RULE_NO BETWEEN 7 AND 16

UNION ALL
-- ---- the 'I' branch: rule 17, and the insert half of rules 7-16 -----------
-- These reach WHEN NOT MATCHED because the MERGE's ON clause excludes
-- ACTION_FLAG = 'I' outright -- it does NOT rely on the new SK being absent
-- from the target, so a reset or externally-seeded sequence cannot break it. NEXTVAL is consumed ONCE, in the inner SELECT,
-- then referenced twice -- never call NEXTVAL twice on one row and assume the
-- two references agree.
SELECT NEW_SK, 'I', 'N',
       BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH,
       UUID_STRING(), RULE_NO, BATCH_ID, JOB_ID
FROM  (SELECT SEQ_BROKER_PARTY_DIM_SK.NEXTVAL AS NEW_SK, c.*
       FROM   classified c
       WHERE  c.RULE_NO = 17 OR c.RULE_NO BETWEEN 7 AND 16);

UPDATE Z1_BROKER_COMMISSION_HIST
SET    NOTE_TEXT = 'back to v1', GRS_REFINED_TIMESTAMP = TIMESTAMP '2026-09-22 12:00'
WHERE  BROKER_ID = 'K1' AND ROW_EFF_DTE = DATE '2026-08-10';

SELECT 'S14 TC05 D2R2 — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S14 TC05 D2R2 — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'S14 TC05 D2R2 — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
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
SELECT 'S14 TC05 D2R2 — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT 'S14 TC05 D2R2 — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'S14 TC05 D2R2' AS TEST,
       CASE WHEN (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)  = 4
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM) = 10
                   AND (SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE) = 4
            -- the view is the original again -- later scenarios are unaffected
                   AND (SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'K1') = 6
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;
