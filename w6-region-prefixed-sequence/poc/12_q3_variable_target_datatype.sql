-- ==========================================================================
-- W6 / Q3 - THE TARGET COLUMN DATATYPE IS NOT ALWAYS NUMBER(38,0)
-- ==========================================================================
-- Nidwika, Q3: "EMPLOYEE_ID NUMBER(38,0) is applicable only to this provided
-- reference SQL. We can have any other column applicable for other tables and
-- the datatype could be VARCHAR as well. So this POC should consider CAST
-- should happen as per target column datatype."
--
-- This reopens R6. Every test so far assumed one numeric key column. The
-- reference Q2 alone casts 27 columns to VARCHAR, so the point is real.
--
-- The difficulty: a SQL UDF has exactly ONE declared return type, and R6's run
-- proved the BASE TYPE is enforced at CREATE (precision and length are not).
-- So one function cannot return NUMBER for one table and VARCHAR for another.
--
--   T12.1  Confirm one function cannot serve both base types
--   T12.2  Close off passing the target type as a parameter
--   T12.3  Scheme C - zero-padded VARCHAR - at twelve regions
--   T12.4  Does the TARGET column's VARCHAR length bite?
--   T12.5  Option 1 - one function per return type
--   T12.6  Option 2 - one NUMBER function, cast at the call site
--   T12.7  VARCHAR keys sort lexically, not numerically  <<< easy to miss
--   T12.8  Round trip - does a key survive NUMBER -> VARCHAR -> NUMBER?
--
-- Runtime: about three minutes, single session.
-- Build standard applied: sequences fully qualified, functions created in
-- their own schema, VOLATILE, cast in the body, run-scoped _V12 names.
-- ==========================================================================

USE DATABASE LM_POC_DB;
DROP SCHEMA IF EXISTS W6V12 CASCADE;
CREATE SCHEMA W6V12;
USE SCHEMA W6V12;

CREATE OR REPLACE SEQUENCE emp_seq_v12 START 1 INCREMENT 1;
CREATE OR REPLACE TABLE region_map_v12 (REGION_NAME VARCHAR(100), REGION_CODE NUMBER(9,0));
INSERT INTO region_map_v12 VALUES
    ('North America',1),('EU',2),('APAC',3),('LATAM',4),('UK',5),('MEA',6),
    ('ANZ',7),('Japan',8),('India',9),('Nordics',10),('Benelux',11),('Iberia',12);

-- ==========================================================================
-- T12.1  CAN ONE FUNCTION SERVE BOTH BASE TYPES?
-- ==========================================================================
-- R6 proved the declared BASE type is enforced at CREATE. Confirm that means
-- one function cannot cover both, rather than assuming it.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION key_num_v12(region_name VARCHAR)
RETURNS NUMBER(38,0) VOLATILE
COMMENT = 'Numeric target. Scheme B - fixed-width offset.'
AS $$
    CAST((SELECT m.REGION_CODE FROM region_map_v12 m WHERE m.REGION_NAME = region_name)
         * 1000000000000000 + LM_POC_DB.W6V12.emp_seq_v12.NEXTVAL AS NUMBER(38,0))
$$;

-- Same body, declared VARCHAR. If the base type is enforced, this must FAIL.
CREATE OR REPLACE FUNCTION key_num_declared_varchar_v12(region_name VARCHAR)
RETURNS VARCHAR(50) VOLATILE
AS $$
    CAST((SELECT m.REGION_CODE FROM region_map_v12 m WHERE m.REGION_NAME = region_name)
         * 1000000000000000 + LM_POC_DB.W6V12.emp_seq_v12.NEXTVAL AS NUMBER(38,0))
$$;
-- EXPECT: one of two outcomes, and WHICH ONE MATTERS.
--   (a) CREATE is REFUSED -> base type strictly enforced; one function per
--       target type is mandatory.
--   (b) CREATE succeeds -> Snowflake coerces NUMBER to VARCHAR on return, and
--       a single numeric function could feed a VARCHAR target directly.
-- Record the outcome and the exact error text if refused. ----------- RECORD

