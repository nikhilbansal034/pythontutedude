/* ============================================================================
   W3 POC — multi-source SCD2 effective-date split
   ----------------------------------------------------------------------------
   Reproduces the Day 1 / Day 2 worked example end to end in Snowflake.

   Run top to bottom. Every numbered EVIDENCE block prints a result set —
   capture each one. Nothing here depends on anything outside this script.

   Scenario
     SRC_TABLE_1   SCD2 source, keeps history          (Zone1 Table 1)
     SRC_TABLE_2   SCD2 source, keeps history          (Zone1 Table 2)
     TGT_TABLE     SCD2 target                         (Zone2 target)
     STG_TABLE     stage, one row per required action  ('I' insert / 'D' soft-delete)

   Keys under test
     K1  the main scenario — Table 1 never changes, yet its target rows get rewritten
     K2  a Day 2 change in a column that never reaches the target — must produce NOTHING
     K3  never touched after Day 1 — must not be re-read or re-written
============================================================================ */

USE DATABASE LM_POC_DB;
USE SCHEMA POC_SCHEMA;


/* ============================================================================
   PART 0 — objects
============================================================================ */

CREATE OR REPLACE TABLE SRC_TABLE_1 (
    BUSINESS_KEY    VARCHAR(50),
    TBL1_VALUE      VARCHAR(50),        -- reaches the target
    TBL1_OTHER_COL  VARCHAR(50),        -- does NOT reach the target
    ROW_EFF_DTE     DATE,
    ROW_EXP_DTE     DATE,
    AUDIT_UPD_TS    TIMESTAMP_NTZ
);

CREATE OR REPLACE TABLE SRC_TABLE_2 (
    BUSINESS_KEY    VARCHAR(50),
    TBL2_VALUE      VARCHAR(50),        -- reaches the target
    TBL2_OTHER_COL  VARCHAR(50),        -- does NOT reach the target
    ROW_EFF_DTE     DATE,
    ROW_EXP_DTE     DATE,
    AUDIT_UPD_TS    TIMESTAMP_NTZ
);

CREATE OR REPLACE TABLE TGT_TABLE (
    TGT_SK          NUMBER(38,0),
    BUSINESS_KEY    VARCHAR(50),
    ROW_EFF_DTE     DATE,
    ROW_EXP_DTE     DATE,
    TBL1_VALUE      VARCHAR(50),
    TBL2_VALUE      VARCHAR(50),
    IS_DEL          CHAR(1),
    ROW_HASH        VARCHAR(64),
    AUDIT_INS_TS    TIMESTAMP_NTZ,
    AUDIT_UPD_TS    TIMESTAMP_NTZ
);

CREATE OR REPLACE TABLE STG_TABLE (
    ACTION_FLAG     CHAR(1),            -- 'I' = insert, 'D' = soft-delete
    TGT_SK          NUMBER(38,0),       -- set on 'D' rows only
    BUSINESS_KEY    VARCHAR(50),
    ROW_EFF_DTE     DATE,
    ROW_EXP_DTE     DATE,
    TBL1_VALUE      VARCHAR(50),
    TBL2_VALUE      VARCHAR(50),
    ROW_HASH        VARCHAR(64)
);

CREATE OR REPLACE SEQUENCE SEQ_TGT_SK START = 1 INCREMENT = 1;

CREATE OR REPLACE TABLE ETL_CTL (
    CTL_ID          NUMBER(38,0),
    LAST_RUN_TS     TIMESTAMP_NTZ
);

INSERT INTO ETL_CTL (CTL_ID, LAST_RUN_TS)
VALUES (1, '1900-01-01 00:00:00'::TIMESTAMP_NTZ);


/* ----------------------------------------------------------------------------
   STEP 1 logic, as one statement.

   This view is the SQL that would sit in the IDMC Source transformation's
   SQL override. It reads both sources and the target, and returns exactly the
   rows the stage table needs.
---------------------------------------------------------------------------- */

