-- ==========================================================================
-- W6 / R2 - CAN THE SEQUENCE BE CHOSEN BY A NAME SUPPLIED AT RUN TIME?
-- ==========================================================================
-- Answers three questions, in this order:
--   T2.1  Does a FULLY-QUALIFIED sequence name work inside a UDF body?
--   T2.2  Does the mapping-table indirection work?  (expected: NO)
--   T2.3  Does the branch-selector shape work?      (expected: YES)
--   T2.4  Do UNTAKEN CASE branches consume values?  (the real unknown)
--
-- Run AFTER 01_r3_sequence_in_udf.sql. If R3 failed, skip this file entirely -
-- it all presupposes that a UDF body may reference a sequence.
--
-- PRIOR EVIDENCE (explore/r2_sequence_name_binding.py, DuckDB):
--   mapping-table indirection  -> refused, "must be a constant expression"
--   branch selector            -> works, correct per-table keys
--   untaken branches           -> cost nothing IN DUCKDB. Snowflake may differ,
--                                 which is exactly what T2.4 is for.
-- ==========================================================================

-- USE SCHEMA <scratch_db>.<scratch_schema>;

CREATE OR REPLACE SEQUENCE w6_employee_seq START 1    INCREMENT 1;
CREATE OR REPLACE SEQUENCE w6_job_seq      START 1000 INCREMENT 1;

-- --------------------------------------------------------------------------
-- T2.1  FULLY-QUALIFIED NAME IN A UDF BODY
--       Nikhil's question. Q2 line 50 already writes the sequence fully
--       qualified, so this looks settled - but note WHY that is not evidence:
--       Q2's $$inout_param_* markers are substituted by the ORCHESTRATOR
--       before Snowflake ever sees the SQL. Snowflake receives literal names.
--       That proves nothing about run-time dynamism, only about qualification.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION w6_qualified_name_test()
RETURNS NUMBER(38,0)
VOLATILE
AS
$$
    -- replace with your real database and schema
    IDENTIFIER_PLACEHOLDER_DB.IDENTIFIER_PLACEHOLDER_SCHEMA.w6_employee_seq.NEXTVAL
$$;
-- Before running: substitute the two placeholders with the actual scratch
-- db/schema names, e.g. MY_DB.MY_SCHEMA.w6_employee_seq.NEXTVAL
--
-- EXPECT: creates and returns values.
-- ------------------------------------------------------------------ PASS/FAIL

SELECT w6_qualified_name_test() AS k FROM TABLE(GENERATOR(ROWCOUNT => 3));

-- IMPORTANT CONSEQUENCE FOR R8, whichever way T2.1 goes:
--   A fully-qualified body hard-codes the database and schema, so the SAME
--   function text is NOT portable across environments - which is what R8
--   requires. An UNQUALIFIED reference resolves "in the schema containing the
--   function" (Introduction to SQL UDFs), so identical text deployed to dev,
--   SIT and prod each binds its own objects.
--   => Prefer UNQUALIFIED inside the function. Qualification is a per-call
--      concern, not a per-function one. Confirm with T2.1b below.

-- --------------------------------------------------------------------------
-- T2.1b UNQUALIFIED NAME - the R8-portable form
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION w6_unqualified_name_test()
RETURNS NUMBER(38,0)
VOLATILE
AS
$$
    w6_employee_seq.NEXTVAL
$$;

SELECT w6_unqualified_name_test() AS k FROM TABLE(GENERATOR(ROWCOUNT => 3));
-- EXPECT: works, resolving w6_employee_seq in the function's own schema.
-- ------------------------------------------------------------------ PASS/FAIL

