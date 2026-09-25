-- ===========================================================================
-- POC v2  —  00_objects.sql
-- Objects shared by every scenario and test case. Run this ONCE.
--
-- Rules   : ../solution_design.md section 6 — the locked 18-row table
-- Source  : ../sources/Requirement.xlsx, confirmed with leadership
-- Scope   : Snowflake only. NO stored procedures. IDMC deferred.
--
-- ETL_DATA_INGESTION_SOURCE_WINDOW, GRS_REFINED_TIMESTAMP and the audit
-- column conventions are REAL. Business table names are illustrative.
-- ===========================================================================

USE ROLE      POC_ROLE;
USE WAREHOUSE POC_WH;
USE DATABASE  LM_POC_DB;
USE SCHEMA    POC_SCHEMA;


-- ---------------------------------------------------------------------------
-- ABC framework — the sourcing window. One row per (run, source table).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ETL_DATA_INGESTION_SOURCE_WINDOW (
    EXECUTION_RUN_ID        NUMBER(38,0),
    JOB_RUN_ID              NUMBER(38,0),
    TARGET_TABLE_NAME       VARCHAR(100),
    SOURCE_TABLE_NAME       VARCHAR(100),
    WINDOW_START            TIMESTAMP_NTZ,
    WINDOW_END              TIMESTAMP_NTZ,
    EXECUTION_TYPE          VARCHAR(20),   -- 'NEW' | 'RESTART' | 'Z1_RERUN'
    JOB_STATUS              VARCHAR(20)
);


-- ---------------------------------------------------------------------------
-- ZONE 1 — history buckets. Both SCD2. Both ~1000 columns in reality;
-- only the target-bound ones are modelled here.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE Z1_BROKER_PARTY_HIST (
    BROKER_ID               VARCHAR(20),
    BROKER_STATUS_CDE       VARCHAR(20),   -- reaches the target
    NOTE_TEXT               VARCHAR(200),  -- does NOT reach the target (S03)
    ROW_EFF_DTE             DATE,
    ROW_EXP_DTE             DATE,
    UNIQUE_ID               VARCHAR(64),
    GRS_REFINED_TIMESTAMP   TIMESTAMP_NTZ  -- when Zone1 loaded it. NOT business time
);

CREATE OR REPLACE TABLE Z1_BROKER_COMMISSION_HIST (
    BROKER_ID               VARCHAR(20),
    COMMISSION_TIER_CDE     VARCHAR(20),   -- reaches the target
    NOTE_TEXT               VARCHAR(200),  -- does NOT reach the target (S03)
    ROW_EFF_DTE             DATE,
    ROW_EXP_DTE             DATE,
    UNIQUE_ID               VARCHAR(64),
    GRS_REFINED_TIMESTAMP   TIMESTAMP_NTZ
);


-- ---------------------------------------------------------------------------
-- ZONE 2 — the target.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE Z2_BROKER_PARTY_DIM (
    BROKER_PARTY_DIM_SK     NUMBER(38,0),
    BROKER_ID               VARCHAR(20),
    ROW_EFF_DTE             DATE,
    ROW_EXP_DTE             DATE,
    BROKER_STATUS_CDE       VARCHAR(20),
    COMMISSION_TIER_CDE     VARCHAR(20),
    IS_DEL                  CHAR(1),
    ROW_HASH                VARCHAR(64),
    UUID                    VARCHAR(64),
    AUDIT_BATCH_ID          NUMBER(38,0),
    AUDIT_JOB_ID            NUMBER(38,0),
    AUDIT_CREATE_DATETIME   TIMESTAMP_NTZ,
    AUDIT_UPDATE_DATETIME   TIMESTAMP_NTZ
);

-- The live view. BOTH conditions are required:
--   IS_DEL = 'N'                  excludes rows retired by delete indicator
--   ROW_EFF_DTE < ROW_EXP_DTE     excludes DEAD RECORDS, which keep IS_DEL = 'N'
-- Without the second, a re-run sees two rows at one effective date and cannot
-- match. See solution_design.md section 8.
CREATE OR REPLACE VIEW V_Z2_BROKER_PARTY_DIM_LIVE AS
SELECT * FROM Z2_BROKER_PARTY_DIM
WHERE  IS_DEL = 'N' AND ROW_EFF_DTE < ROW_EXP_DTE;


