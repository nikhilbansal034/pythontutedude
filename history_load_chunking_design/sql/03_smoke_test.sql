-- =====================================================================================
-- 03_smoke_test.sql — prove every scripting construct the planner relies on
-- =====================================================================================
-- Anonymous block. Run AFTER 01 and 02. Returns one row per check:
--   PASS = works as the planner needs.
--   INFO = optional capability; the planner has a fallback (explained in DETAIL).
--   FAIL = the planner will hit the same problem; share the screenshot before going further.
-- Nothing here writes to the metadata tables (check 11 only reads HIST_PLAN_TABLE).
-- =====================================================================================
DECLARE
    metadata_database VARCHAR DEFAULT 'test_db';
    metadata_schema   VARCHAR DEFAULT 'test_schema';
    test_database     VARCHAR DEFAULT 'TEST_DB';
    test_schema_src   VARCHAR DEFAULT 'CHUNK_TEST_SRC';

    v_sql       VARCHAR;
    v_n         NUMBER;
    v_a         NUMBER DEFAULT 2;
    v_b         NUMBER DEFAULT 3;
    v_k         NUMBER;
    v_last      NUMBER DEFAULT 2;
    v_txt       VARCHAR;
    v_first_ice VARCHAR;
    v_ts        TIMESTAMP_TZ;
    v_d         DATE;
    v_ok        BOOLEAN;
    res         RESULTSET;
    e_test      EXCEPTION (-20001, 'Deliberate test exception');
    c_probe     CURSOR FOR SELECT N FROM SMOKE_TMP_PROBE ORDER BY N;
