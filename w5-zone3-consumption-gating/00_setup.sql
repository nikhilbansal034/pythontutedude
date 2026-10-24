/* =====================================================================
   Zone 3 Consumption Gating POC — 00 SETUP
   Run this first. Every other script depends on it.
   =====================================================================
   DISCIPLINE (same as POC02 / POC05 packs)
     - Synthetic data only. No LM data is read or written.
     - Everything lives inside one throwaway database.
     - One least-privilege role. No ACCOUNTADMIN, no USE SECONDARY ROLES ALL.
     - Teardown is a single statement (99_teardown.sql).

   PREREQUISITES
     - A role that can CREATE DATABASE, and can CREATE MASKING POLICY /
       CREATE TAG in a schema it owns.
     - A second role to stand in for a reporting role. It needs no
       privileges granted up front; the scripts grant what they need.
     - A warehouse. XSMALL is fine for everything except 05.

   HOW TO USE
     Replace the four SET values below, run this whole file, then run
     01 .. 05 in any order. Each test case is delimited and prints its
     own EXPECTED result. Capture the grid for each and record it
     against the TC id in Zone3_Gating_Test_Tracker.xlsx.
   ===================================================================== */

SET wh          = 'POC_WH';
SET poc_db      = 'POC_GATING_DB';
SET exec_role   = 'POC_ROLE';          -- stands in for the batch identity
SET reader_role = 'POC_READER_ROLE';   -- stands in for a reporting role

USE ROLE IDENTIFIER($exec_role);
USE WAREHOUSE IDENTIFIER($wh);

CREATE DATABASE IF NOT EXISTS IDENTIFIER($poc_db);
USE DATABASE IDENTIFIER($poc_db);

/* ---------------------------------------------------------------------
   Schemas, mirroring the proposed layout in solution_design.md §5.2
   --------------------------------------------------------------------- */
CREATE SCHEMA IF NOT EXISTS GOV;        -- tags + policies. Never swapped
CREATE SCHEMA IF NOT EXISTS SRC;        -- synthetic source data
CREATE SCHEMA IF NOT EXISTS PUB;        -- stands in for Z3_PUB_<group>
CREATE SCHEMA IF NOT EXISTS STG;        -- stands in for Z3_STG_<group>
CREATE SCHEMA IF NOT EXISTS CONSUME;    -- the view estate. Never swapped
CREATE SCHEMA IF NOT EXISTS CTRL;       -- publication state + gate results
CREATE SCHEMA IF NOT EXISTS SCHEMA_TAG; -- for TC-010 only: schema-level tag test

GRANT USAGE ON DATABASE  IDENTIFIER($poc_db) TO ROLE IDENTIFIER($reader_role);
GRANT USAGE ON SCHEMA    PUB     TO ROLE IDENTIFIER($reader_role);
GRANT USAGE ON SCHEMA    STG     TO ROLE IDENTIFIER($reader_role);
GRANT USAGE ON SCHEMA    CONSUME TO ROLE IDENTIFIER($reader_role);
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE IDENTIFIER($reader_role);

/* ---------------------------------------------------------------------
   Governance objects.

   Tags are bound at COLUMN level, per solution_design.md §5.3 — because
   a table cloned out of a schema is NOT protected by a tag-based policy
   set at schema level. TC-010 deliberately tests the schema-level form
   to demonstrate that difference.
   --------------------------------------------------------------------- */
CREATE OR REPLACE MASKING POLICY GOV.MASK_EMAIL AS (val STRING)
  RETURNS STRING ->
  CASE WHEN CURRENT_ROLE() = 'POC_ROLE' THEN val
       ELSE SHA2(val, 256) END;

CREATE OR REPLACE TAG GOV.PII_EMAIL;
ALTER TAG GOV.PII_EMAIL SET MASKING POLICY GOV.MASK_EMAIL;

/* A second policy + tag, used by TC-010's schema-level binding test. */
CREATE OR REPLACE MASKING POLICY GOV.MASK_EMAIL_2 AS (val STRING)
  RETURNS STRING ->
  CASE WHEN CURRENT_ROLE() = 'POC_ROLE' THEN val ELSE '***SCHEMA-MASKED***' END;