-- ---------------------------------------------------------------------------
-- STAGE — Step 1's only output. Truncate + reload each run.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE STG_Z2_BROKER_PARTY_DIM (
    MERGE_KEY               NUMBER(38,0),  -- target SK on 'U'/'D'; a fresh SK on 'I' (cannot match)
    ACTION_FLAG             CHAR(1),       -- 'U' expire in place | 'D' retire | 'I' insert
    RETIRE_MODE             CHAR(1),       -- 'X' dead record | 'Y' delete indicator. DEBUG: the
                                           -- MERGE derives this from T.ROW_EXP_DTE and never reads it
    DEL_IND                 CHAR(1),       -- IS_DEL to apply. Already present in the real stage
    BROKER_PARTY_DIM_SK     NUMBER(38,0),  -- pre-assigned in Step 1; used by the INSERT branch
    BROKER_ID               VARCHAR(20),
    ROW_EFF_DTE             DATE,
    ROW_EXP_DTE             DATE,
    BROKER_STATUS_CDE       VARCHAR(20),   -- DEBUG on 'U'/'D' rows — the MERGE never reads it there
    COMMISSION_TIER_CDE     VARCHAR(20),   -- DEBUG on 'U'/'D' rows
    ROW_HASH                VARCHAR(64),   -- DEBUG on 'U'/'D' rows
    UUID                    VARCHAR(64),
    RULE_NO                 NUMBER(2,0),   -- DEBUG: which of the 18 rules produced this row
    AUDIT_BATCH_ID          NUMBER(38,0),
    AUDIT_JOB_ID            NUMBER(38,0)
);

CREATE SEQUENCE IF NOT EXISTS SEQ_BROKER_PARTY_DIM_SK START = 1 INCREMENT = 1;


-- ===========================================================================
-- STEP 1 — the diff. A VIEW, because stored procedures are not allowed.
--
-- Eight stages, one statement, no intermediate tables. Emits the complete
-- instruction list: a retire-plus-insert produces TWO rows.
-- ===========================================================================
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
-- gap in S05; without it two A1 versions either side of a gap would merge.
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

-- stage 8 — classify. One row per (key, eff date); rule 18 rows are simply
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
           CASE
             WHEN t.BROKER_PARTY_DIM_SK IS NULL                                       THEN 17
             WHEN t.ROW_HASH = n.ROW_HASH AND t.ROW_EXP_DTE = n.ROW_EXP_DTE
                  THEN CASE WHEN t.ROW_EXP_DTE = DATE '9999-12-31' THEN 1 ELSE 3 END
             WHEN t.ROW_HASH = n.ROW_HASH
                  THEN CASE WHEN t.ROW_EXP_DTE = DATE '9999-12-31' THEN 5 ELSE 7 END
             WHEN t.ROW_EXP_DTE = n.ROW_EXP_DTE
                  THEN CASE WHEN t.ROW_EXP_DTE = DATE '9999-12-31' THEN 9 ELSE 11 END
             ELSE CASE WHEN t.ROW_EXP_DTE = DATE '9999-12-31' THEN 13 ELSE 15 END
           END
           + CASE WHEN m.EXECUTION_TYPE = 'Z1_RERUN' THEN 1 ELSE 0 END AS RULE_NO
    FROM      new_rows n
    LEFT JOIN cur_tgt  t ON t.BROKER_ID = n.BROKER_ID AND t.ROW_EFF_DTE = n.ROW_EFF_DTE
    CROSS JOIN run_meta m
)

-- ---- the 'U' branch: rules 5,6 -------------------------------------------
SELECT TGT_SK AS MERGE_KEY, 'U' AS ACTION_FLAG, NULL AS RETIRE_MODE, NULL AS DEL_IND,
       TGT_SK AS BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH,
       UUID_STRING() AS UUID, RULE_NO, BATCH_ID, JOB_ID
FROM   classified WHERE RULE_NO IN (5,6)

UNION ALL
-- ---- the 'U' branch: rules 2,4 — rerun, nothing changed but the UUID -------
SELECT TGT_SK, 'U', NULL, NULL, TGT_SK, BROKER_ID, ROW_EFF_DTE, TGT_EXP,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH,
       UUID_STRING(), RULE_NO, BATCH_ID, JOB_ID
FROM   classified WHERE RULE_NO IN (2,4)

UNION ALL
-- ---- the 'D' branch: rules 7-16, the retire half --------------------------
SELECT TGT_SK, 'D',
       CASE WHEN TGT_EXP = DATE '9999-12-31' THEN 'X' ELSE 'Y' END,
       CASE WHEN TGT_EXP = DATE '9999-12-31' THEN NULL ELSE 'Y' END,
       TGT_SK, BROKER_ID, ROW_EFF_DTE, TGT_EXP,
       TGT_STATUS, TGT_TIER, TGT_HASH,          -- the row being RETIRED, not the new one
       NULL, RULE_NO, BATCH_ID, JOB_ID
FROM   classified WHERE RULE_NO BETWEEN 7 AND 16

UNION ALL
-- ---- the 'I' branch: rule 17, and the insert half of rules 7-16 -----------
-- A freshly allocated SK cannot exist in the target, so these never match and
-- always reach WHEN NOT MATCHED. NEXTVAL is consumed ONCE, in the inner SELECT,
-- then referenced twice -- never call NEXTVAL twice on one row and assume the
-- two references agree.
SELECT NEW_SK, 'I', NULL, 'N',
       NEW_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH,
       UUID_STRING(), RULE_NO, BATCH_ID, JOB_ID
FROM  (SELECT SEQ_BROKER_PARTY_DIM_SK.NEXTVAL AS NEW_SK, c.*
       FROM   classified c
       WHERE  c.RULE_NO = 17 OR c.RULE_NO BETWEEN 7 AND 16);
