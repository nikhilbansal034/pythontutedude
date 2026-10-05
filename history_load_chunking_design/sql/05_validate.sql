-- =====================================================================================
-- 05_validate.sql — check the planner's output
-- =====================================================================================
-- Part A: plain queries (run one at a time and screenshot each result).
-- Part B: an anonymous block that proves, against the source data itself, that every row
--         falls in exactly one chunk.
-- A1/A2 compare against the expected results for the synthetic schema (TEST_PLAN.md,
-- max_chunk_rows = 1000). A3, A4 and Part B are generic: they work on any planned schema.
--
-- These queries build chunk predicates ONLY to test the plan. The planner itself never
-- stores or generates load SQL.
-- =====================================================================================

-- ===== LOCATIONS: same values as in 04 =====
SET meta_location = 'test_db.test_schema';   -- where the plan tables live (01)
SET src_database  = 'TEST_DB';               -- the schema that was planned (02 / 04 p_database, p_schema)
SET src_schema    = 'CHUNK_TEST_SRC';

USE SCHEMA IDENTIFIER($meta_location);
ALTER SESSION SET TIMEZONE = 'UTC';

-- -------------------------------------------------------------------------------------
-- A1 (evidence E08) — table-level outcome vs expected, active rows only
-- -------------------------------------------------------------------------------------
WITH expected (TABLE_NAME, EXP_STATUS, EXP_AXIS, EXP_METHOD, EXP_CHUNKS, EXP_ROWS) AS (
    SELECT * FROM VALUES
        ('T01_CUR_SPREAD',            'PLANNED', 'PARTITION_DAY',  'DAY_RANGES',             10, 9000),
        ('T02_HIST_BACKFILL_SPREAD',  'PLANNED', 'PARTITION_YMD',  'DAY_RANGES_WITH_SPLITS',  7, 5800),
        ('T03_HIST_BACKFILL_SAME_TS', 'PLANNED', 'PARTITION_YMD',  'DAY_RANGES_WITH_SPLITS',  4, 2900),
        ('T04_SMALL',                 'PLANNED', 'PARTITION_DAY',  'SINGLE',                  1,  500),
        ('T05_NULL_PARTITION',        'PLANNED', 'PARTITION_DAY',  'DAY_RANGES',              3, 1750),
        ('T06_UNPARTITIONED_TS',      'PLANNED', 'REFINED_TS_DAY', 'DAY_RANGES',              3, 2700),
        ('T07_NO_USABLE_COLUMN',      'FAILED',  'NONE',           NULL,                   NULL, 2000),
        ('T08_UNIQUE_ID_ONLY',        'PLANNED', 'UNIQUE_ID_HASH', 'HASH_BUCKETS',            3, 2500),
        ('T09_STANDARD_TABLE',        'SKIPPED', NULL,             NULL,                   NULL, NULL),
        ('T10_VIEW',                  'SKIPPED', NULL,             NULL,                   NULL, NULL),
        ('T11_EMPTY',                 'PLANNED', 'PARTITION_DAY',  'SINGLE',                  1,    0)
),
actual AS (
    SELECT TABLE_NAME, PLAN_STATUS, CHUNK_AXIS, CHUNK_METHOD, CHUNK_COUNT, TOTAL_ROWS,
           LAYER, PARTITION_VERIFIED, STATUS_REASON
      FROM HIST_PLAN_TABLE
     WHERE UPPER(DATABASE_NAME) = UPPER($src_database) AND UPPER(SCHEMA_NAME) = UPPER($src_schema) AND IS_ACTIVE
)
SELECT e.TABLE_NAME,
       e.EXP_STATUS, a.PLAN_STATUS,
       e.EXP_AXIS,   a.CHUNK_AXIS,
       e.EXP_METHOD, a.CHUNK_METHOD,
       e.EXP_CHUNKS, a.CHUNK_COUNT,
       e.EXP_ROWS,   a.TOTAL_ROWS,
       a.LAYER, a.PARTITION_VERIFIED, a.STATUS_REASON,
       IFF(EQUAL_NULL(e.EXP_STATUS, a.PLAN_STATUS) AND EQUAL_NULL(e.EXP_AXIS, a.CHUNK_AXIS)
           AND EQUAL_NULL(e.EXP_METHOD, a.CHUNK_METHOD) AND EQUAL_NULL(e.EXP_CHUNKS, a.CHUNK_COUNT)
           AND EQUAL_NULL(e.EXP_ROWS, a.TOTAL_ROWS), 'PASS', 'FAIL') AS RESULT
  FROM expected e
  LEFT JOIN actual a ON a.TABLE_NAME = e.TABLE_NAME
 ORDER BY e.TABLE_NAME;

