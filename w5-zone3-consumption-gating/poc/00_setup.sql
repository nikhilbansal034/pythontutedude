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
       CREATE TAG in a schema it owns. This stands in for the BATCH
       IDENTITY — the thing that runs the nightly refresh.
     - A second role to stand in for a reporting role. It needs no
       privileges granted up front; the scripts grant what they need.
     - A THIRD role to stand in for the Liquibase deployment role, which
       OWNS the published tables. The user running these scripts must be
       able to USE both this and the batch role.
     - A warehouse. XSMALL is fine for everything except 05.

   WHY A THIRD ROLE — read this before changing it.
     The recommendation (O10 over O8) rests on ONE claim: that replacing
     a table's CONTENTS leaves its OWNER alone, where replacing the
     OBJECT hands ownership to whoever ran the statement.
     If the same role both owns the table and refreshes it, the owner
     reads back unchanged either way and TC-003 / TC-006 prove NOTHING.
     So: the deploy role owns the published tables; the batch role holds
     only SELECT / INSERT / DELETE / UPDATE on them. That split is the
     test. Collapse it and the critical test cases become decorative.

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
SET deploy_role = 'POC_DEPLOY_ROLE';   -- stands in for the Liquibase deployment role
                                       -- OWNS the published tables. See PREREQUISITES.

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
   Group membership WITH a per-cycle refresh expectation (R22).

   Objects in one consistency group refresh on different cadences, so
   "the group is complete" is NOT "every object loaded this cycle".
   Without this table the gate cannot tell a job that FAILED from one
   that was never DUE, and must either block every cycle on which some
   member is not scheduled, or pass a genuine failure.

   DUE_THIS_CYCLE stands in for what Stonebranch knows about tonight's
   run. In production it is derived, not typed.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE CTRL.GROUP_EXPECTATION (
    group_name      STRING,
    object_schema   STRING,
    object_name     STRING,
    refresh_cadence STRING,    -- DAILY | WEEKLY | YEARLY
    due_this_cycle  BOOLEAN
);

INSERT INTO CTRL.GROUP_EXPECTATION
  (group_name, object_schema, object_name, refresh_cadence, due_this_cycle)
VALUES
  ('PREMIUM','PUB','FACT_PREMIUM','DAILY' , TRUE),
  ('PREMIUM','PUB','DIM_POLICY'  ,'DAILY' , TRUE),
  ('PREMIUM','PUB','DIM_BROKER'  ,'WEEKLY', FALSE),   -- deliberately NOT due
  ('PREMIUM','PUB','DIM_DATE'    ,'YEARLY', FALSE);   -- deliberately NOT due

/* Staging and published state, one row per group object, so the gate
   can be written against the EXPECTATION rather than against a
   hardcoded "all four tables". */
CREATE OR REPLACE VIEW CTRL.V_STAGING_STATE AS
SELECT 'FACT_PREMIUM' AS object_name, COUNT(*) AS row_count, MAX(cycle_marker) AS staged_cycle FROM STG.FACT_PREMIUM
UNION ALL SELECT 'DIM_POLICY', COUNT(*), MAX(cycle_marker) FROM STG.DIM_POLICY
UNION ALL SELECT 'DIM_BROKER', COUNT(*), MAX(cycle_marker) FROM STG.DIM_BROKER
UNION ALL SELECT 'DIM_DATE'  , COUNT(*), MAX(cycle_marker) FROM STG.DIM_DATE;

CREATE OR REPLACE VIEW CTRL.V_PUBLISHED_STATE AS
SELECT 'FACT_PREMIUM' AS object_name, MAX(cycle_marker) AS published_cycle FROM PUB.FACT_PREMIUM
UNION ALL SELECT 'DIM_POLICY', MAX(cycle_marker) FROM PUB.DIM_POLICY
UNION ALL SELECT 'DIM_BROKER', MAX(cycle_marker) FROM PUB.DIM_BROKER
UNION ALL SELECT 'DIM_DATE'  , MAX(cycle_marker) FROM PUB.DIM_DATE;

CREATE OR REPLACE VIEW CTRL.V_GROUP_STATE AS
SELECT e.object_name, e.refresh_cadence, e.due_this_cycle,
       s.row_count, s.staged_cycle, p.published_cycle
FROM CTRL.GROUP_EXPECTATION e
JOIN CTRL.V_STAGING_STATE   s ON s.object_name = e.object_name
JOIN CTRL.V_PUBLISHED_STATE p ON p.object_name = e.object_name
WHERE e.group_name = 'PREMIUM';

/* ---------------------------------------------------------------------
   O12 fixture — publication by row access policy.

   O12 is compared against O11 and O16 in the deck, so it needs evidence
   like the others. It also supplies the row access policy that R26
   requires and that the fixture otherwise lacks.

   The mechanism: both cycles' rows live in the table at once, and a row
   access policy admits only the cycle named in CTRL.PUBLISHED_VERSION.
   Publication is an UPDATE of that one marker row.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE CTRL.PUBLISHED_VERSION (
    group_name    STRING,
    visible_cycle NUMBER
);
INSERT INTO CTRL.PUBLISHED_VERSION (group_name, visible_cycle) VALUES ('RAP', 1);

CREATE OR REPLACE ROW ACCESS POLICY GOV.RAP_VISIBLE_CYCLE
  AS (cycle_marker NUMBER) RETURNS BOOLEAN ->
     cycle_marker = (SELECT visible_cycle
                     FROM CTRL.PUBLISHED_VERSION
                     WHERE group_name = 'RAP');

/* Two tables, so "the whole group flips together" is actually testable. */
CREATE OR REPLACE TABLE PUB.RAP_FACT (
    fact_id      NUMBER,
    policy_id    NUMBER,
    amount       NUMBER(12,2),
    cycle_marker NUMBER
);
CREATE OR REPLACE TABLE PUB.RAP_DIM (
    policy_id    NUMBER,
    policy_name  STRING,
    cycle_marker NUMBER
);

