-- ==========================================================================
-- W6 / R6 - DOES THE FUNCTION RETURN THE TARGET'S DATATYPE?
-- ==========================================================================
-- R6 says the cast happens ONCE, inside the function, so no ETL repeats it.
-- That was section 4's whole motivation: prefixing the region changed the
-- datatype and needed casting back.
--
-- The documentation says the DECLARATION will not deliver it (SQL UDF
-- limitations, verbatim):
--
--   "Argument and return type constraints are sometimes ignored ... the
--    received value may be used as received whether or not it conforms to
--    constraints specified in the declaration. The following are ignored for
--    UDFs whose logic is written in SQL: Precision and scale for arguments and
--    return values of type NUMBER; Length for arguments and return values of
--    type VARCHAR."
--
-- So RETURNS NUMBER(38,0) is documentation, not enforcement. This file proves
-- that, then proves a body-level CAST does work, then checks the two candidate
-- prefix schemes end to end.
--
--   T3.1  Is declared NUMBER precision/scale really ignored?
--   T3.2  Is declared VARCHAR length really ignored?
--   T3.3  Does a body-level CAST deliver the type?
--   T3.4  Fixed-width offset, end to end          (C3 candidate A)
--   T3.5  Digit concatenation, end to end         (C3 candidate B)
--   T3.6  Does the value land correctly in a real NUMBER(38,0) column?
--
-- Runtime: about two minutes. Scratch schema; teardown at the end.
--
-- SCREENSHOT GUIDE: every test ends in a query with a VERDICT column.
-- T3.1 and T3.2 are EXPECTED to show the declaration being ignored - that is
-- the finding, not a failure of the design.
-- ==========================================================================

-- EDIT THESE TWO LINES, then run the file top to bottom.
USE DATABASE LM_POC_DB;
USE SCHEMA POC_SCHEMA;

-- --------------------------------------------------------------------------
-- SETUP
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE w6_r6_seq START 1 INCREMENT 1;

CREATE OR REPLACE TABLE w6_region_map (REGION_NAME VARCHAR(100), REGION_CODE NUMBER(9,0));
INSERT INTO w6_region_map VALUES ('North America', 1), ('EU', 2), ('APAC', 3);

-- FIELD WIDTH for the fixed-width scheme: 10^15, written as a literal
-- throughout. 15 digits keeps the sequence half well clear of its own 64-bit
-- ceiling, and 10^15 is still a quadrillion keys per region. A session
-- variable is deliberately NOT used - a UDF body cannot see one.
-- THIS NUMBER MUST NEVER CHANGE once keys are issued: changing it renumbers
-- every key ever generated.

-- ==========================================================================
-- T3.1  IS DECLARED NUMBER PRECISION/SCALE REALLY IGNORED?
-- ==========================================================================
-- Declare a return type far too small for the value the body produces. If the
-- declaration were enforced, this would error or truncate.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION w6_tiny_declared_type()
RETURNS NUMBER(3,0)                 -- max 999. The body returns far more.
VOLATILE
AS
$$
    CAST(123456789012345 AS NUMBER(38,0))
$$;

SELECT w6_tiny_declared_type()                      AS returned_value,
       SYSTEM$TYPEOF(w6_tiny_declared_type())       AS actual_type,
       CASE WHEN w6_tiny_declared_type() > 999
            THEN 'DECLARATION IGNORED - value exceeds the declared NUMBER(3,0)'
            ELSE 'DECLARATION ENFORCED - docs would be wrong' END AS verdict;
-- EXPECT: the full 15-digit value back, and "DECLARATION IGNORED".
-- THAT IS THE DOCUMENTED BEHAVIOUR, and the reason R6 needs a body-level cast.
-- If it instead errors or truncates, the docs do not describe this account and
-- R6 is simpler than we thought - say so. --------------------------- RECORD

-- ==========================================================================
-- T3.2  IS DECLARED VARCHAR LENGTH REALLY IGNORED?
-- ==========================================================================
CREATE OR REPLACE FUNCTION w6_tiny_varchar()
RETURNS VARCHAR(1)                  -- one character. The body returns many.
VOLATILE
AS
$$
    'ABCDEFGHIJ'
$$;

SELECT w6_tiny_varchar()            AS returned_value,
       LENGTH(w6_tiny_varchar())    AS returned_length,
       CASE WHEN LENGTH(w6_tiny_varchar()) > 1
            THEN 'DECLARATION IGNORED - longer than the declared VARCHAR(1)'
            ELSE 'DECLARATION ENFORCED' END AS verdict;
-- EXPECT: 'ABCDEFGHIJ', length 10, "DECLARATION IGNORED". ----------- RECORD

-- ==========================================================================
-- T3.3  DOES A BODY-LEVEL CAST DELIVER THE TYPE?
-- ==========================================================================
-- The fix R6 depends on: put the CAST in the body, not the signature.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION w6_cast_in_body()
RETURNS NUMBER(38,0)
VOLATILE
AS
$$
    CAST('42' AS NUMBER(38,0))      -- text in, number out, cast in the body