SELECT key_num_declared_varchar_v12('North America') AS v,
       SYSTEM$TYPEOF(key_num_declared_varchar_v12('North America')) AS actual_type;
-- Only run this if the CREATE above succeeded. -------------------- RECORD

-- ==========================================================================
-- T12.2  CAN THE TARGET TYPE BE PASSED AS A PARAMETER?
-- ==========================================================================
-- The obvious wish: f(region_name, sequence_name, target_type). Close it off
-- definitively rather than leaving it as an open idea.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION key_typed_v12(region_name VARCHAR, target_type VARCHAR)
RETURNS VARCHAR VOLATILE
AS $$
    CASE target_type
        WHEN 'NUMBER'  THEN CAST(CAST((SELECT m.REGION_CODE FROM region_map_v12 m WHERE m.REGION_NAME = region_name)
                                      * 1000000000000000 + LM_POC_DB.W6V12.emp_seq_v12.NEXTVAL AS NUMBER(38,0)) AS VARCHAR)
        WHEN 'VARCHAR' THEN LPAD((SELECT m.REGION_CODE FROM region_map_v12 m WHERE m.REGION_NAME = region_name), 2, '0')
                            || LPAD(LM_POC_DB.W6V12.emp_seq_v12.NEXTVAL, 15, '0')
    END
$$;

SELECT key_typed_v12('North America','NUMBER')  AS as_number,
       key_typed_v12('North America','VARCHAR') AS as_varchar,
       'The function still returns ONE declared type (VARCHAR). The caller must '
       || 'cast anyway, so the parameter buys nothing - it only moves the CASE inside.' AS verdict;
-- EXPECT: both return VARCHAR. The declared return type cannot vary by
-- argument, so this is not a solution - it is the same problem relocated.
-- ------------------------------------------------------------------ RECORD

-- ==========================================================================
-- T12.3  SCHEME C - ZERO-PADDED VARCHAR - AT TWELVE REGIONS
-- ==========================================================================
-- Scheme B's principle expressed as text. Pad BOTH parts to a fixed width.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION key_padded_v12(region_name VARCHAR)
RETURNS VARCHAR(17) VOLATILE
COMMENT = 'Text target. Scheme C - zero-padded concatenation. Region 2 chars, sequence 15.'
AS $$
    LPAD((SELECT m.REGION_CODE FROM region_map_v12 m WHERE m.REGION_NAME = region_name), 2, '0')
    || LPAD(LM_POC_DB.W6V12.emp_seq_v12.NEXTVAL, 15, '0')
$$;

CREATE OR REPLACE TABLE keys_v12 (K VARCHAR(17), REGION VARCHAR(100));

-- One statement per region so no statement references two sequences.
-- Deliberately includes the two-digit codes that broke plain concatenation.
INSERT INTO keys_v12 SELECT key_padded_v12('North America'),'North America' FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v12 SELECT key_padded_v12('Nordics'),      'Nordics'       FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v12 SELECT key_padded_v12('Benelux'),      'Benelux'       FROM TABLE(GENERATOR(ROWCOUNT => 400));
INSERT INTO keys_v12 SELECT key_padded_v12('Iberia'),       'Iberia'        FROM TABLE(GENERATOR(ROWCOUNT => 400));

SELECT COUNT(*) AS total, COUNT(DISTINCT K) AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT K) AS duplicates,
       MIN(LENGTH(K)) AS min_len, MAX(LENGTH(K)) AS max_len,
       CASE WHEN COUNT(*) = COUNT(DISTINCT K) AND MIN(LENGTH(K)) = MAX(LENGTH(K))
            THEN 'PASS - padded text is unique AND uniform width'
            WHEN COUNT(*) = COUNT(DISTINCT K)
            THEN 'unique but width varies - check the padding'
            ELSE 'FAIL - collisions' END AS verdict
FROM keys_v12;
-- EXPECT: 1600 / 1600 / 0, min_len = max_len = 17.
-- NOTE: this uses ONE shared sequence, so uniqueness here is NOT proof the
-- prefix is load-bearing - that was proven separately in R12 v3. What this
-- tests is the SCHEME's width and decode behaviour. ---------------- PASS/FAIL