CREATE OR REPLACE VIEW V_STEP1_DIFF AS
WITH ctl AS (
    SELECT LAST_RUN_TS FROM ETL_CTL WHERE CTL_ID = 1
),

/* [1] which business keys changed in either source since the last run */
impacted_keys AS (
    SELECT DISTINCT s.BUSINESS_KEY
    FROM SRC_TABLE_1 s, ctl c
    WHERE s.AUDIT_UPD_TS > c.LAST_RUN_TS
    UNION
    SELECT DISTINCT s.BUSINESS_KEY
    FROM SRC_TABLE_2 s, ctl c
    WHERE s.AUDIT_UPD_TS > c.LAST_RUN_TS
),

/* [2] full history of those keys from BOTH sources — not only the delta rows */
src1_full AS (
    SELECT s.*
    FROM SRC_TABLE_1 s
    JOIN impacted_keys k ON k.BUSINESS_KEY = s.BUSINESS_KEY
),
src2_full AS (
    SELECT s.*
    FROM SRC_TABLE_2 s
    JOIN impacted_keys k ON k.BUSINESS_KEY = s.BUSINESS_KEY
),

/* [3a] keep the latest row per (key, eff date) — guards multi-batch arrival */
src1_dedup AS (
    SELECT BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE
    FROM src1_full
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY BUSINESS_KEY, ROW_EFF_DTE
        ORDER BY AUDIT_UPD_TS DESC
    ) = 1
),
src2_dedup AS (
    SELECT BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL2_VALUE
    FROM src2_full
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY BUSINESS_KEY, ROW_EFF_DTE
        ORDER BY AUDIT_UPD_TS DESC
    ) = 1
),

/* [3b] mark where a new run of identical values starts.
        A new run starts on the first row, on a gap in cover, or on a value change.
        A gap must NOT be collapsed even when the value either side is the same. */
src1_flag AS (
    SELECT BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE,
           CASE
               WHEN LAG(ROW_EXP_DTE) OVER (PARTITION BY BUSINESS_KEY ORDER BY ROW_EFF_DTE) IS NULL THEN 1
               WHEN LAG(ROW_EXP_DTE) OVER (PARTITION BY BUSINESS_KEY ORDER BY ROW_EFF_DTE) <> ROW_EFF_DTE THEN 1
               WHEN LAG(TBL1_VALUE)  OVER (PARTITION BY BUSINESS_KEY ORDER BY ROW_EFF_DTE)
                    IS DISTINCT FROM TBL1_VALUE THEN 1
               ELSE 0
           END AS NEW_RUN
    FROM src1_dedup
),
src2_flag AS (
    SELECT BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL2_VALUE,
           CASE
               WHEN LAG(ROW_EXP_DTE) OVER (PARTITION BY BUSINESS_KEY ORDER BY ROW_EFF_DTE) IS NULL THEN 1
               WHEN LAG(ROW_EXP_DTE) OVER (PARTITION BY BUSINESS_KEY ORDER BY ROW_EFF_DTE) <> ROW_EFF_DTE THEN 1
               WHEN LAG(TBL2_VALUE)  OVER (PARTITION BY BUSINESS_KEY ORDER BY ROW_EFF_DTE)
                    IS DISTINCT FROM TBL2_VALUE THEN 1
               ELSE 0
           END AS NEW_RUN
    FROM src2_dedup
),
src1_grp AS (
    SELECT BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE,
           SUM(NEW_RUN) OVER (
               PARTITION BY BUSINESS_KEY ORDER BY ROW_EFF_DTE
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
           ) AS GRP
    FROM src1_flag
),
src2_grp AS (
    SELECT BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL2_VALUE,
           SUM(NEW_RUN) OVER (
               PARTITION BY BUSINESS_KEY ORDER BY ROW_EFF_DTE
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
           ) AS GRP
    FROM src2_flag
),

