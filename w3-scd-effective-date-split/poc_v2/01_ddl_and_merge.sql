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
-- STAGE — Step 1's only output, truncate + reload each run.
--
-- NO NEW COLUMNS. An earlier draft carried MERGE_KEY and RETIRE_MODE — both are
-- gone, because both were avoidable:
--
--   MERGE_KEY    was byte-for-byte identical to BROKER_PARTY_DIM_SK on every
--                branch. Pure duplication. The MERGE joins on the SK directly.
--   RETIRE_MODE  told the MERGE which retirement mechanism to use. It never
--                needed telling: the mechanism is decided by the TARGET row's
--                current expiry, which the MERGE reads as T.ROW_EXP_DTE.
--
-- DEL_IND already exists on the real stage, so it is not an ALTER either, and
-- the MERGE no longer depends on it. That leaves ACTION_FLAG as the only
-- genuinely load-bearing control column, and RULE_NO as POC-only debug.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE STG_Z2_BROKER_PARTY_DIM (
    -- ---- drives the MERGE -------------------------------------------------
    BROKER_PARTY_DIM_SK     NUMBER(38,0),  -- target SK on 'U'/'D' — a NEW SK on 'I'. IS the merge key
    ACTION_FLAG             CHAR(1),       -- 'U' expire in place | 'D' retire | 'I' insert

    -- ---- already on the real stage — carried for lineage, not read ---------
    DEL_IND                 CHAR(1),       -- the MERGE derives IS_DEL from T.ROW_EXP_DTE instead

    -- ---- the row being written -------------------------------------------
    BROKER_ID               VARCHAR(20),
    ROW_EFF_DTE             DATE,
    ROW_EXP_DTE             DATE,
    BROKER_STATUS_CDE       VARCHAR(20),   -- DEBUG ONLY on 'D'/'U' rows — the MERGE never reads it there
    COMMISSION_TIER_CDE     VARCHAR(20),   -- DEBUG ONLY on 'D'/'U' rows
    ROW_HASH                VARCHAR(64),   -- DEBUG ONLY on 'D'/'U' rows
    UUID                    VARCHAR(64),
    RULE_NO                 NUMBER(2,0),   -- POC ONLY. Drop when folding into the real pipeline

    -- ---- audit ------------------------------------------------------------
    AUDIT_BATCH_ID          NUMBER(38,0),
    AUDIT_JOB_ID            NUMBER(38,0)
);

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


-- ===========================================================================
-- WHY THE 'D' BRANCH NEEDS NO RETIRE_MODE COLUMN
--
-- Both CASE expressions test T.ROW_EXP_DTE, the value the target row holds
-- BEFORE this statement. Every right-hand side in an UPDATE is evaluated
-- against the pre-update row, so the second assignment does not see the value
-- the first one would write. The two branches are therefore:
--
--   target sat at 9999-12-31  ->  DEAD RECORD.      IS_DEL untouched ('N'),
--                                 ROW_EXP_DTE pulled back to ROW_EFF_DTE
--   target sat at a real date ->  DELETE INDICATOR. IS_DEL = 'Y',
--                                 both dates left exactly as they are
--
-- Safe because stage 7 excludes dead records (row_eff_dte < row_exp_dte), so a
-- row already retired can never re-enter the diff, and nothing writes to the
-- target between Step 1 and Step 2 within a run.
--
-- Reading the mechanism from the target at apply time is also strictly more
-- robust than carrying it on the stage: a stage column is a snapshot taken in
-- Step 1, while T.ROW_EXP_DTE is the value actually being overwritten.
-- ===========================================================================