-- --------------------------------------------------------------------------
-- T2.2  THE MAPPING-TABLE INDIRECTION  (Nikhil's proposal)
--       Hold the full sequence name in a registry table, read it, use it.
--       If this worked, onboarding a table would be an INSERT, not a release.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE w6_sequence_registry (
    LOGICAL_NAME        VARCHAR(100),
    FULL_SEQUENCE_NAME  VARCHAR(500)
);
INSERT INTO w6_sequence_registry VALUES
    ('EMPLOYEE', 'w6_employee_seq'),
    ('JOB',      'w6_job_seq');

-- T2.2a  via IDENTIFIER() on a value read from the registry
CREATE OR REPLACE FUNCTION w6_registry_lookup_test(logical_name VARCHAR)
RETURNS NUMBER(38,0)
VOLATILE
AS
$$
    (SELECT IDENTIFIER(r.FULL_SEQUENCE_NAME || '.NEXTVAL')
     FROM w6_sequence_registry r
     WHERE r.LOGICAL_NAME = logical_name)
$$;
-- EXPECT: FAILS. Two documented reasons, either of which is sufficient:
--   1. SQL UDF limitations - "Dynamic SQL is not supported when referring to
--      database objects", with an IDENTIFIER(parameter) failure example.
--   2. IDENTIFIER() syntax accepts only a string LITERAL, session variable,
--      bind variable or Snowflake Scripting variable. A COLUMN VALUE is none
--      of those - and a registry lookup is a column value.
-- Record the exact error text. ------------------------------------- PASS/FAIL

-- T2.2b  via IDENTIFIER() directly on the parameter, no table at all.
--        Isolates whether the registry read is the problem or the parameter is.
CREATE OR REPLACE FUNCTION w6_param_identifier_test(seq_name VARCHAR)
RETURNS NUMBER(38,0)
VOLATILE
AS
$$
    IDENTIFIER(seq_name).NEXTVAL
$$;
-- EXPECT: FAILS, same limitation. Confirms the parameter is the blocker, so no
-- amount of table indirection helps. ------------------------------- PASS/FAIL

-- --------------------------------------------------------------------------
-- T2.3  THE BRANCH SELECTOR - what is expected to work
--       The run-time value picks a branch; every sequence is named literally.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION w6_branch_selector(sequence_name VARCHAR)
RETURNS NUMBER(38,0)
VOLATILE
AS
$$
    CASE sequence_name
        WHEN 'EMPLOYEE_SEQ' THEN w6_employee_seq.NEXTVAL
        WHEN 'JOB_SEQ'      THEN w6_job_seq.NEXTVAL
    END
$$;

SELECT 'EMPLOYEE_SEQ' AS requested, w6_branch_selector('EMPLOYEE_SEQ') AS k
FROM TABLE(GENERATOR(ROWCOUNT => 3))
UNION ALL
SELECT 'JOB_SEQ', w6_branch_selector('JOB_SEQ')
FROM TABLE(GENERATOR(ROWCOUNT => 3));
-- EXPECT: EMPLOYEE keys in the 1.. range, JOB keys in the 1000.. range,
-- all six distinct. ------------------------------------------------ PASS/FAIL

-- T2.3b  Called with the name varying PER ROW, not fixed per statement.
--        This is the realistic case if one function serves several tables in
--        one load, and it is a harder test than T2.3.
CREATE OR REPLACE TABLE w6_mixed_stage (LOGICAL_NAME VARCHAR(100));
INSERT INTO w6_mixed_stage VALUES
    ('EMPLOYEE_SEQ'), ('JOB_SEQ'), ('EMPLOYEE_SEQ'), ('JOB_SEQ'), ('EMPLOYEE_SEQ');

SELECT LOGICAL_NAME, w6_branch_selector(LOGICAL_NAME) AS k
FROM w6_mixed_stage;
-- EXPECT: each row keyed from its own sequence, all distinct within a range.
-- ------------------------------------------------------------------ PASS/FAIL

-- --------------------------------------------------------------------------
-- T2.4  DO UNTAKEN CASE BRANCHES CONSUME VALUES?
--       THE REAL UNKNOWN, and the one DuckDB answered misleadingly.
--       Using Sequences: "Each occurrence of a sequence generates a set of
--       distinct values" - wording about occurrences in the STATEMENT, not
--       branches taken. So a CASE may burn a value from EVERY arm per row.
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE w6_employee_seq START 1    INCREMENT 1;
CREATE OR REPLACE SEQUENCE w6_job_seq      START 1000 INCREMENT 1;

-- Draw 10 rows, ALL of them asking for EMPLOYEE_SEQ. job_seq should be untouched.
SELECT COUNT(*) AS rows_drawn, COUNT(DISTINCT k) AS distinct_keys
FROM (SELECT w6_branch_selector('EMPLOYEE_SEQ') AS k
      FROM TABLE(GENERATOR(ROWCOUNT => 10)));

-- Now inspect what each sequence advanced to.
SELECT w6_employee_seq.NEXTVAL AS employee_next;   -- EXPECT ~11
SELECT w6_job_seq.NEXTVAL      AS job_next;        -- EXPECT 1000 if untaken
                                                   --        branches are free
-- INTERPRETATION:
--   job_next = 1000          -> untaken branches cost nothing. Safe to put
--                               many sequences in one function.
--   job_next = ~1010         -> EVERY arm consumed once per row. Tolerable
--                               (gaps are never guaranteed) but it means one
--                               function per sequence is the better shape as
--                               the branch list grows, and consumption must
--                               be documented so nobody reads gaps as loss.
-- ------------------------------------------------------------------ PASS/FAIL

-- --------------------------------------------------------------------------
-- TEARDOWN
-- --------------------------------------------------------------------------
DROP FUNCTION IF EXISTS w6_qualified_name_test();
DROP FUNCTION IF EXISTS w6_unqualified_name_test();
DROP FUNCTION IF EXISTS w6_registry_lookup_test(VARCHAR);
DROP FUNCTION IF EXISTS w6_param_identifier_test(VARCHAR);
DROP FUNCTION IF EXISTS w6_branch_selector(VARCHAR);
DROP TABLE    IF EXISTS w6_sequence_registry;
DROP TABLE    IF EXISTS w6_mixed_stage;
DROP SEQUENCE IF EXISTS w6_employee_seq;
DROP SEQUENCE IF EXISTS w6_job_seq;