$$;

SELECT w6_cast_in_body()                        AS returned_value,
       SYSTEM$TYPEOF(w6_cast_in_body())         AS actual_type,
       CASE WHEN SYSTEM$TYPEOF(w6_cast_in_body()) ILIKE 'NUMBER%'
            THEN 'PASS - the body cast delivers a NUMBER'
            ELSE 'FAIL - still not numeric' END AS verdict;
-- EXPECT: 42, a NUMBER type, PASS. ---------------------------------- PASS/FAIL

-- ==========================================================================
-- T3.4  FIXED-WIDTH OFFSET, END TO END          (C3 candidate A - recommended)
-- ==========================================================================
-- region_code * 10^15 + nextval. Arithmetic never leaves the numeric domain,
-- so in principle there is nothing for the ignored declaration to get wrong.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION w6_key_offset(region_name VARCHAR)
RETURNS NUMBER(38,0)
VOLATILE
COMMENT = 'VOLATILE is required - never IMMUTABLE or MEMOIZABLE. See 04_r10.'
AS
$$
    CAST(
        (SELECT m.REGION_CODE FROM w6_region_map m WHERE m.REGION_NAME = region_name)
        * 1000000000000000 + w6_r6_seq.NEXTVAL
    AS NUMBER(38,0))
$$;

WITH k AS (
    SELECT 'North America' AS region, w6_key_offset('North America') AS key_val
    FROM TABLE(GENERATOR(ROWCOUNT => 5))
    UNION ALL
    SELECT 'EU', w6_key_offset('EU') FROM TABLE(GENERATOR(ROWCOUNT => 5))
)
, typed AS (
    SELECT region, key_val, SYSTEM$TYPEOF(key_val) AS val_type FROM k
)
SELECT region,
       COUNT(*)                                   AS rows_out,
       COUNT(DISTINCT key_val)                    AS distinct_keys,
       MIN(val_type)                              AS actual_type,
       CAST(MIN(key_val) AS VARCHAR)              AS min_key,
       CAST(MAX(key_val) AS VARCHAR)              AS max_key,
       MIN(FLOOR(key_val / 1000000000000000))     AS decoded_region_code,
       CASE WHEN COUNT(DISTINCT key_val) = COUNT(*) AND MIN(val_type) ILIKE 'NUMBER%'
            THEN 'PASS' ELSE 'FAIL' END           AS verdict
FROM typed GROUP BY region ORDER BY region;
-- EXPECT: two rows. 5 distinct keys each, a NUMBER type, keys of the shape
-- 1000000000000001.. and 2000000000000001.., decoded_region_code 1 and 2.
-- NOTE the actual_type: if it reports NUMBER(38,0) the declaration happened to
-- match; what matters is that it is numeric and the value is intact.
-- ------------------------------------------------------------------ PASS/FAIL

-- ==========================================================================
-- T3.5  DIGIT CONCATENATION, END TO END          (C3 candidate B)
-- ==========================================================================
-- Two variants, to show exactly where section 4's datatype problem comes from.
-- --------------------------------------------------------------------------

-- T3.5a  WITHOUT a body cast - what the ETL would hit if it concatenated inline.
CREATE OR REPLACE FUNCTION w6_key_concat_nocast(region_name VARCHAR)
RETURNS NUMBER(38,0)                -- declared numeric; body returns text
VOLATILE
AS
$$
    (SELECT CAST(m.REGION_CODE AS VARCHAR) FROM w6_region_map m
     WHERE m.REGION_NAME = region_name)
    || CAST(w6_r6_seq.NEXTVAL AS VARCHAR)
$$;

WITH one_call AS (
    SELECT w6_key_concat_nocast('North America') AS v
)
SELECT v                                AS returned_value,
       SYSTEM$TYPEOF(v)                 AS actual_type,
       CASE WHEN SYSTEM$TYPEOF(v) ILIKE 'VARCHAR%'
            THEN 'TEXT RETURNED despite RETURNS NUMBER - this is section 4''s problem'
            WHEN SYSTEM$TYPEOF(v) ILIKE 'NUMBER%'
            THEN 'coerced to NUMBER anyway - declaration did more than documented'
            ELSE 'other - record the type' END AS verdict
FROM one_call;
-- EXPECT: likely VARCHAR, proving the declaration does not coerce. If it comes
-- back NUMBER, Snowflake coerced it and R6 is less fragile than the docs imply
-- - either way, RECORD WHICH. --------------------------------------- RECORD

-- T3.5b  WITH the body cast - the form that would actually ship.
CREATE OR REPLACE FUNCTION w6_key_concat_cast(region_name VARCHAR)
RETURNS NUMBER(38,0)
VOLATILE
AS
$$
    CAST(
        (SELECT CAST(m.REGION_CODE AS VARCHAR) FROM w6_region_map m
         WHERE m.REGION_NAME = region_name)
        || CAST(w6_r6_seq.NEXTVAL AS VARCHAR)
    AS NUMBER(38,0))