-- -------------------------------------------------------------------------------------
-- A2 (evidence E09) — every chunk vs expected: type, day range, sub-range, hash bucket, rows
-- 32 expected chunk rows. Hash chunks expect the even split (833/833/834).
-- -------------------------------------------------------------------------------------
WITH expected (TABLE_NAME, CHUNK_SEQ, CHUNK_TYPE, DAY_START, DAY_END, SUB_START, SUB_END, HASH_BUCKET, HASH_MODULUS, EST_ROWS) AS (
    SELECT * FROM VALUES
        ('T01_CUR_SPREAD',  1, 'DAY_RANGE', NULL,         '2026-01-07', NULL, NULL, NULL, NULL, 900),
        ('T01_CUR_SPREAD',  2, 'DAY_RANGE', '2026-01-07', '2026-01-13', NULL, NULL, NULL, NULL, 900),
        ('T01_CUR_SPREAD',  3, 'DAY_RANGE', '2026-01-13', '2026-01-19', NULL, NULL, NULL, NULL, 900),
        ('T01_CUR_SPREAD',  4, 'DAY_RANGE', '2026-01-19', '2026-01-25', NULL, NULL, NULL, NULL, 900),
        ('T01_CUR_SPREAD',  5, 'DAY_RANGE', '2026-01-25', '2026-01-31', NULL, NULL, NULL, NULL, 900),
        ('T01_CUR_SPREAD',  6, 'DAY_RANGE', '2026-01-31', '2026-02-06', NULL, NULL, NULL, NULL, 900),
        ('T01_CUR_SPREAD',  7, 'DAY_RANGE', '2026-02-06', '2026-02-12', NULL, NULL, NULL, NULL, 900),
        ('T01_CUR_SPREAD',  8, 'DAY_RANGE', '2026-02-12', '2026-02-18', NULL, NULL, NULL, NULL, 900),
        ('T01_CUR_SPREAD',  9, 'DAY_RANGE', '2026-02-18', '2026-02-24', NULL, NULL, NULL, NULL, 900),
        ('T01_CUR_SPREAD', 10, 'DAY_RANGE', '2026-02-24', NULL,         NULL, NULL, NULL, NULL, 900),
        ('T02_HIST_BACKFILL_SPREAD', 1, 'DAY_RANGE',    NULL,         '2026-03-10', NULL, NULL, NULL, NULL, 300),
        ('T02_HIST_BACKFILL_SPREAD', 2, 'DAY_SUBRANGE', '2026-03-10', '2026-03-11', NULL,                         '2026-03-10 00:20:00 +00:00', NULL, NULL, 1000),
        ('T02_HIST_BACKFILL_SPREAD', 3, 'DAY_SUBRANGE', '2026-03-10', '2026-03-11', '2026-03-10 00:20:00 +00:00', '2026-03-10 00:40:00 +00:00', NULL, NULL, 1000),
        ('T02_HIST_BACKFILL_SPREAD', 4, 'DAY_SUBRANGE', '2026-03-10', '2026-03-11', '2026-03-10 00:40:00 +00:00', '2026-03-10 01:00:00 +00:00', NULL, NULL, 1000),
        ('T02_HIST_BACKFILL_SPREAD', 5, 'DAY_SUBRANGE', '2026-03-10', '2026-03-11', '2026-03-10 01:00:00 +00:00', NULL,                         NULL, NULL, 500),
        ('T02_HIST_BACKFILL_SPREAD', 6, 'DAY_RANGE',    '2026-03-11', '2026-03-16', NULL, NULL, NULL, NULL, 1000),
        ('T02_HIST_BACKFILL_SPREAD', 7, 'DAY_RANGE',    '2026-03-16', NULL,         NULL, NULL, NULL, NULL, 1000),
        ('T03_HIST_BACKFILL_SAME_TS', 1, 'DAY_HASH',  '2026-04-05', '2026-04-06', NULL, NULL, 0, 3, 833),
        ('T03_HIST_BACKFILL_SAME_TS', 2, 'DAY_HASH',  '2026-04-05', '2026-04-06', NULL, NULL, 1, 3, 833),
        ('T03_HIST_BACKFILL_SAME_TS', 3, 'DAY_HASH',  '2026-04-05', '2026-04-06', NULL, NULL, 2, 3, 834),
        ('T03_HIST_BACKFILL_SAME_TS', 4, 'DAY_RANGE', '2026-04-06', NULL,         NULL, NULL, NULL, NULL, 400),
        ('T04_SMALL', 1, 'ALL', NULL, NULL, NULL, NULL, NULL, NULL, 500),
        ('T05_NULL_PARTITION', 1, 'DAY_RANGE',   NULL,         '2026-06-03', NULL, NULL, NULL, NULL, 800),
        ('T05_NULL_PARTITION', 2, 'DAY_RANGE',   '2026-06-03', NULL,         NULL, NULL, NULL, NULL, 800),
        ('T05_NULL_PARTITION', 3, 'NULL_VALUES', NULL,         NULL,         NULL, NULL, NULL, NULL, 150),
        ('T06_UNPARTITIONED_TS', 1, 'DAY_RANGE', NULL,         '2026-05-03', NULL, NULL, NULL, NULL, 900),
        ('T06_UNPARTITIONED_TS', 2, 'DAY_RANGE', '2026-05-03', '2026-05-05', NULL, NULL, NULL, NULL, 900),
        ('T06_UNPARTITIONED_TS', 3, 'DAY_RANGE', '2026-05-05', NULL,         NULL, NULL, NULL, NULL, 900),
        ('T08_UNIQUE_ID_ONLY', 1, 'HASH', NULL, NULL, NULL, NULL, 0, 3, 833),
        ('T08_UNIQUE_ID_ONLY', 2, 'HASH', NULL, NULL, NULL, NULL, 1, 3, 833),
        ('T08_UNIQUE_ID_ONLY', 3, 'HASH', NULL, NULL, NULL, NULL, 2, 3, 834),
        ('T11_EMPTY', 1, 'ALL', NULL, NULL, NULL, NULL, NULL, NULL, 0)
),
actual AS (
    SELECT c.*
      FROM HIST_PLAN_CHUNK c
      JOIN HIST_PLAN_TABLE t ON t.PLAN_ID = c.PLAN_ID AND t.IS_ACTIVE AND t.PLAN_STATUS = 'PLANNED'
     WHERE UPPER(c.DATABASE_NAME) = UPPER($src_database) AND UPPER(c.SCHEMA_NAME) = UPPER($src_schema)
)
SELECT COALESCE(e.TABLE_NAME, a.TABLE_NAME) AS TABLE_NAME,
       COALESCE(e.CHUNK_SEQ, a.CHUNK_SEQ)   AS CHUNK_SEQ,
       e.CHUNK_TYPE AS EXP_TYPE, a.CHUNK_TYPE,
       e.DAY_START  AS EXP_DAY_START, a.DAY_START,
       e.DAY_END    AS EXP_DAY_END,   a.DAY_END,
       e.SUB_START  AS EXP_SUB_START, a.SUB_START_TS,
       e.SUB_END    AS EXP_SUB_END,   a.SUB_END_TS,
       e.HASH_BUCKET AS EXP_BUCKET, a.HASH_BUCKET, e.HASH_MODULUS AS EXP_MOD, a.HASH_MODULUS,
       e.EST_ROWS   AS EXP_ROWS,  a.ESTIMATED_ROWS,
       IFF(    EQUAL_NULL(e.CHUNK_TYPE, a.CHUNK_TYPE)
           AND EQUAL_NULL(TO_DATE(e.DAY_START), a.DAY_START)
           AND EQUAL_NULL(TO_DATE(e.DAY_END),   a.DAY_END)
           AND EQUAL_NULL(TO_TIMESTAMP_TZ(e.SUB_START, 'YYYY-MM-DD HH24:MI:SS TZH:TZM'), a.SUB_START_TS)
           AND EQUAL_NULL(TO_TIMESTAMP_TZ(e.SUB_END,   'YYYY-MM-DD HH24:MI:SS TZH:TZM'), a.SUB_END_TS)
           AND EQUAL_NULL(e.HASH_BUCKET, a.HASH_BUCKET)
           AND EQUAL_NULL(e.HASH_MODULUS, a.HASH_MODULUS)
           AND EQUAL_NULL(e.EST_ROWS, a.ESTIMATED_ROWS), 'PASS', 'FAIL') AS RESULT
  FROM expected e
  FULL OUTER JOIN actual a ON a.TABLE_NAME = e.TABLE_NAME AND a.CHUNK_SEQ = e.CHUNK_SEQ
 ORDER BY 1, 2;

