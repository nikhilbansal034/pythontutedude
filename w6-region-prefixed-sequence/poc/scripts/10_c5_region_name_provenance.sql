-- ==========================================================================
-- W6 / C5 - WHERE DOES THE REGION NAME COME FROM, AND WHAT IF IT IS WRONG?
-- ==========================================================================
-- R8 says the region name is an input, never hard-coded. The transcript never
-- says where the ETL gets it. A region name hard-coded in a job definition is
-- a hard-coded region with extra steps.
--
-- >>> SCOPE LIMIT, STATED UP FRONT. <<<
-- Which mechanism the ETL should use is an ORCHESTRATOR decision (IDMC), not a
-- Snowflake one. This script cannot choose for you. What it CAN do - and what
-- matters more - is test each candidate mechanism inside Snowflake and, above
-- all, characterise THE FAILURE MODE when the region name is wrong or missing.
-- That failure mode is the real risk, and it is fully testable here.
--
--   T10.1  Candidate A - region name passed as a literal argument
--   T10.2  Candidate B - derived from the deployment (CURRENT_SCHEMA)
--   T10.3  Candidate C - read from a one-row config table per deployment
--   T10.4  FAILURE MODE - an unknown region name          <<< the important one
--   T10.5  FAILURE MODE - a NULL region name
--   T10.6  Does a bad region name CORRUPT or merely FAIL?
--   T10.7  A guard that makes the failure loud
--
-- Runtime: about two minutes, single session.
-- ==========================================================================

USE DATABASE LM_POC_DB;
DROP SCHEMA IF EXISTS W6V10 CASCADE;
CREATE SCHEMA W6V10;
USE SCHEMA W6V10;

CREATE OR REPLACE SEQUENCE emp_seq_v10 START 1 INCREMENT 1;
CREATE OR REPLACE TABLE region_map_v10 (REGION_NAME VARCHAR(100), REGION_CODE NUMBER(9,0));
INSERT INTO region_map_v10 VALUES ('North America', 1), ('EU', 2), ('APAC', 3);

-- One-row deployment config, Candidate C's mechanism.
CREATE OR REPLACE TABLE deployment_config_v10 (SETTING VARCHAR(50), VALUE VARCHAR(100));
INSERT INTO deployment_config_v10 VALUES ('REGION_NAME', 'North America');

-- ==========================================================================
-- T10.1  CANDIDATE A - region name as a literal argument
-- ==========================================================================
-- What every test so far assumed. The ETL (or the orchestrator substituting
-- into it) supplies the name at the call site.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION key_by_arg_v10(region_name VARCHAR)
RETURNS NUMBER(38,0) VOLATILE
COMMENT = 'Candidate A. Sequence fully qualified per R12 v3 F19.'
AS $$
    CAST((SELECT m.REGION_CODE FROM region_map_v10 m WHERE m.REGION_NAME = region_name)
         * 1000000000000000 + LM_POC_DB.W6V10.emp_seq_v10.NEXTVAL AS NUMBER(38,0))
$$;

SELECT key_by_arg_v10('North America') AS k,
       FLOOR(key_by_arg_v10('North America') / 1000000000000000) AS decoded_region,
       'PASS - works, but the name must come from somewhere' AS verdict;
-- EXPECT: a 10^15-scale key decoding to 1.
-- NOTE: this is the mechanism, not the provenance. It pushes the question one
-- level up to whoever writes the call site. ------------------------- RECORD

-- ==========================================================================
-- T10.2  CANDIDATE B - derived from the deployment itself
-- ==========================================================================
-- If each region has its own schema/database, the region is implicit in WHERE
-- the function lives. No parameter, nothing to get wrong.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE schema_region_map_v10 (SCHEMA_NAME VARCHAR(100), REGION_NAME VARCHAR(100));
INSERT INTO schema_region_map_v10 VALUES ('W6V10', 'North America');

CREATE OR REPLACE FUNCTION key_by_deployment_v10()
RETURNS NUMBER(38,0) VOLATILE
COMMENT = 'Candidate B. Region implied by the deployment - no argument to get wrong.'
AS $$
    CAST((SELECT m.REGION_CODE
          FROM region_map_v10 m
          JOIN schema_region_map_v10 s ON s.REGION_NAME = m.REGION_NAME
          WHERE s.SCHEMA_NAME = 'W6V10')
         * 1000000000000000 + LM_POC_DB.W6V10.emp_seq_v10.NEXTVAL AS NUMBER(38,0))
$$;