CREATE OR REPLACE TAG GOV.PII_EMAIL_SCHEMA;
ALTER TAG GOV.PII_EMAIL_SCHEMA SET MASKING POLICY GOV.MASK_EMAIL_2;

/* ---------------------------------------------------------------------
   Declared governance baseline (solution_design.md §8.2).
   The gate reconciles against this, NOT against whatever happens to be
   bound to the live object. Without it, non-reinstatement (TC-039) is
   unimplementable.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE GOV.GOVERNANCE_BASELINE (
    group_name    STRING,
    object_schema STRING,
    object_name   STRING,
    column_name   STRING,
    tag_database  STRING,
    tag_schema    STRING,
    tag_name      STRING,
    tag_value     STRING,
    declared_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO GOV.GOVERNANCE_BASELINE
  (group_name, object_schema, object_name, column_name, tag_database, tag_schema, tag_name, tag_value)
SELECT 'PREMIUM', 'PUB', 'CUSTOMER_360', 'EMAIL', $poc_db, 'GOV', 'PII_EMAIL', 'EMAIL';

/* ---------------------------------------------------------------------
   Publication control (solution_design.md §7.1)
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE CTRL.PUBLICATION_LOG (
    group_name        STRING,
    cycle_id          STRING,
    published_at      TIMESTAMP_NTZ,
    published_by      STRING,
    jobs_expected     NUMBER,
    jobs_succeeded    NUMBER,
    gate_result       STRING,   -- PASS | FAIL | AUTHORISED_PARTIAL
    authorisation_ref STRING,
    previous_cycle_id STRING,
    mechanism         STRING    -- O10 | O11 | O16 | O12
);

CREATE OR REPLACE TABLE CTRL.GATE_RESULT (
    group_name  STRING,
    cycle_id    STRING,
    check_id    STRING,
    check_name  STRING,
    status      STRING,   -- PASS | FAIL
    detail      STRING,
    checked_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE CTRL.PARTIAL_RELEASE_AUTH (
    group_name     STRING,
    cycle_id       STRING,
    authorised_by  STRING,
    authorised_at  TIMESTAMP_NTZ,
    reason         STRING,
    failed_jobs    STRING
);

/* ---------------------------------------------------------------------
   Synthetic source data
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE SRC.CUSTOMER_SRC AS
SELECT seq4()                                     AS customer_id,
       'cust'  || seq4() || '@example.invalid'     AS email,
       'Name ' || seq4()                           AS customer_name,
       100 + seq4()                                AS premium_amt,
       1                                           AS cycle_marker
FROM TABLE(GENERATOR(ROWCOUNT => 1000));

/* A four-object group, for the group-atomicity tests. cycle_marker is
   how a reader proves it saw one cycle rather than a mixture. */
CREATE OR REPLACE TABLE SRC.FACT_PREMIUM AS
SELECT seq4() AS premium_id, MOD(seq4(), 100) AS policy_id,
       MOD(seq4(), 50) AS broker_id, 1000 + seq4() AS amt, 1 AS cycle_marker
FROM TABLE(GENERATOR(ROWCOUNT => 5000));

CREATE OR REPLACE TABLE SRC.DIM_POLICY AS
SELECT seq4() AS policy_id, 'POL-' || seq4() AS policy_no, 1 AS cycle_marker
FROM TABLE(GENERATOR(ROWCOUNT => 100));

CREATE OR REPLACE TABLE SRC.DIM_BROKER AS
SELECT seq4() AS broker_id, 'BRK-' || seq4() AS broker_cd, 1 AS cycle_marker
FROM TABLE(GENERATOR(ROWCOUNT => 50));

CREATE OR REPLACE TABLE SRC.DIM_DATE AS
SELECT seq4() AS date_key,
       DATEADD('day', seq4(), '2026-01-01')::DATE AS cal_date, 1 AS cycle_marker
FROM TABLE(GENERATOR(ROWCOUNT => 365));

