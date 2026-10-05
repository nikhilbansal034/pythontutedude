-- =====================================================================================
-- 06_reset_test_metadata.sql — clear the planner's rows for the TEST schema only
-- =====================================================================================
-- Use when you want to repeat the test runs from a clean state (TEST_PLAN.md).
-- Touches only rows for CHUNK_TEST_SRC; other planned schemas are left alone.
-- =====================================================================================
USE SCHEMA test_db.test_schema;

DELETE FROM HIST_PLAN_CHUNK
 WHERE UPPER(DATABASE_NAME) = 'TEST_DB' AND UPPER(SCHEMA_NAME) = 'CHUNK_TEST_SRC';

DELETE FROM HIST_PLAN_TABLE
 WHERE UPPER(DATABASE_NAME) = 'TEST_DB' AND UPPER(SCHEMA_NAME) = 'CHUNK_TEST_SRC';

-- Expect 0 and 0
SELECT (SELECT COUNT(*) FROM HIST_PLAN_TABLE WHERE UPPER(SCHEMA_NAME) = 'CHUNK_TEST_SRC') AS PLAN_ROWS_LEFT,
       (SELECT COUNT(*) FROM HIST_PLAN_CHUNK WHERE UPPER(SCHEMA_NAME) = 'CHUNK_TEST_SRC') AS CHUNK_ROWS_LEFT;
