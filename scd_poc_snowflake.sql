/* ============================================================================
   W3 POC — multi-source SCD2 effective-date split
   ----------------------------------------------------------------------------
   Reproduces the Day 1 / Day 2 worked example end to end in Snowflake.
   Run top to bottom. Every EVIDENCE block returns a result set — capture each.

   WHAT IS REAL AND WHAT IS ILLUSTRATIVE
   -------------------------------------
   Taken from the ABC framework reference (abc_framework_success_scenario.md),
   names and columns as documented:
     ETL_DATA_INGESTION_SOURCE_WINDOW  the per-source-table sourcing window,
                                       with its real column list
     GRS_UNIQUE_ID                     Zone1 record-identifier audit column
     AUDIT_BATCH_ID / AUDIT_JOB_ID     Snowflake stage/target audit columns.
                                       NOTE the documented quirk: these hold
                                       EXECUTION_RUN_ID and JOB_RUN_ID, not the
                                       metadata batch_id / job_id
     AUDIT_CREATE_DATETIME /           standard audit column names
       AUDIT_UPDATE_DATETIME
     Stage tables are truncate-and-reload every run, never upsert

   Illustrative — shaped to the documented naming conventions, but the real
   object names are not in anything we hold, so SUBSTITUTE BEFORE REAL USE:
     Z1_BROKER_PARTY_HIST, Z1_BROKER_COMMISSION_HIST   Zone1 history bucket
     Z2_BROKER_PARTY_DIM                               Zone2 target
     STG_Z2_BROKER_PARTY_DIM                           stage
     GRS_REFINED_TIMESTAMP   the ABC doc describes "an audit column present on
                             every Zone1 target table marking when that row was
                             last refined" but never spells the column name

   SCENARIO
     Two Zone1 history-bucket tables, both SCD2, both contributing attributes
     to one Zone2 SCD2 dimension, joined on BROKER_ID.

   BROKERS UNDER TEST
     BR001  the main scenario — the party table never changes on Day 2, yet
            three of its target rows still have to be rewritten
     BR002  Day 2 changes a column that never reaches the target — must produce
            NO target change at all
     BR003  never touched after Day 1 — must not be re-read or re-written
============================================================================ */

USE DATABASE LM_POC_DB;
USE SCHEMA POC_SCHEMA;


/* ============================================================================
   PART 0 — objects
============================================================================ */

/* ---- ABC control table : real structure ---------------------------------- */
CREATE OR REPLACE TABLE ETL_DATA_INGESTION_SOURCE_WINDOW (
    EXECUTION_RUN_ID      NUMBER(38,0),
    TARGET_BATCH_ID       NUMBER(38,0),
    TARGET_JOB_ID         NUMBER(38,0),
    TARGET_TABLE_NAME     VARCHAR(128),
    SOURCE_TABLE_NAME     VARCHAR(128),
    JOB_RUN_ID            NUMBER(38,0),
    JOB_STATUS            VARCHAR(20),
    SOURCING_START_TIME   TIMESTAMP_NTZ,
    SOURCING_END_TIME     TIMESTAMP_NTZ
);

/* ---- Zone1 history-bucket sources ---------------------------------------- */
CREATE OR REPLACE TABLE Z1_BROKER_PARTY_HIST (
    GRS_UNIQUE_ID           VARCHAR(64),
    BROKER_ID               VARCHAR(20),
    BROKER_STATUS_CDE       VARCHAR(20),   -- reaches the target
    BROKER_NAME_TXT         VARCHAR(100),  -- does NOT reach the target
    ROW_EFF_DTE             DATE,
    ROW_EXP_DTE             DATE,
    GRS_REFINED_TIMESTAMP   TIMESTAMP_NTZ
);

CREATE OR REPLACE TABLE Z1_BROKER_COMMISSION_HIST (
    GRS_UNIQUE_ID           VARCHAR(64),
    BROKER_ID               VARCHAR(20),
    COMMISSION_TIER_CDE     VARCHAR(20),   -- reaches the target
    COMMISSION_NOTE_TXT     VARCHAR(100),  -- does NOT reach the target
    ROW_EFF_DTE             DATE,
    ROW_EXP_DTE             DATE,
    GRS_REFINED_TIMESTAMP   TIMESTAMP_NTZ
);