-- -------------------------------------------------------------------------------------
-- A3 (evidence E10) — generic: chunk rows add up to the table, for every active plan
-- -------------------------------------------------------------------------------------
SELECT t.DATABASE_NAME, t.SCHEMA_NAME, t.TABLE_NAME, t.CHUNK_METHOD, t.CHUNK_COUNT,
       COUNT(c.CHUNK_SEQ)     AS CHUNK_ROWS_FOUND,
       t.TOTAL_ROWS,
       SUM(c.ESTIMATED_ROWS)  AS SUM_OF_CHUNK_ROWS,
       IFF(COUNT(c.CHUNK_SEQ) = t.CHUNK_COUNT AND COALESCE(SUM(c.ESTIMATED_ROWS), 0) = t.TOTAL_ROWS, 'PASS', 'FAIL') AS RESULT
  FROM HIST_PLAN_TABLE t
  LEFT JOIN HIST_PLAN_CHUNK c ON c.PLAN_ID = t.PLAN_ID
 WHERE t.IS_ACTIVE AND t.PLAN_STATUS = 'PLANNED'
 GROUP BY t.DATABASE_NAME, t.SCHEMA_NAME, t.TABLE_NAME, t.CHUNK_METHOD, t.CHUNK_COUNT, t.TOTAL_ROWS
 ORDER BY 1, 2, 3;

