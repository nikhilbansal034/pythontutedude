/* =====================================================================
   POC07 — CTAS + SWAP      00_setup.sql
   =====================================================================
   Everything shared by all ten scenarios: database, schemas, roles,
   RBAC, tags, masking, base tables, source views, control tables.

   RUN THIS ONCE. Each scenario script then resets only the swap pair,
   the reader views and the control tables back to day 1 — the base
   layer and the governance objects below are never torn down between
   scenarios.

   ---------------------------------------------------------------------
   BEFORE YOU RUN
   ---------------------------------------------------------------------
   1. Set the warehouse on the next line to one you can use.
   2. Roles are created with SECURITYADMIN and objects with SYSADMIN.
      If your account restricts those, run the whole file as
      ACCOUNTADMIN - nothing else changes.
   3. Nothing here touches POC01 or POC02 objects. Every name starts
      P7_ and everything lives in one database, so 99_teardown.sql
      removes exactly what this created.

   ---------------------------------------------------------------------
   TWO DELIBERATE SIMPLIFICATIONS, recorded so nobody reads more into
   the results than is there
   ---------------------------------------------------------------------
   a) Masking is decided by CURRENT_ROLE() against an entitlement table,
      not per user and not per attribute. That proves the mechanism -
      tagged column masks for an unentitled role - without creating
      users and key pairs. Production keys on user, attribute and scope.
   b) The publish steps are plain SQL, not a stored procedure. Each
      scenario runs them in order so every step and its result is
      visible. Production wraps them in one owner's-rights procedure.
   ===================================================================== */

SET wh = 'COMPUTE_WH';          -- <<< CHANGE ME if needed

USE SECONDARY ROLES NONE;

/* =====================================================================
   1. ROLES
   ===================================================================== */
USE ROLE SECURITYADMIN;

CREATE ROLE IF NOT EXISTS P7_BASE_OWNER      COMMENT = 'owns the Zone 3 base tables and the source views';
CREATE ROLE IF NOT EXISTS P7_PUBLISH_ROLE    COMMENT = 'owns D_LIVE, D_STAGE and CTRL. Builds and swaps';
CREATE ROLE IF NOT EXISTS P7_VIEW_OWNER      COMMENT = 'owns D_VIEWS, the thin reader views';
CREATE ROLE IF NOT EXISTS P7_READER_OK       COMMENT = 'a report user ENTITLED to see real values';
CREATE ROLE IF NOT EXISTS P7_READER_NO       COMMENT = 'a report user NOT entitled - sees masked values';
CREATE ROLE IF NOT EXISTS P7_PROBE_ROLE      COMMENT = 'grant target for the grants scenario. No work of its own';
CREATE ROLE IF NOT EXISTS P7_BATCH_NOENT     COMMENT = 'a batch identity with NO entitlement row - writes masks';

/* every P7 role to SYSADMIN so one person can switch between them */
GRANT ROLE P7_BASE_OWNER   TO ROLE SYSADMIN;
GRANT ROLE P7_PUBLISH_ROLE TO ROLE SYSADMIN;
GRANT ROLE P7_VIEW_OWNER   TO ROLE SYSADMIN;
GRANT ROLE P7_READER_OK    TO ROLE SYSADMIN;
GRANT ROLE P7_READER_NO    TO ROLE SYSADMIN;
GRANT ROLE P7_PROBE_ROLE   TO ROLE SYSADMIN;
GRANT ROLE P7_BATCH_NOENT  TO ROLE SYSADMIN;

/* and to you, so USE ROLE works in your own session */
SET me = CURRENT_USER();
GRANT ROLE P7_BASE_OWNER   TO USER IDENTIFIER($me);
GRANT ROLE P7_PUBLISH_ROLE TO USER IDENTIFIER($me);
GRANT ROLE P7_VIEW_OWNER   TO USER IDENTIFIER($me);
GRANT ROLE P7_READER_OK    TO USER IDENTIFIER($me);
GRANT ROLE P7_READER_NO    TO USER IDENTIFIER($me);
GRANT ROLE P7_PROBE_ROLE   TO USER IDENTIFIER($me);
GRANT ROLE P7_BATCH_NOENT  TO USER IDENTIFIER($me);

/* =====================================================================
   2. DATABASE AND SCHEMAS
   ---------------------------------------------------------------------
   D_LIVE and D_STAGE are the swap pair. D_VIEWS and CTRL sit OUTSIDE
   it - a view inside a swapped schema would be swapped out with the
   tables, and CTRL would lose its own state mid-run.
   ===================================================================== */
USE ROLE SYSADMIN;
CREATE DATABASE IF NOT EXISTS P7_POC;
USE DATABASE P7_POC;

