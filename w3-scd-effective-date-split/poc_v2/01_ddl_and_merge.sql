-- ===========================================================================
-- POC v2 — object definitions and the apply step
--
-- Scope      : Snowflake only. NO stored procedures. IDMC deferred.
-- Rules      : solution_design.md section 6, the locked 18-row table.
-- Source     : sources/Requirement.xlsx, confirmed with leadership.
--
-- Business table names are ILLUSTRATIVE. Z1_/Z2_ stand in for the real
-- Zone1 history-bucket and Zone2 tables. ETL_DATA_INGESTION_SOURCE_WINDOW
-- and the audit column conventions are REAL.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- TARGET — Zone 2
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE Z2_BROKER_PARTY_DIM (
    BROKER_PARTY_DIM_SK     NUMBER(38,0),
    BROKER_ID               VARCHAR(20),
    ROW_EFF_DTE             DATE,
    ROW_EXP_DTE             DATE,
    BROKER_STATUS_CDE       VARCHAR(20),   -- from SRC_1
    COMMISSION_TIER_CDE     VARCHAR(20),   -- from SRC_2
    IS_DEL                  CHAR(1),
    ROW_HASH                VARCHAR(64),   -- over the target-bound columns only
    UUID                    VARCHAR(64),   -- restamped on a rerun (rules 2,4,6,8,10,12,14,16)
    AUDIT_BATCH_ID          NUMBER(38,0),  -- EXECUTION_RUN_ID
    AUDIT_JOB_ID            NUMBER(38,0),  -- JOB_RUN_ID
    AUDIT_CREATE_DATETIME   TIMESTAMP_NTZ,
    AUDIT_UPDATE_DATETIME   TIMESTAMP_NTZ
);

-- The live view of the target. BOTH conditions are required:
--   is_del = 'N'                   excludes rows retired by delete indicator
--   row_eff_dte < row_exp_dte      excludes DEAD RECORDS, which keep is_del = 'N'
-- Without the second condition a re-run sees two rows at one effective date
-- and cannot match. See solution_design.md section 8.
CREATE OR REPLACE VIEW V_Z2_BROKER_PARTY_DIM_LIVE AS
SELECT *
FROM   Z2_BROKER_PARTY_DIM
WHERE  IS_DEL = 'N'
  AND  ROW_EFF_DTE < ROW_EXP_DTE;


-- ---------------------------------------------------------------------------
-- STAGE — Step 1's only output, truncate + reload each run
--
-- NOTE ON EXISTING PIPELINES: the shared stage structure is not recreated per
-- run, so any column added here needs an ALTER across pipelines. See the
-- comment above the MERGE — RETIRE_MODE and DEL_IND are NOT required by the
-- apply logic and can be dropped if the ALTER is unwelcome.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE STG_Z2_BROKER_PARTY_DIM (
    -- ---- drives the MERGE -------------------------------------------------
    MERGE_KEY               NUMBER(38,0),  -- target SK on 'U'/'D'; NULL on 'I' so it can never match
    ACTION_FLAG             CHAR(1),       -- 'U' expire in place | 'D' retire | 'I' insert
    RETIRE_MODE             CHAR(1),       -- 'X' dead record | 'Y' delete indicator. NULL unless 'D'
    DEL_IND                 CHAR(1),       -- IS_DEL to apply: 'Y' retire, 'N' insert, NULL = leave as is

    -- ---- the row being written -------------------------------------------
    BROKER_PARTY_DIM_SK     NUMBER(38,0),  -- pre-assigned in Step 1; used by the INSERT branch
    BROKER_ID               VARCHAR(20),
    ROW_EFF_DTE             DATE,
    ROW_EXP_DTE             DATE,
    BROKER_STATUS_CDE       VARCHAR(20),   -- DEBUG ONLY on 'D'/'U' rows — the MERGE never reads it there
    COMMISSION_TIER_CDE     VARCHAR(20),   -- DEBUG ONLY on 'D'/'U' rows — the MERGE never reads it there
    ROW_HASH                VARCHAR(64),   -- DEBUG ONLY on 'D'/'U' rows — the MERGE never reads it there
    UUID                    VARCHAR(64),

    -- ---- audit ------------------------------------------------------------
    AUDIT_BATCH_ID          NUMBER(38,0),
    AUDIT_JOB_ID            NUMBER(38,0)
);