$$;

WITH one_call AS (
    SELECT w6_key_concat_cast('North America') AS v
)
SELECT v                    AS returned_value,
       SYSTEM$TYPEOF(v)     AS actual_type,
       CASE WHEN SYSTEM$TYPEOF(v) ILIKE 'NUMBER%'
            THEN 'PASS - body cast fixes it' ELSE 'FAIL' END AS verdict
FROM one_call;
-- EXPECT: a NUMBER, PASS. ------------------------------------------- PASS/FAIL

-- ==========================================================================
-- T3.6  DOES THE KEY LAND CORRECTLY IN A REAL NUMBER(38,0) COLUMN?
-- ==========================================================================
-- The declaration being ignored matters only if a wrong value reaches the
-- target. The column type IS enforced, so this is the test that counts.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE w6_key_target (
    EMPLOYEE_ID NUMBER(38,0),
    REGION      VARCHAR(50)
);

INSERT INTO w6_key_target (EMPLOYEE_ID, REGION)
SELECT w6_key_offset('North America'), 'North America' FROM TABLE(GENERATOR(ROWCOUNT => 10))
UNION ALL
SELECT w6_key_offset('APAC'), 'APAC' FROM TABLE(GENERATOR(ROWCOUNT => 10));

SELECT COUNT(*)                                      AS rows_stored,
       COUNT(DISTINCT EMPLOYEE_ID)                   AS distinct_keys,
       SUM(CASE WHEN FLOOR(EMPLOYEE_ID / 1000000000000000) = m.REGION_CODE
                THEN 1 ELSE 0 END)                   AS decode_correct,
       CASE WHEN COUNT(*) = COUNT(DISTINCT EMPLOYEE_ID)
             AND COUNT(*) = SUM(CASE WHEN FLOOR(EMPLOYEE_ID / 1000000000000000) = m.REGION_CODE
                                     THEN 1 ELSE 0 END)
            THEN 'PASS - stored intact and every key decodes to its region'
            ELSE 'FAIL' END                          AS verdict
FROM w6_key_target t
JOIN w6_region_map m ON m.REGION_NAME = t.REGION;
-- EXPECT: 20 / 20 / 20 / PASS. -------------------------------------- PASS/FAIL

-- T3.6b  The stored column's type, checked separately.
SELECT SYSTEM$TYPEOF(EMPLOYEE_ID) AS stored_type,
       CASE WHEN SYSTEM$TYPEOF(EMPLOYEE_ID) ILIKE 'NUMBER%' THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM w6_key_target LIMIT 1;
-- EXPECT: a NUMBER type, PASS. -------------------------------------- PASS/FAIL

-- Eyeball a few actual keys - useful in the evidence pack.
SELECT REGION, CAST(EMPLOYEE_ID AS VARCHAR) AS employee_id,
       FLOOR(EMPLOYEE_ID / 1000000000000000) AS region_part,
       EMPLOYEE_ID % 1000000000000000        AS sequence_part
FROM w6_key_target ORDER BY EMPLOYEE_ID LIMIT 6;
-- EXPECT: region_part 1 or 3, sequence_part small and ascending. ---- RECORD

-- --------------------------------------------------------------------------
-- TEARDOWN
-- --------------------------------------------------------------------------
DROP FUNCTION IF EXISTS w6_tiny_declared_type();
DROP FUNCTION IF EXISTS w6_tiny_varchar();
DROP FUNCTION IF EXISTS w6_cast_in_body();
DROP FUNCTION IF EXISTS w6_key_offset(VARCHAR);
DROP FUNCTION IF EXISTS w6_key_concat_nocast(VARCHAR);
DROP FUNCTION IF EXISTS w6_key_concat_cast(VARCHAR);
DROP TABLE    IF EXISTS w6_key_target;
DROP TABLE    IF EXISTS w6_region_map;
DROP SEQUENCE IF EXISTS w6_r6_seq;

-- ==========================================================================
-- WHAT THE RESULTS MEAN FOR R6
-- ==========================================================================
-- T3.1/T3.2 show the declaration ignored -> confirms the docs. The build
--      standard must say: PUT THE CAST IN THE BODY, and test the returned
--      type, never trust RETURNS.
-- T3.3 + T3.4 + T3.6 pass -> R6 is satisfied. Closes R6.
-- T3.5a returns VARCHAR -> concatenation genuinely needs the body cast, which
--      is section 4's problem centralised rather than removed. Evidence for
--      C3: fixed-width offset avoids the problem instead of managing it.
-- T3.5a returns NUMBER  -> Snowflake coerced it; concatenation is less fragile
--      than feared, and C3 turns purely on R12/R13 instead.
-- T3.1 unexpectedly ENFORCES the declaration -> the docs do not describe this
--      account. Tell the team: R6 gets simpler, and C7 goes away.
-- ==========================================================================