CREATE SCHEMA IF NOT EXISTS GOV;        -- tags, masking, entitlement. Never swapped
CREATE SCHEMA IF NOT EXISTS BASE;       -- Zone 3 base tables, loaded by "ETL"
CREATE SCHEMA IF NOT EXISTS SRC_VIEWS;  -- the existing complex views
CREATE SCHEMA IF NOT EXISTS D_LIVE;     -- published tables            ) the
CREATE SCHEMA IF NOT EXISTS D_STAGE;    -- next batch is built here    ) swap pair
CREATE SCHEMA IF NOT EXISTS D_VIEWS;    -- thin reader views. NEVER swapped
CREATE SCHEMA IF NOT EXISTS CTRL;       -- control tables. NEVER swapped

GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_BASE_OWNER;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_PUBLISH_ROLE;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_VIEW_OWNER;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_READER_OK;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_READER_NO;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_PROBE_ROLE;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_BATCH_NOENT;

GRANT USAGE ON DATABASE P7_POC TO ROLE P7_BASE_OWNER;
GRANT USAGE ON DATABASE P7_POC TO ROLE P7_PUBLISH_ROLE;
GRANT USAGE ON DATABASE P7_POC TO ROLE P7_VIEW_OWNER;
GRANT USAGE ON DATABASE P7_POC TO ROLE P7_READER_OK;
GRANT USAGE ON DATABASE P7_POC TO ROLE P7_READER_NO;
GRANT USAGE ON DATABASE P7_POC TO ROLE P7_PROBE_ROLE;
GRANT USAGE ON DATABASE P7_POC TO ROLE P7_BATCH_NOENT;

/* ownership of each schema, so each role really is tested on its own rights */
GRANT OWNERSHIP ON SCHEMA BASE      TO ROLE P7_BASE_OWNER   REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA SRC_VIEWS TO ROLE P7_BASE_OWNER   REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA D_LIVE    TO ROLE P7_PUBLISH_ROLE REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA D_STAGE   TO ROLE P7_PUBLISH_ROLE REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA CTRL      TO ROLE P7_PUBLISH_ROLE REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA D_VIEWS   TO ROLE P7_VIEW_OWNER   REVOKE CURRENT GRANTS;

/* the publishing role must be able to read the source views to build from them */
GRANT USAGE ON SCHEMA SRC_VIEWS TO ROLE P7_PUBLISH_ROLE;
GRANT USAGE ON SCHEMA BASE      TO ROLE P7_PUBLISH_ROLE;
GRANT USAGE ON SCHEMA GOV       TO ROLE P7_PUBLISH_ROLE;
GRANT USAGE ON SCHEMA GOV       TO ROLE P7_BASE_OWNER;

/* the view owner reads both swapped schemas so its views resolve after a swap.
   NOTE: this is exactly the standing access S04 TC-04.7 measures.          */
GRANT USAGE ON SCHEMA D_LIVE  TO ROLE P7_VIEW_OWNER;
GRANT USAGE ON SCHEMA D_STAGE TO ROLE P7_VIEW_OWNER;

/* readers reach D_VIEWS and nothing else */
GRANT USAGE ON SCHEMA D_VIEWS TO ROLE P7_READER_OK;
GRANT USAGE ON SCHEMA D_VIEWS TO ROLE P7_READER_NO;

/* the no-entitlement batch identity needs to build, like the real one */
GRANT USAGE ON SCHEMA SRC_VIEWS TO ROLE P7_BATCH_NOENT;
GRANT USAGE ON SCHEMA BASE      TO ROLE P7_BATCH_NOENT;
GRANT USAGE ON SCHEMA D_STAGE   TO ROLE P7_BATCH_NOENT;

/* =====================================================================
   3. GOVERNANCE - tags, entitlement, masking
   ===================================================================== */
USE ROLE SYSADMIN;
USE SCHEMA GOV;

CREATE TAG IF NOT EXISTS PII
  COMMENT = 'what a column holds. EMAIL | SSN';
CREATE TAG IF NOT EXISTS PII_SCOPE
  COMMENT = 'the governance scope of a table or schema. Tested for survival, not wired into masking in this POC';