/* [3c] collapse each run into one version */
src1_clean AS (
    SELECT BUSINESS_KEY, TBL1_VALUE,
           MIN(ROW_EFF_DTE) AS ROW_EFF_DTE,
           MAX(ROW_EXP_DTE) AS ROW_EXP_DTE
    FROM src1_grp
    GROUP BY BUSINESS_KEY, TBL1_VALUE, GRP
),
src2_clean AS (
    SELECT BUSINESS_KEY, TBL2_VALUE,
           MIN(ROW_EFF_DTE) AS ROW_EFF_DTE,
           MAX(ROW_EXP_DTE) AS ROW_EXP_DTE
    FROM src2_grp
    GROUP BY BUSINESS_KEY, TBL2_VALUE, GRP
),

/* [4] every boundary date either source mentions — eff dates AND exp dates.
       Exp dates matter: without them a gap in one source would be filled
       with the value from before the gap. UNION de-duplicates. */
boundaries AS (
    SELECT BUSINESS_KEY, ROW_EFF_DTE AS BOUNDARY_DTE FROM src1_clean
    UNION
    SELECT BUSINESS_KEY, ROW_EXP_DTE                 FROM src1_clean
    UNION
    SELECT BUSINESS_KEY, ROW_EFF_DTE                 FROM src2_clean
    UNION
    SELECT BUSINESS_KEY, ROW_EXP_DTE                 FROM src2_clean
),

/* [5] turn the boundaries into intervals; the last boundary closes the final
       interval and is not an interval of its own */
intervals AS (
    SELECT BUSINESS_KEY,
           BOUNDARY_DTE AS ROW_EFF_DTE,
           LEAD(BOUNDARY_DTE) OVER (PARTITION BY BUSINESS_KEY ORDER BY BOUNDARY_DTE) AS ROW_EXP_DTE
    FROM boundaries
),
intervals_valid AS (
    SELECT * FROM intervals WHERE ROW_EXP_DTE IS NOT NULL
),

/* [6] fill each interval. Because the interval edges come from the boundary
       set, each interval falls entirely inside at most ONE version per source,
       so each join matches 0 or 1 rows and nothing fans out. */
new_timeline AS (
    SELECT i.BUSINESS_KEY,
           i.ROW_EFF_DTE,
           i.ROW_EXP_DTE,
           s1.TBL1_VALUE,
           s2.TBL2_VALUE,
           SHA2(COALESCE(s1.TBL1_VALUE, '<NULL>') || '||' ||
                COALESCE(s2.TBL2_VALUE, '<NULL>'), 256) AS ROW_HASH
    FROM intervals_valid i
    LEFT JOIN src1_clean s1
           ON s1.BUSINESS_KEY = i.BUSINESS_KEY
          AND s1.ROW_EFF_DTE <= i.ROW_EFF_DTE
          AND s1.ROW_EXP_DTE >  i.ROW_EFF_DTE
    LEFT JOIN src2_clean s2
           ON s2.BUSINESS_KEY = i.BUSINESS_KEY
          AND s2.ROW_EFF_DTE <= i.ROW_EFF_DTE
          AND s2.ROW_EXP_DTE >  i.ROW_EFF_DTE
),

/* [7] what the target holds right now for those keys */
cur_tgt AS (
    SELECT t.TGT_SK, t.BUSINESS_KEY, t.ROW_EFF_DTE, t.ROW_EXP_DTE,
           t.TBL1_VALUE, t.TBL2_VALUE, t.ROW_HASH
    FROM TGT_TABLE t
    JOIN impacted_keys k ON k.BUSINESS_KEY = t.BUSINESS_KEY
    WHERE t.IS_DEL = 'N'
),

/* [8] diff. Compares dates AND values, so a value corrected without moving
       its dates still produces a D + I pair. */
