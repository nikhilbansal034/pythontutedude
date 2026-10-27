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
   1. The warehouse is set on the next line to LM_PII_POC_WH, the shared
      POC warehouse POC01 and POC02 both use. Change it if you use another.
   2. Roles are created with SECURITYADMIN and objects with SYSADMIN.
      The seven warehouse grants need ACCOUNTADMIN, because the warehouse
      is owned by it and SYSADMIN holds no grant on it - see the note at
      those statements. That is the ONLY ACCOUNTADMIN use in the suite,
      and it is setup plumbing: no test statement uses it.
   3. SCOPE OF WHAT THIS TOUCHES, corrected 27 Oct. Every object this
      file CREATES starts P7_ and lives in one database, so
      99_teardown.sql removes exactly what was created. But it is not
      true that nothing outside is touched: the seven grants above add
      USAGE on LM_PII_POC_WH to the seven P7_ roles, so that warehouse
      carries seven more grants than before. They disappear with the
      roles when 99_teardown.sql drops them. Nothing else outside P7_POC
      is read or written, and no POC01 or POC02 tag, policy, table or
      entitlement row is touched.

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

SET wh = 'LM_PII_POC_WH';        -- the shared POC warehouse, reused from POC01/POC02
/* FIXED 27 Oct — was 'COMPUTE_WH', which does not exist on this account
   (SHOW TERSE WAREHOUSES LIKE '%COMPUTE_WH%' returns no rows), so every
   GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) below failed and the 26 October
   setup run stopped at the first of them. LM_PII_POC_WH is the warehouse
   POC01 and POC02 both use (36 references across their SQL; it is the
   WAREHOUSE constant in poc02_names.py). X-Small, auto-resume, on monitor
   RM_LM_PII_POC_WH — 100 credits monthly, 0.00 used at the time of writing. */

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

/* ---------------------------------------------------------------------
   WAREHOUSE GRANTS — these need ACCOUNTADMIN, not SYSADMIN.

   FIXED 27 Oct. LM_PII_POC_WH is owned by ACCOUNTADMIN, and SYSADMIN holds
   no grant on it at all: SHOW GRANTS ON WAREHOUSE LM_PII_POC_WH returns
   OWNERSHIP to ACCOUNTADMIN plus twelve USAGE grants, every one of them
   granted_by ACCOUNTADMIN, and none carrying grant_option. So running
   these under the USE ROLE SYSADMIN set above fails on privileges.
   Granting as ACCOUNTADMIN is how POC01 and POC02 granted this same
   warehouse, so it matches house practice.

   NOTE this is the ONE place in the suite that uses ACCOUNTADMIN, and it
   is setup plumbing, not a test. Every test statement remains free of it,
   which is what the header's claim is about. Stated rather than hidden.
   --------------------------------------------------------------------- */
USE ROLE ACCOUNTADMIN;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_BASE_OWNER;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_PUBLISH_ROLE;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_VIEW_OWNER;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_READER_OK;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_READER_NO;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_PROBE_ROLE;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P7_BATCH_NOENT;

/* confirm the grants landed, before anything depends on them */
SHOW GRANTS ON WAREHOUSE IDENTIFIER($wh);
SELECT 'setup warehouse grants' AS check_name,
       COUNT(*) AS p7_usage_grants
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" = 'USAGE' AND "grantee_name" LIKE 'P7_%';
/* EXPECT  p7_usage_grants = 7. Fewer means a role cannot run a query and
   the scenarios will fail later with a confusing error.               */

/* back to SYSADMIN for the object grants that follow */
USE ROLE SYSADMIN;
USE DATABASE P7_POC;

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
   is what protects it - and losing the tag is what exposes it.

   FIXED 27 Oct — was CREATE OR REPLACE, which makes this file impossible to
   re-run. Once ALTER TAG below attaches the policy, a replace fails with
     "Policy MASK_PII cannot be dropped/replaced as it is associated with
      one or more entities."
   so a setup that stopped part-way could only be recovered by a full teardown.
   IF NOT EXISTS plus the idempotent ALTER TAG below makes the file re-runnable.

   TRADE-OFF, stated: with IF NOT EXISTS an EDIT to this policy body is not
   applied on a re-run. If the rule changes, drop the policy first — or run
   99_teardown.sql. The body is not expected to change during the POC.      */