/* ---------------------------------------------------------------------
   The published objects, as Liquibase would deploy them:
   created once, then governed, then only ever refreshed by DML.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE PUB.CUSTOMER_360 (
    customer_id   NUMBER,
    email         STRING,
    customer_name STRING,
    premium_amt   NUMBER,
    cycle_marker  NUMBER
);
ALTER TABLE PUB.CUSTOMER_360 MODIFY COLUMN email SET TAG GOV.PII_EMAIL = 'EMAIL';
GRANT SELECT ON TABLE PUB.CUSTOMER_360 TO ROLE IDENTIFIER($reader_role);
INSERT INTO PUB.CUSTOMER_360 SELECT * FROM SRC.CUSTOMER_SRC;

/* The group, published + staging halves, both pre-deployed. */
CREATE OR REPLACE TABLE PUB.FACT_PREMIUM LIKE SRC.FACT_PREMIUM;
CREATE OR REPLACE TABLE PUB.DIM_POLICY   LIKE SRC.DIM_POLICY;
CREATE OR REPLACE TABLE PUB.DIM_BROKER   LIKE SRC.DIM_BROKER;
CREATE OR REPLACE TABLE PUB.DIM_DATE     LIKE SRC.DIM_DATE;

CREATE OR REPLACE TABLE STG.FACT_PREMIUM LIKE SRC.FACT_PREMIUM;
CREATE OR REPLACE TABLE STG.DIM_POLICY   LIKE SRC.DIM_POLICY;
CREATE OR REPLACE TABLE STG.DIM_BROKER   LIKE SRC.DIM_BROKER;
CREATE OR REPLACE TABLE STG.DIM_DATE     LIKE SRC.DIM_DATE;
CREATE OR REPLACE TABLE STG.CUSTOMER_360 LIKE PUB.CUSTOMER_360;
ALTER TABLE STG.CUSTOMER_360 MODIFY COLUMN email SET TAG GOV.PII_EMAIL = 'EMAIL';

GRANT SELECT ON ALL TABLES IN SCHEMA PUB TO ROLE IDENTIFIER($reader_role);
GRANT SELECT ON ALL TABLES IN SCHEMA STG TO ROLE IDENTIFIER($reader_role);

INSERT INTO PUB.FACT_PREMIUM SELECT * FROM SRC.FACT_PREMIUM;
INSERT INTO PUB.DIM_POLICY   SELECT * FROM SRC.DIM_POLICY;
INSERT INTO PUB.DIM_BROKER   SELECT * FROM SRC.DIM_BROKER;
INSERT INTO PUB.DIM_DATE     SELECT * FROM SRC.DIM_DATE;

/* ---------------------------------------------------------------------
   The view estate.
     V_PREMIUM_REPORT   — scenario V-a: reads only gated tables.
                          Must never be edited by this design (C1).
     V_CUSTOMER_360     — scenario V-b: the view whose output gets
                          physicalized by INSERT OVERWRITE.
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW CONSUME.V_PREMIUM_REPORT AS
SELECT f.premium_id, f.amt, p.policy_no, b.broker_cd,
       f.cycle_marker AS f_cycle, p.cycle_marker AS p_cycle,
       b.cycle_marker AS b_cycle
FROM   PUB.FACT_PREMIUM f
JOIN   PUB.DIM_POLICY   p ON p.policy_id = f.policy_id
JOIN   PUB.DIM_BROKER   b ON b.broker_id = f.broker_id;

CREATE OR REPLACE VIEW CONSUME.V_CUSTOMER_360 AS
SELECT customer_id, email, customer_name, premium_amt, cycle_marker
FROM   SRC.CUSTOMER_SRC;

GRANT SELECT ON ALL VIEWS IN SCHEMA CONSUME TO ROLE IDENTIFIER($reader_role);

/* ---------------------------------------------------------------------
   Reusable capture helpers. Run these before and after any mechanism;
   the TC scripts call them by name in their comments.
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW CTRL.V_TAGS_PUB AS
SELECT object_schema, object_name, column_name, tag_name, tag_value
FROM   SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES          -- NOTE: has latency
WHERE  object_database = CURRENT_DATABASE();
/* For a GATE, use INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS instead —
   ACCOUNT_USAGE is not real-time. The TC scripts use the real-time form. */

SELECT 'SETUP COMPLETE' AS status,
       CURRENT_DATABASE() AS db, CURRENT_ROLE() AS role,
       CURRENT_WAREHOUSE() AS wh, CURRENT_VERSION() AS snowflake_version;
/* Record snowflake_version in the tracker: COPY TAGS (Apr 2026) and the
   dynamic-table pass-through change (Jul 2026) are recent enough that
   behaviour can differ by account release. */