/* who may see real values. Keyed on ROLE - see simplification (a) */
CREATE TABLE IF NOT EXISTS ENTITLEMENT (
    role_name   STRING,
    can_see_pii BOOLEAN,
    note        STRING
);
DELETE FROM ENTITLEMENT WHERE role_name LIKE 'P7_%';
INSERT INTO ENTITLEMENT (role_name, can_see_pii, note) VALUES
  ('P7_READER_OK'   , TRUE , 'an approved report user'),
  ('P7_PUBLISH_ROLE', TRUE , 'the batch identity - MUST be entitled or the CTAS writes masks'),
  ('P7_BASE_OWNER'  , TRUE , 'owns the raw data'),
  ('P7_READER_NO'   , FALSE, 'an unapproved report user'),
  ('P7_PROBE_ROLE'  , FALSE, 'grant target only'),
  ('P7_VIEW_OWNER'  , FALSE, 'deliberately NOT entitled, so TC-04.7 shows what it can read'),
  ('P7_BATCH_NOENT' , FALSE, 'deliberately NOT entitled - proves a writer stores masks');

/* the masking rule. Attached to the PII tag below, so tagging a column
   is what protects it - and losing the tag is what exposes it.        */
CREATE OR REPLACE MASKING POLICY MASK_PII AS (val STRING) RETURNS STRING ->
  CASE
    WHEN EXISTS ( SELECT 1
                  FROM P7_POC.GOV.ENTITLEMENT e
                  WHERE e.role_name   = CURRENT_ROLE()
                    AND e.can_see_pii = TRUE )
    THEN val
    ELSE '***MASKED***'
  END;

ALTER TAG PII SET MASKING POLICY MASK_PII;

GRANT APPLY ON TAG P7_POC.GOV.PII       TO ROLE P7_PUBLISH_ROLE;
GRANT APPLY ON TAG P7_POC.GOV.PII_SCOPE TO ROLE P7_PUBLISH_ROLE;
GRANT APPLY ON TAG P7_POC.GOV.PII       TO ROLE P7_BASE_OWNER;
GRANT APPLY ON TAG P7_POC.GOV.PII_SCOPE TO ROLE P7_BASE_OWNER;
GRANT SELECT ON TABLE P7_POC.GOV.ENTITLEMENT TO ROLE P7_PUBLISH_ROLE;

/* =====================================================================
   4. THE BASE LAYER - what the existing ETL loads
   ===================================================================== */
USE ROLE P7_BASE_OWNER;
USE DATABASE P7_POC;
USE SCHEMA BASE;

CREATE OR REPLACE TABLE CUSTOMER (
    customer_id NUMBER,
    full_name   STRING,
    email       STRING,      -- tagged PII
    ssn         STRING,      -- tagged PII
    batch_id    STRING       -- stamped by every load. The consistency evidence
);
CREATE OR REPLACE TABLE POLICY (
    policy_id   NUMBER,
    customer_id NUMBER,
    premium     NUMBER(12,2),
    batch_id    STRING
);

ALTER TABLE CUSTOMER MODIFY COLUMN email SET TAG P7_POC.GOV.PII = 'EMAIL';
ALTER TABLE CUSTOMER MODIFY COLUMN ssn   SET TAG P7_POC.GOV.PII = 'SSN';

GRANT SELECT ON ALL TABLES IN SCHEMA BASE TO ROLE P7_PUBLISH_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA BASE TO ROLE P7_PUBLISH_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA BASE TO ROLE P7_BATCH_NOENT;

/* ---------------------------------------------------------------------
   The source views - the existing complex logic, text never edited.
   V_CUSTOMER_360 builds CUSTOMER_360;  V_POLICY_SUMMARY builds
   POLICY_SUMMARY.  (Convention: table name = view name without V_.)
   --------------------------------------------------------------------- */
USE SCHEMA SRC_VIEWS;

CREATE OR REPLACE VIEW V_CUSTOMER_360 AS
SELECT c.customer_id,
       c.full_name,
       c.email,
       c.ssn,
       COUNT(p.policy_id) AS policy_count,
       c.batch_id
FROM BASE.CUSTOMER c
LEFT JOIN BASE.POLICY p ON p.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name, c.email, c.ssn, c.batch_id;

CREATE OR REPLACE VIEW V_POLICY_SUMMARY AS
SELECT p.policy_id,
       p.customer_id,
       p.premium,
       p.batch_id
FROM BASE.POLICY p;

GRANT SELECT ON ALL VIEWS IN SCHEMA SRC_VIEWS TO ROLE P7_PUBLISH_ROLE;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA SRC_VIEWS TO ROLE P7_PUBLISH_ROLE;
GRANT SELECT ON ALL VIEWS IN SCHEMA SRC_VIEWS TO ROLE P7_BATCH_NOENT;

/* =====================================================================
   5. CONTROL TABLES  (four, not nine)
   ===================================================================== */
USE ROLE P7_PUBLISH_ROLE;
USE DATABASE P7_POC;
USE SCHEMA CTRL;

CREATE OR REPLACE TABLE OBJECT_REGISTRY (
    object_name  STRING,     -- CUSTOMER_360   (built from V_CUSTOMER_360)
    object_type  STRING,     -- SOURCE | PUBLISHED
    is_required  STRING DEFAULT 'Y',
    live_schema  STRING,
    stage_schema STRING
);

