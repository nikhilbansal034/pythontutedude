-- =====================================================================================
-- 02_test_setup.sql — synthetic source objects, one per planner scenario
-- =====================================================================================
-- Anonymous Snowflake Scripting block. In a Workspace: select everything and run once.
-- Creates schema TEST_DB.CHUNK_TEST_SRC with 9 Iceberg tables, 1 standard table and 1 view.
-- Each object is built to drive exactly one branch of the planner; expected results are
-- in TEST_PLAN.md (computed for max_chunk_rows = 1000).
--
-- Needs: CREATE SCHEMA on TEST_DB. Storage for the test Iceberg tables, one of:
--   * ext_volume = 'SNOWFLAKE_MANAGED' (default): Snowflake stores the files itself. No external
--     volume, no S3 access, nothing to grant.
--   * the name of an external volume your role may use. Find one with:  SHOW EXTERNAL VOLUMES;
--     (the production volume EV_GRSDIAI_REFINED_FULL_BUCKET_ICEBERG is usually not available here).
-- The Iceberg tables mirror the reference DDL (reference_ddl.sql): Snowflake catalog,
-- TIMESTAMP_LTZ(6) audit columns, GRS_PROCESS_DATE or GRS_PROCESS_YEAR/MONTH/DAY partitions.
--
-- Re-runnable: every object is CREATE OR REPLACE. With an external volume, each run writes to a
-- fresh BASE_LOCATION sub-folder (timestamped) so locations never collide.
-- =====================================================================================
DECLARE
    -- ================= SETTINGS: check before running =================
    test_database   VARCHAR DEFAULT 'TEST_DB';
    test_schema_src VARCHAR DEFAULT 'CHUNK_TEST_SRC';
    ext_volume      VARCHAR DEFAULT 'SNOWFLAKE_MANAGED';   -- or an external volume your role may use (SHOW EXTERNAL VOLUMES)
    base_prefix     VARCHAR DEFAULT 'test/chunk_planner';  -- BASE_LOCATION prefix; used only with an external volume
    iceberg_options VARCHAR DEFAULT '';                    -- e.g. 'ICEBERG_VERSION = 3'; '' = account default
    -- ==================================================================
    v_sql     VARCHAR;
    v_tail    VARCHAR;
    v_run_tag VARCHAR;
    v_managed BOOLEAN;
    v_loc     VARCHAR;
    res       RESULTSET;