-- -------------------------------------------------------------------------------------
-- A4 (evidence E11) — generic: the day chunks tile with no gaps and no overlaps
--   * the first day chunk of a table starts open (NULL) unless it is a split day
--   * every other chunk starts where the previous one ended
--   * pieces of one split day share the day; sub-ranges continue end-to-start
-- -------------------------------------------------------------------------------------
WITH c AS (
    SELECT k.TABLE_NAME, k.CHUNK_SEQ, k.CHUNK_TYPE, k.DAY_START, k.DAY_END, k.SUB_START_TS, k.SUB_END_TS,
           LAG(k.CHUNK_TYPE)   OVER (PARTITION BY k.PLAN_ID ORDER BY k.CHUNK_SEQ) AS PREV_TYPE,
           LAG(k.DAY_START)    OVER (PARTITION BY k.PLAN_ID ORDER BY k.CHUNK_SEQ) AS PREV_DAY_START,
           LAG(k.DAY_END)      OVER (PARTITION BY k.PLAN_ID ORDER BY k.CHUNK_SEQ) AS PREV_DAY_END,
           LAG(k.SUB_END_TS)   OVER (PARTITION BY k.PLAN_ID ORDER BY k.CHUNK_SEQ) AS PREV_SUB_END
      FROM HIST_PLAN_CHUNK k
      JOIN HIST_PLAN_TABLE t ON t.PLAN_ID = k.PLAN_ID AND t.IS_ACTIVE AND t.PLAN_STATUS = 'PLANNED'
     WHERE k.CHUNK_TYPE IN ('DAY_RANGE', 'DAY_SUBRANGE', 'DAY_HASH')
)
SELECT TABLE_NAME, CHUNK_SEQ, CHUNK_TYPE, DAY_START, DAY_END, SUB_START_TS, SUB_END_TS,
       PREV_TYPE, PREV_DAY_END,
       CASE
         WHEN PREV_TYPE IS NULL AND CHUNK_TYPE = 'DAY_RANGE'
              THEN IFF(DAY_START IS NULL, 'PASS', 'FAIL: first day range should start open (NULL)')
         WHEN PREV_TYPE IS NULL
              THEN IFF(CHUNK_TYPE = 'DAY_SUBRANGE' AND SUB_START_TS IS NOT NULL, 'FAIL: first piece of a split day should start open', 'PASS')
         WHEN CHUNK_TYPE IN ('DAY_SUBRANGE', 'DAY_HASH') AND PREV_TYPE = CHUNK_TYPE AND DAY_START = PREV_DAY_START
              THEN IFF(CHUNK_TYPE = 'DAY_SUBRANGE' AND NOT EQUAL_NULL(SUB_START_TS, PREV_SUB_END),
                       'FAIL: sub-range does not start where the previous piece ended', 'PASS')
         WHEN CHUNK_TYPE = 'DAY_SUBRANGE' AND SUB_START_TS IS NOT NULL
              THEN 'FAIL: first piece of a split day should start open'
         WHEN DAY_START = PREV_DAY_END THEN 'PASS'
         ELSE 'FAIL: does not start where the previous chunk ended'
       END AS TILING_CHECK
  FROM c
 ORDER BY TABLE_NAME, CHUNK_SEQ;