/* ---- Zone2 target -------------------------------------------------------- */
CREATE OR REPLACE TABLE Z2_BROKER_PARTY_DIM (
    BROKER_PARTY_DIM_SK     NUMBER(38,0),
    BROKER_ID               VARCHAR(20),
    ROW_EFF_DTE             DATE,
    ROW_EXP_DTE             DATE,
    BROKER_STATUS_CDE       VARCHAR(20),
    COMMISSION_TIER_CDE     VARCHAR(20),
    IS_DEL                  CHAR(1),
    ROW_HASH                VARCHAR(64),
    AUDIT_BATCH_ID          NUMBER(38,0),  -- holds EXECUTION_RUN_ID
    AUDIT_JOB_ID            NUMBER(38,0),  -- holds JOB_RUN_ID
    AUDIT_CREATE_DATETIME   TIMESTAMP_NTZ,
    AUDIT_UPDATE_DATETIME   TIMESTAMP_NTZ
);

/* ---- Stage : truncate-and-reload every run ------------------------------- */
CREATE OR REPLACE TABLE STG_Z2_BROKER_PARTY_DIM (
    ACTION_FLAG             CHAR(1),       -- 'I' insert, 'D' soft-delete
    BROKER_PARTY_DIM_SK     NUMBER(38,0),  -- set on 'D' rows only
    BROKER_ID               VARCHAR(20),
    ROW_EFF_DTE             DATE,
    ROW_EXP_DTE             DATE,
    BROKER_STATUS_CDE       VARCHAR(20),
    COMMISSION_TIER_CDE     VARCHAR(20),
    ROW_HASH                VARCHAR(64),
    AUDIT_BATCH_ID          NUMBER(38,0),
    AUDIT_JOB_ID            NUMBER(38,0)
);

CREATE OR REPLACE SEQUENCE SEQ_BROKER_PARTY_DIM_SK START = 1 INCREMENT = 1;


/* ----------------------------------------------------------------------------
   STEP 1 logic, as one statement.

   This is the SQL that would sit in the IDMC Source transformation's SQL
   override. It reads both Zone1 sources, the sourcing window, and the Zone2
   target, and returns exactly the rows the stage needs.

   The window is read PER SOURCE TABLE, which is how the real ABC table works —
   each source has its own start and end time, and only sources whose Zone1 job
   reached JOB_STATUS = 'Completed' are read.
---------------------------------------------------------------------------- */

CREATE OR REPLACE VIEW V_STEP1_BROKER_PARTY_DIM_DIFF AS
WITH cur_run AS (
    SELECT MAX(EXECUTION_RUN_ID) AS EXECUTION_RUN_ID
    FROM ETL_DATA_INGESTION_SOURCE_WINDOW
),
win AS (
    SELECT w.SOURCE_TABLE_NAME, w.SOURCING_START_TIME, w.SOURCING_END_TIME,
           w.EXECUTION_RUN_ID, w.JOB_RUN_ID
    FROM ETL_DATA_INGESTION_SOURCE_WINDOW w
    JOIN cur_run r ON r.EXECUTION_RUN_ID = w.EXECUTION_RUN_ID
    WHERE w.JOB_STATUS = 'Completed'
),
run_ids AS (
    SELECT MAX(EXECUTION_RUN_ID) AS AUDIT_BATCH_ID, MAX(JOB_RUN_ID) AS AUDIT_JOB_ID
    FROM win
),

/* [1] which broker ids changed in either source inside this run's window */
impacted_keys AS (
    SELECT DISTINCT s.BROKER_ID
    FROM Z1_BROKER_PARTY_HIST s
    JOIN win w ON w.SOURCE_TABLE_NAME = 'Z1_BROKER_PARTY_HIST'
    WHERE s.GRS_REFINED_TIMESTAMP >  w.SOURCING_START_TIME
      AND s.GRS_REFINED_TIMESTAMP <= w.SOURCING_END_TIME
    UNION
    SELECT DISTINCT s.BROKER_ID
    FROM Z1_BROKER_COMMISSION_HIST s
    JOIN win w ON w.SOURCE_TABLE_NAME = 'Z1_BROKER_COMMISSION_HIST'
    WHERE s.GRS_REFINED_TIMESTAMP >  w.SOURCING_START_TIME
      AND s.GRS_REFINED_TIMESTAMP <= w.SOURCING_END_TIME
),

/* [2] full history of those keys from BOTH sources — not only the delta rows */
party_full AS (
    SELECT s.* FROM Z1_BROKER_PARTY_HIST s
    JOIN impacted_keys k ON k.BROKER_ID = s.BROKER_ID
),
comm_full AS (
    SELECT s.* FROM Z1_BROKER_COMMISSION_HIST s
    JOIN impacted_keys k ON k.BROKER_ID = s.BROKER_ID
),