BEGIN
    ALTER SESSION SET TIMEZONE = 'UTC';   -- all synthetic timestamps are built in UTC

    v_sql := 'CREATE SCHEMA IF NOT EXISTS ' || test_database || '.' || test_schema_src;
    EXECUTE IMMEDIATE :v_sql;
    v_sql := 'USE SCHEMA ' || test_database || '.' || test_schema_src;
    EXECUTE IMMEDIATE :v_sql;

    v_run_tag := TO_CHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS');
    v_managed := (UPPER(TRIM(ext_volume)) = 'SNOWFLAKE_MANAGED');
    -- Snowflake-managed storage takes the reserved, unquoted value and no BASE_LOCATION
    v_tail := IFF(v_managed, ' EXTERNAL_VOLUME = SNOWFLAKE_MANAGED', ' EXTERNAL_VOLUME = ''' || ext_volume || '''')
           || ' ' || COALESCE(iceberg_options, '') || ' CATALOG = ''SNOWFLAKE''';
    v_loc  := base_prefix || '/' || v_run_tag || '/';

    -- ---------------------------------------------------------------------------------
    -- T01  CURRENT-style, PARTITION BY GRS_PROCESS_DATE. 30 days x 300 rows, every other day.
    --      Expect: 10 DAY_RANGE chunks of 3 days (900 rows each).
    -- ---------------------------------------------------------------------------------
    v_sql := 'CREATE OR REPLACE ICEBERG TABLE T01_CUR_SPREAD (BUS_ID INT, GRS_UNIQUE_ID STRING, ROW_HASH STRING, '
          || 'GRS_REFINED_TIMESTAMP TIMESTAMP_LTZ(6), GRS_PROCESS_DATE DATE) PARTITION BY (GRS_PROCESS_DATE)'
          || v_tail || IFF(v_managed, '', ' BASE_LOCATION = ''' || v_loc || 't01_cur_spread/''');
    EXECUTE IMMEDIATE :v_sql;
    INSERT INTO T01_CUR_SPREAD (BUS_ID, GRS_UNIQUE_ID, ROW_HASH, GRS_REFINED_TIMESTAMP, GRS_PROCESS_DATE)
    SELECT x.rn, UUID_STRING(), MD5(TO_VARCHAR(x.rn)),
           DATEADD(minute, MOD(x.rn, 300), TO_TIMESTAMP_LTZ(x.d)), x.d
    FROM (SELECT g.rn, DATEADD(day, 2 * FLOOR(g.rn / 300), TO_DATE('2026-01-01')) AS d
          FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS rn
                FROM TABLE(GENERATOR(ROWCOUNT => 9000))) g) x;

    -- ---------------------------------------------------------------------------------
    -- T02  HISTORY-style, PARTITION BY GRS_PROCESS_YEAR/MONTH/DAY.
    --      3 small days (100 each) | one backfill day 2026-03-10 with 3,500 rows spread
    --      over 70 minutes (50 per minute) | 10 days x 200.
    --      Expect: DAY_RANGE, 4 x DAY_SUBRANGE on GRS_REFINED_TIMESTAMP, 2 x DAY_RANGE = 7.
    -- ---------------------------------------------------------------------------------
    v_sql := 'CREATE OR REPLACE ICEBERG TABLE T02_HIST_BACKFILL_SPREAD (BUS_ID INT, GRS_UNIQUE_ID STRING, '
          || 'NEW_ROW_HASH STRING, LAST_ROW_HASH STRING, GRS_REFINED_TIMESTAMP TIMESTAMP_LTZ(6), '
          || 'GRS_PROCESS_YEAR INT, GRS_PROCESS_MONTH INT, GRS_PROCESS_DAY INT) '
          || 'PARTITION BY (GRS_PROCESS_YEAR, GRS_PROCESS_MONTH, GRS_PROCESS_DAY)'
          || v_tail || IFF(v_managed, '', ' BASE_LOCATION = ''' || v_loc || 't02_hist_backfill_spread/''');
    EXECUTE IMMEDIATE :v_sql;
    INSERT INTO T02_HIST_BACKFILL_SPREAD (BUS_ID, GRS_UNIQUE_ID, NEW_ROW_HASH, LAST_ROW_HASH,
                                          GRS_REFINED_TIMESTAMP, GRS_PROCESS_YEAR, GRS_PROCESS_MONTH, GRS_PROCESS_DAY)
    SELECT x.rn, UUID_STRING(), MD5(TO_VARCHAR(x.rn)), MD5(TO_VARCHAR(x.rn + 1)),
           DATEADD(minute, x.minute_offset, TO_TIMESTAMP_LTZ(x.d)), YEAR(x.d), MONTH(x.d), DAY(x.d)
    FROM (SELECT g.rn,
                 CASE WHEN g.rn < 300  THEN DATEADD(day, FLOOR(g.rn / 100), TO_DATE('2026-03-01'))
                      WHEN g.rn < 3800 THEN TO_DATE('2026-03-10')
                      ELSE DATEADD(day, FLOOR((g.rn - 3800) / 200), TO_DATE('2026-03-11')) END AS d,
                 CASE WHEN g.rn < 300  THEN MOD(g.rn, 100)
                      WHEN g.rn < 3800 THEN FLOOR((g.rn - 300) / 50)
                      ELSE MOD(g.rn - 3800, 200) END AS minute_offset
          FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS rn
                FROM TABLE(GENERATOR(ROWCOUNT => 5800))) g) x;

    -- ---------------------------------------------------------------------------------
    -- T03  HISTORY-style. One backfill day 2026-04-05 with 2,500 rows that ALL carry the
    --      same GRS_REFINED_TIMESTAMP (10:00) | 4 days x 100.
    --      Expect: 3 x DAY_HASH on GRS_UNIQUE_ID (833/833/834) + 1 DAY_RANGE = 4.
    -- ---------------------------------------------------------------------------------
    v_sql := 'CREATE OR REPLACE ICEBERG TABLE T03_HIST_BACKFILL_SAME_TS (BUS_ID INT, GRS_UNIQUE_ID STRING, '
          || 'NEW_ROW_HASH STRING, LAST_ROW_HASH STRING, GRS_REFINED_TIMESTAMP TIMESTAMP_LTZ(6), '
          || 'GRS_PROCESS_YEAR INT, GRS_PROCESS_MONTH INT, GRS_PROCESS_DAY INT) '
          || 'PARTITION BY (GRS_PROCESS_YEAR, GRS_PROCESS_MONTH, GRS_PROCESS_DAY)'
          || v_tail || IFF(v_managed, '', ' BASE_LOCATION = ''' || v_loc || 't03_hist_backfill_same_ts/''');
    EXECUTE IMMEDIATE :v_sql;
    INSERT INTO T03_HIST_BACKFILL_SAME_TS (BUS_ID, GRS_UNIQUE_ID, NEW_ROW_HASH, LAST_ROW_HASH,
                                           GRS_REFINED_TIMESTAMP, GRS_PROCESS_YEAR, GRS_PROCESS_MONTH, GRS_PROCESS_DAY)
    SELECT x.rn, UUID_STRING(), MD5(TO_VARCHAR(x.rn)), MD5(TO_VARCHAR(x.rn + 1)),
           DATEADD(minute, x.minute_offset, TO_TIMESTAMP_LTZ(x.d)), YEAR(x.d), MONTH(x.d), DAY(x.d)
    FROM (SELECT g.rn,
                 CASE WHEN g.rn < 2500 THEN TO_DATE('2026-04-05')
                      ELSE DATEADD(day, FLOOR((g.rn - 2500) / 100), TO_DATE('2026-04-06')) END AS d,
                 CASE WHEN g.rn < 2500 THEN 600 ELSE MOD(g.rn - 2500, 100) END AS minute_offset
          FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS rn
                FROM TABLE(GENERATOR(ROWCOUNT => 2900))) g) x;

    -- ---------------------------------------------------------------------------------
    -- T04  CURRENT-style, small: 500 rows on one day.  Expect: 1 ALL chunk (SINGLE).
    -- ---------------------------------------------------------------------------------
    v_sql := 'CREATE OR REPLACE ICEBERG TABLE T04_SMALL (BUS_ID INT, GRS_UNIQUE_ID STRING, ROW_HASH STRING, '
          || 'GRS_REFINED_TIMESTAMP TIMESTAMP_LTZ(6), GRS_PROCESS_DATE DATE) PARTITION BY (GRS_PROCESS_DATE)'
          || v_tail || IFF(v_managed, '', ' BASE_LOCATION = ''' || v_loc || 't04_small/''');
    EXECUTE IMMEDIATE :v_sql;
    INSERT INTO T04_SMALL (BUS_ID, GRS_UNIQUE_ID, ROW_HASH, GRS_REFINED_TIMESTAMP, GRS_PROCESS_DATE)
    SELECT g.rn, UUID_STRING(), MD5(TO_VARCHAR(g.rn)),
           DATEADD(minute, g.rn, TO_TIMESTAMP_LTZ(TO_DATE('2026-02-01'))), TO_DATE('2026-02-01')
    FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS rn FROM TABLE(GENERATOR(ROWCOUNT => 500))) g;

    -- ---------------------------------------------------------------------------------
    -- T05  CURRENT-style. 4 days x 400 + 150 rows with a NULL GRS_PROCESS_DATE.
    --      Expect: 2 x DAY_RANGE (800 each) + 1 NULL_VALUES (150) = 3.
    -- ---------------------------------------------------------------------------------
    v_sql := 'CREATE OR REPLACE ICEBERG TABLE T05_NULL_PARTITION (BUS_ID INT, GRS_UNIQUE_ID STRING, ROW_HASH STRING, '
          || 'GRS_REFINED_TIMESTAMP TIMESTAMP_LTZ(6), GRS_PROCESS_DATE DATE) PARTITION BY (GRS_PROCESS_DATE)'
          || v_tail || IFF(v_managed, '', ' BASE_LOCATION = ''' || v_loc || 't05_null_partition/''');
    EXECUTE IMMEDIATE :v_sql;
    INSERT INTO T05_NULL_PARTITION (BUS_ID, GRS_UNIQUE_ID, ROW_HASH, GRS_REFINED_TIMESTAMP, GRS_PROCESS_DATE)
    SELECT x.rn, UUID_STRING(), MD5(TO_VARCHAR(x.rn)),
           DATEADD(minute, MOD(x.rn, 400), TO_TIMESTAMP_LTZ(COALESCE(x.d, TO_DATE('2026-06-10')))), x.d
    FROM (SELECT g.rn,
                 IFF(g.rn < 1600, DATEADD(day, FLOOR(g.rn / 400), TO_DATE('2026-06-01')), NULL) AS d
          FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS rn
                FROM TABLE(GENERATOR(ROWCOUNT => 1750))) g) x;

    -- ---------------------------------------------------------------------------------
    -- T06  Not partitioned, but has GRS_REFINED_TIMESTAMP. 6 days x 450 (at 12:00 + seconds).
    --      Expect: axis REFINED_TS_DAY, 3 x DAY_RANGE of 2 days (900 each).
    -- ---------------------------------------------------------------------------------
    v_sql := 'CREATE OR REPLACE ICEBERG TABLE T06_UNPARTITIONED_TS (BUS_ID INT, GRS_UNIQUE_ID STRING, ROW_HASH STRING, '
          || 'GRS_REFINED_TIMESTAMP TIMESTAMP_LTZ(6))'
          || v_tail || IFF(v_managed, '', ' BASE_LOCATION = ''' || v_loc || 't06_unpartitioned_ts/''');
    EXECUTE IMMEDIATE :v_sql;
    INSERT INTO T06_UNPARTITIONED_TS (BUS_ID, GRS_UNIQUE_ID, ROW_HASH, GRS_REFINED_TIMESTAMP)
    SELECT x.rn, UUID_STRING(), MD5(TO_VARCHAR(x.rn)),
           DATEADD(second, MOD(x.rn, 450), DATEADD(hour, 12, TO_TIMESTAMP_LTZ(x.d)))
    FROM (SELECT g.rn, DATEADD(day, FLOOR(g.rn / 450), TO_DATE('2026-05-01')) AS d
          FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS rn
                FROM TABLE(GENERATOR(ROWCOUNT => 2700))) g) x;

    -- ---------------------------------------------------------------------------------
    -- T07  Not partitioned, no GRS_* columns at all, 2,000 rows (bigger than one chunk).
    --      Expect: FAILED "No usable chunk column", and the run carries on (D6).
    -- ---------------------------------------------------------------------------------
    v_sql := 'CREATE OR REPLACE ICEBERG TABLE T07_NO_USABLE_COLUMN (ID INT, NAME STRING)'
          || v_tail || IFF(v_managed, '', ' BASE_LOCATION = ''' || v_loc || 't07_no_usable_column/''');
    EXECUTE IMMEDIATE :v_sql;
    INSERT INTO T07_NO_USABLE_COLUMN (ID, NAME)
    SELECT g.rn, 'name_' || g.rn
    FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS rn FROM TABLE(GENERATOR(ROWCOUNT => 2000))) g;

    -- ---------------------------------------------------------------------------------
    -- T08  Not partitioned, only GRS_UNIQUE_ID, 2,500 rows.
    --      Expect: axis UNIQUE_ID_HASH, 3 x HASH (833/833/834).
    -- ---------------------------------------------------------------------------------
    v_sql := 'CREATE OR REPLACE ICEBERG TABLE T08_UNIQUE_ID_ONLY (ID INT, GRS_UNIQUE_ID STRING)'
          || v_tail || IFF(v_managed, '', ' BASE_LOCATION = ''' || v_loc || 't08_unique_id_only/''');
    EXECUTE IMMEDIATE :v_sql;
    INSERT INTO T08_UNIQUE_ID_ONLY (ID, GRS_UNIQUE_ID)
    SELECT g.rn, UUID_STRING()
    FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS rn FROM TABLE(GENERATOR(ROWCOUNT => 2500))) g;

    -- ---------------------------------------------------------------------------------
    -- T09  Standard (non-Iceberg) table and T10 a view.  Expect: both SKIPPED, with reason.
    -- ---------------------------------------------------------------------------------
    CREATE OR REPLACE TABLE T09_STANDARD_TABLE (ID INT, GRS_UNIQUE_ID STRING);
    INSERT INTO T09_STANDARD_TABLE (ID, GRS_UNIQUE_ID)
    SELECT g.rn, UUID_STRING()
    FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS rn FROM TABLE(GENERATOR(ROWCOUNT => 10))) g;
    CREATE OR REPLACE VIEW T10_VIEW AS SELECT ID, GRS_UNIQUE_ID FROM T09_STANDARD_TABLE;

    -- ---------------------------------------------------------------------------------
    -- T11  CURRENT-style, partitioned, EMPTY.  Expect: 1 ALL chunk with 0 rows.
    -- ---------------------------------------------------------------------------------
    v_sql := 'CREATE OR REPLACE ICEBERG TABLE T11_EMPTY (BUS_ID INT, GRS_UNIQUE_ID STRING, ROW_HASH STRING, '
          || 'GRS_REFINED_TIMESTAMP TIMESTAMP_LTZ(6), GRS_PROCESS_DATE DATE) PARTITION BY (GRS_PROCESS_DATE)'
          || v_tail || IFF(v_managed, '', ' BASE_LOCATION = ''' || v_loc || 't11_empty/''');
    EXECUTE IMMEDIATE :v_sql;

    -- Evidence E02: what was built
    res := (
        SELECT 'T01_CUR_SPREAD' AS OBJECT_NAME, COUNT(*) AS ROW_COUNT, '9000 expected' AS NOTE FROM T01_CUR_SPREAD
        UNION ALL SELECT 'T02_HIST_BACKFILL_SPREAD', COUNT(*), '5800 expected' FROM T02_HIST_BACKFILL_SPREAD
        UNION ALL SELECT 'T03_HIST_BACKFILL_SAME_TS', COUNT(*), '2900 expected' FROM T03_HIST_BACKFILL_SAME_TS
        UNION ALL SELECT 'T04_SMALL', COUNT(*), '500 expected' FROM T04_SMALL
        UNION ALL SELECT 'T05_NULL_PARTITION', COUNT(*), '1750 expected (150 with NULL GRS_PROCESS_DATE)' FROM T05_NULL_PARTITION
        UNION ALL SELECT 'T06_UNPARTITIONED_TS', COUNT(*), '2700 expected' FROM T06_UNPARTITIONED_TS
        UNION ALL SELECT 'T07_NO_USABLE_COLUMN', COUNT(*), '2000 expected' FROM T07_NO_USABLE_COLUMN
        UNION ALL SELECT 'T08_UNIQUE_ID_ONLY', COUNT(*), '2500 expected' FROM T08_UNIQUE_ID_ONLY
        UNION ALL SELECT 'T09_STANDARD_TABLE', COUNT(*), '10 expected (standard table)' FROM T09_STANDARD_TABLE
        UNION ALL SELECT 'T10_VIEW', COUNT(*), '10 expected (view)' FROM T10_VIEW
        UNION ALL SELECT 'T11_EMPTY', COUNT(*), '0 expected' FROM T11_EMPTY
        ORDER BY 1
    );
    RETURN TABLE(res);
END;