to_insert AS (
    SELECT n.BUSINESS_KEY, n.ROW_EFF_DTE, n.ROW_EXP_DTE,
           n.TBL1_VALUE, n.TBL2_VALUE, n.ROW_HASH
    FROM new_timeline n
    LEFT JOIN cur_tgt c
           ON c.BUSINESS_KEY = n.BUSINESS_KEY
          AND c.ROW_EFF_DTE  = n.ROW_EFF_DTE
          AND c.ROW_EXP_DTE  = n.ROW_EXP_DTE
          AND c.ROW_HASH     = n.ROW_HASH
    WHERE c.BUSINESS_KEY IS NULL
),
to_delete AS (
    SELECT c.TGT_SK, c.BUSINESS_KEY, c.ROW_EFF_DTE, c.ROW_EXP_DTE,
           c.TBL1_VALUE, c.TBL2_VALUE, c.ROW_HASH
    FROM cur_tgt c
    LEFT JOIN new_timeline n
           ON n.BUSINESS_KEY = c.BUSINESS_KEY
          AND n.ROW_EFF_DTE  = c.ROW_EFF_DTE
          AND n.ROW_EXP_DTE  = c.ROW_EXP_DTE
          AND n.ROW_HASH     = c.ROW_HASH
    WHERE n.BUSINESS_KEY IS NULL
)

SELECT 'I' AS ACTION_FLAG, CAST(NULL AS NUMBER(38,0)) AS TGT_SK,
       BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE, ROW_HASH
FROM to_insert
UNION ALL
SELECT 'D' AS ACTION_FLAG, TGT_SK,
       BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE, ROW_HASH
FROM to_delete;


/* ============================================================================
   PART 1 — DAY 1 : source data arrives
============================================================================ */

INSERT INTO SRC_TABLE_1
    (BUSINESS_KEY, TBL1_VALUE, TBL1_OTHER_COL, ROW_EFF_DTE, ROW_EXP_DTE, AUDIT_UPD_TS)
VALUES
    ('K1', 'a', 'x1', '2026-09-10'::DATE, '2026-09-21'::DATE, '2026-09-18 08:00:00'::TIMESTAMP_NTZ),
    ('K1', 'b', 'x1', '2026-09-21'::DATE, '9999-12-31'::DATE, '2026-09-18 08:00:00'::TIMESTAMP_NTZ),
    ('K2', 'm', 'x1', '2026-09-05'::DATE, '9999-12-31'::DATE, '2026-09-18 08:00:00'::TIMESTAMP_NTZ),
    ('K3', 'g', 'x1', '2026-09-01'::DATE, '9999-12-31'::DATE, '2026-09-18 08:00:00'::TIMESTAMP_NTZ);

INSERT INTO SRC_TABLE_2
    (BUSINESS_KEY, TBL2_VALUE, TBL2_OTHER_COL, ROW_EFF_DTE, ROW_EXP_DTE, AUDIT_UPD_TS)
VALUES
    ('K1', 'p', 'y1', '2026-09-09'::DATE, '9999-12-31'::DATE, '2026-09-18 08:00:00'::TIMESTAMP_NTZ),
    ('K2', 'n', 'z1', '2026-09-05'::DATE, '9999-12-31'::DATE, '2026-09-18 08:00:00'::TIMESTAMP_NTZ),
    ('K3', 'h', 'z1', '2026-09-01'::DATE, '9999-12-31'::DATE, '2026-09-18 08:00:00'::TIMESTAMP_NTZ);

-- EVIDENCE 1 — Day 1 sources
SELECT 'EV1 SRC_TABLE_1 (Day 1)' AS EVIDENCE, BUSINESS_KEY, TBL1_VALUE, TBL1_OTHER_COL,
       ROW_EFF_DTE, ROW_EXP_DTE
FROM SRC_TABLE_1 ORDER BY BUSINESS_KEY, ROW_EFF_DTE;

SELECT 'EV1 SRC_TABLE_2 (Day 1)' AS EVIDENCE, BUSINESS_KEY, TBL2_VALUE, TBL2_OTHER_COL,
       ROW_EFF_DTE, ROW_EXP_DTE
FROM SRC_TABLE_2 ORDER BY BUSINESS_KEY, ROW_EFF_DTE;


/* ============================================================================
   PART 2 — DAY 1 : STEP 1, build the stage
============================================================================ */

TRUNCATE TABLE STG_TABLE;

INSERT INTO STG_TABLE
    (ACTION_FLAG, TGT_SK, BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE, ROW_HASH)