CREATE OR REPLACE TABLE OBJECT_DEPENDENCY (
    object_name       STRING,
    depends_on_object STRING  -- Zone 3 objects only. Zone 2 is not tracked
);

CREATE OR REPLACE TABLE BATCH_STATUS (
    batch_id       STRING,
    object_name    STRING,
    status         STRING,    -- COMPLETED | FAILED | PENDING
    status_at      TIMESTAMP_NTZ,
    exception_flag STRING DEFAULT 'N',
    approved_by    STRING,
    approved_at    TIMESTAMP_NTZ,
    reason         STRING
);

CREATE OR REPLACE TABLE PUBLISH_LOG (
    batch_id        STRING,
    attempted_at    TIMESTAMP_NTZ,
    outcome         STRING,    -- PUBLISHED | REFUSED
    refused_reason  STRING,
    exceptions_used STRING,
    run_by          STRING
);

/* the registry and the dependency graph for this POC */
INSERT INTO OBJECT_REGISTRY (object_name, object_type, is_required, live_schema, stage_schema) VALUES
  ('CUSTOMER'      ,'SOURCE'   ,'Y','',''),
  ('POLICY'        ,'SOURCE'   ,'Y','',''),
  ('CUSTOMER_360'  ,'PUBLISHED','Y','D_LIVE','D_STAGE'),
  ('POLICY_SUMMARY','PUBLISHED','Y','D_LIVE','D_STAGE');

INSERT INTO OBJECT_DEPENDENCY (object_name, depends_on_object) VALUES
  ('CUSTOMER_360'  ,'CUSTOMER'),
  ('CUSTOMER_360'  ,'POLICY'),
  ('POLICY_SUMMARY','POLICY');

/* =====================================================================
   6. SETUP ASSERTIONS - read these before running any scenario
   ===================================================================== */
USE ROLE SYSADMIN;
USE DATABASE P7_POC;

/* 6a. the schemas exist and are owned by the right roles */
SHOW SCHEMAS IN DATABASE P7_POC;
SELECT '6a schema owners' AS check_name, "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" IN ('BASE','SRC_VIEWS','GOV','D_LIVE','D_STAGE','D_VIEWS','CTRL')
ORDER BY "name";
/* EXPECT  D_LIVE, D_STAGE, CTRL -> P7_PUBLISH_ROLE
           D_VIEWS              -> P7_VIEW_OWNER
           BASE, SRC_VIEWS      -> P7_BASE_OWNER                        */

/* 6b. the base columns carry their tags */
SELECT '6b base tags' AS check_name, column_name, tag_name, tag_value
FROM TABLE(P7_POC.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('P7_POC.BASE.CUSTOMER','table'))
ORDER BY column_name;
/* EXPECT  email -> PII = EMAIL,  ssn -> PII = SSN                       */

/* 6c. masking really is driven by the tag.
       Load one row, read it as an entitled role and an unentitled one. */
USE ROLE P7_BASE_OWNER;
INSERT INTO P7_POC.BASE.CUSTOMER
VALUES (999,'Setup Check','setup@example.invalid','000-00-0000','B0');

SELECT '6c entitled role (expect REAL values)' AS check_name, email, ssn
FROM P7_POC.BASE.CUSTOMER WHERE customer_id = 999;
/* EXPECT  setup@example.invalid  /  000-00-0000                         */

GRANT SELECT ON TABLE P7_POC.BASE.CUSTOMER TO ROLE P7_READER_NO;
GRANT USAGE  ON SCHEMA P7_POC.BASE         TO ROLE P7_READER_NO;

USE ROLE P7_READER_NO;
SELECT '6c unentitled role (expect ***MASKED***)' AS check_name, email, ssn
FROM P7_POC.BASE.CUSTOMER WHERE customer_id = 999;
/* EXPECT  ***MASKED***  /  ***MASKED***
   If this returns real values the masking policy is NOT attached to the
   tag - stop and fix setup before running any scenario.                 */

/* clean up the probe row and the temporary grant */
USE ROLE P7_BASE_OWNER;
DELETE FROM P7_POC.BASE.CUSTOMER WHERE customer_id = 999;
USE ROLE SECURITYADMIN;
REVOKE SELECT ON TABLE P7_POC.BASE.CUSTOMER FROM ROLE P7_READER_NO;
REVOKE USAGE  ON SCHEMA P7_POC.BASE         FROM ROLE P7_READER_NO;

SELECT 'SETUP COMPLETE - run a scenario script next. Each one resets itself to day 1.' AS status;
