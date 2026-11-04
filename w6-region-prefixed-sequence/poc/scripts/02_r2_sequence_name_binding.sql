-- ==========================================================================
-- W6 / R2 - CAN THE SEQUENCE BE CHOSEN BY A NAME SUPPLIED AT RUN TIME?
-- ==========================================================================
-- Prerequisite: R3 PASSED on 2026-11-03 (see R3_RESULTS.md), so a SQL UDF body
-- may contain seq.NEXTVAL. Everything below builds on that.
--
-- R2 requires the signature f(region_name, sequence_name). This file settles
-- what the function may legally DO with that second argument:
--
--   T2.1   Fully-qualified vs unqualified name in the body  (Nikhil's question)
--   T2.2   The registry-table indirection                   (expected to FAIL)
--   T2.3   The branch-selector shape                        (expected to PASS)
--   T2.4   Do UNTAKEN CASE arms consume sequence values?    (the real unknown)
--
-- Runtime: about two minutes. Needs CREATE SEQUENCE / FUNCTION / TABLE in a
-- scratch schema. Ends with a teardown; nothing here touches real objects.
--
-- SCREENSHOT GUIDE: every test ends in a query with a VERDICT column, so one
-- screenshot per numbered test is enough. For T2.2 the FAILURE is the result -
-- please capture the error message text itself.
-- ==========================================================================

-- EDIT THESE TWO LINES, then run the file top to bottom.
USE DATABASE LM_POC_DB;
USE SCHEMA POC_SCHEMA;

-- --------------------------------------------------------------------------
-- SETUP
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE w6_employee_seq START 1    INCREMENT 1;
CREATE OR REPLACE SEQUENCE w6_job_seq      START 1000 INCREMENT 1;

-- ==========================================================================
-- T2.1  QUALIFIED vs UNQUALIFIED NAME IN THE BODY
-- ==========================================================================
-- Q2 line 50 already writes the sequence fully qualified, so qualification
-- plainly works in a query. What matters here is which form belongs inside the
-- FUNCTION, because the two differ for R8 (one code base per environment):
--   qualified   - hard-codes database + schema  -> NOT portable
--   unqualified - "resolved in the schema containing the function" -> portable
-- --------------------------------------------------------------------------

-- T2.1a  Fully qualified.  <<< EDIT the DB/SCHEMA below to match your USE lines
CREATE OR REPLACE FUNCTION w6_qualified_test()
RETURNS NUMBER(38,0)
VOLATILE
AS
$$
    LM_POC_DB.POC_SCHEMA.w6_employee_seq.NEXTVAL
$$;

SELECT COUNT(*) AS rows_out, COUNT(DISTINCT k) AS distinct_keys,
       CASE WHEN COUNT(DISTINCT k) = COUNT(*) THEN 'PASS - qualified name works'
            ELSE 'FAIL' END AS verdict
FROM (SELECT w6_qualified_test() AS k FROM TABLE(GENERATOR(ROWCOUNT => 5)));
-- EXPECT: 5 / 5 / PASS. --------------------------------------------- PASS/FAIL

-- T2.1b  Unqualified - the R8-portable form.
CREATE OR REPLACE FUNCTION w6_unqualified_test()
RETURNS NUMBER(38,0)
VOLATILE
AS
$$
    w6_employee_seq.NEXTVAL
$$;

SELECT COUNT(*) AS rows_out, COUNT(DISTINCT k) AS distinct_keys,
       CASE WHEN COUNT(DISTINCT k) = COUNT(*) THEN 'PASS - unqualified name works'
            ELSE 'FAIL' END AS verdict
FROM (SELECT w6_unqualified_test() AS k FROM TABLE(GENERATOR(ROWCOUNT => 5)));
-- EXPECT: 5 / 5 / PASS.
-- IF BOTH PASS -> use the UNQUALIFIED form in the real function, for R8.
-- ------------------------------------------------------------------ PASS/FAIL

-- ==========================================================================
-- T2.2  THE REGISTRY-TABLE INDIRECTION  (Nikhil's proposal)
-- ==========================================================================
-- Hold the full sequence name in a registry table, read it, use it. If this
-- worked, onboarding a table would be an INSERT rather than a code release.
--
-- EXPECTED TO FAIL, for a documented reason: "Dynamic SQL is not supported
-- when referring to database objects" (SQL UDF limitations), and IDENTIFIER()
-- accepts only "a string literal, session variable, bind variable, or
-- Snowflake Scripting variable" - a COLUMN VALUE is none of those.
--
-- >>> THE ERROR MESSAGE IS THE EVIDENCE. Please screenshot the error text. <<<
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE w6_sequence_registry (
    LOGICAL_NAME       VARCHAR(100),
    FULL_SEQUENCE_NAME VARCHAR(500)
);
INSERT INTO w6_sequence_registry VALUES
    ('EMPLOYEE', 'w6_employee_seq'),
    ('JOB',      'w6_job_seq');

-- T2.2a  IDENTIFIER() on a value read from the registry.
CREATE OR REPLACE FUNCTION w6_registry_lookup_test(logical_name VARCHAR)
RETURNS NUMBER(38,0)
VOLATILE
AS
$$
    (SELECT IDENTIFIER(r.FULL_SEQUENCE_NAME || '.NEXTVAL')
     FROM w6_sequence_registry r
     WHERE r.LOGICAL_NAME = logical_name)
$$;
-- EXPECT: a compilation error, at CREATE or at first call. Capture the text.
-- ------------------------------------------------------------------ PASS/FAIL

-- T2.2b  IDENTIFIER() straight on the parameter, no table involved.
--        Isolates whether the registry read is the problem, or the parameter.
CREATE OR REPLACE FUNCTION w6_param_identifier_test(seq_name VARCHAR)
RETURNS NUMBER(38,0)
VOLATILE
AS
$$
    IDENTIFIER(seq_name).NEXTVAL
$$;
-- EXPECT: the same failure. That confirms the PARAMETER is the blocker, so no
-- amount of table indirection can help. ----------------------------- PASS/FAIL

-- ==========================================================================
-- T2.3  THE BRANCH SELECTOR - the shape expected to work
-- ==========================================================================
-- The run-time value picks a branch; every sequence is named literally, so no
-- identifier is ever constructed from data.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION w6_branch_selector(sequence_name VARCHAR)
RETURNS NUMBER(38,0)
VOLATILE
COMMENT = 'VOLATILE is required - see 04_r10_concurrency.sql T4.4/T4.5.'
AS
$$
    CASE sequence_name
        WHEN 'EMPLOYEE_SEQ' THEN w6_employee_seq.NEXTVAL
        WHEN 'JOB_SEQ'      THEN w6_job_seq.NEXTVAL
    END
$$;

-- T2.3a  One sequence name per statement.
SELECT requested,
       COUNT(*) AS rows_out,
       COUNT(DISTINCT k) AS distinct_keys,
       MIN(k) AS min_key, MAX(k) AS max_key,
       CASE WHEN COUNT(DISTINCT k) = COUNT(*) THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM (
    SELECT 'EMPLOYEE_SEQ' AS requested, w6_branch_selector('EMPLOYEE_SEQ') AS k
    FROM TABLE(GENERATOR(ROWCOUNT => 5))
    UNION ALL
    SELECT 'JOB_SEQ', w6_branch_selector('JOB_SEQ')
    FROM TABLE(GENERATOR(ROWCOUNT => 5))
)
GROUP BY requested ORDER BY requested;
-- EXPECT: two rows. EMPLOYEE keys in the 1.. range, JOB keys in the 1000..
-- range, 5 distinct each, both PASS. -------------------------------- PASS/FAIL

-- T2.3b  Name varying PER ROW - the realistic case when one function serves
--        several tables in one load. Harder than T2.3a.
CREATE OR REPLACE TABLE w6_mixed_stage (LOGICAL_NAME VARCHAR(100));
INSERT INTO w6_mixed_stage VALUES
    ('EMPLOYEE_SEQ'), ('JOB_SEQ'), ('EMPLOYEE_SEQ'), ('JOB_SEQ'), ('EMPLOYEE_SEQ');

WITH keyed AS (
    SELECT LOGICAL_NAME, w6_branch_selector(LOGICAL_NAME) AS k FROM w6_mixed_stage
)
SELECT COUNT(*) AS rows_out,
       COUNT(DISTINCT k) AS distinct_keys,
       SUM(CASE WHEN LOGICAL_NAME = 'EMPLOYEE_SEQ' AND k < 1000 THEN 1
                WHEN LOGICAL_NAME = 'JOB_SEQ'      AND k >= 1000 THEN 1
                ELSE 0 END) AS keys_from_correct_sequence,
       CASE WHEN COUNT(DISTINCT k) = COUNT(*)
             AND COUNT(*) = SUM(CASE WHEN LOGICAL_NAME = 'EMPLOYEE_SEQ' AND k < 1000 THEN 1
                                     WHEN LOGICAL_NAME = 'JOB_SEQ'      AND k >= 1000 THEN 1
                                     ELSE 0 END)
            THEN 'PASS - every row keyed from its own sequence'
            ELSE 'FAIL' END AS verdict
FROM keyed;
-- EXPECT: 5 / 5 / 5 / PASS. ----------------------------------------- PASS/FAIL

-- ==========================================================================
-- T2.4  DO UNTAKEN CASE ARMS CONSUME SEQUENCE VALUES?
-- ==========================================================================
-- THE REAL UNKNOWN. Using Sequences: "Each occurrence of a sequence generates
-- a set of distinct values" - wording about occurrences in the STATEMENT, not
-- branches taken. So a CASE may burn a value from EVERY arm, per row.
--
-- MEASURED VIA INFORMATION_SCHEMA, NOT A BARE NEXTVAL. R3's T1.5 tried to
-- measure consumption with SELECT seq.NEXTVAL and got a misleading answer,
-- because direct and UDF calls draw from different reserved ranges (NOORDER).
-- INFORMATION_SCHEMA.SEQUENCES.NEXT_VALUE reads the metadata and consumes
-- nothing, so it is the right instrument. Do not substitute a bare NEXTVAL.
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE w6_employee_seq START 1    INCREMENT 1;
CREATE OR REPLACE SEQUENCE w6_job_seq      START 1000 INCREMENT 1;

-- T2.4a  Snapshot BEFORE. Keep this screenshot.
SELECT SEQUENCE_NAME, NEXT_VALUE, ORDERED
FROM INFORMATION_SCHEMA.SEQUENCES
WHERE SEQUENCE_SCHEMA = CURRENT_SCHEMA()
  AND SEQUENCE_NAME IN ('W6_EMPLOYEE_SEQ','W6_JOB_SEQ')
ORDER BY SEQUENCE_NAME;
-- EXPECT: NEXT_VALUE 1 and 1000. Note ORDERED too - 'NO' means NOORDER, which
-- explains R3's T1.5 and is the property this design wants. --------- RECORD

-- T2.4b  Draw 20 rows, ALL asking for EMPLOYEE_SEQ. JOB_SEQ is never selected.
SELECT COUNT(*) AS rows_drawn, COUNT(DISTINCT k) AS distinct_keys
FROM (SELECT w6_branch_selector('EMPLOYEE_SEQ') AS k
      FROM TABLE(GENERATOR(ROWCOUNT => 20)));
-- EXPECT: 20 / 20. -------------------------------------------------- PASS/FAIL

-- T2.4c  Snapshot AFTER, and the verdict in one row.
SELECT
    MAX(CASE WHEN SEQUENCE_NAME = 'W6_EMPLOYEE_SEQ' THEN NEXT_VALUE END) AS employee_next,
    MAX(CASE WHEN SEQUENCE_NAME = 'W6_JOB_SEQ'      THEN NEXT_VALUE END) AS job_next,
    CASE WHEN MAX(CASE WHEN SEQUENCE_NAME = 'W6_JOB_SEQ' THEN TO_NUMBER(NEXT_VALUE) END) = 1000
         THEN 'UNTAKEN ARMS ARE FREE - job_seq never moved'
         ELSE 'UNTAKEN ARMS CONSUME - job_seq advanced without being selected'
    END AS verdict
FROM INFORMATION_SCHEMA.SEQUENCES
WHERE SEQUENCE_SCHEMA = CURRENT_SCHEMA()
  AND SEQUENCE_NAME IN ('W6_EMPLOYEE_SEQ','W6_JOB_SEQ');
-- INTERPRETATION - neither outcome sinks the design, but they differ:
--   job_next = 1000  -> untaken arms cost nothing. Many sequences may live in
--                       one function safely.
--   job_next > 1000  -> every arm consumes. Tolerable, since gaps are never
--                       guaranteed anyway, BUT it argues for one function per
--                       sequence once the branch list grows, and the wasted
--                       consumption must be documented so nobody reads the
--                       gaps as lost rows.
-- Either way, record the number. ------------------------------------ RECORD

-- --------------------------------------------------------------------------
-- TEARDOWN
-- --------------------------------------------------------------------------
DROP FUNCTION IF EXISTS w6_qualified_test();
DROP FUNCTION IF EXISTS w6_unqualified_test();
DROP FUNCTION IF EXISTS w6_registry_lookup_test(VARCHAR);
DROP FUNCTION IF EXISTS w6_param_identifier_test(VARCHAR);
DROP FUNCTION IF EXISTS w6_branch_selector(VARCHAR);
DROP TABLE    IF EXISTS w6_sequence_registry;
DROP TABLE    IF EXISTS w6_mixed_stage;
DROP SEQUENCE IF EXISTS w6_employee_seq;
DROP SEQUENCE IF EXISTS w6_job_seq;

-- ==========================================================================
-- WHAT THE RESULTS MEAN FOR R2
-- ==========================================================================
-- T2.1a+b pass          -> use the UNQUALIFIED form in the real function (R8).
-- T2.2a+b fail          -> the registry CANNOT be an indirection inside a UDF.
--                          It stays useful as a REGISTRY: generate the
--                          function's CASE arms from it, so onboarding a table
--                          is still "insert a row, re-run the generator".
-- T2.2 unexpectedly PASSES -> significant. Nikhil's original design works as
--                          drafted; tell the team before building anything.
-- T2.3a+b pass          -> R2 is satisfied by the branch selector. Closes R2.
-- T2.4 job_seq moved    -> add "one function per sequence" to the build
--                          standard, and document the consumption.
-- ==========================================================================