BEGIN
    -- 1. session settings + USE inside a block
    ALTER SESSION SET TIMEZONE = 'UTC';
    v_sql := 'USE SCHEMA ' || metadata_database || '.' || metadata_schema;
    EXECUTE IMMEDIATE :v_sql;
    CREATE OR REPLACE TEMPORARY TABLE SMOKE_TMP_RESULTS (CHECK_NO NUMBER, CHECK_NAME VARCHAR, RESULT VARCHAR, DETAIL VARCHAR);
    v_txt := CURRENT_DATABASE() || '.' || CURRENT_SCHEMA() || ', TIMEZONE = UTC';
    INSERT INTO SMOKE_TMP_RESULTS VALUES (1, 'ALTER SESSION and USE SCHEMA inside a block', 'PASS', :v_txt);

    -- 2. cursor declared up front, over a temp table created inside the block
    BEGIN
        CREATE OR REPLACE TEMPORARY TABLE SMOKE_TMP_PROBE (N NUMBER);
        INSERT INTO SMOKE_TMP_PROBE VALUES (1), (2), (3);
        v_n := 0;
        FOR r IN c_probe DO
            v_n := v_n + r.N;
        END FOR;
        v_txt := IFF(v_n = 6, 'PASS', 'FAIL');
        INSERT INTO SMOKE_TMP_RESULTS VALUES (2, 'FOR loop over a cursor on a temp table built in the block', :v_txt, 'sum = ' || :v_n || ' (expect 6)');
    EXCEPTION WHEN OTHER THEN
        v_txt := SQLERRM;
        INSERT INTO SMOKE_TMP_RESULTS VALUES (2, 'FOR loop over a cursor on a temp table built in the block', 'FAIL', :v_txt);
    END;

    -- 3. SHOW + RESULT_SCAN(LAST_QUERY_ID())
    BEGIN
        v_sql := 'SHOW DATABASES LIKE ''' || test_database || '''';
        EXECUTE IMMEDIATE :v_sql;
        SELECT COUNT(*) INTO :v_n FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        v_txt := IFF(v_n >= 1, 'PASS', 'FAIL');
        INSERT INTO SMOKE_TMP_RESULTS VALUES (3, 'SHOW via EXECUTE IMMEDIATE, read with RESULT_SCAN(LAST_QUERY_ID())', :v_txt, 'databases matched: ' || :v_n);
    EXCEPTION WHEN OTHER THEN
        v_txt := SQLERRM;
        INSERT INTO SMOKE_TMP_RESULTS VALUES (3, 'SHOW via EXECUTE IMMEDIATE, read with RESULT_SCAN(LAST_QUERY_ID())', 'FAIL', :v_txt);
    END;

    -- 4. EXECUTE IMMEDIATE ... USING (bind variables)
    BEGIN
        v_sql := 'SELECT ? + ?';
        EXECUTE IMMEDIATE :v_sql USING (v_a, v_b);
        SELECT $1 INTO :v_n FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        v_txt := IFF(v_n = 5, 'PASS', 'FAIL');
        INSERT INTO SMOKE_TMP_RESULTS VALUES (4, 'EXECUTE IMMEDIATE ... USING (binds)', :v_txt, '2 + 3 = ' || :v_n);
    EXCEPTION WHEN OTHER THEN
        v_txt := SQLERRM;
        INSERT INTO SMOKE_TMP_RESULTS VALUES (4, 'EXECUTE IMMEDIATE ... USING (binds)', 'FAIL', :v_txt);
    END;

    -- 5. custom exception caught by WHEN OTHER in a nested block; run continues
    BEGIN
        v_txt := 'reason set before raise';
        BEGIN
            RAISE e_test;
        EXCEPTION WHEN OTHER THEN
            v_txt := v_txt || ' | caught: ' || SQLERRM;
        END;
        v_ok := (v_txt LIKE '%caught%');
        v_sql := IFF(v_ok, 'PASS', 'FAIL');
        INSERT INTO SMOKE_TMP_RESULTS VALUES (5, 'Per-table failure isolation (RAISE + WHEN OTHER, then continue)', :v_sql, :v_txt);
    EXCEPTION WHEN OTHER THEN
        v_txt := SQLERRM;
        INSERT INTO SMOKE_TMP_RESULTS VALUES (5, 'Per-table failure isolation (RAISE + WHEN OTHER, then continue)', 'FAIL', :v_txt);
    END;

    -- 6. explicit transaction + ROLLBACK inside a block
    BEGIN
        BEGIN TRANSACTION;
        INSERT INTO SMOKE_TMP_PROBE VALUES (100);
        ROLLBACK;
        SELECT COUNT(*) INTO :v_n FROM SMOKE_TMP_PROBE WHERE N = 100;
        v_txt := IFF(v_n = 0, 'PASS', 'FAIL');
        INSERT INTO SMOKE_TMP_RESULTS VALUES (6, 'BEGIN TRANSACTION / ROLLBACK inside a block', :v_txt, 'rows left after rollback: ' || :v_n || ' (expect 0)');
    EXCEPTION WHEN OTHER THEN
        v_txt := SQLERRM;
        INSERT INTO SMOKE_TMP_RESULTS VALUES (6, 'BEGIN TRANSACTION / ROLLBACK inside a block', 'FAIL', :v_txt);
    END;

    -- 7. expressions the planner assigns directly
    BEGIN
        v_txt := UUID_STRING();
        v_ts  := TO_TIMESTAMP_TZ(CURRENT_TIMESTAMP());
        v_d   := DATEADD(day, 1, TO_DATE('2026-03-10'));
        v_sql := 'Y=' || YEAR(v_d) || ' M=' || MONTH(v_d) || ' D=' || DAY(v_d) || ' | ' || TO_CHAR(v_d, 'YYYY-MM-DD');
        v_n := 0;
        FOR k IN 0 TO v_last DO
            v_k := k;
            v_n := v_n + v_k;
        END FOR;
        v_ok := (v_sql = 'Y=2026 M=3 D=11 | 2026-03-11' AND v_n = 3 AND LENGTH(v_txt) = 36);
        v_txt := IFF(v_ok, 'PASS', 'FAIL');
        v_sql := v_sql || ' | counter sum ' || v_n || ' | ts ' || TO_CHAR(v_ts, 'YYYY-MM-DD HH24:MI:SS TZH:TZM');
        INSERT INTO SMOKE_TMP_RESULTS VALUES (7, 'Scripting expressions (UUID, DATEADD, YEAR/MONTH/DAY, FOR counter)', :v_txt, :v_sql);
    EXCEPTION WHEN OTHER THEN
        v_txt := SQLERRM;
        INSERT INTO SMOKE_TMP_RESULTS VALUES (7, 'Scripting expressions (UUID, DATEADD, YEAR/MONTH/DAY, FOR counter)', 'FAIL', :v_txt);
    END;

    -- 8. SHOW ICEBERG TABLES -> temp table (the planner's discovery step)
    BEGIN
        v_sql := 'SHOW ICEBERG TABLES IN SCHEMA ' || test_database || '.' || test_schema_src;
        EXECUTE IMMEDIATE :v_sql;
        CREATE OR REPLACE TEMPORARY TABLE SMOKE_TMP_ICE AS SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        SELECT COUNT(*), MIN("name") INTO :v_n, :v_first_ice FROM SMOKE_TMP_ICE;
        v_txt := IFF(v_n = 9, 'PASS', 'FAIL');
        INSERT INTO SMOKE_TMP_RESULTS VALUES (8, 'SHOW ICEBERG TABLES captured into a temp table', :v_txt, 'Iceberg tables found: ' || :v_n || ' (expect 9 after 02_test_setup)');
    EXCEPTION WHEN OTHER THEN
        v_txt := SQLERRM;
        INSERT INTO SMOKE_TMP_RESULTS VALUES (8, 'SHOW ICEBERG TABLES captured into a temp table', 'FAIL', :v_txt);
    END;

    -- 9. partition_specs in SHOW ICEBERG TABLES output (optional — naming fallback otherwise)
    BEGIN
        v_sql := 'SELECT LISTAGG("name" || '': '' || COALESCE(TO_VARCHAR("partition_specs"), ''(null)''), '' | '') '
              || 'WITHIN GROUP (ORDER BY "name") FROM SMOKE_TMP_ICE';
        EXECUTE IMMEDIATE :v_sql;
        SELECT $1 INTO :v_txt FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        v_txt := LEFT(v_txt, 3000);
        INSERT INTO SMOKE_TMP_RESULTS VALUES (9, 'partition_specs column available (planner sets PARTITION_VERIFIED = TRUE)', 'PASS', :v_txt);
    EXCEPTION WHEN OTHER THEN
        v_txt := 'Not available: ' || SQLERRM || ' -> planner uses the GRS_PROCESS_* naming fallback, PARTITION_VERIFIED = FALSE';
        INSERT INTO SMOKE_TMP_RESULTS VALUES (9, 'partition_specs column available (planner sets PARTITION_VERIFIED = TRUE)', 'INFO', :v_txt);
    END;

    -- 10. ICEBERG_TABLE_FILES (optional — sizing falls back to the row cap otherwise)
    BEGIN
        v_sql := 'SELECT COUNT(*), COALESCE(SUM(FILE_SIZE), 0) FROM TABLE(' || test_database
              || '.INFORMATION_SCHEMA.ICEBERG_TABLE_FILES(TABLE_NAME => ''' || test_database || '.' || test_schema_src
              || '.' || v_first_ice || '''))';
        EXECUTE IMMEDIATE :v_sql;
        SELECT $1 || ' files, ' || $2 || ' bytes' INTO :v_txt FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        v_txt := v_first_ice || ': ' || v_txt;
        INSERT INTO SMOKE_TMP_RESULTS VALUES (10, 'INFORMATION_SCHEMA.ICEBERG_TABLE_FILES readable', 'PASS', :v_txt);
    EXCEPTION WHEN OTHER THEN
        v_txt := 'Not available: ' || SQLERRM || ' -> planner sizes chunks by max_chunk_rows only';
        INSERT INTO SMOKE_TMP_RESULTS VALUES (10, 'INFORMATION_SCHEMA.ICEBERG_TABLE_FILES readable', 'INFO', :v_txt);
    END;

    -- 11. static, unqualified reference to the metadata table after USE SCHEMA
    BEGIN
        SELECT COUNT(*) INTO :v_n FROM HIST_PLAN_TABLE;
        INSERT INTO SMOKE_TMP_RESULTS VALUES (11, 'Metadata table HIST_PLAN_TABLE reachable (run 01 first)', 'PASS', 'rows today: ' || :v_n);
    EXCEPTION WHEN OTHER THEN
        v_txt := SQLERRM;
        INSERT INTO SMOKE_TMP_RESULTS VALUES (11, 'Metadata table HIST_PLAN_TABLE reachable (run 01 first)', 'FAIL', :v_txt);
    END;

    -- 12. SPLIT_TO_TABLE with a bound variable (input table list parsing)
    BEGIN
        v_txt := ' A , b,, "c" ';
        SELECT COUNT(*) INTO :v_n FROM TABLE(SPLIT_TO_TABLE(:v_txt, ',')) s WHERE TRIM(s.VALUE) <> '';
        v_sql := IFF(v_n = 3, 'PASS', 'FAIL');
        INSERT INTO SMOKE_TMP_RESULTS VALUES (12, 'Input list parsing (SPLIT_TO_TABLE on a variable)', :v_sql, 'non-empty names: ' || :v_n || ' (expect 3)');
    EXCEPTION WHEN OTHER THEN
        v_txt := SQLERRM;
        INSERT INTO SMOKE_TMP_RESULTS VALUES (12, 'Input list parsing (SPLIT_TO_TABLE on a variable)', 'FAIL', :v_txt);
    END;

    -- Evidence E03
    res := (SELECT CHECK_NO, CHECK_NAME, RESULT, DETAIL FROM SMOKE_TMP_RESULTS ORDER BY CHECK_NO);
    RETURN TABLE(res);
END;