/* [3a] latest row per (key, eff date) — guards multi-batch arrival */
party_dedup AS (
    SELECT BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE, BROKER_STATUS_CDE
    FROM party_full
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY BROKER_ID, ROW_EFF_DTE ORDER BY GRS_REFINED_TIMESTAMP DESC
    ) = 1
),
comm_dedup AS (
    SELECT BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE, COMMISSION_TIER_CDE
    FROM comm_full
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY BROKER_ID, ROW_EFF_DTE ORDER BY GRS_REFINED_TIMESTAMP DESC
    ) = 1
),

/* [3b] a new run of identical values starts on the first row, on a gap in
        cover, or on a value change. A gap must NOT collapse even when the
        value either side is the same. */
party_flag AS (
    SELECT BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE, BROKER_STATUS_CDE,
           CASE
               WHEN LAG(ROW_EXP_DTE) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE) IS NULL THEN 1
               WHEN LAG(ROW_EXP_DTE) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE) <> ROW_EFF_DTE THEN 1
               WHEN LAG(BROKER_STATUS_CDE) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE)
                    IS DISTINCT FROM BROKER_STATUS_CDE THEN 1
               ELSE 0
           END AS NEW_RUN
    FROM party_dedup
),
comm_flag AS (
    SELECT BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE, COMMISSION_TIER_CDE,
           CASE
               WHEN LAG(ROW_EXP_DTE) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE) IS NULL THEN 1
               WHEN LAG(ROW_EXP_DTE) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE) <> ROW_EFF_DTE THEN 1
               WHEN LAG(COMMISSION_TIER_CDE) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE)
                    IS DISTINCT FROM COMMISSION_TIER_CDE THEN 1
               ELSE 0
           END AS NEW_RUN
    FROM comm_dedup
),
party_grp AS (
    SELECT BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE, BROKER_STATUS_CDE,
           SUM(NEW_RUN) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS GRP
    FROM party_flag
),
comm_grp AS (
    SELECT BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE, COMMISSION_TIER_CDE,
           SUM(NEW_RUN) OVER (PARTITION BY BROKER_ID ORDER BY ROW_EFF_DTE
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS GRP
    FROM comm_flag
),

/* [3c] collapse each run into one version */
party_clean AS (
    SELECT BROKER_ID, BROKER_STATUS_CDE,
           MIN(ROW_EFF_DTE) AS ROW_EFF_DTE, MAX(ROW_EXP_DTE) AS ROW_EXP_DTE
    FROM party_grp GROUP BY BROKER_ID, BROKER_STATUS_CDE, GRP
),
comm_clean AS (
    SELECT BROKER_ID, COMMISSION_TIER_CDE,
           MIN(ROW_EFF_DTE) AS ROW_EFF_DTE, MAX(ROW_EXP_DTE) AS ROW_EXP_DTE
    FROM comm_grp GROUP BY BROKER_ID, COMMISSION_TIER_CDE, GRP
),

/* [4] every boundary date either source mentions — eff dates AND exp dates.
       Exp dates matter: without them a gap in one source would be filled with
       the value from before the gap. UNION de-duplicates. */
boundaries AS (
    SELECT BROKER_ID, ROW_EFF_DTE AS BOUNDARY_DTE FROM party_clean
    UNION SELECT BROKER_ID, ROW_EXP_DTE FROM party_clean
    UNION SELECT BROKER_ID, ROW_EFF_DTE FROM comm_clean
    UNION SELECT BROKER_ID, ROW_EXP_DTE FROM comm_clean
),

/* [5] boundaries become intervals; the final boundary closes the last interval
       and is not an interval of its own */
intervals AS (
    SELECT BROKER_ID, BOUNDARY_DTE AS ROW_EFF_DTE,
           LEAD(BOUNDARY_DTE) OVER (PARTITION BY BROKER_ID ORDER BY BOUNDARY_DTE) AS ROW_EXP_DTE
    FROM boundaries
),
intervals_valid AS (
    SELECT * FROM intervals WHERE ROW_EXP_DTE IS NOT NULL
),

/* [6] fill each interval. Interval edges come from the boundary set, so each
       interval falls entirely inside at most ONE version per source — each
       join matches 0 or 1 rows and nothing fans out. */
new_timeline AS (
    SELECT i.BROKER_ID, i.ROW_EFF_DTE, i.ROW_EXP_DTE,
           p.BROKER_STATUS_CDE, c.COMMISSION_TIER_CDE,
           SHA2(COALESCE(p.BROKER_STATUS_CDE,   '<NULL>') || '||' ||
                COALESCE(c.COMMISSION_TIER_CDE, '<NULL>'), 256) AS ROW_HASH
    FROM intervals_valid i
    LEFT JOIN party_clean p
           ON p.BROKER_ID   = i.BROKER_ID
          AND p.ROW_EFF_DTE <= i.ROW_EFF_DTE
          AND p.ROW_EXP_DTE >  i.ROW_EFF_DTE
    LEFT JOIN comm_clean c
           ON c.BROKER_ID   = i.BROKER_ID
          AND c.ROW_EFF_DTE <= i.ROW_EFF_DTE
          AND c.ROW_EXP_DTE >  i.ROW_EFF_DTE
),

/* [7] what the target holds right now for those keys */
cur_tgt AS (
    SELECT t.BROKER_PARTY_DIM_SK, t.BROKER_ID, t.ROW_EFF_DTE, t.ROW_EXP_DTE,
           t.BROKER_STATUS_CDE, t.COMMISSION_TIER_CDE, t.ROW_HASH
    FROM Z2_BROKER_PARTY_DIM t
    JOIN impacted_keys k ON k.BROKER_ID = t.BROKER_ID
    WHERE t.IS_DEL = 'N'
),

/* [8] diff — dates AND values, so a value corrected without moving its dates
       still produces a D + I pair */
to_insert AS (
    SELECT n.BROKER_ID, n.ROW_EFF_DTE, n.ROW_EXP_DTE,
           n.BROKER_STATUS_CDE, n.COMMISSION_TIER_CDE, n.ROW_HASH
    FROM new_timeline n
    LEFT JOIN cur_tgt c
           ON c.BROKER_ID    = n.BROKER_ID
          AND c.ROW_EFF_DTE  = n.ROW_EFF_DTE
          AND c.ROW_EXP_DTE  = n.ROW_EXP_DTE
          AND c.ROW_HASH     = n.ROW_HASH
    WHERE c.BROKER_ID IS NULL
),
to_delete AS (
    SELECT c.BROKER_PARTY_DIM_SK, c.BROKER_ID, c.ROW_EFF_DTE, c.ROW_EXP_DTE,
           c.BROKER_STATUS_CDE, c.COMMISSION_TIER_CDE, c.ROW_HASH
    FROM cur_tgt c
    LEFT JOIN new_timeline n
           ON n.BROKER_ID    = c.BROKER_ID
          AND n.ROW_EFF_DTE  = c.ROW_EFF_DTE
          AND n.ROW_EXP_DTE  = c.ROW_EXP_DTE
          AND n.ROW_HASH     = c.ROW_HASH
    WHERE n.BROKER_ID IS NULL
)

SELECT 'I' AS ACTION_FLAG,
       CAST(NULL AS NUMBER(38,0)) AS BROKER_PARTY_DIM_SK,
       i.BROKER_ID, i.ROW_EFF_DTE, i.ROW_EXP_DTE,
       i.BROKER_STATUS_CDE, i.COMMISSION_TIER_CDE, i.ROW_HASH,
       r.AUDIT_BATCH_ID, r.AUDIT_JOB_ID
FROM to_insert i, run_ids r
UNION ALL
SELECT 'D', d.BROKER_PARTY_DIM_SK,
       d.BROKER_ID, d.ROW_EFF_DTE, d.ROW_EXP_DTE,
       d.BROKER_STATUS_CDE, d.COMMISSION_TIER_CDE, d.ROW_HASH,
       r.AUDIT_BATCH_ID, r.AUDIT_JOB_ID
FROM to_delete d, run_ids r;


/* ============================================================================
   PART 1 — DAY 1 : Zone1 data, and the sourcing window for run 101
============================================================================ */

INSERT INTO Z1_BROKER_PARTY_HIST
    (GRS_UNIQUE_ID, BROKER_ID, BROKER_STATUS_CDE, BROKER_NAME_TXT,
     ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP)
VALUES
    ('UID-P-001','BR001','ACTIVE' ,'Acme Broking','2026-09-10'::DATE,'2026-09-21'::DATE,'2026-09-18 08:00:00'::TIMESTAMP_NTZ),
    ('UID-P-002','BR001','SUSPEND','Acme Broking','2026-09-21'::DATE,'9999-12-31'::DATE,'2026-09-18 08:00:00'::TIMESTAMP_NTZ),
    ('UID-P-003','BR002','ACTIVE' ,'Border Ins'  ,'2026-09-05'::DATE,'9999-12-31'::DATE,'2026-09-18 08:00:00'::TIMESTAMP_NTZ),
    ('UID-P-004','BR003','ACTIVE' ,'Crown Agency','2026-09-01'::DATE,'9999-12-31'::DATE,'2026-09-18 08:00:00'::TIMESTAMP_NTZ);

INSERT INTO Z1_BROKER_COMMISSION_HIST
    (GRS_UNIQUE_ID, BROKER_ID, COMMISSION_TIER_CDE, COMMISSION_NOTE_TXT,
     ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP)
VALUES
    ('UID-C-001','BR001','TIER1','initial','2026-09-09'::DATE,'9999-12-31'::DATE,'2026-09-18 08:00:00'::TIMESTAMP_NTZ),
    ('UID-C-002','BR002','TIER1','initial','2026-09-05'::DATE,'9999-12-31'::DATE,'2026-09-18 08:00:00'::TIMESTAMP_NTZ),
    ('UID-C-003','BR003','TIER1','initial','2026-09-01'::DATE,'9999-12-31'::DATE,'2026-09-18 08:00:00'::TIMESTAMP_NTZ);

-- the sourcing window the framework writes at job preload: one row per source
INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
    (EXECUTION_RUN_ID, TARGET_BATCH_ID, TARGET_JOB_ID, TARGET_TABLE_NAME,
     SOURCE_TABLE_NAME, JOB_RUN_ID, JOB_STATUS, SOURCING_START_TIME, SOURCING_END_TIME)
VALUES
    (101, 5001, 7001, 'Z2_BROKER_PARTY_DIM', 'Z1_BROKER_PARTY_HIST',      9101, 'Completed',
     '1900-01-01 00:00:00'::TIMESTAMP_NTZ, '2026-09-18 23:59:59'::TIMESTAMP_NTZ),
    (101, 5001, 7001, 'Z2_BROKER_PARTY_DIM', 'Z1_BROKER_COMMISSION_HIST', 9101, 'Completed',
     '1900-01-01 00:00:00'::TIMESTAMP_NTZ, '2026-09-18 23:59:59'::TIMESTAMP_NTZ);

-- EVIDENCE 1
SELECT 'EV1 Z1_BROKER_PARTY_HIST (Day 1)' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       BROKER_NAME_TXT, ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'EV1 Z1_BROKER_COMMISSION_HIST (Day 1)' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       COMMISSION_NOTE_TXT, ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'EV1 ETL_DATA_INGESTION_SOURCE_WINDOW' AS EVIDENCE, EXECUTION_RUN_ID, TARGET_TABLE_NAME,
       SOURCE_TABLE_NAME, JOB_STATUS, SOURCING_START_TIME, SOURCING_END_TIME
FROM ETL_DATA_INGESTION_SOURCE_WINDOW ORDER BY EXECUTION_RUN_ID, SOURCE_TABLE_NAME;


/* ============================================================================
   PART 2 — DAY 1 : STEP 1, build the stage
============================================================================ */

TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;

INSERT INTO STG_Z2_BROKER_PARTY_DIM
    (ACTION_FLAG, BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
     BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH, AUDIT_BATCH_ID, AUDIT_JOB_ID)
SELECT ACTION_FLAG, BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH, AUDIT_BATCH_ID, AUDIT_JOB_ID
FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

-- EVIDENCE 2 — expect 5 rows, all 'I', no 'D'
SELECT 'EV2 STAGE (Day 1)' AS EVIDENCE, ACTION_FLAG, BROKER_PARTY_DIM_SK, BROKER_ID,
       ROW_EFF_DTE, ROW_EXP_DTE, BROKER_STATUS_CDE, COMMISSION_TIER_CDE,
       AUDIT_BATCH_ID, AUDIT_JOB_ID
FROM STG_Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ACTION_FLAG, ROW_EFF_DTE;

SELECT 'EV2 counts (Day 1)' AS EVIDENCE, ACTION_FLAG, COUNT(*) AS ROW_COUNT
FROM STG_Z2_BROKER_PARTY_DIM GROUP BY ACTION_FLAG ORDER BY ACTION_FLAG;


/* ============================================================================
   PART 3 — DAY 1 : STEP 2 soft-delete, then STEP 3 insert
============================================================================ */

-- STEP 2 — nothing to soft-delete on a first load; runs anyway
UPDATE Z2_BROKER_PARTY_DIM
SET IS_DEL = 'Y',
    AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM STG_Z2_BROKER_PARTY_DIM S
WHERE S.ACTION_FLAG = 'D'
  AND Z2_BROKER_PARTY_DIM.BROKER_PARTY_DIM_SK = S.BROKER_PARTY_DIM_SK;

-- STEP 3
INSERT INTO Z2_BROKER_PARTY_DIM
    (BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
     BROKER_STATUS_CDE, COMMISSION_TIER_CDE, IS_DEL, ROW_HASH,
     AUDIT_BATCH_ID, AUDIT_JOB_ID, AUDIT_CREATE_DATETIME, AUDIT_UPDATE_DATETIME)
SELECT SEQ_BROKER_PARTY_DIM_SK.NEXTVAL, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, 'N', ROW_HASH,
       AUDIT_BATCH_ID, AUDIT_JOB_ID,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM STG_Z2_BROKER_PARTY_DIM
WHERE ACTION_FLAG = 'I';

-- EVIDENCE 3
SELECT 'EV3 Z2_BROKER_PARTY_DIM (after Day 1)' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       ROW_EFF_DTE, ROW_EXP_DTE, BROKER_STATUS_CDE, COMMISSION_TIER_CDE, IS_DEL, AUDIT_BATCH_ID
FROM Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, BROKER_PARTY_DIM_SK;


/* ============================================================================
   PART 4 — DAY 2 : Zone1 changes, and the window for run 102

   Z1_BROKER_PARTY_HIST      : nothing at all.
   Z1_BROKER_COMMISSION_HIST : BR001 splits into three versions.
                               BR002 splits too, but only COMMISSION_NOTE_TXT
                               differs — the target must not change for BR002.
============================================================================ */

UPDATE Z1_BROKER_COMMISSION_HIST
SET ROW_EXP_DTE = '2026-09-15'::DATE,
    GRS_REFINED_TIMESTAMP = '2026-09-19 08:00:00'::TIMESTAMP_NTZ
WHERE BROKER_ID = 'BR001' AND ROW_EFF_DTE = '2026-09-09'::DATE;

UPDATE Z1_BROKER_COMMISSION_HIST
SET ROW_EXP_DTE = '2026-09-12'::DATE,
    GRS_REFINED_TIMESTAMP = '2026-09-19 08:00:00'::TIMESTAMP_NTZ
WHERE BROKER_ID = 'BR002' AND ROW_EFF_DTE = '2026-09-05'::DATE;

INSERT INTO Z1_BROKER_COMMISSION_HIST
    (GRS_UNIQUE_ID, BROKER_ID, COMMISSION_TIER_CDE, COMMISSION_NOTE_TXT,
     ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP)
VALUES
    ('UID-C-004','BR001','TIER2','uplift'  ,'2026-09-15'::DATE,'2026-09-22'::DATE,'2026-09-19 08:00:00'::TIMESTAMP_NTZ),
    ('UID-C-005','BR001','TIER3','uplift'  ,'2026-09-22'::DATE,'9999-12-31'::DATE,'2026-09-19 08:00:00'::TIMESTAMP_NTZ),
    ('UID-C-006','BR002','TIER1','reworded','2026-09-12'::DATE,'9999-12-31'::DATE,'2026-09-19 08:00:00'::TIMESTAMP_NTZ);

INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
    (EXECUTION_RUN_ID, TARGET_BATCH_ID, TARGET_JOB_ID, TARGET_TABLE_NAME,
     SOURCE_TABLE_NAME, JOB_RUN_ID, JOB_STATUS, SOURCING_START_TIME, SOURCING_END_TIME)
VALUES
    (102, 5001, 7001, 'Z2_BROKER_PARTY_DIM', 'Z1_BROKER_PARTY_HIST',      9102, 'Completed',
     '2026-09-18 23:59:59'::TIMESTAMP_NTZ, '2026-09-19 23:59:59'::TIMESTAMP_NTZ),
    (102, 5001, 7001, 'Z2_BROKER_PARTY_DIM', 'Z1_BROKER_COMMISSION_HIST', 9102, 'Completed',
     '2026-09-18 23:59:59'::TIMESTAMP_NTZ, '2026-09-19 23:59:59'::TIMESTAMP_NTZ);

-- EVIDENCE 4
SELECT 'EV4 Z1_BROKER_PARTY_HIST (Day 2 - untouched)' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT 'EV4 Z1_BROKER_COMMISSION_HIST (Day 2)' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       COMMISSION_NOTE_TXT, ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;


/* ============================================================================
   PART 5 — DAY 2 : STEP 1
============================================================================ */

TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;

INSERT INTO STG_Z2_BROKER_PARTY_DIM
    (ACTION_FLAG, BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
     BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH, AUDIT_BATCH_ID, AUDIT_JOB_ID)
SELECT ACTION_FLAG, BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH, AUDIT_BATCH_ID, AUDIT_JOB_ID
FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

-- EVIDENCE 5 — expect exactly 4 'I' and 2 'D', all BR001.
-- Nothing for BR002 (the collapse) and nothing for BR003 (outside the window).
SELECT 'EV5 STAGE (Day 2)' AS EVIDENCE, ACTION_FLAG, BROKER_PARTY_DIM_SK, BROKER_ID,
       ROW_EFF_DTE, ROW_EXP_DTE, BROKER_STATUS_CDE, COMMISSION_TIER_CDE,
       AUDIT_BATCH_ID, AUDIT_JOB_ID
FROM STG_Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ACTION_FLAG, ROW_EFF_DTE;

SELECT 'EV5 counts (Day 2)' AS EVIDENCE, BROKER_ID, ACTION_FLAG, COUNT(*) AS ROW_COUNT
FROM STG_Z2_BROKER_PARTY_DIM GROUP BY BROKER_ID, ACTION_FLAG ORDER BY BROKER_ID, ACTION_FLAG;


/* ============================================================================
   PART 6 — DAY 2 : STEP 2 then STEP 3
============================================================================ */

UPDATE Z2_BROKER_PARTY_DIM
SET IS_DEL = 'Y',
    AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM STG_Z2_BROKER_PARTY_DIM S
WHERE S.ACTION_FLAG = 'D'
  AND Z2_BROKER_PARTY_DIM.BROKER_PARTY_DIM_SK = S.BROKER_PARTY_DIM_SK;

INSERT INTO Z2_BROKER_PARTY_DIM
    (BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
     BROKER_STATUS_CDE, COMMISSION_TIER_CDE, IS_DEL, ROW_HASH,
     AUDIT_BATCH_ID, AUDIT_JOB_ID, AUDIT_CREATE_DATETIME, AUDIT_UPDATE_DATETIME)
SELECT SEQ_BROKER_PARTY_DIM_SK.NEXTVAL, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, 'N', ROW_HASH,
       AUDIT_BATCH_ID, AUDIT_JOB_ID,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM STG_Z2_BROKER_PARTY_DIM
WHERE ACTION_FLAG = 'I';

-- EVIDENCE 6 — everything, live and superseded
SELECT 'EV6 Z2_BROKER_PARTY_DIM (after Day 2 - all rows)' AS EVIDENCE, BROKER_PARTY_DIM_SK,
       BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE, BROKER_STATUS_CDE, COMMISSION_TIER_CDE,
       IS_DEL, AUDIT_BATCH_ID
FROM Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

-- EVIDENCE 7 — the live timeline; this is what consumers see
SELECT 'EV7 Z2_BROKER_PARTY_DIM (live rows only)' AS EVIDENCE, BROKER_ID,
       ROW_EFF_DTE, ROW_EXP_DTE, BROKER_STATUS_CDE, COMMISSION_TIER_CDE
FROM Z2_BROKER_PARTY_DIM WHERE IS_DEL = 'N'
ORDER BY BROKER_ID, ROW_EFF_DTE;


/* ============================================================================
   PART 7 — validation. Every row must read PASS.
============================================================================ */

SELECT 'T01 BR001 has 5 live versions after Day 2' AS TEST_NAME,
       COUNT(*) AS ACTUAL, 5 AS EXPECTED,
       CASE WHEN COUNT(*) = 5 THEN 'PASS' ELSE 'FAIL' END AS RESULT
FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'BR001' AND IS_DEL = 'N'

UNION ALL SELECT 'T02 BR001 has 2 superseded rows', COUNT(*), 2,
       CASE WHEN COUNT(*) = 2 THEN 'PASS' ELSE 'FAIL' END
FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'BR001' AND IS_DEL = 'Y'

UNION ALL SELECT 'T03 BR002 unchanged - still exactly 1 live row', COUNT(*), 1,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'BR002' AND IS_DEL = 'N'

UNION ALL SELECT 'T04 BR002 never soft-deleted - the collapse worked', COUNT(*), 0,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'BR002' AND IS_DEL = 'Y'

UNION ALL SELECT 'T05 BR003 untouched - exactly 1 live row', COUNT(*), 1,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'BR003' AND IS_DEL = 'N'

UNION ALL SELECT 'T06 BR001 live timeline has no gaps or overlaps', COUNT(*), 0,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (
    SELECT ROW_EXP_DTE, LEAD(ROW_EFF_DTE) OVER (ORDER BY ROW_EFF_DTE) AS NEXT_EFF
    FROM Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'BR001' AND IS_DEL = 'N'
) q WHERE NEXT_EFF IS NOT NULL AND NEXT_EFF <> ROW_EXP_DTE

UNION ALL SELECT 'T07 BROKER_ID + ROW_EFF_DTE unique among live rows', COUNT(*), 0,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (
    SELECT BROKER_ID, ROW_EFF_DTE FROM Z2_BROKER_PARTY_DIM WHERE IS_DEL = 'N'
    GROUP BY BROKER_ID, ROW_EFF_DTE HAVING COUNT(*) > 1
) d

UNION ALL SELECT 'T08 that same pair is NOT unique across all rows', COUNT(*), 2,
       CASE WHEN COUNT(*) = 2 THEN 'PASS' ELSE 'FAIL' END
FROM (
    SELECT BROKER_ID, ROW_EFF_DTE FROM Z2_BROKER_PARTY_DIM
    GROUP BY BROKER_ID, ROW_EFF_DTE HAVING COUNT(*) > 1
) d2

UNION ALL SELECT 'T09 BR001 first interval is 09-Sep to 10-Sep', COUNT(*), 1,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM Z2_BROKER_PARTY_DIM
WHERE BROKER_ID = 'BR001' AND IS_DEL = 'N'
  AND ROW_EFF_DTE = '2026-09-09'::DATE AND ROW_EXP_DTE = '2026-09-10'::DATE

UNION ALL SELECT 'T10 that first row has no BROKER_STATUS_CDE', COUNT(*), 1,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM Z2_BROKER_PARTY_DIM
WHERE BROKER_ID = 'BR001' AND IS_DEL = 'N'
  AND ROW_EFF_DTE = '2026-09-09'::DATE AND BROKER_STATUS_CDE IS NULL

UNION ALL SELECT 'T11 Day 2 rows carry AUDIT_BATCH_ID 102', COUNT(*), 4,
       CASE WHEN COUNT(*) = 4 THEN 'PASS' ELSE 'FAIL' END
FROM Z2_BROKER_PARTY_DIM WHERE AUDIT_BATCH_ID = 102

ORDER BY 1;


/* ============================================================================
   PART 8 — idempotence

   A third run whose window contains no newly refined rows must produce an
   empty stage. If this returns anything, the diff is unstable.
============================================================================ */

INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
    (EXECUTION_RUN_ID, TARGET_BATCH_ID, TARGET_JOB_ID, TARGET_TABLE_NAME,
     SOURCE_TABLE_NAME, JOB_RUN_ID, JOB_STATUS, SOURCING_START_TIME, SOURCING_END_TIME)
VALUES
    (103, 5001, 7001, 'Z2_BROKER_PARTY_DIM', 'Z1_BROKER_PARTY_HIST',      9103, 'Completed',
     '2026-09-19 23:59:59'::TIMESTAMP_NTZ, '2026-09-20 23:59:59'::TIMESTAMP_NTZ),
    (103, 5001, 7001, 'Z2_BROKER_PARTY_DIM', 'Z1_BROKER_COMMISSION_HIST', 9103, 'Completed',
     '2026-09-19 23:59:59'::TIMESTAMP_NTZ, '2026-09-20 23:59:59'::TIMESTAMP_NTZ);

TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;

INSERT INTO STG_Z2_BROKER_PARTY_DIM
    (ACTION_FLAG, BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
     BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH, AUDIT_BATCH_ID, AUDIT_JOB_ID)
SELECT ACTION_FLAG, BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_HASH, AUDIT_BATCH_ID, AUDIT_JOB_ID
FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT 'T12 re-run with no newly refined rows produces an empty stage' AS TEST_NAME,
       COUNT(*) AS ACTUAL, 0 AS EXPECTED,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS RESULT
FROM STG_Z2_BROKER_PARTY_DIM;