-- -------------------------------------------------------------------------------------
-- A5 (evidence E14 / E16) — plan history for one table (shows SUPERSEDED / FAILED rows)
-- -------------------------------------------------------------------------------------
SELECT TABLE_NAME, PLAN_ID, RUN_ID, PLAN_STATUS, IS_ACTIVE, CHUNK_COUNT, STATUS_REASON, PLANNED_AT
  FROM HIST_PLAN_TABLE
 WHERE UPPER(DATABASE_NAME) = UPPER($src_database) AND UPPER(SCHEMA_NAME) = UPPER($src_schema)
   AND TABLE_NAME IN ('T01_CUR_SPREAD', 'T07_NO_USABLE_COLUMN', 'T09_STANDARD_TABLE', 'T10_VIEW')
 ORDER BY TABLE_NAME, PLANNED_AT;


-- =====================================================================================
-- Part B (evidence E12 / E17) — coverage proof against the source data
-- For every active plan in the chosen schema: evaluates each chunk's range on every
-- source row and counts rows that fall in NO chunk and rows that fall in TWO OR MORE.
-- Both must be 0. Also compares each range chunk's actual row count with its estimate.
-- Reads the source tables once per chunk: fine for the test schema; on large production
-- tables run it on a few chosen tables only.
-- =====================================================================================
DECLARE
    -- ===== same values as the SET lines at the top of this file =====
    metadata_database VARCHAR DEFAULT 'test_db';
    metadata_schema   VARCHAR DEFAULT 'test_schema';
    p_database        VARCHAR DEFAULT 'TEST_DB';
    p_schema          VARCHAR DEFAULT 'CHUNK_TEST_SRC';

    v_sql       VARCHAR;
    v_pid       VARCHAR;
    v_db        VARCHAR;
    v_sch       VARCHAR;
    v_tbl       VARCHAR;
    v_axis      VARCHAR;
    v_cols      VARCHAR;
    v_plan_rows NUMBER;
    v_c1        VARCHAR;
    v_c2        VARCHAR;
    v_c3        VARCHAR;
    v_ax        VARCHAR;
    v_fq        VARCHAR;
    v_sum_expr  VARCHAR;
    v_union     VARCHAR;
    v_chunks    NUMBER;
    v_total     NUMBER;
    v_missed    NUMBER;
    v_multi     NUMBER;
    v_exact_n   NUMBER;
    v_exact_ok  NUMBER;
    v_exact_txt VARCHAR;
    v_result    VARCHAR;
    res         RESULTSET;
    c_plans CURSOR FOR SELECT PLAN_ID, DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, CHUNK_AXIS, AXIS_COLUMNS, TOTAL_ROWS
                         FROM HVAL_TMP_PLANS ORDER BY TABLE_NAME;