SELECT ACTION_FLAG, TGT_SK, BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE, ROW_HASH
FROM V_STEP1_DIFF;

-- EVIDENCE 2 — the stage after Day 1. Expect 5 rows, all 'I', no 'D'.
SELECT 'EV2 STG_TABLE (Day 1)' AS EVIDENCE, ACTION_FLAG, TGT_SK, BUSINESS_KEY,
       ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE
FROM STG_TABLE ORDER BY BUSINESS_KEY, ACTION_FLAG, ROW_EFF_DTE;

SELECT 'EV2 counts (Day 1)' AS EVIDENCE, ACTION_FLAG, COUNT(*) AS ROW_COUNT
FROM STG_TABLE GROUP BY ACTION_FLAG ORDER BY ACTION_FLAG;


/* ============================================================================
   PART 3 — DAY 1 : STEP 2 soft-delete, then STEP 3 insert
============================================================================ */

-- STEP 2 — nothing to soft-delete on the first load, runs anyway
UPDATE TGT_TABLE
SET IS_DEL = 'Y',
    AUDIT_UPD_TS = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM STG_TABLE S
WHERE S.ACTION_FLAG = 'D'
  AND TGT_TABLE.TGT_SK = S.TGT_SK;

-- STEP 3
INSERT INTO TGT_TABLE
    (TGT_SK, BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE,
     IS_DEL, ROW_HASH, AUDIT_INS_TS, AUDIT_UPD_TS)
SELECT SEQ_TGT_SK.NEXTVAL, BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE,
       'N', ROW_HASH, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM STG_TABLE
WHERE ACTION_FLAG = 'I';

-- close the run
UPDATE ETL_CTL SET LAST_RUN_TS = '2026-09-18 23:59:59'::TIMESTAMP_NTZ WHERE CTL_ID = 1;

-- EVIDENCE 3 — the Day 1 target
SELECT 'EV3 TGT_TABLE (after Day 1)' AS EVIDENCE, TGT_SK, BUSINESS_KEY,
       ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE, IS_DEL
FROM TGT_TABLE ORDER BY BUSINESS_KEY, ROW_EFF_DTE, TGT_SK;


/* ============================================================================
   PART 4 — DAY 2 : source changes arrive

   SRC_TABLE_1 : nothing at all.
   SRC_TABLE_2 : K1 splits into three versions.
                 K2 splits too, but only TBL2_OTHER_COL differs — the target
                 must not change for K2.
============================================================================ */

-- K1 : the open version is closed at 15-Sep
UPDATE SRC_TABLE_2
SET ROW_EXP_DTE  = '2026-09-15'::DATE,
    AUDIT_UPD_TS = '2026-09-19 08:00:00'::TIMESTAMP_NTZ
WHERE BUSINESS_KEY = 'K1' AND ROW_EFF_DTE = '2026-09-09'::DATE;

-- K2 : the open version is closed at 12-Sep, TBL2_VALUE unchanged
UPDATE SRC_TABLE_2
SET ROW_EXP_DTE  = '2026-09-12'::DATE,
    AUDIT_UPD_TS = '2026-09-19 08:00:00'::TIMESTAMP_NTZ
WHERE BUSINESS_KEY = 'K2' AND ROW_EFF_DTE = '2026-09-05'::DATE;

INSERT INTO SRC_TABLE_2
    (BUSINESS_KEY, TBL2_VALUE, TBL2_OTHER_COL, ROW_EFF_DTE, ROW_EXP_DTE, AUDIT_UPD_TS)
VALUES
    ('K1', 'q', 'y1', '2026-09-15'::DATE, '2026-09-22'::DATE, '2026-09-19 08:00:00'::TIMESTAMP_NTZ),
    ('K1', 'r', 'y2', '2026-09-22'::DATE, '9999-12-31'::DATE, '2026-09-19 08:00:00'::TIMESTAMP_NTZ),
    ('K2', 'n', 'z2', '2026-09-12'::DATE, '9999-12-31'::DATE, '2026-09-19 08:00:00'::TIMESTAMP_NTZ);