-- Decode: fixed positions, so it works for any region-code length.
SELECT k.REGION, COUNT(*) AS keys,
       SUM(CASE WHEN TO_NUMBER(LEFT(k.K,2)) = m.REGION_CODE THEN 1 ELSE 0 END) AS decode_ok,
       CASE WHEN COUNT(*) = SUM(CASE WHEN TO_NUMBER(LEFT(k.K,2)) = m.REGION_CODE THEN 1 ELSE 0 END)
            THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM keys_v12 k JOIN region_map_v12 m ON m.REGION_NAME = k.REGION
GROUP BY k.REGION ORDER BY k.REGION;
-- EXPECT: PASS for all four, INCLUDING the two-digit codes 10, 11, 12 that
-- plain concatenation misdecoded. ----------------------------------- PASS/FAIL

-- ==========================================================================
-- T12.4  DOES THE TARGET COLUMN'S VARCHAR LENGTH BITE?
-- ==========================================================================
-- R6 showed the FUNCTION's declared VARCHAR length is ignored. The TARGET
-- column's length is a different matter and is enforced.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE target_short_v12 (K VARCHAR(10));
INSERT INTO target_short_v12 SELECT key_padded_v12('North America') FROM TABLE(GENERATOR(ROWCOUNT => 5));
-- EXPECT: FAILS - a 17-character key will not fit VARCHAR(10). Record the
-- error. This is the control that catches an under-sized target column.
-- ------------------------------------------------------------------ RECORD

CREATE OR REPLACE TABLE target_ok_v12 (K VARCHAR(17));
INSERT INTO target_ok_v12 SELECT key_padded_v12('Iberia') FROM TABLE(GENERATOR(ROWCOUNT => 5));
SELECT COUNT(*) AS rows_in, MIN(LENGTH(K)) AS len,
       CASE WHEN COUNT(*) = 5 THEN 'PASS - VARCHAR(17) is the right size for region 2 + sequence 15'
            ELSE 'FAIL' END AS verdict
FROM target_ok_v12;
-- EXPECT: 5 / 17 / PASS. Build standard: a text key column must be at least
-- region_width + sequence_width. ------------------------------------ PASS/FAIL

-- ==========================================================================
-- T12.5  OPTION 1 - ONE FUNCTION PER RETURN TYPE
-- ==========================================================================
CREATE OR REPLACE TABLE target_num_v12 (K NUMBER(38,0));
CREATE OR REPLACE TABLE target_txt_v12 (K VARCHAR(17));
INSERT INTO target_num_v12 SELECT key_num_v12('EU')    FROM TABLE(GENERATOR(ROWCOUNT => 100));
INSERT INTO target_txt_v12 SELECT key_padded_v12('EU') FROM TABLE(GENERATOR(ROWCOUNT => 100));

SELECT 'numeric target' AS target, COUNT(*) AS rows, MIN(SYSTEM$TYPEOF(K)) AS stored_type FROM target_num_v12
UNION ALL
SELECT 'text target',            COUNT(*),         MIN(SYSTEM$TYPEOF(K)) FROM target_txt_v12;
-- EXPECT: both 100 rows, stored as NUMBER and VARCHAR respectively.
-- Each table's ETL calls the function matching its own key column's type.
-- COST: two functions to maintain, and the caller must pick correctly.
-- ------------------------------------------------------------------ PASS/FAIL

-- ==========================================================================
-- T12.6  OPTION 2 - ONE NUMERIC FUNCTION, CAST AT THE CALL SITE
-- ==========================================================================
-- Does this reintroduce the §4 problem the whole requirement exists to avoid?
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE target_txt_cast_v12 (K VARCHAR(20));
INSERT INTO target_txt_cast_v12
SELECT CAST(key_num_v12('APAC') AS VARCHAR(20)) FROM TABLE(GENERATOR(ROWCOUNT => 100));

SELECT COUNT(*) AS rows, MIN(LENGTH(K)) AS min_len, MAX(LENGTH(K)) AS max_len,
       MIN(K) AS lowest_lexical, MAX(K) AS highest_lexical,
       CASE WHEN MIN(LENGTH(K)) <> MAX(LENGTH(K))
            THEN 'WARNING - casting a NUMBER to VARCHAR gives VARIABLE width; padding is lost'
            ELSE 'uniform width' END AS verdict
