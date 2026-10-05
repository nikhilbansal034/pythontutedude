-- =====================================================================================
-- 04_chunk_planner.sql — Iceberg historical-load chunk planner
-- =====================================================================================
-- Anonymous Snowflake Scripting block (no stored procedure). In a Snowflake Workspace:
-- edit the INPUTS below, select everything, run. Design: ../design_review.md (revision 9).
--
-- What it does, per table in scope:
--   1. reads the table's structure (partition spec, columns, size) - metadata only
--   2. picks the chunk axis:  date partition -> year/month/day partition -> naming
--      convention fallback -> GRS_REFINED_TIMESTAMP day -> GRS_UNIQUE_ID hash -> none
--   3. counts rows per axis day, groups whole days up to the size target, and splits a
--      day that alone exceeds it (GRS_REFINED_TIMESTAMP ranges, else GRS_UNIQUE_ID hash)
--   4. writes HIST_PLAN_TABLE (one row per table, with status) and HIST_PLAN_CHUNK
--      (one row per chunk) in one transaction per table
-- It never builds load SQL and never touches target tables.
--
-- Behaviour (decisions in design_review.md §1a):
--   * Bad input (database, schema, or ANY listed table name) -> nothing is written; the
--     result grid lists every problem and the run exits (D12).
--   * No table list -> every object in the schema; non-Iceberg objects are SKIPPED and
--     recorded with the reason (D13, D15).
--   * A table whose chunking cannot be decided -> FAILED with the reason; the run carries
--     on with the next table (D6).
--   * A table that already has an active plan -> SKIPPED unless p_force_replan = TRUE;
--     re-planning marks the old plan SUPERSEDED (never edited).
--
-- Side effects on YOUR session: TIMEZONE is set to UTC and the current schema becomes the
-- metadata schema. Temporary HPLAN_TMP_* tables are created there (session-private).
-- =====================================================================================
DECLARE
    -- ================= INPUTS: edit before each run =================
    p_database        VARCHAR DEFAULT 'TEST_DB';          -- required
    p_schema          VARCHAR DEFAULT 'CHUNK_TEST_SRC';   -- required
    p_tables          VARCHAR DEFAULT '';                 -- '' = every table in the schema,
                                                          -- or a list: 'T01_CUR_SPREAD, T02_HIST_BACKFILL_SPREAD'
                                                          -- wrap a name in double quotes for an exact-case match
    p_force_replan    BOOLEAN DEFAULT FALSE;              -- TRUE = re-plan tables that already have a plan

    -- ====== METADATA LOCATION: update by hand once finalised (D3) ======
    metadata_database VARCHAR DEFAULT 'test_db';
    metadata_schema   VARCHAR DEFAULT 'test_schema';

    -- ====== CHUNK SIZING: fixed, Medium-warehouse assumption (D8, D14) ======
    target_chunk_bytes NUMBER(38,0) DEFAULT 10737418240;  -- 10 GB of Iceberg data per chunk
    max_chunk_rows     NUMBER(38,0) DEFAULT 250000000;    -- 250M-row cap. TEST RUNS: set to 1000 (TEST_PLAN.md)
    split_grain        VARCHAR      DEFAULT 'MINUTE';     -- grain for splitting an oversized day: SECOND / MINUTE / HOUR
    -- =================================================================

    -- run level
    v_run_id          VARCHAR;
    v_sql             VARCHAR;
    v_msg             VARCHAR;
    v_meta_fq         VARCHAR;
    v_in_db           VARCHAR;
    v_in_sch          VARCHAR;
    v_db_quoted       BOOLEAN;
    v_sch_quoted      BOOLEAN;
    v_db              VARCHAR;
    v_sch             VARCHAR;
    v_q_db            VARCHAR;
    v_fq_schema       VARCHAR;
    v_n_exact         NUMBER;
    v_n_ci            NUMBER;
    v_exact           VARCHAR;
    v_ci              VARCHAR;
    v_n_inputs        NUMBER DEFAULT 0;
    v_n_invalid       NUMBER DEFAULT 0;
    v_spec_ok         BOOLEAN DEFAULT FALSE;
    v_grain           VARCHAR;
    v_cnt_scope       NUMBER DEFAULT 0;
    v_cnt_planned     NUMBER DEFAULT 0;
    v_cnt_failed      NUMBER DEFAULT 0;
    v_cnt_skip_ice    NUMBER DEFAULT 0;
    v_cnt_skip_done   NUMBER DEFAULT 0;
    v_probe           NUMBER;

    -- per table
    v_tbl             VARCHAR;
    v_obj_type        VARCHAR;
    v_is_ice          BOOLEAN;
    v_skip_reason     VARCHAR;
    v_fq              VARCHAR;
    v_fn_arg          VARCHAR;
    v_plan_id         VARCHAR;
    v_old_plan        VARCHAR;
    v_n_active_plan   NUMBER;
    v_fail_active     BOOLEAN;
    v_fail_reason     VARCHAR;
    v_note            VARCHAR;
    v_profiled_at     TIMESTAMP_TZ;
    v_layer           VARCHAR;
    v_axis            VARCHAR;
    v_axis_cols       VARCHAR;
    v_axis_expr       VARCHAR;
    v_verified        BOOLEAN;
    v_method          VARCHAR;
    v_c1              VARCHAR;
    v_c2              VARCHAR;
    v_c3              VARCHAR;
    v_col_count       NUMBER;
    v_col_ts          VARCHAR;
    v_col_uid         VARCHAR;
    v_col_date        VARCHAR;
    v_col_y           VARCHAR;
    v_col_m           VARCHAR;
    v_col_d           VARCHAR;
    v_n_rowhash       NUMBER;
    v_n_histhash      NUMBER;
    v_sp_fields       NUMBER;
    v_sp_ident        NUMBER;
    v_sp_date         VARCHAR;
    v_sp_y            VARCHAR;
    v_sp_m            VARCHAR;
    v_sp_d            VARCHAR;
    v_total_rows      NUMBER(38,0);
    v_total_bytes     NUMBER(38,0);
    v_file_count      NUMBER(38,0);
    v_avg_row         NUMBER(38,4);
    v_avg_file        NUMBER(38,2);
    v_target_rows     NUMBER(38,0);
    v_day_count       NUMBER;
    v_split_days      NUMBER;
    v_null_rows       NUMBER;
    v_days_total      NUMBER;
    v_chunk_count     NUMBER;
    v_sum_rows        NUMBER;

    -- day walk
    v_seq             NUMBER;
    v_open            BOOLEAN;
    v_acc             NUMBER;
    v_open_start      DATE;
    v_next_start      DATE;
    v_day             DATE;
    v_day_next        DATE;
    v_day_str         VARCHAR;
    v_day_rows        NUMBER;
    v_day_pred        VARCHAR;
    v_can_ts          BOOLEAN;
    v_bkt_null        NUMBER;
    v_bkt_max         NUMBER;
    v_bkt_total       NUMBER;
    v_bkt             TIMESTAMP_TZ;
    v_bkt_rows        NUMBER;
    v_piece_start     TIMESTAMP_TZ;
    v_pacc            NUMBER;
    v_mod             NUMBER;
    v_base            NUMBER;
    v_last            NUMBER;
    v_k               NUMBER;
    v_rows_k          NUMBER;
    v_hash_rows       NUMBER;

    res               RESULTSET;
    e_plan            EXCEPTION (-20001, 'Chunk planning failed for this table');

    c_scope CURSOR FOR SELECT OBJ_NAME, OBJ_TYPE, IS_ICEBERG, SKIP_REASON
                         FROM HPLAN_TMP_SCOPE ORDER BY IS_ICEBERG, OBJ_NAME;
    c_days  CURSOR FOR SELECT PROCESS_DAY, DAY_ROWS
                         FROM HPLAN_TMP_DAYS WHERE PROCESS_DAY IS NOT NULL ORDER BY PROCESS_DAY;
    c_bkts  CURSOR FOR SELECT BKT, BKT_ROWS
                         FROM HPLAN_TMP_BKTS ORDER BY BKT;