-- Surrogate keys are assigned in STEP 1, not inside the MERGE, so nothing
-- depends on a sequence behaving correctly under pushdown later.
CREATE SEQUENCE IF NOT EXISTS SEQ_BROKER_PARTY_DIM_SK START = 1 INCREMENT = 1;


-- ===========================================================================
-- STEP 2 — the apply. ONE atomic MERGE.
--
-- Separate UPDATE and INSERT statements are not approved by the client, and a
-- single MERGE cannot both update a matched row and insert its replacement
-- from the same source row. The stage solves that: a retire-plus-insert emits
-- TWO rows — one carrying the target SK, one carrying NULL.
--
-- Determinism: the diff emits at most one instruction per target row, so no
-- target row is ever matched twice and ERROR_ON_NONDETERMINISTIC_MERGE
-- (default TRUE) stays quiet.
-- ===========================================================================
MERGE INTO Z2_BROKER_PARTY_DIM T
USING STG_Z2_BROKER_PARTY_DIM S
   ON T.BROKER_PARTY_DIM_SK = S.MERGE_KEY

-- rules 5-6 : sat at the high end date, values unchanged -> move the expiry only
WHEN MATCHED AND S.ACTION_FLAG = 'U' THEN UPDATE SET
     T.ROW_EXP_DTE           = S.ROW_EXP_DTE,
     T.UUID                  = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()

-- rules 7-16 : retire.
--   RETIRE_MODE 'X' = dead record      -> pull ROW_EXP_DTE back to the row's own ROW_EFF_DTE
--   RETIRE_MODE 'Y' = delete indicator -> set IS_DEL = 'Y', leave both dates alone
WHEN MATCHED AND S.ACTION_FLAG = 'D' THEN UPDATE SET
     T.IS_DEL                = COALESCE(S.DEL_IND, T.IS_DEL),
     T.ROW_EXP_DTE           = CASE WHEN S.RETIRE_MODE = 'X'
                                    THEN T.ROW_EFF_DTE
                                    ELSE T.ROW_EXP_DTE END,
     T.UUID                  = COALESCE(S.UUID, T.UUID),
     T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()

-- rule 17, and the insert half of rules 7-16.
-- MERGE_KEY is NULL on these rows and NULL never equals a surrogate key,
-- so they can only ever reach this branch.
WHEN NOT MATCHED THEN INSERT (
     BROKER_PARTY_DIM_SK, BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE,
     BROKER_STATUS_CDE, COMMISSION_TIER_CDE, IS_DEL, ROW_HASH, UUID,
     AUDIT_BATCH_ID, AUDIT_JOB_ID, AUDIT_CREATE_DATETIME, AUDIT_UPDATE_DATETIME)
VALUES (
     S.BROKER_PARTY_DIM_SK, S.BROKER_ID, S.ROW_EFF_DTE, S.ROW_EXP_DTE,
     S.BROKER_STATUS_CDE, S.COMMISSION_TIER_CDE, COALESCE(S.DEL_IND,'N'), S.ROW_HASH, S.UUID,
     S.AUDIT_BATCH_ID, S.AUDIT_JOB_ID, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());


-- ===========================================================================
-- ALTERNATIVE 'D' BRANCH — needs NO new stage columns
--
-- The retirement mechanism is decided purely by the TARGET row's current
-- expiry, and the MERGE can already see it as T.ROW_EXP_DTE. So RETIRE_MODE
-- and DEL_IND do not have to be carried on the stage at all:
--
--   WHEN MATCHED AND S.ACTION_FLAG = 'D' THEN UPDATE SET
--        T.IS_DEL      = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
--                             THEN T.IS_DEL ELSE 'Y' END,
--        T.ROW_EXP_DTE = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
--                             THEN T.ROW_EFF_DTE ELSE T.ROW_EXP_DTE END,
--        T.AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
--
-- Safe because stage 7 excludes dead records, so a row already retired can
-- never re-enter the diff, and nothing writes to the target between Step 1
-- and Step 2 within a run.
--
-- If the ALTER across existing pipelines is unwelcome, switch to this branch
-- and drop RETIRE_MODE and DEL_IND from the stage. The apply behaves
-- identically; the two columns become debugging aids only.
-- ===========================================================================