-- EVIDENCE 4 — Day 2 sources
SELECT 'EV4 SRC_TABLE_1 (Day 2 - unchanged)' AS EVIDENCE, BUSINESS_KEY, TBL1_VALUE,
       ROW_EFF_DTE, ROW_EXP_DTE, AUDIT_UPD_TS
FROM SRC_TABLE_1 ORDER BY BUSINESS_KEY, ROW_EFF_DTE;

SELECT 'EV4 SRC_TABLE_2 (Day 2)' AS EVIDENCE, BUSINESS_KEY, TBL2_VALUE, TBL2_OTHER_COL,
       ROW_EFF_DTE, ROW_EXP_DTE, AUDIT_UPD_TS
FROM SRC_TABLE_2 ORDER BY BUSINESS_KEY, ROW_EFF_DTE;


/* ============================================================================
   PART 5 — DAY 2 : STEP 1
============================================================================ */

TRUNCATE TABLE STG_TABLE;

INSERT INTO STG_TABLE
    (ACTION_FLAG, TGT_SK, BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE, ROW_HASH)
SELECT ACTION_FLAG, TGT_SK, BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE, ROW_HASH
FROM V_STEP1_DIFF;

-- EVIDENCE 5 — the stage after Day 2.
-- Expect exactly 4 'I' and 2 'D', all for K1. Nothing for K2. Nothing for K3.
SELECT 'EV5 STG_TABLE (Day 2)' AS EVIDENCE, ACTION_FLAG, TGT_SK, BUSINESS_KEY,
       ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE
FROM STG_TABLE ORDER BY BUSINESS_KEY, ACTION_FLAG, ROW_EFF_DTE;

SELECT 'EV5 counts (Day 2)' AS EVIDENCE, BUSINESS_KEY, ACTION_FLAG, COUNT(*) AS ROW_COUNT
FROM STG_TABLE GROUP BY BUSINESS_KEY, ACTION_FLAG ORDER BY BUSINESS_KEY, ACTION_FLAG;


/* ============================================================================
   PART 6 — DAY 2 : STEP 2 then STEP 3
============================================================================ */

UPDATE TGT_TABLE
SET IS_DEL = 'Y',
    AUDIT_UPD_TS = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM STG_TABLE S
WHERE S.ACTION_FLAG = 'D'
  AND TGT_TABLE.TGT_SK = S.TGT_SK;

INSERT INTO TGT_TABLE
    (TGT_SK, BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE,
     IS_DEL, ROW_HASH, AUDIT_INS_TS, AUDIT_UPD_TS)
SELECT SEQ_TGT_SK.NEXTVAL, BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE,
       'N', ROW_HASH, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM STG_TABLE
WHERE ACTION_FLAG = 'I';

UPDATE ETL_CTL SET LAST_RUN_TS = '2026-09-19 23:59:59'::TIMESTAMP_NTZ WHERE CTL_ID = 1;

-- EVIDENCE 6 — the full target, both live and superseded rows
SELECT 'EV6 TGT_TABLE (after Day 2 - all rows)' AS EVIDENCE, TGT_SK, BUSINESS_KEY,
       ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE, IS_DEL
FROM TGT_TABLE ORDER BY BUSINESS_KEY, ROW_EFF_DTE, TGT_SK;

-- EVIDENCE 7 — the live timeline only; this is what consumers see
SELECT 'EV7 TGT_TABLE (live rows only)' AS EVIDENCE, BUSINESS_KEY,
       ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE
FROM TGT_TABLE WHERE IS_DEL = 'N'
ORDER BY BUSINESS_KEY, ROW_EFF_DTE;


/* ============================================================================
   PART 7 — validation

   Every row must read PASS.
============================================================================ */

SELECT 'T1 K1 has 5 live versions after Day 2' AS TEST_NAME,
       COUNT(*) AS ACTUAL, 5 AS EXPECTED,
       CASE WHEN COUNT(*) = 5 THEN 'PASS' ELSE 'FAIL' END AS RESULT