BEGIN
    ALTER SESSION SET TIMEZONE = 'UTC';
    v_sql := 'USE SCHEMA ' || metadata_database || '.' || metadata_schema;
    EXECUTE IMMEDIATE :v_sql;

    CREATE OR REPLACE TEMPORARY TABLE HVAL_TMP_PLANS (PLAN_ID VARCHAR, DATABASE_NAME VARCHAR, SCHEMA_NAME VARCHAR,
        TABLE_NAME VARCHAR, CHUNK_AXIS VARCHAR, AXIS_COLUMNS VARCHAR, TOTAL_ROWS NUMBER);
    CREATE OR REPLACE TEMPORARY TABLE HVAL_TMP_PRED (CHUNK_SEQ NUMBER, CHUNK_TYPE VARCHAR, PRED VARCHAR, EST NUMBER);
    CREATE OR REPLACE TEMPORARY TABLE HVAL_TMP_ACTUAL (CHUNK_SEQ NUMBER, ACTUAL_ROWS NUMBER);
    CREATE OR REPLACE TEMPORARY TABLE HVAL_TMP_RESULTS (TABLE_NAME VARCHAR, CHUNK_AXIS VARCHAR, CHUNKS NUMBER,
        SOURCE_ROWS NUMBER, PLAN_ROWS NUMBER, ROWS_IN_NO_CHUNK NUMBER, ROWS_IN_2PLUS_CHUNKS NUMBER,
        RANGE_CHUNKS_EXACT VARCHAR, RESULT VARCHAR);

    INSERT INTO HVAL_TMP_PLANS
        SELECT PLAN_ID, DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, CHUNK_AXIS, AXIS_COLUMNS, TOTAL_ROWS
          FROM HIST_PLAN_TABLE
         WHERE IS_ACTIVE AND PLAN_STATUS = 'PLANNED'
           AND UPPER(DATABASE_NAME) = UPPER(:p_database) AND UPPER(SCHEMA_NAME) = UPPER(:p_schema);

    FOR p IN c_plans DO
        v_pid := p.PLAN_ID;  v_db := p.DATABASE_NAME;  v_sch := p.SCHEMA_NAME;  v_tbl := p.TABLE_NAME;
        v_axis := p.CHUNK_AXIS;  v_cols := p.AXIS_COLUMNS;  v_plan_rows := p.TOTAL_ROWS;
        BEGIN
            v_fq := '"' || REPLACE(v_db, '"', '""') || '"."' || REPLACE(v_sch, '"', '""') || '"."' || REPLACE(v_tbl, '"', '""') || '"';
            v_c1 := SPLIT_PART(COALESCE(v_cols, ''), ',', 1);
            v_c2 := SPLIT_PART(COALESCE(v_cols, ''), ',', 2);
            v_c3 := SPLIT_PART(COALESCE(v_cols, ''), ',', 3);
            v_ax := CASE v_axis
                WHEN 'PARTITION_DAY'  THEN '"' || v_c1 || '"'
                WHEN 'PARTITION_YMD'  THEN 'DATE_FROM_PARTS("' || v_c1 || '", "' || v_c2 || '", "' || v_c3 || '")'
                WHEN 'REFINED_TS_DAY' THEN 'TO_DATE("' || v_c1 || '")'
                ELSE 'NULL' END;

            DELETE FROM HVAL_TMP_PRED;
            INSERT INTO HVAL_TMP_PRED (CHUNK_SEQ, CHUNK_TYPE, PRED, EST)
            SELECT CHUNK_SEQ, CHUNK_TYPE,
                   CASE CHUNK_TYPE
                     WHEN 'ALL' THEN 'TRUE'
                     WHEN 'NULL_VALUES' THEN '(' || :v_ax || ') IS NULL'
                     WHEN 'DAY_RANGE' THEN
                          '((' || :v_ax || ') IS NOT NULL'
                          || IFF(DAY_START IS NULL, '', ' AND (' || :v_ax || ') >= TO_DATE(''' || TO_CHAR(DAY_START, 'YYYY-MM-DD') || ''')')
                          || IFF(DAY_END   IS NULL, '', ' AND (' || :v_ax || ') < TO_DATE('''  || TO_CHAR(DAY_END,   'YYYY-MM-DD') || ''')')
                          || ')'
                     WHEN 'DAY_SUBRANGE' THEN
                          '((' || :v_ax || ') = TO_DATE(''' || TO_CHAR(DAY_START, 'YYYY-MM-DD') || ''')'
                          || ' AND "' || SUB_COLUMN || '" IS NOT NULL'
                          || IFF(SUB_START_TS IS NULL, '', ' AND "' || SUB_COLUMN || '" >= TO_TIMESTAMP_TZ('''
                                 || TO_CHAR(SUB_START_TS, 'YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM') || ''', ''YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM'')')
                          || IFF(SUB_END_TS IS NULL, '', ' AND "' || SUB_COLUMN || '" < TO_TIMESTAMP_TZ('''
                                 || TO_CHAR(SUB_END_TS, 'YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM') || ''', ''YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM'')')
                          || ')'
                     WHEN 'DAY_HASH' THEN
                          '((' || :v_ax || ') = TO_DATE(''' || TO_CHAR(DAY_START, 'YYYY-MM-DD') || ''')'
                          || ' AND MOD(ABS(HASH("' || SUB_COLUMN || '")), ' || HASH_MODULUS || ') = ' || HASH_BUCKET || ')'
                     WHEN 'HASH' THEN
                          '(MOD(ABS(HASH("' || SUB_COLUMN || '")), ' || HASH_MODULUS || ') = ' || HASH_BUCKET || ')'
                   END,
                   ESTIMATED_ROWS
              FROM HIST_PLAN_CHUNK
             WHERE PLAN_ID = :v_pid;

            SELECT LISTAGG('IFF(' || PRED || ', 1, 0)', ' + ') WITHIN GROUP (ORDER BY CHUNK_SEQ),
                   LISTAGG('SELECT ' || CHUNK_SEQ || ' AS CHUNK_SEQ, COUNT_IF(' || PRED || ') AS ACTUAL_ROWS FROM ' || :v_fq, ' UNION ALL ')
                       WITHIN GROUP (ORDER BY CHUNK_SEQ),
                   COUNT(*)
              INTO :v_sum_expr, :v_union, :v_chunks
              FROM HVAL_TMP_PRED;

            -- every source row: in how many chunks does it fall?
            v_sql := 'SELECT COUNT(*), COUNT_IF(N = 0), COUNT_IF(N > 1) FROM (SELECT ' || v_sum_expr || ' AS N FROM ' || v_fq || ')';
            EXECUTE IMMEDIATE :v_sql;
            SELECT $1, $2, $3 INTO :v_total, :v_missed, :v_multi FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

            -- actual rows per chunk, compared with the plan's estimate (exact for range chunks)
            DELETE FROM HVAL_TMP_ACTUAL;
            v_sql := 'INSERT INTO HVAL_TMP_ACTUAL (CHUNK_SEQ, ACTUAL_ROWS) ' || v_union;
            EXECUTE IMMEDIATE :v_sql;
            SELECT COUNT_IF(p2.CHUNK_TYPE NOT IN ('HASH', 'DAY_HASH')),
                   COUNT_IF(p2.CHUNK_TYPE NOT IN ('HASH', 'DAY_HASH') AND p2.EST = a.ACTUAL_ROWS)
              INTO :v_exact_n, :v_exact_ok
              FROM HVAL_TMP_PRED p2 JOIN HVAL_TMP_ACTUAL a ON a.CHUNK_SEQ = p2.CHUNK_SEQ;

            v_exact_txt := v_exact_ok || ' of ' || v_exact_n;
            v_result := IFF(v_missed = 0 AND v_multi = 0 AND v_exact_ok = v_exact_n AND v_total = v_plan_rows, 'PASS', 'FAIL');
            INSERT INTO HVAL_TMP_RESULTS VALUES (:v_tbl, :v_axis, :v_chunks, :v_total, :v_plan_rows, :v_missed, :v_multi,
                                                 :v_exact_txt, :v_result);
        EXCEPTION WHEN OTHER THEN
            v_result := 'ERROR: ' || LEFT(SQLERRM, 500);
            INSERT INTO HVAL_TMP_RESULTS (TABLE_NAME, CHUNK_AXIS, RESULT) VALUES (:v_tbl, :v_axis, :v_result);
        END;
    END FOR;

    res := (SELECT * FROM HVAL_TMP_RESULTS ORDER BY TABLE_NAME);
    RETURN TABLE(res);
END;
