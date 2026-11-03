-- ==========================================================================
-- W6 / R3 - CAN A SNOWFLAKE SQL UDF BODY REFERENCE A SEQUENCE?
-- ==========================================================================
-- This is THE blocking unknown for the whole design. Snowflake's docs do not
-- answer it: "sequence" appears nowhere in CREATE FUNCTION, Introduction to
-- SQL UDFs, or SQL UDF limitations, and Using Sequences never mentions UDFs.
-- It is not excluded by "DDL and DML operations are not supported in UDFs",
-- because consuming a sequence is neither DDL nor DML.
--
-- Run this FIRST. Everything else in W6 is wasted effort until T1.3 is known.
-- Expected runtime: under a minute. Needs CREATE SEQUENCE + CREATE FUNCTION.
--
-- Record each result in the tracker. Do not infer the outcome of one test
-- from another: the silent-failure case (T1.3c) looks like success.
-- ==========================================================================

-- Set these to a scratch database/schema. Nothing here touches real objects.
-- USE SCHEMA <scratch_db>.<scratch_schema>;

-- --------------------------------------------------------------------------
-- SETUP
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE w6_test_seq START 1 INCREMENT 1;

-- --------------------------------------------------------------------------
-- T1.1  Baseline: NEXTVAL works here at all, outside any function.
--       If this fails, the problem is privileges, not the design.
-- --------------------------------------------------------------------------
SELECT w6_test_seq.NEXTVAL AS baseline_value;
-- EXPECT: one row, a number. ---------------------------------------- PASS/FAIL

-- --------------------------------------------------------------------------
-- T1.2  Does the UDF even CREATE with a sequence in its body?
--       This is the first point of truth.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION w6_seq_in_udf()
RETURNS NUMBER(38,0)
VOLATILE                       -- never IMMUTABLE here; see 04_r10_*.sql
AS
$$
    w6_test_seq.NEXTVAL
$$;
-- EXPECT (a): "Function W6_SEQ_IN_UDF successfully created."  -> go to T1.3
-- EXPECT (b): a compilation error                             -> R3 IMPOSSIBLE
--             as a SQL UDF. Record the exact error text, then stop and go to
--             03_r3_fallbacks.sql.
-- ------------------------------------------------------------------ PASS/FAIL

-- --------------------------------------------------------------------------
-- T1.3  THE DECISIVE TEST. Creating is not enough - it must return a
--       DIFFERENT value per row. Three outcomes, and one of them is a trap.
-- --------------------------------------------------------------------------
SELECT seq_no, w6_seq_in_udf() AS generated_key
FROM (SELECT ROW_NUMBER() OVER (ORDER BY 1) AS seq_no
      FROM TABLE(GENERATOR(ROWCOUNT => 10)))
ORDER BY seq_no;
-- EXPECT (a) 10 DISTINCT values            -> R3 ACHIEVED. Proceed to test 02.
-- EXPECT (b) an error at run time          -> R3 impossible. Record the text.
-- EXPECT (c) 10 IDENTICAL values           -> WORST CASE, and SILENT. The body
--            was folded to a constant. R3 is unusable as a scalar UDF even
--            though CREATE succeeded. This is why T1.2 passing is not enough.
-- ------------------------------------------------------------------ PASS/FAIL

-- --------------------------------------------------------------------------
-- T1.4  Make T1.3 machine-checkable rather than eyeballed.
-- --------------------------------------------------------------------------
WITH generated AS (
    SELECT w6_seq_in_udf() AS k FROM TABLE(GENERATOR(ROWCOUNT => 100))
)
SELECT COUNT(*)                        AS rows_generated,
       COUNT(DISTINCT k)               AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT k)    AS duplicates,
       MIN(k)                          AS min_key,
       MAX(k)                          AS max_key,
       CASE WHEN COUNT(DISTINCT k) = COUNT(*) THEN 'PASS - one key per row'
            WHEN COUNT(DISTINCT k) = 1        THEN 'FAIL - folded to a constant'
            ELSE 'FAIL - partial duplication' END AS verdict
FROM generated;
-- EXPECT: rows_generated = 100, distinct_keys = 100, duplicates = 0.
-- NOTE: gaps between min and max are EXPECTED and are not a failure -
-- "Snowflake does not guarantee generating sequence numbers without gaps."
-- ------------------------------------------------------------------ PASS/FAIL

-- --------------------------------------------------------------------------
-- T1.5  How many values did 100 rows actually consume? If the UDF is invoked
--       more than once per row, consumption outruns the row count.
-- --------------------------------------------------------------------------
SELECT w6_test_seq.NEXTVAL AS next_after_100_rows;
-- EXPECT: roughly 100 ahead of T1.4's max_key. Materially higher means extra
-- invocations; record the number rather than judging it here.
-- ------------------------------------------------------------------ PASS/FAIL

-- --------------------------------------------------------------------------
-- T1.6  Does it still work nested inside a MERGE source, which is where Q2
--       actually calls it? A UDF valid in a bare SELECT can still be rejected
--       in a MERGE USING projection.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE w6_merge_target (ID NUMBER(38,0), BK VARCHAR(10));
CREATE OR REPLACE TABLE w6_merge_stage  (BK VARCHAR(10), CHANGE_FLAG VARCHAR(1));
INSERT INTO w6_merge_stage VALUES ('A','0'), ('B','0'), ('C','0');

MERGE INTO w6_merge_target tgt
USING (
    SELECT CAST(CASE WHEN stg.CHANGE_FLAG = '0' THEN w6_seq_in_udf() END AS NUMBER(38,0)) AS ID,
           stg.BK,
           stg.CHANGE_FLAG
    FROM w6_merge_stage stg
) src
ON tgt.ID = src.ID AND src.CHANGE_FLAG <> '0'
WHEN NOT MATCHED AND src.CHANGE_FLAG = '0' THEN INSERT (ID, BK) VALUES (src.ID, src.BK);

SELECT COUNT(*) AS rows_inserted, COUNT(DISTINCT ID) AS distinct_ids,
       CASE WHEN COUNT(*) = 3 AND COUNT(DISTINCT ID) = 3 THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM w6_merge_target;
-- EXPECT: 3 rows, 3 distinct IDs. This mirrors Q2 line 50 exactly.
-- ------------------------------------------------------------------ PASS/FAIL

-- --------------------------------------------------------------------------
-- TEARDOWN
-- --------------------------------------------------------------------------
DROP FUNCTION IF EXISTS w6_seq_in_udf();
DROP TABLE    IF EXISTS w6_merge_target;
DROP TABLE    IF EXISTS w6_merge_stage;
DROP SEQUENCE IF EXISTS w6_test_seq;

-- ==========================================================================
-- DECISION TABLE - what the result means for the design
-- ==========================================================================
-- T1.2 fails                  -> R3 impossible in a SQL UDF.
--                                Go to 03_r3_fallbacks.sql. R2's signature
--                                cannot be kept with NEXTVAL inside a UDF.
-- T1.2 passes, T1.3 = (c)      -> Same conclusion as above, but SILENT.
--                                Treat as a hard failure. Do not build on it.
-- T1.2 + T1.3 + T1.6 all pass  -> R3 ACHIEVED. The branch-selector design in
--                                02_r2_sequence_name_binding.sql is viable.
-- T1.6 fails alone             -> Works in SELECT but not MERGE. The design
--                                survives only if Q2 is restructured to stage
--                                keys in a prior SELECT.
-- ==========================================================================