BEGIN
    -- =================================================================================
    -- 0. Session, metadata location, working tables
    -- =================================================================================
    ALTER SESSION SET TIMEZONE = 'UTC';
    v_run_id  := UUID_STRING();
    v_meta_fq := metadata_database || '.' || metadata_schema;
    v_sql := 'USE SCHEMA ' || v_meta_fq;
    BEGIN
        EXECUTE IMMEDIATE :v_sql;
        SELECT COUNT(*) INTO :v_probe FROM HIST_PLAN_TABLE WHERE 1 = 0;
        SELECT COUNT(*) INTO :v_probe FROM HIST_PLAN_CHUNK WHERE 1 = 0;
    EXCEPTION WHEN OTHER THEN
        v_msg := 'Metadata location ' || v_meta_fq || ' is not usable (' || LEFT(SQLERRM, 300)
              || '). Run 01_metadata_ddl.sql for this location, or set metadata_database / metadata_schema to where you ran it. Nothing was written.';
    END;
    IF (v_msg IS NOT NULL) THEN
        res := (SELECT NULL::VARCHAR AS TABLE_NAME, 'VALIDATION_FAILED' AS OUTCOME, :v_msg AS REASON,
                       NULL::VARCHAR AS LAYER, NULL::VARCHAR AS CHUNK_AXIS, NULL::VARCHAR AS CHUNK_METHOD,
                       NULL::NUMBER AS CHUNK_COUNT, NULL::NUMBER AS TOTAL_ROWS, NULL::NUMBER AS TOTAL_BYTES);
        RETURN TABLE(res);
    END IF;

    CREATE OR REPLACE TEMPORARY TABLE HPLAN_TMP_SUMMARY (SORT_KEY NUMBER, TABLE_NAME VARCHAR, OUTCOME VARCHAR, REASON VARCHAR,
        LAYER VARCHAR, CHUNK_AXIS VARCHAR, CHUNK_METHOD VARCHAR, CHUNK_COUNT NUMBER, TOTAL_ROWS NUMBER, TOTAL_BYTES NUMBER);
    CREATE OR REPLACE TEMPORARY TABLE HPLAN_TMP_OBJECTS (OBJ_NAME VARCHAR, OBJ_TYPE VARCHAR, IS_ICEBERG BOOLEAN);
    CREATE OR REPLACE TEMPORARY TABLE HPLAN_TMP_INPUT  (INPUT_NAME VARCHAR, RESOLVED_NAME VARCHAR, ISSUE VARCHAR);
    CREATE OR REPLACE TEMPORARY TABLE HPLAN_TMP_SCOPE  (OBJ_NAME VARCHAR, OBJ_TYPE VARCHAR, IS_ICEBERG BOOLEAN, SKIP_REASON VARCHAR);
    CREATE OR REPLACE TEMPORARY TABLE HPLAN_TMP_COLS   (TABLE_NAME VARCHAR, COLUMN_NAME VARCHAR, DATA_TYPE VARCHAR);
    CREATE OR REPLACE TEMPORARY TABLE HPLAN_TMP_DAYS   (PROCESS_DAY DATE, DAY_ROWS NUMBER);
    CREATE OR REPLACE TEMPORARY TABLE HPLAN_TMP_BKTS   (BKT TIMESTAMP_TZ, BKT_ROWS NUMBER);
    CREATE OR REPLACE TEMPORARY TABLE HPLAN_TMP_CHUNKS (CHUNK_SEQ NUMBER, CHUNK_TYPE VARCHAR, DAY_START DATE, DAY_END DATE,
        SUB_COLUMN VARCHAR, SUB_START_TS TIMESTAMP_TZ, SUB_END_TS TIMESTAMP_TZ, HASH_BUCKET NUMBER, HASH_MODULUS NUMBER,
        ESTIMATED_ROWS NUMBER, ESTIMATED_BYTES NUMBER);

    -- =================================================================================
    -- 1. Validate inputs. Any problem -> report and exit, nothing written (D12)
    -- =================================================================================
    v_grain := UPPER(TRIM(COALESCE(split_grain, '')));
    IF (TRIM(COALESCE(p_database, '')) = '' OR TRIM(COALESCE(p_schema, '')) = '') THEN
        v_msg := 'p_database and p_schema are both required';
    ELSEIF (v_grain <> 'SECOND' AND v_grain <> 'MINUTE' AND v_grain <> 'HOUR') THEN
        v_msg := 'split_grain must be SECOND, MINUTE or HOUR (got ' || COALESCE(split_grain, 'NULL') || ')';
    ELSEIF (COALESCE(target_chunk_bytes, 0) <= 0 OR COALESCE(max_chunk_rows, 0) <= 0) THEN
        v_msg := 'target_chunk_bytes and max_chunk_rows must be greater than 0';
    END IF;
    IF (v_msg IS NOT NULL) THEN
        INSERT INTO HPLAN_TMP_SUMMARY (SORT_KEY, TABLE_NAME, OUTCOME, REASON) VALUES (0, NULL, 'VALIDATION_FAILED', :v_msg);
        INSERT INTO HPLAN_TMP_SUMMARY (SORT_KEY, TABLE_NAME, OUTCOME, REASON) VALUES (9, '*** SUMMARY ***', 'EXITED', 'Input validation failed. Nothing was written.');
        res := (SELECT TABLE_NAME, OUTCOME, REASON, LAYER, CHUNK_AXIS, CHUNK_METHOD, CHUNK_COUNT, TOTAL_ROWS, TOTAL_BYTES
                  FROM HPLAN_TMP_SUMMARY ORDER BY SORT_KEY, TABLE_NAME);
        RETURN TABLE(res);
    END IF;

    -- 1a. database: exact name first, then a unique case-insensitive match
    v_in_db     := TRIM(p_database);
    v_db_quoted := (LEFT(v_in_db, 1) = '"' AND RIGHT(v_in_db, 1) = '"' AND LENGTH(v_in_db) > 2);
    IF (v_db_quoted) THEN v_in_db := SUBSTR(v_in_db, 2, LENGTH(v_in_db) - 2); END IF;
    v_sql := 'SHOW DATABASES LIKE ''' || REPLACE(v_in_db, '''', '''''') || '''';
    EXECUTE IMMEDIATE :v_sql;
    SELECT COUNT_IF("name" = :v_in_db), COUNT_IF(UPPER("name") = UPPER(:v_in_db)),
           MAX(IFF("name" = :v_in_db, "name", NULL)), MAX(IFF(UPPER("name") = UPPER(:v_in_db), "name", NULL))
      INTO :v_n_exact, :v_n_ci, :v_exact, :v_ci
      FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    v_db := IFF(v_n_exact = 1, v_exact, IFF(NOT v_db_quoted AND v_n_ci = 1, v_ci, NULL));
    IF (v_db IS NULL) THEN
        v_msg := IFF(v_n_ci > 1,
                     'Database ' || p_database || ' is ambiguous (' || v_n_ci || ' databases differ only by case); quote the exact name',
                     'Database ' || p_database || ' not found, or not visible to role ' || CURRENT_ROLE());
        INSERT INTO HPLAN_TMP_SUMMARY (SORT_KEY, TABLE_NAME, OUTCOME, REASON) VALUES (0, NULL, 'VALIDATION_FAILED', :v_msg);
        INSERT INTO HPLAN_TMP_SUMMARY (SORT_KEY, TABLE_NAME, OUTCOME, REASON) VALUES (9, '*** SUMMARY ***', 'EXITED', 'Input validation failed. Nothing was written.');
        res := (SELECT TABLE_NAME, OUTCOME, REASON, LAYER, CHUNK_AXIS, CHUNK_METHOD, CHUNK_COUNT, TOTAL_ROWS, TOTAL_BYTES
                  FROM HPLAN_TMP_SUMMARY ORDER BY SORT_KEY, TABLE_NAME);
        RETURN TABLE(res);
    END IF;
    v_q_db := '"' || REPLACE(v_db, '"', '""') || '"';

    -- 1b. schema, inside that database
    v_in_sch     := TRIM(p_schema);
    v_sch_quoted := (LEFT(v_in_sch, 1) = '"' AND RIGHT(v_in_sch, 1) = '"' AND LENGTH(v_in_sch) > 2);
    IF (v_sch_quoted) THEN v_in_sch := SUBSTR(v_in_sch, 2, LENGTH(v_in_sch) - 2); END IF;
    v_sql := 'SELECT COUNT_IF(SCHEMA_NAME = ?), COUNT_IF(UPPER(SCHEMA_NAME) = UPPER(?)), '
          || 'MAX(IFF(SCHEMA_NAME = ?, SCHEMA_NAME, NULL)), MAX(IFF(UPPER(SCHEMA_NAME) = UPPER(?), SCHEMA_NAME, NULL)) '
          || 'FROM ' || v_q_db || '.INFORMATION_SCHEMA.SCHEMATA';
    EXECUTE IMMEDIATE :v_sql USING (v_in_sch, v_in_sch, v_in_sch, v_in_sch);
    SELECT $1, $2, $3, $4 INTO :v_n_exact, :v_n_ci, :v_exact, :v_ci FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    v_sch := IFF(v_n_exact = 1, v_exact, IFF(NOT v_sch_quoted AND v_n_ci = 1, v_ci, NULL));
    IF (v_sch IS NULL) THEN
        v_msg := IFF(v_n_ci > 1,
                     'Schema ' || p_schema || ' is ambiguous in ' || v_db || '; quote the exact name',
                     'Schema ' || p_schema || ' not found in database ' || v_db || ', or not visible to role ' || CURRENT_ROLE());
        INSERT INTO HPLAN_TMP_SUMMARY (SORT_KEY, TABLE_NAME, OUTCOME, REASON) VALUES (0, NULL, 'VALIDATION_FAILED', :v_msg);
        INSERT INTO HPLAN_TMP_SUMMARY (SORT_KEY, TABLE_NAME, OUTCOME, REASON) VALUES (9, '*** SUMMARY ***', 'EXITED', 'Input validation failed. Nothing was written.');
        res := (SELECT TABLE_NAME, OUTCOME, REASON, LAYER, CHUNK_AXIS, CHUNK_METHOD, CHUNK_COUNT, TOTAL_ROWS, TOTAL_BYTES
                  FROM HPLAN_TMP_SUMMARY ORDER BY SORT_KEY, TABLE_NAME);
        RETURN TABLE(res);
    END IF;
    v_fq_schema := v_q_db || '."' || REPLACE(v_sch, '"', '""') || '"';

    -- 1c. everything in the schema: all objects, which of them are Iceberg, all columns
    v_sql := 'INSERT INTO HPLAN_TMP_OBJECTS (OBJ_NAME, OBJ_TYPE, IS_ICEBERG) SELECT TABLE_NAME, TABLE_TYPE, FALSE FROM '
          || v_q_db || '.INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ?'
          || ' AND TABLE_TYPE <> ''TEMPORARY TABLE'''                                -- session temp tables, incl. the planner's own
          || ' AND TABLE_NAME NOT IN (''HIST_PLAN_TABLE'', ''HIST_PLAN_CHUNK'')';    -- the plan tables, if they share the schema
    EXECUTE IMMEDIATE :v_sql USING (v_sch);

    v_sql := 'SHOW ICEBERG TABLES IN SCHEMA ' || v_fq_schema;
    EXECUTE IMMEDIATE :v_sql;
    CREATE OR REPLACE TEMPORARY TABLE HPLAN_TMP_ICE AS SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    UPDATE HPLAN_TMP_OBJECTS SET IS_ICEBERG = TRUE, OBJ_TYPE = 'ICEBERG TABLE'
     WHERE OBJ_NAME IN (SELECT "name" FROM HPLAN_TMP_ICE);
    INSERT INTO HPLAN_TMP_OBJECTS (OBJ_NAME, OBJ_TYPE, IS_ICEBERG)
        SELECT "name", 'ICEBERG TABLE', TRUE FROM HPLAN_TMP_ICE
         WHERE "name" NOT IN (SELECT OBJ_NAME FROM HPLAN_TMP_OBJECTS);

    v_sql := 'INSERT INTO HPLAN_TMP_COLS (TABLE_NAME, COLUMN_NAME, DATA_TYPE) SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE FROM '
          || v_q_db || '.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = ?';
    EXECUTE IMMEDIATE :v_sql USING (v_sch);

    -- is the Iceberg partition spec readable in this account? (else: naming-convention fallback)
    BEGIN
        v_sql := 'SELECT COUNT("partition_specs"), COUNT("current_partition_spec_id") FROM HPLAN_TMP_ICE';
        EXECUTE IMMEDIATE :v_sql;
        v_spec_ok := TRUE;
    EXCEPTION WHEN OTHER THEN
        v_spec_ok := FALSE;
    END;

    -- 1d. the input table list, if any
    INSERT INTO HPLAN_TMP_INPUT (INPUT_NAME, RESOLVED_NAME, ISSUE)
    SELECT r.RAW_NAME,
           r.RESOLVED_NAME,
           CASE WHEN r.RESOLVED_NAME IS NULL AND r.N_CI > 1
                     THEN 'ambiguous: ' || r.N_CI || ' objects differ only by case - wrap the exact name in double quotes'
                WHEN r.RESOLVED_NAME IS NULL
                     THEN 'not found in ' || :v_db || '.' || :v_sch
                WHEN NOT o.IS_ICEBERG
                     THEN 'exists but is not an Iceberg table ('
                          || CASE o.OBJ_TYPE WHEN 'BASE TABLE' THEN 'standard table' ELSE LOWER(o.OBJ_TYPE) END || ')'
           END
    FROM (
        SELECT m.RAW_NAME, m.N_CI,
               CASE WHEN m.N_EXACT = 1 THEN m.EXACT_NAME
                    WHEN NOT m.IS_QUOTED AND m.N_CI = 1 THEN m.CI_NAME END AS RESOLVED_NAME
        FROM (
            SELECT n.RAW_NAME, n.IS_QUOTED,
                   COUNT_IF(o2.OBJ_NAME = n.CLEAN_NAME)                 AS N_EXACT,
                   COUNT(o2.OBJ_NAME)                                   AS N_CI,
                   MAX(IFF(o2.OBJ_NAME = n.CLEAN_NAME, o2.OBJ_NAME, NULL)) AS EXACT_NAME,
                   MAX(o2.OBJ_NAME)                                     AS CI_NAME
            FROM (
                SELECT i.RAW_NAME,
                       (LEFT(i.RAW_NAME, 1) = '"' AND RIGHT(i.RAW_NAME, 1) = '"' AND LENGTH(i.RAW_NAME) > 2) AS IS_QUOTED,
                       IFF(LEFT(i.RAW_NAME, 1) = '"' AND RIGHT(i.RAW_NAME, 1) = '"' AND LENGTH(i.RAW_NAME) > 2,
                           SUBSTR(i.RAW_NAME, 2, LENGTH(i.RAW_NAME) - 2), i.RAW_NAME) AS CLEAN_NAME
                FROM (SELECT DISTINCT TRIM(s.VALUE) AS RAW_NAME
                        FROM TABLE(SPLIT_TO_TABLE(COALESCE(:p_tables, ''), ',')) s
                       WHERE TRIM(s.VALUE) <> '') i
            ) n
            LEFT JOIN HPLAN_TMP_OBJECTS o2 ON UPPER(o2.OBJ_NAME) = UPPER(n.CLEAN_NAME)
            GROUP BY n.RAW_NAME, n.IS_QUOTED
        ) m
    ) r
    LEFT JOIN HPLAN_TMP_OBJECTS o ON o.OBJ_NAME = r.RESOLVED_NAME;

    SELECT COUNT(*), COUNT_IF(ISSUE IS NOT NULL) INTO :v_n_inputs, :v_n_invalid FROM HPLAN_TMP_INPUT;
    IF (v_n_invalid > 0) THEN
        INSERT INTO HPLAN_TMP_SUMMARY (SORT_KEY, TABLE_NAME, OUTCOME, REASON)
            SELECT 0, INPUT_NAME, 'VALIDATION_FAILED', ISSUE FROM HPLAN_TMP_INPUT WHERE ISSUE IS NOT NULL;
        v_msg := 'Input validation failed: ' || v_n_invalid || ' of ' || v_n_inputs || ' table names are invalid. Nothing was written.';
        INSERT INTO HPLAN_TMP_SUMMARY (SORT_KEY, TABLE_NAME, OUTCOME, REASON) VALUES (9, '*** SUMMARY ***', 'EXITED', :v_msg);
        res := (SELECT TABLE_NAME, OUTCOME, REASON, LAYER, CHUNK_AXIS, CHUNK_METHOD, CHUNK_COUNT, TOTAL_ROWS, TOTAL_BYTES
                  FROM HPLAN_TMP_SUMMARY ORDER BY SORT_KEY, TABLE_NAME);
        RETURN TABLE(res);
    END IF;

    -- =================================================================================
    -- 2. Scope: the listed tables, or every object in the schema
    -- =================================================================================
    IF (v_n_inputs > 0) THEN
        INSERT INTO HPLAN_TMP_SCOPE (OBJ_NAME, OBJ_TYPE, IS_ICEBERG, SKIP_REASON)
            SELECT DISTINCT o.OBJ_NAME, o.OBJ_TYPE, o.IS_ICEBERG, NULL
              FROM HPLAN_TMP_INPUT i JOIN HPLAN_TMP_OBJECTS o ON o.OBJ_NAME = i.RESOLVED_NAME;
    ELSE
        INSERT INTO HPLAN_TMP_SCOPE (OBJ_NAME, OBJ_TYPE, IS_ICEBERG, SKIP_REASON)
            SELECT OBJ_NAME, OBJ_TYPE, IS_ICEBERG,
                   IFF(IS_ICEBERG, NULL,
                       'Not an Iceberg table (' || CASE OBJ_TYPE WHEN 'BASE TABLE' THEN 'standard table' ELSE LOWER(OBJ_TYPE) END || ')')
              FROM HPLAN_TMP_OBJECTS;
    END IF;

    -- =================================================================================
    -- 3. One table at a time
    -- =================================================================================
    FOR rec_s IN c_scope DO
        v_tbl         := rec_s.OBJ_NAME;
        v_obj_type    := rec_s.OBJ_TYPE;
        v_is_ice      := rec_s.IS_ICEBERG;
        v_skip_reason := rec_s.SKIP_REASON;
        v_cnt_scope   := v_cnt_scope + 1;

        -- 3a. non-Iceberg object: SKIPPED, one current row per object (D13, D15)
        IF (NOT v_is_ice) THEN
            v_plan_id := UUID_STRING();
            DELETE FROM HIST_PLAN_TABLE
             WHERE DATABASE_NAME = :v_db AND SCHEMA_NAME = :v_sch AND TABLE_NAME = :v_tbl AND PLAN_STATUS = 'SKIPPED';
            INSERT INTO HIST_PLAN_TABLE (PLAN_ID, RUN_ID, DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, OBJECT_TYPE,
                                         PLAN_STATUS, STATUS_REASON, IS_ACTIVE, PLANNED_AT)
                VALUES (:v_plan_id, :v_run_id, :v_db, :v_sch, :v_tbl, :v_obj_type,
                        'SKIPPED', :v_skip_reason, TRUE, CURRENT_TIMESTAMP());
            INSERT INTO HPLAN_TMP_SUMMARY (SORT_KEY, TABLE_NAME, OUTCOME, REASON) VALUES (1, :v_tbl, 'SKIPPED', :v_skip_reason);
            v_cnt_skip_ice := v_cnt_skip_ice + 1;
            CONTINUE;
        END IF;

        -- 3b. already planned and not forced: SKIPPED (reported, not written)
        SELECT COUNT(*), MAX(PLAN_ID) INTO :v_n_active_plan, :v_old_plan
          FROM HIST_PLAN_TABLE
         WHERE DATABASE_NAME = :v_db AND SCHEMA_NAME = :v_sch AND TABLE_NAME = :v_tbl
           AND IS_ACTIVE AND PLAN_STATUS = 'PLANNED';
        IF (v_n_active_plan > 0 AND NOT p_force_replan) THEN
            v_msg := 'Already planned (plan ' || v_old_plan || '); set p_force_replan = TRUE to re-plan';
            INSERT INTO HPLAN_TMP_SUMMARY (SORT_KEY, TABLE_NAME, OUTCOME, REASON) VALUES (1, :v_tbl, 'SKIPPED', :v_msg);
            v_cnt_skip_done := v_cnt_skip_done + 1;
            CONTINUE;
        END IF;

        -- 3c. plan this table; any failure is caught below and recorded as FAILED (D6)
        BEGIN
            v_fail_reason := NULL;  v_note := NULL;      v_layer := NULL;      v_axis := 'NONE';
            v_axis_cols   := NULL;  v_axis_expr := NULL; v_verified := NULL;   v_method := NULL;
            v_c1 := NULL; v_c2 := NULL; v_c3 := NULL;
            v_sp_fields := NULL; v_sp_ident := NULL; v_sp_date := NULL; v_sp_y := NULL; v_sp_m := NULL; v_sp_d := NULL;
            v_total_rows := NULL; v_total_bytes := NULL; v_file_count := NULL; v_avg_row := NULL; v_avg_file := NULL;
            v_target_rows := NULL; v_day_count := NULL; v_split_days := 0; v_chunk_count := NULL; v_col_count := NULL;
            v_plan_id     := UUID_STRING();
            v_profiled_at := TO_TIMESTAMP_TZ(CURRENT_TIMESTAMP());
            v_fq          := v_fq_schema || '."' || REPLACE(v_tbl, '"', '""') || '"';
            DELETE FROM HPLAN_TMP_CHUNKS;

            -- columns (standard GRS_* columns only; business columns are never used)
            SELECT COUNT(*),
                   MAX(IFF(UPPER(COLUMN_NAME) = 'GRS_REFINED_TIMESTAMP' AND DATA_TYPE LIKE 'TIMESTAMP%', COLUMN_NAME, NULL)),
                   MAX(IFF(UPPER(COLUMN_NAME) = 'GRS_UNIQUE_ID', COLUMN_NAME, NULL)),
                   MAX(IFF(UPPER(COLUMN_NAME) = 'GRS_PROCESS_DATE'  AND DATA_TYPE = 'DATE',   COLUMN_NAME, NULL)),
                   MAX(IFF(UPPER(COLUMN_NAME) = 'GRS_PROCESS_YEAR'  AND DATA_TYPE = 'NUMBER', COLUMN_NAME, NULL)),
                   MAX(IFF(UPPER(COLUMN_NAME) = 'GRS_PROCESS_MONTH' AND DATA_TYPE = 'NUMBER', COLUMN_NAME, NULL)),
                   MAX(IFF(UPPER(COLUMN_NAME) = 'GRS_PROCESS_DAY'   AND DATA_TYPE = 'NUMBER', COLUMN_NAME, NULL)),
                   COUNT_IF(UPPER(COLUMN_NAME) = 'ROW_HASH'),
                   COUNT_IF(UPPER(COLUMN_NAME) IN ('NEW_ROW_HASH', 'LAST_ROW_HASH'))
              INTO :v_col_count, :v_col_ts, :v_col_uid, :v_col_date, :v_col_y, :v_col_m, :v_col_d, :v_n_rowhash, :v_n_histhash
              FROM HPLAN_TMP_COLS WHERE TABLE_NAME = :v_tbl;
            v_layer := CASE WHEN v_n_histhash = 2 THEN 'HISTORY' WHEN v_n_rowhash = 1 THEN 'CURRENT' ELSE 'UNKNOWN' END;

            -- partition spec (current spec only), mapped to real columns
            IF (v_spec_ok) THEN
                BEGIN
                    v_sql := 'SELECT COUNT(*), COUNT_IF(p.F_TRANSFORM = ''identity''), '
                          || 'MAX(IFF(p.F_TRANSFORM = ''identity'' AND c.DATA_TYPE = ''DATE'', c.COLUMN_NAME, NULL)), '
                          || 'MAX(IFF(p.F_TRANSFORM = ''identity'' AND c.DATA_TYPE = ''NUMBER'' AND UPPER(c.COLUMN_NAME) LIKE ''%YEAR'', c.COLUMN_NAME, NULL)), '
                          || 'MAX(IFF(p.F_TRANSFORM = ''identity'' AND c.DATA_TYPE = ''NUMBER'' AND UPPER(c.COLUMN_NAME) LIKE ''%MONTH'', c.COLUMN_NAME, NULL)), '
                          || 'MAX(IFF(p.F_TRANSFORM = ''identity'' AND c.DATA_TYPE = ''NUMBER'' AND UPPER(c.COLUMN_NAME) LIKE ''%DAY'', c.COLUMN_NAME, NULL)) '
                          || 'FROM (SELECT UPPER(f.value:"name"::VARCHAR) AS F_NAME, LOWER(f.value:"transform"::VARCHAR) AS F_TRANSFORM '
                          || '        FROM HPLAN_TMP_ICE t, '
                          || '             LATERAL FLATTEN(INPUT => TRY_PARSE_JSON(TO_VARCHAR(t."partition_specs"))) s, '
                          || '             LATERAL FLATTEN(INPUT => s.value:"fields") f '
                          || '       WHERE t."name" = ? '
                          || '         AND TO_VARCHAR(s.value:"spec-id") = TO_VARCHAR(t."current_partition_spec_id")) p '
                          || 'LEFT JOIN HPLAN_TMP_COLS c ON c.TABLE_NAME = ? AND UPPER(c.COLUMN_NAME) = p.F_NAME';
                    EXECUTE IMMEDIATE :v_sql USING (v_tbl, v_tbl);
                    SELECT $1, $2, $3, $4, $5, $6 INTO :v_sp_fields, :v_sp_ident, :v_sp_date, :v_sp_y, :v_sp_m, :v_sp_d
                      FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
                EXCEPTION WHEN OTHER THEN
                    v_sp_fields := NULL;
                END;
            END IF;

            -- chunk axis: the first rule that matches wins (design_review.md §4.2)
            IF (COALESCE(v_sp_fields, -1) = 1 AND v_sp_date IS NOT NULL) THEN
                v_axis := 'PARTITION_DAY';  v_c1 := v_sp_date;  v_verified := TRUE;
            ELSEIF (COALESCE(v_sp_fields, -1) = 3 AND v_sp_ident = 3 AND v_sp_y IS NOT NULL AND v_sp_m IS NOT NULL AND v_sp_d IS NOT NULL) THEN
                v_axis := 'PARTITION_YMD';  v_c1 := v_sp_y;  v_c2 := v_sp_m;  v_c3 := v_sp_d;  v_verified := TRUE;
            ELSEIF (v_col_date IS NOT NULL) THEN
                v_axis := 'PARTITION_DAY';  v_c1 := v_col_date;  v_verified := FALSE;
            ELSEIF (v_col_y IS NOT NULL AND v_col_m IS NOT NULL AND v_col_d IS NOT NULL) THEN
                v_axis := 'PARTITION_YMD';  v_c1 := v_col_y;  v_c2 := v_col_m;  v_c3 := v_col_d;  v_verified := FALSE;
            ELSEIF (v_col_ts IS NOT NULL) THEN
                v_axis := 'REFINED_TS_DAY'; v_c1 := v_col_ts;
            ELSEIF (v_col_uid IS NOT NULL) THEN
                v_axis := 'UNIQUE_ID_HASH'; v_c1 := v_col_uid;
            END IF;
            IF (v_verified = FALSE) THEN
                v_note := 'Axis taken from the GRS_PROCESS_* naming convention; the Iceberg partition spec did not confirm it, so file skipping is not guaranteed';
            END IF;
            v_axis_cols := CASE WHEN v_axis = 'PARTITION_YMD' THEN v_c1 || ',' || v_c2 || ',' || v_c3 ELSE v_c1 END;
            v_axis_expr := CASE v_axis
                WHEN 'PARTITION_DAY'  THEN '"' || REPLACE(v_c1, '"', '""') || '"'
                WHEN 'PARTITION_YMD'  THEN 'DATE_FROM_PARTS("' || REPLACE(v_c1, '"', '""') || '", "' || REPLACE(v_c2, '"', '""')
                                           || '", "' || REPLACE(v_c3, '"', '""') || '")'
                WHEN 'REFINED_TS_DAY' THEN 'TO_DATE("' || REPLACE(v_c1, '"', '""') || '")'
                ELSE NULL END;

            -- size: exact row count, plus Iceberg file bytes when readable
            v_sql := 'SELECT COUNT(*) FROM ' || v_fq;
            EXECUTE IMMEDIATE :v_sql;
            SELECT $1 INTO :v_total_rows FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
            BEGIN
                v_fn_arg := REPLACE(v_fq, '''', '''''');
                v_sql := 'SELECT COUNT(*), COALESCE(SUM(FILE_SIZE), 0) FROM TABLE(' || v_q_db
                      || '.INFORMATION_SCHEMA.ICEBERG_TABLE_FILES(TABLE_NAME => ''' || v_fn_arg || '''))';
                EXECUTE IMMEDIATE :v_sql;
                SELECT $1, $2 INTO :v_file_count, :v_total_bytes FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
            EXCEPTION WHEN OTHER THEN
                v_file_count := NULL;
                v_total_bytes := NULL;
                v_note := COALESCE(v_note || ' | ', '') || 'Iceberg file sizes unavailable (' || LEFT(SQLERRM, 200)
                          || '); chunks sized by max_chunk_rows only';
            END;
            v_avg_row  := NULLIF(DIV0NULL(v_total_bytes, v_total_rows), 0);    -- NULL when bytes unknown or the table is empty
            v_avg_file := NULLIF(DIV0NULL(v_total_bytes, v_file_count), 0);
            v_target_rows := IFF(v_avg_row IS NULL, max_chunk_rows, LEAST(max_chunk_rows, FLOOR(target_chunk_bytes / v_avg_row)));
            v_target_rows := GREATEST(1, v_target_rows);

            -- -------------------------------------------------------------------------
            -- build the chunks
            -- -------------------------------------------------------------------------
            IF (v_total_rows <= v_target_rows) THEN
                -- the whole table fits in one chunk
                v_method := 'SINGLE';
                INSERT INTO HPLAN_TMP_CHUNKS (CHUNK_SEQ, CHUNK_TYPE, ESTIMATED_ROWS) VALUES (1, 'ALL', :v_total_rows);

            ELSEIF (v_axis = 'NONE') THEN
                v_fail_reason := 'No usable chunk column: not partitioned on a date, and no GRS_REFINED_TIMESTAMP or GRS_UNIQUE_ID column';
                RAISE e_plan;

            ELSEIF (v_axis = 'UNIQUE_ID_HASH') THEN
                -- no date axis at all: even hash buckets over the whole table
                v_method := 'HASH_BUCKETS';
                v_mod  := CEIL(v_total_rows / v_target_rows);
                v_base := FLOOR(v_total_rows / v_mod);
                v_last := v_mod - 1;
                FOR k IN 0 TO v_last DO
                    v_k := k;
                    v_rows_k := IFF(v_k = v_last, v_total_rows - v_base * v_last, v_base);
                    v_seq := v_k + 1;
                    INSERT INTO HPLAN_TMP_CHUNKS (CHUNK_SEQ, CHUNK_TYPE, SUB_COLUMN, HASH_BUCKET, HASH_MODULUS, ESTIMATED_ROWS)
                        VALUES (:v_seq, 'HASH', :v_c1, :v_k, :v_mod, :v_rows_k);
                END FOR;

            ELSE
                -- rows per axis day (reads only the axis column[s])
                DELETE FROM HPLAN_TMP_DAYS;
                v_sql := 'INSERT INTO HPLAN_TMP_DAYS (PROCESS_DAY, DAY_ROWS) SELECT ' || v_axis_expr || ', COUNT(*) FROM '
                      || v_fq || ' GROUP BY 1';
                EXECUTE IMMEDIATE :v_sql;
                SELECT COUNT_IF(PROCESS_DAY IS NOT NULL), COALESCE(SUM(IFF(PROCESS_DAY IS NULL, DAY_ROWS, 0)), 0)
                  INTO :v_day_count, :v_null_rows FROM HPLAN_TMP_DAYS;

                -- walk the days: group whole days up to the target, split a day that alone exceeds it
                v_seq := 0;  v_open := FALSE;  v_acc := 0;  v_open_start := NULL;  v_next_start := NULL;
                FOR rec_d IN c_days DO
                    v_day      := rec_d.PROCESS_DAY;
                    v_day_rows := rec_d.DAY_ROWS;
                    v_day_next := DATEADD(day, 1, v_day);

                    IF (v_day_rows > v_target_rows) THEN
                        -- close the open day range where this day starts
                        IF (v_open) THEN
                            v_seq := v_seq + 1;
                            INSERT INTO HPLAN_TMP_CHUNKS (CHUNK_SEQ, CHUNK_TYPE, DAY_START, DAY_END, ESTIMATED_ROWS)
                                VALUES (:v_seq, 'DAY_RANGE', :v_open_start, :v_day, :v_acc);
                            v_open := FALSE;  v_acc := 0;
                        END IF;
                        v_split_days := v_split_days + 1;
                        v_day_str := TO_CHAR(v_day, 'YYYY-MM-DD');
                        v_day_pred := CASE v_axis
                            WHEN 'PARTITION_DAY' THEN v_axis_expr || ' = TO_DATE(''' || v_day_str || ''')'
                            WHEN 'PARTITION_YMD' THEN '"' || REPLACE(v_c1, '"', '""') || '" = ' || YEAR(v_day)
                                                   || ' AND "' || REPLACE(v_c2, '"', '""') || '" = ' || MONTH(v_day)
                                                   || ' AND "' || REPLACE(v_c3, '"', '""') || '" = ' || DAY(v_day)
                            ELSE '"' || REPLACE(v_c1, '"', '""') || '" >= TO_TIMESTAMP_TZ(''' || v_day_str
                                 || ' 00:00:00 +00:00'', ''YYYY-MM-DD HH24:MI:SS TZH:TZM'') AND "' || REPLACE(v_c1, '"', '""')
                                 || '" < TO_TIMESTAMP_TZ(''' || TO_CHAR(v_day_next, 'YYYY-MM-DD')
                                 || ' 00:00:00 +00:00'', ''YYYY-MM-DD HH24:MI:SS TZH:TZM'')'
                        END;

                        -- first choice: ranges of GRS_REFINED_TIMESTAMP inside the day
                        v_can_ts := FALSE;
                        IF (v_col_ts IS NOT NULL) THEN
                            DELETE FROM HPLAN_TMP_BKTS;
                            v_sql := 'INSERT INTO HPLAN_TMP_BKTS (BKT, BKT_ROWS) SELECT TO_TIMESTAMP_TZ(DATE_TRUNC(''' || v_grain
                                  || ''', "' || REPLACE(v_col_ts, '"', '""') || '")), COUNT(*) FROM ' || v_fq
                                  || ' WHERE ' || v_day_pred || ' GROUP BY 1';
                            EXECUTE IMMEDIATE :v_sql;
                            SELECT COALESCE(SUM(IFF(BKT IS NULL, BKT_ROWS, 0)), 0), COALESCE(MAX(BKT_ROWS), 0), COALESCE(SUM(BKT_ROWS), 0)
                              INTO :v_bkt_null, :v_bkt_max, :v_bkt_total FROM HPLAN_TMP_BKTS;
                            v_can_ts := (v_bkt_null = 0 AND v_bkt_max <= v_target_rows AND v_bkt_total = v_day_rows);
                        END IF;

                        IF (v_can_ts) THEN
                            v_pacc := 0;  v_piece_start := NULL;
                            FOR rec_b IN c_bkts DO
                                v_bkt      := rec_b.BKT;
                                v_bkt_rows := rec_b.BKT_ROWS;
                                IF (v_pacc > 0 AND v_pacc + v_bkt_rows > v_target_rows) THEN
                                    v_seq := v_seq + 1;
                                    INSERT INTO HPLAN_TMP_CHUNKS (CHUNK_SEQ, CHUNK_TYPE, DAY_START, DAY_END, SUB_COLUMN,
                                                                  SUB_START_TS, SUB_END_TS, ESTIMATED_ROWS)
                                        VALUES (:v_seq, 'DAY_SUBRANGE', :v_day, :v_day_next, :v_col_ts, :v_piece_start, :v_bkt, :v_pacc);
                                    v_piece_start := v_bkt;  v_pacc := v_bkt_rows;
                                ELSE
                                    v_pacc := v_pacc + v_bkt_rows;
                                END IF;
                            END FOR;
                            v_seq := v_seq + 1;
                            INSERT INTO HPLAN_TMP_CHUNKS (CHUNK_SEQ, CHUNK_TYPE, DAY_START, DAY_END, SUB_COLUMN,
                                                          SUB_START_TS, SUB_END_TS, ESTIMATED_ROWS)
                                VALUES (:v_seq, 'DAY_SUBRANGE', :v_day, :v_day_next, :v_col_ts, :v_piece_start, NULL, :v_pacc);

                        ELSEIF (v_col_uid IS NOT NULL) THEN
                            -- fallback: even hash buckets on GRS_UNIQUE_ID inside the day
                            v_mod  := CEIL(v_day_rows / v_target_rows);
                            v_base := FLOOR(v_day_rows / v_mod);
                            v_last := v_mod - 1;
                            FOR k IN 0 TO v_last DO
                                v_k := k;
                                v_hash_rows := IFF(v_k = v_last, v_day_rows - v_base * v_last, v_base);
                                v_seq := v_seq + 1;
                                INSERT INTO HPLAN_TMP_CHUNKS (CHUNK_SEQ, CHUNK_TYPE, DAY_START, DAY_END, SUB_COLUMN,
                                                              HASH_BUCKET, HASH_MODULUS, ESTIMATED_ROWS)
                                    VALUES (:v_seq, 'DAY_HASH', :v_day, :v_day_next, :v_col_uid, :v_k, :v_mod, :v_hash_rows);
                            END FOR;

                        ELSE
                            v_fail_reason := 'Day ' || v_day_str || ' holds ' || v_day_rows || ' rows (target ' || v_target_rows
                                          || ') and cannot be split: GRS_REFINED_TIMESTAMP does not spread it and there is no GRS_UNIQUE_ID';
                            RAISE e_plan;
                        END IF;
                        v_next_start := v_day_next;     -- the next day range starts where this split day ends

                    ELSEIF (v_open AND v_acc + v_day_rows > v_target_rows) THEN
                        -- this day would overflow the open range: close it, start a new one here
                        v_seq := v_seq + 1;
                        INSERT INTO HPLAN_TMP_CHUNKS (CHUNK_SEQ, CHUNK_TYPE, DAY_START, DAY_END, ESTIMATED_ROWS)
                            VALUES (:v_seq, 'DAY_RANGE', :v_open_start, :v_day, :v_acc);
                        v_open_start := v_day;  v_acc := v_day_rows;

                    ELSEIF (v_open) THEN
                        v_acc := v_acc + v_day_rows;

                    ELSE
                        v_open := TRUE;  v_acc := v_day_rows;
                        v_open_start := COALESCE(v_next_start, v_day);  v_next_start := NULL;
                    END IF;
                END FOR;

                IF (v_open) THEN
                    v_seq := v_seq + 1;
                    INSERT INTO HPLAN_TMP_CHUNKS (CHUNK_SEQ, CHUNK_TYPE, DAY_START, DAY_END, ESTIMATED_ROWS)
                        VALUES (:v_seq, 'DAY_RANGE', :v_open_start, NULL, :v_acc);      -- last range: open end
                END IF;
                UPDATE HPLAN_TMP_CHUNKS SET DAY_START = NULL WHERE CHUNK_SEQ = 1 AND CHUNK_TYPE = 'DAY_RANGE';  -- first range: open start
                IF (v_null_rows > 0) THEN
                    v_seq := v_seq + 1;
                    INSERT INTO HPLAN_TMP_CHUNKS (CHUNK_SEQ, CHUNK_TYPE, ESTIMATED_ROWS) VALUES (:v_seq, 'NULL_VALUES', :v_null_rows);
                END IF;
                v_method := IFF(v_split_days > 0, 'DAY_RANGES_WITH_SPLITS', 'DAY_RANGES');
            END IF;

            -- every row must be in exactly one chunk: the chunk rows must add up to the table
            SELECT COUNT(*), COALESCE(SUM(ESTIMATED_ROWS), 0) INTO :v_chunk_count, :v_sum_rows FROM HPLAN_TMP_CHUNKS;
            IF (v_sum_rows <> v_total_rows) THEN
                v_fail_reason := 'Row-sum check failed: chunks add up to ' || v_sum_rows || ' rows but the table has '
                              || v_total_rows || ' (did the table change while it was being planned?)';
                RAISE e_plan;
            END IF;
            UPDATE HPLAN_TMP_CHUNKS SET ESTIMATED_BYTES = IFF(:v_avg_row IS NULL, NULL, ROUND(ESTIMATED_ROWS * :v_avg_row));

            -- write: supersede the old plan, insert the new one, in one transaction
            BEGIN TRANSACTION;
            UPDATE HIST_PLAN_TABLE
               SET IS_ACTIVE = FALSE,
                   PLAN_STATUS = IFF(PLAN_STATUS IN ('PLANNED', 'FAILED'), 'SUPERSEDED', PLAN_STATUS)
             WHERE DATABASE_NAME = :v_db AND SCHEMA_NAME = :v_sch AND TABLE_NAME = :v_tbl AND IS_ACTIVE;
            INSERT INTO HIST_PLAN_TABLE (PLAN_ID, RUN_ID, DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, OBJECT_TYPE, LAYER,
                    CHUNK_AXIS, AXIS_COLUMNS, PARTITION_VERIFIED, CHUNK_METHOD, PROFILED_AT, TOTAL_ROWS, TOTAL_BYTES,
                    COLUMN_COUNT, AVG_ROW_BYTES, FILE_COUNT, AVG_FILE_BYTES, DAY_COUNT, SPLIT_DAY_COUNT, CHUNK_COUNT,
                    TARGET_CHUNK_BYTES, TARGET_ROWS_PER_CHUNK, PLAN_STATUS, STATUS_REASON, IS_ACTIVE, PLANNED_AT)
                VALUES (:v_plan_id, :v_run_id, :v_db, :v_sch, :v_tbl, :v_obj_type, :v_layer,
                    :v_axis, :v_axis_cols, :v_verified, :v_method, :v_profiled_at, :v_total_rows, :v_total_bytes,
                    :v_col_count, :v_avg_row, :v_file_count, :v_avg_file, :v_day_count, :v_split_days, :v_chunk_count,
                    :target_chunk_bytes, :v_target_rows, 'PLANNED', :v_note, TRUE, CURRENT_TIMESTAMP());
            INSERT INTO HIST_PLAN_CHUNK (PLAN_ID, CHUNK_SEQ, DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, CHUNK_TYPE,
                    DAY_START, DAY_END, SUB_COLUMN, SUB_START_TS, SUB_END_TS, HASH_BUCKET, HASH_MODULUS,
                    ESTIMATED_ROWS, ESTIMATED_BYTES)
                SELECT :v_plan_id, CHUNK_SEQ, :v_db, :v_sch, :v_tbl, CHUNK_TYPE,
                       DAY_START, DAY_END, SUB_COLUMN, SUB_START_TS, SUB_END_TS, HASH_BUCKET, HASH_MODULUS,
                       ESTIMATED_ROWS, ESTIMATED_BYTES
                  FROM HPLAN_TMP_CHUNKS;
            COMMIT;

            INSERT INTO HPLAN_TMP_SUMMARY VALUES (3, :v_tbl, 'PLANNED', :v_note, :v_layer, :v_axis, :v_method,
                                                  :v_chunk_count, :v_total_rows, :v_total_bytes);
            v_cnt_planned := v_cnt_planned + 1;

        EXCEPTION
            WHEN OTHER THEN
                ROLLBACK;
                v_msg := LEFT(COALESCE(v_fail_reason, 'Error: ' || SQLERRM), 4000);
                -- keep an older successful plan active if this was a forced re-plan that failed
                UPDATE HIST_PLAN_TABLE SET IS_ACTIVE = FALSE, PLAN_STATUS = 'SUPERSEDED'
                 WHERE DATABASE_NAME = :v_db AND SCHEMA_NAME = :v_sch AND TABLE_NAME = :v_tbl
                   AND IS_ACTIVE AND PLAN_STATUS = 'FAILED';
                SELECT COUNT(*) INTO :v_n_active_plan FROM HIST_PLAN_TABLE
                 WHERE DATABASE_NAME = :v_db AND SCHEMA_NAME = :v_sch AND TABLE_NAME = :v_tbl
                   AND IS_ACTIVE AND PLAN_STATUS = 'PLANNED';
                v_fail_active := (v_n_active_plan = 0);
                INSERT INTO HIST_PLAN_TABLE (PLAN_ID, RUN_ID, DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, OBJECT_TYPE, LAYER,
                        CHUNK_AXIS, AXIS_COLUMNS, PARTITION_VERIFIED, PROFILED_AT, TOTAL_ROWS, TOTAL_BYTES, COLUMN_COUNT,
                        AVG_ROW_BYTES, FILE_COUNT, AVG_FILE_BYTES, TARGET_CHUNK_BYTES, TARGET_ROWS_PER_CHUNK,
                        PLAN_STATUS, STATUS_REASON, IS_ACTIVE, PLANNED_AT)
                    VALUES (:v_plan_id, :v_run_id, :v_db, :v_sch, :v_tbl, :v_obj_type, :v_layer,
                        :v_axis, :v_axis_cols, :v_verified, :v_profiled_at, :v_total_rows, :v_total_bytes, :v_col_count,
                        :v_avg_row, :v_file_count, :v_avg_file, :target_chunk_bytes, :v_target_rows,
                        'FAILED', :v_msg, :v_fail_active, CURRENT_TIMESTAMP());
                INSERT INTO HPLAN_TMP_SUMMARY VALUES (2, :v_tbl, 'FAILED', :v_msg, :v_layer, :v_axis, NULL,
                                                      NULL, :v_total_rows, :v_total_bytes);
                v_cnt_failed := v_cnt_failed + 1;
        END;
    END FOR;

    -- =================================================================================
    -- 4. Result grid: one row per table, then a summary row
    -- =================================================================================
    v_msg := 'Objects in scope: ' || v_cnt_scope || ' | Planned: ' || v_cnt_planned || ' | Failed: ' || v_cnt_failed
          || ' | Skipped: ' || (v_cnt_skip_ice + v_cnt_skip_done) || ' (non-Iceberg: ' || v_cnt_skip_ice
          || ', already planned: ' || v_cnt_skip_done || ')'
          || ' | Target: ' || ROUND(target_chunk_bytes / 1073741824, 2) || ' GB / ' || max_chunk_rows || ' rows max per chunk'
          || ' | Partition spec readable: ' || IFF(v_spec_ok, 'yes', 'no (naming fallback)')
          || ' | Run ' || v_run_id;
    INSERT INTO HPLAN_TMP_SUMMARY (SORT_KEY, TABLE_NAME, OUTCOME, REASON) VALUES (9, '*** SUMMARY ***', 'COMPLETED', :v_msg);
    res := (SELECT TABLE_NAME, OUTCOME, REASON, LAYER, CHUNK_AXIS, CHUNK_METHOD, CHUNK_COUNT, TOTAL_ROWS, TOTAL_BYTES
              FROM HPLAN_TMP_SUMMARY ORDER BY SORT_KEY, TABLE_NAME);
    RETURN TABLE(res);
END;
