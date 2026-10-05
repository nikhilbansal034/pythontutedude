-- =====================================================================================
-- 06_reset_test_metadata.sql — clear the planner's rows for the TEST schema only
-- =====================================================================================
-- Use when you want to repeat the test runs from a clean state (TEST_PLAN.md).
-- Touches only rows for the test schema set below; other planned schemas are left alone.
-- =====================================================================================
SET meta_location = 'test_db.test_schema';   -- where the plan tables live (01)
SET src_database  = 'TEST_DB';               -- the test schema whose plan rows are cleared
SET src_schema    = 'CHUNK_TEST_SRC';

USE SCHEMA IDENTIFIER($meta_location);

DELETE FROM HIST_PLAN_CHUNK
 WHERE UPPER(DATABASE_NAME) = UPPER($src_database) AND UPPER(SCHEMA_NAME) = UPPER($src_schema);

DELETE FROM HIST_PLAN_TABLE
 WHERE UPPER(DATABASE_NAME) = UPPER($src_database) AND UPPER(SCHEMA_NAME) = UPPER($src_schema);

-- Expect 0 and 0
SELECT (SELECT COUNT(*) FROM HIST_PLAN_TABLE
         WHERE UPPER(DATABASE_NAME) = UPPER($src_database) AND UPPER(SCHEMA_NAME) = UPPER($src_schema)) AS PLAN_ROWS_LEFT,
       (SELECT COUNT(*) FROM HIST_PLAN_CHUNK
         WHERE UPPER(DATABASE_NAME) = UPPER($src_database) AND UPPER(SCHEMA_NAME) = UPPER($src_schema)) AS CHUNK_ROWS_LEFT;