FROM target_txt_cast_v12;
-- EXPECT: lengths vary (16 for region 3 at low sequence values, more later).
-- >>> THE POINT: a numeric key cast to text is NOT the same as Scheme C. The
-- leading zeros that make the width uniform are lost in the cast. So Option 2
-- is NOT equivalent to Option 1 for a text target. <<< -------------- RECORD

-- And it does reintroduce per-ETL casting - one CAST at each call site. That
-- is far less than nextval -> prefix -> cast, but it is not zero.
-- ------------------------------------------------------------------ RECORD

-- ==========================================================================
-- T12.7  VARCHAR KEYS SORT LEXICALLY, NOT NUMERICALLY
-- ==========================================================================
-- Easy to miss, and it bites range predicates, MIN/MAX and ORDER BY.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE sort_probe_v12 (PADDED VARCHAR(17), UNPADDED VARCHAR(20));
INSERT INTO sort_probe_v12 VALUES
    ('01000000000000002','12'), ('01000000000000010','102'),
    ('02000000000000002','22'), ('12000000000000002','1202');

SELECT 'padded'   AS form, MIN(PADDED)   AS lexical_min, MAX(PADDED)   AS lexical_max FROM sort_probe_v12
UNION ALL
SELECT 'unpadded',        MIN(UNPADDED),               MAX(UNPADDED)   FROM sort_probe_v12;
-- EXPECT: padded sorts in the intended order because every key is the same
-- width. Unpadded does NOT - '102' sorts before '12' lexically.
-- >>> Another reason padding is not cosmetic: it preserves ordering and range
-- predicates on a text key. <<< ------------------------------------- RECORD

-- ==========================================================================
-- T12.8  ROUND TRIP - DOES A KEY SURVIVE NUMBER -> VARCHAR -> NUMBER?
-- ==========================================================================
-- Relevant if the global consolidation layer stores a different type from the
-- regional one.
-- --------------------------------------------------------------------------
WITH one AS (SELECT key_num_v12('Iberia') AS n)
SELECT n                                              AS original_number,
       CAST(n AS VARCHAR(20))                         AS as_text,
       CAST(CAST(n AS VARCHAR(20)) AS NUMBER(38,0))   AS back_to_number,
       CASE WHEN n = CAST(CAST(n AS VARCHAR(20)) AS NUMBER(38,0))
            THEN 'PASS - round trip is lossless for a numeric key'
            ELSE 'FAIL - value changed' END           AS verdict,
       FLOOR(n / 1000000000000000)                    AS decoded_region
FROM one;
-- EXPECT: PASS, decoded_region = 12. ------------------------------- PASS/FAIL

-- --------------------------------------------------------------------------
-- TEARDOWN
-- --------------------------------------------------------------------------
DROP SCHEMA IF EXISTS W6V12 CASCADE;

-- ==========================================================================
-- WHAT THIS DECIDES FOR Q3
-- ==========================================================================
-- T12.1 refused      -> one function per return type is MANDATORY, not a
--                       preference. Option 1 (T12.5) is the answer.
-- T12.1 succeeded    -> a single numeric function can feed a text target, but
--                       T12.6 shows the result is VARIABLE WIDTH, which loses
--                       the property that makes Scheme C safe. Option 1 is
--                       still preferable for text targets.
-- T12.2              -> passing the target type as a parameter solves nothing.
--                       The declared return type cannot vary by argument.
-- T12.3 PASS         -> Scheme C works, including two-digit region codes. The
--                       principle is FIXED WIDTH, not numeric-versus-text.
-- T12.4              -> a text key column must be sized >= region + sequence
--                       width, or inserts fail.
-- T12.7              -> padding also preserves ordering on a text key, which
--                       an unpadded cast does not.
--
-- RECOMMENDATION going in: keep ONE function per target base type -
-- Scheme B for numeric columns, Scheme C for text - with the same region and
-- sequence widths in both so a key means the same thing either way.
-- ==========================================================================