/* cycle 1 = the published version; cycle 2 = staged, not yet visible */
INSERT INTO PUB.RAP_FACT SELECT seq4(), MOD(seq4(),10), 100, 1 FROM TABLE(GENERATOR(ROWCOUNT=>100));
INSERT INTO PUB.RAP_FACT SELECT seq4(), MOD(seq4(),10), 200, 2 FROM TABLE(GENERATOR(ROWCOUNT=>100));
INSERT INTO PUB.RAP_DIM  SELECT seq4(), 'policy_v1_' || seq4(), 1 FROM TABLE(GENERATOR(ROWCOUNT=>10));
INSERT INTO PUB.RAP_DIM  SELECT seq4(), 'policy_v2_' || seq4(), 2 FROM TABLE(GENERATOR(ROWCOUNT=>10));

ALTER TABLE PUB.RAP_FACT ADD ROW ACCESS POLICY GOV.RAP_VISIBLE_CYCLE ON (cycle_marker);
ALTER TABLE PUB.RAP_DIM  ADD ROW ACCESS POLICY GOV.RAP_VISIBLE_CYCLE ON (cycle_marker);

GRANT SELECT ON TABLE PUB.RAP_FACT TO ROLE IDENTIFIER($reader_role);
GRANT SELECT ON TABLE PUB.RAP_DIM  TO ROLE IDENTIFIER($reader_role);
/* NOTE: the reader is deliberately NOT granted anything on CTRL.
   A row access policy body runs with the policy owner's rights, so the
   reader should still be filtered correctly. TC-045 asserts that. */

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
   HAND THE PUBLISHED TABLES TO THE DEPLOY ROLE.

   Up to this point the batch role created everything, which is the
   convenient way to write a setup script and the WRONG way to model the
   design. In the real thing, Liquibase deploys and owns the published
   tables; the batch identity only ever changes their CONTENTS.

   Order matters. Grant the batch role its DML first, then transfer
   ownership with COPY CURRENT GRANTS so those grants (and the reader's
   SELECT) survive the transfer. REVOKE CURRENT GRANTS would strip them
   and leave the batch role unable to refresh anything.
   --------------------------------------------------------------------- */
/* The deploy role needs enough to act as a deployment role: reach the
   objects, and APPLY the tags it binds at deploy time. It gets no DML
   on anything — it deploys and governs, it does not load. */
GRANT USAGE ON DATABASE IDENTIFIER($poc_db) TO ROLE IDENTIFIER($deploy_role);
GRANT USAGE ON SCHEMA   PUB  TO ROLE IDENTIFIER($deploy_role);
GRANT USAGE ON SCHEMA   STG  TO ROLE IDENTIFIER($deploy_role);
GRANT USAGE ON SCHEMA   GOV  TO ROLE IDENTIFIER($deploy_role);
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE IDENTIFIER($deploy_role);
GRANT APPLY ON TAG GOV.PII_EMAIL        TO ROLE IDENTIFIER($deploy_role);
GRANT APPLY ON TAG GOV.PII_EMAIL_SCHEMA TO ROLE IDENTIFIER($deploy_role);

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE PUB.CUSTOMER_360 TO ROLE IDENTIFIER($exec_role);
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE PUB.FACT_PREMIUM TO ROLE IDENTIFIER($exec_role);
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE PUB.DIM_POLICY   TO ROLE IDENTIFIER($exec_role);
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE PUB.DIM_BROKER   TO ROLE IDENTIFIER($exec_role);
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE PUB.DIM_DATE     TO ROLE IDENTIFIER($exec_role);

GRANT OWNERSHIP ON TABLE PUB.CUSTOMER_360 TO ROLE IDENTIFIER($deploy_role) COPY CURRENT GRANTS;
GRANT OWNERSHIP ON TABLE PUB.FACT_PREMIUM TO ROLE IDENTIFIER($deploy_role) COPY CURRENT GRANTS;
GRANT OWNERSHIP ON TABLE PUB.DIM_POLICY   TO ROLE IDENTIFIER($deploy_role) COPY CURRENT GRANTS;
GRANT OWNERSHIP ON TABLE PUB.DIM_BROKER   TO ROLE IDENTIFIER($deploy_role) COPY CURRENT GRANTS;
GRANT OWNERSHIP ON TABLE PUB.DIM_DATE     TO ROLE IDENTIFIER($deploy_role) COPY CURRENT GRANTS;

/* Staging stays with the batch role. Only PUBLISHED objects are the
   deploy role's — staging is the batch's working area, and modelling it
   otherwise would just add role switches that prove nothing. */

/* ---------------------------------------------------------------------
   SETUP ASSERTION — run this and read it before running 01.
   Expected: owner = POC_DEPLOY_ROLE on all five published tables.
   If it says POC_ROLE, the ownership transfer did not happen and
   TC-003 / TC-006 will produce a false PASS. Stop and fix it.
   --------------------------------------------------------------------- */
SHOW TABLES IN SCHEMA PUB;
SELECT 'SETUP owner check (expect POC_DEPLOY_ROLE on all rows)' AS check_,
       "name", "owner"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE  "name" IN ('CUSTOMER_360','FACT_PREMIUM','DIM_POLICY','DIM_BROKER','DIM_DATE')
ORDER BY "name";

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