FROM TGT_TABLE WHERE BUSINESS_KEY = 'K1' AND IS_DEL = 'N'

UNION ALL
SELECT 'T2 K1 has 2 superseded rows',
       COUNT(*), 2,
       CASE WHEN COUNT(*) = 2 THEN 'PASS' ELSE 'FAIL' END
FROM TGT_TABLE WHERE BUSINESS_KEY = 'K1' AND IS_DEL = 'Y'

UNION ALL
SELECT 'T3 K2 unchanged - still exactly 1 live row',
       COUNT(*), 1,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM TGT_TABLE WHERE BUSINESS_KEY = 'K2' AND IS_DEL = 'N'

UNION ALL
SELECT 'T4 K2 never soft-deleted - the collapse worked',
       COUNT(*), 0,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM TGT_TABLE WHERE BUSINESS_KEY = 'K2' AND IS_DEL = 'Y'

UNION ALL
SELECT 'T5 K3 untouched - exactly 1 live row',
       COUNT(*), 1,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM TGT_TABLE WHERE BUSINESS_KEY = 'K3' AND IS_DEL = 'N'

UNION ALL
SELECT 'T6 K1 live timeline has no gaps or overlaps',
       COUNT(*), 0,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (
    SELECT ROW_EXP_DTE,
           LEAD(ROW_EFF_DTE) OVER (ORDER BY ROW_EFF_DTE) AS NEXT_EFF
    FROM TGT_TABLE WHERE BUSINESS_KEY = 'K1' AND IS_DEL = 'N'
) q
WHERE NEXT_EFF IS NOT NULL AND NEXT_EFF <> ROW_EXP_DTE

UNION ALL
SELECT 'T7 business_key + row_eff_dte unique among live rows',
       COUNT(*), 0,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (
    SELECT BUSINESS_KEY, ROW_EFF_DTE
    FROM TGT_TABLE WHERE IS_DEL = 'N'
    GROUP BY BUSINESS_KEY, ROW_EFF_DTE
    HAVING COUNT(*) > 1
) d

UNION ALL
SELECT 'T8 that same pair is NOT unique across all rows',
       COUNT(*), 2,
       CASE WHEN COUNT(*) = 2 THEN 'PASS' ELSE 'FAIL' END
FROM (
    SELECT BUSINESS_KEY, ROW_EFF_DTE
    FROM TGT_TABLE
    GROUP BY BUSINESS_KEY, ROW_EFF_DTE
    HAVING COUNT(*) > 1
) d2

UNION ALL
SELECT 'T9 K1 covers 9-Sep to high end date continuously',
       COUNT(*), 1,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM TGT_TABLE
WHERE BUSINESS_KEY = 'K1' AND IS_DEL = 'N'
  AND ROW_EFF_DTE = '2026-09-09'::DATE AND ROW_EXP_DTE = '2026-09-10'::DATE

UNION ALL
SELECT 'T10 the 9-Sep row has no Table 1 value',
       COUNT(*), 1,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM TGT_TABLE
WHERE BUSINESS_KEY = 'K1' AND IS_DEL = 'N'
  AND ROW_EFF_DTE = '2026-09-09'::DATE AND TBL1_VALUE IS NULL

ORDER BY 1;


/* ============================================================================
   PART 8 — idempotence

   Re-running Step 1 with no new source data must produce an empty stage.
   If this returns anything, the diff is unstable and the design is wrong.
============================================================================ */

TRUNCATE TABLE STG_TABLE;

INSERT INTO STG_TABLE
    (ACTION_FLAG, TGT_SK, BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE, ROW_HASH)
SELECT ACTION_FLAG, TGT_SK, BUSINESS_KEY, ROW_EFF_DTE, ROW_EXP_DTE, TBL1_VALUE, TBL2_VALUE, ROW_HASH
FROM V_STEP1_DIFF;

SELECT 'T11 re-run with no new data produces an empty stage' AS TEST_NAME,
       COUNT(*) AS ACTUAL, 0 AS EXPECTED,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS RESULT
FROM STG_TABLE;