CREATE MASKING POLICY IF NOT EXISTS MASK_PII AS (val STRING) RETURNS STRING ->
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
GRANT SELECT ON ALL TABLES IN SCHEMA BASE TO ROLE P7_BATCH_NOENT;

/* The FUTURE grant needs SECURITYADMIN, not the schema owner.

   FIXED 27 Oct. As written this ran under P7_BASE_OWNER and failed with:
     "Insufficient privileges to operate on SCHEMA 'BASE'. Your primary role
      P7_BASE_OWNER must have MANAGE GRANTS granted on ACCOUNT DELOITTENA."
   Owning a schema is NOT sufficient to make a FUTURE grant in it — that needs
   the account-level MANAGE GRANTS privilege, which SECURITYADMIN holds.

   It matters: scenarios rebuild the source views (s03 replaces V_CUSTOMER_360),
   and CREATE OR REPLACE drops the object's grants. Without the future grant,
   P7_PUBLISH_ROLE loses SELECT on the rebuilt view and the scenario fails on a
   privilege error that has nothing to do with what is being tested.         */
USE ROLE SECURITYADMIN;
GRANT SELECT ON FUTURE TABLES IN SCHEMA P7_POC.BASE TO ROLE P7_PUBLISH_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA P7_POC.BASE TO ROLE P7_BATCH_NOENT;
USE ROLE P7_BASE_OWNER;
USE DATABASE P7_POC;
USE SCHEMA BASE;

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
GRANT SELECT ON ALL VIEWS IN SCHEMA SRC_VIEWS TO ROLE P7_BATCH_NOENT;

/* Same fix as the BASE future grant above — SECURITYADMIN, not the owner.

   BOTH roles need it, not just the publisher. ADDED 27 Oct: P7_BATCH_NOENT had
   only GRANT SELECT ON ALL VIEWS, and s03 does CREATE OR REPLACE VIEW on the
   source views, which drops their grants. So by the time s08 TC-08.4 ran — the
   case that proves an unentitled writer stores masks — P7_BATCH_NOENT could no
   longer read the view it was supposed to rebuild from, and the case failed on a
   privilege error instead of demonstrating anything. ALL + FUTURE together is
   what makes a grant survive the suite's own view rebuilds.                  */
USE ROLE SECURITYADMIN;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA P7_POC.SRC_VIEWS TO ROLE P7_PUBLISH_ROLE;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA P7_POC.SRC_VIEWS TO ROLE P7_BATCH_NOENT;
USE ROLE P7_BASE_OWNER;
USE DATABASE P7_POC;
USE SCHEMA SRC_VIEWS;

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

/* ADDED 27 Oct — exception approvals, recorded OUTSIDE batch status.

   Why a separate table. The dependency gate reads exception_flag from
   the DEPENDENCY'S OWN BATCH_STATUS row. That works when the dependency
   reported FAILED, because there is a row to set the flag on. It cannot
   work for the missing-row case (s05 TC-05.3): with no row, there is
   nothing to flag, so that block can never be cleared and the domain is
   stuck until someone invents a status the ETL never reported.

   An approval is also a different kind of fact from a load status: it
   is a human decision, with an approver and a reason, and it must apply
   to ONE batch only. Keeping it in its own table lets the gate approve
   a missing dependency, and keeps the audit trail honest.           */
CREATE OR REPLACE TABLE EXCEPTION_APPROVAL (
    batch_id       STRING,
    object_name    STRING,   -- the dependency being waived
    approved_by    STRING,
    approved_at    TIMESTAMP_NTZ,
    reason         STRING
);

CREATE OR REPLACE TABLE PUBLISH_LOG (
    batch_id        STRING,
    attempted_at    TIMESTAMP_NTZ,
    outcome         STRING,    -- PUBLISHED | REFUSED | ROLLED_BACK
    refused_reason  STRING,
    exceptions_used STRING,
    run_by          STRING
);
/* FIXED 27 Oct — ROLLED_BACK added as an outcome in its own right.
   s10's rollback was logged as 'REFUSED', which conflates two different
   events: "never published" and "published, then deliberately reverted".
   Only the second one means readers saw the bad batch for a while, so
   the audit trail has to tell them apart without parsing free text.   */

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