SELECT key_by_deployment_v10() AS k,
       FLOOR(key_by_deployment_v10() / 1000000000000000) AS decoded_region,
       'PASS - no caller input, so no caller can get it wrong' AS verdict;
-- EXPECT: decodes to 1.
-- TRADE-OFF: removes the failure mode entirely, but the function text now
-- differs per region, and R2's agreed signature takes region_name. Raise with
-- Nidwika before adopting. ------------------------------------------ RECORD

-- ==========================================================================
-- T10.3  CANDIDATE C - read from a one-row config table
-- ==========================================================================
CREATE OR REPLACE FUNCTION key_by_config_v10()
RETURNS NUMBER(38,0) VOLATILE
COMMENT = 'Candidate C. One config row per deployment; identical function text everywhere.'
AS $$
    CAST((SELECT m.REGION_CODE FROM region_map_v10 m
          WHERE m.REGION_NAME = (SELECT c.VALUE FROM deployment_config_v10 c
                                 WHERE c.SETTING = 'REGION_NAME'))
         * 1000000000000000 + LM_POC_DB.W6V10.emp_seq_v10.NEXTVAL AS NUMBER(38,0))
$$;

SELECT key_by_config_v10() AS k,
       FLOOR(key_by_config_v10() / 1000000000000000) AS decoded_region,
       'PASS - identical function text in every region; only the config row differs' AS verdict;
-- EXPECT: decodes to 1. This is the closest thing to R8's original promise.
-- ------------------------------------------------------------------ RECORD

-- ==========================================================================
-- T10.4  FAILURE MODE - AN UNKNOWN REGION NAME     <<< THE IMPORTANT TEST
-- ==========================================================================
-- A typo, a renamed region, a job pointed at the wrong value. Does the key
-- come out wrong, or does the load fail?
-- --------------------------------------------------------------------------
SELECT key_by_arg_v10('Noth America')  AS typo_key,          -- note the typo
       key_by_arg_v10('NORTH AMERICA') AS wrong_case_key,
       key_by_arg_v10('LATAM')         AS unmapped_key;
-- EXPECT: all three NULL, because the lookup finds no row.
-- >>> A NULL SURROGATE KEY IS THE DANGER. It does not raise an error here. <<<
-- ------------------------------------------------------------------ RECORD

-- What happens when that NULL reaches the target?
CREATE OR REPLACE TABLE target_nullable_v10   (EMPLOYEE_ID NUMBER(38,0), PIN VARCHAR(30));
CREATE OR REPLACE TABLE target_notnull_v10    (EMPLOYEE_ID NUMBER(38,0) NOT NULL, PIN VARCHAR(30));

INSERT INTO target_nullable_v10
SELECT key_by_arg_v10('Noth America'), 'PIN-' || SEQ4() FROM TABLE(GENERATOR(ROWCOUNT => 10));

SELECT COUNT(*) AS rows_inserted,
       SUM(CASE WHEN EMPLOYEE_ID IS NULL THEN 1 ELSE 0 END) AS null_keys,
       CASE WHEN SUM(CASE WHEN EMPLOYEE_ID IS NULL THEN 1 ELSE 0 END) > 0
            THEN 'DANGEROUS - rows loaded with NULL surrogate keys and NO error raised'
            ELSE 'rows carry real keys' END AS verdict
FROM target_nullable_v10;
-- EXPECT: 10 rows, 10 NULL keys, DANGEROUS.
-- A nullable key column turns a configuration mistake into silent data damage.
-- ------------------------------------------------------------------ PASS/FAIL

-- The same load against a NOT NULL column.
INSERT INTO target_notnull_v10
SELECT key_by_arg_v10('Noth America'), 'PIN-' || SEQ4() FROM TABLE(GENERATOR(ROWCOUNT => 10));
-- EXPECT: THIS STATEMENT FAILS with a NOT NULL violation. The failure is the
-- desired behaviour. Record the exact error text. ------------------- RECORD

SELECT COUNT(*) AS rows_in_notnull_target,
       CASE WHEN COUNT(*) = 0
            THEN 'PASS - NOT NULL on the key column converts silent corruption into a loud failure'
            ELSE 'CHECK - rows got in; the column may not be NOT NULL' END AS verdict
FROM target_notnull_v10;
-- ------------------------------------------------------------------ PASS/FAIL

-- ==========================================================================
-- T10.5  FAILURE MODE - A NULL REGION NAME
-- ==========================================================================
SELECT key_by_arg_v10(NULL) AS null_input_key,
       CASE WHEN key_by_arg_v10(NULL) IS NULL
            THEN 'NULL in, NULL out - same silent failure as T10.4'
            ELSE 'unexpected - a non-null key from a null region' END AS verdict;
-- EXPECT: NULL. ----------------------------------------------------- RECORD

-- ==========================================================================
-- T10.6  DOES A BAD REGION NAME CORRUPT, OR MERELY FAIL?
-- ==========================================================================
-- The worst case is not NULL. It is a VALID-LOOKING key carrying the WRONG
-- region - that would be undetectable downstream. Check that cannot happen.
-- --------------------------------------------------------------------------
SELECT 'EU name, NA deployment' AS scenario,
       key_by_arg_v10('EU') AS k,
       FLOOR(key_by_arg_v10('EU') / 1000000000000000) AS decoded_region,
       'The function obeys the ARGUMENT, not the deployment. A wrong-but-valid '
       || 'name produces a wrong-but-valid key, and nothing detects it.' AS implication;
-- EXPECT: decodes to 2 (EU) even though this deployment is North America.
-- >>> THIS IS THE REAL C5 RISK. A typo gives NULL and is catchable. A valid
-- name for the WRONG region gives a plausible key that is silently wrong. <<<
-- ------------------------------------------------------------------ RECORD

-- ==========================================================================
-- T10.7  A GUARD THAT MAKES BOTH FAILURE MODES LOUD
-- ==========================================================================
-- Candidate A plus a deployment check: the argument must match what this
-- deployment is allowed to issue.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION key_guarded_v10(region_name VARCHAR)
RETURNS NUMBER(38,0) VOLATILE
COMMENT = 'Candidate A with a deployment guard. Rejects a name this deployment may not issue.'
AS $$
    CAST(
        (SELECT m.REGION_CODE FROM region_map_v10 m
         WHERE m.REGION_NAME = region_name
           AND m.REGION_NAME = (SELECT c.VALUE FROM deployment_config_v10 c
                                WHERE c.SETTING = 'REGION_NAME'))
        * 1000000000000000 + LM_POC_DB.W6V10.emp_seq_v10.NEXTVAL
    AS NUMBER(38,0))
$$;

SELECT key_guarded_v10('North America') AS correct_region,
       key_guarded_v10('EU')            AS wrong_region,
       key_guarded_v10('Noth America')  AS typo,
       CASE WHEN key_guarded_v10('North America') IS NOT NULL
             AND key_guarded_v10('EU') IS NULL
             AND key_guarded_v10('Noth America') IS NULL
            THEN 'PASS - only this deployment''s own region yields a key; everything else is NULL'
            ELSE 'FAIL - the guard did not work' END AS verdict;
-- EXPECT: a real key for North America, NULL for both wrong inputs.
-- Combined with NOT NULL on the target column, a misconfigured job now FAILS
-- the load instead of writing a wrong key. ------------------------- PASS/FAIL

-- --------------------------------------------------------------------------
-- TEARDOWN
-- --------------------------------------------------------------------------
DROP SCHEMA IF EXISTS W6V10 CASCADE;

-- ==========================================================================
-- WHAT THIS ESTABLISHES FOR C5
-- ==========================================================================
-- This script does NOT choose the provenance mechanism - that is an IDMC
-- decision for Nidwika and the team. It establishes the following, which the
-- decision should be made on:
--
-- 1. All three candidates work in Snowflake (T10.1-T10.3). The choice is about
--    where the mistake can be made, not about capability.
-- 2. A wrong region name does NOT raise an error. It returns NULL (T10.4,
--    T10.5), and against a nullable key column that loads silently.
-- 3. The worst case is NOT the typo. A VALID name for the WRONG region gives a
--    plausible, wrong, undetectable key (T10.6). No amount of care at the call
--    site rules this out by itself.
-- 4. Two cheap controls remove both failure modes, and should be adopted
--    whichever mechanism is chosen:
--      a. EMPLOYEE_ID must be NOT NULL in the target - turns silent corruption
--         into a failed load (T10.4).
--      b. The function should verify the requested region against a
--         per-deployment config row (T10.7) - a job pointed at the wrong
--         region then produces nothing rather than something wrong.
--
-- RECOMMENDATION to put to the team: Candidate C (config row) or Candidate A
-- plus the T10.7 guard. Candidate B is the safest but changes R2's agreed
-- signature, so it needs Nidwika's agreement before it is considered.
-- ==========================================================================
