/* =====================================================================
   POC07 (NB) — CTAS + SWAP      00_setup.sql
   =====================================================================
   THE NB_ COPY OF THE PACK. Everything it creates is named NB_ and
   lives in the SHARED database LM_POC_DB, so it cannot collide with
   your colleague's run of the P7_ pack in w5-zone3-consumption-gating/poc07/.
   Everything shared by all ten scenarios: schemas, roles,
   RBAC, tags, masking, base tables, source views, control tables.

   RUN THIS ONCE. Each scenario script then resets only the swap pair,
   the reader views and the control tables back to day 1 — the base
   layer and the governance objects below are never torn down between
   scenarios.

   ---------------------------------------------------------------------
   BEFORE YOU RUN
   ---------------------------------------------------------------------
   1. The warehouse on the next line is POC_WH, from your Snowsight
      context. Change it only if you use a different one.
   2. This file switches roles deliberately. You need to be able to
      USE ROLE both SECURITYADMIN and SYSADMIN.

      SECURITYADMIN is not optional. Two things here cannot be done by
      a schema owner, however much it owns:
        - any GRANT ... ON FUTURE, which needs MANAGE GRANTS
        - any grant on a schema whose ownership has just been handed
          over, because the handover uses REVOKE CURRENT GRANTS
      If your account restricts SECURITYADMIN, run the whole file as
      ACCOUNTADMIN - nothing else changes. Do NOT instead grant
      MANAGE GRANTS to an NB_ role: that is account-wide, and it would
      undo the least-privilege split this POC exists to test.
   3. LM_POC_DB IS SHARED and already exists. This file never creates
      or drops it, never creates or drops POC_WH, and never touches a
      schema that does not start NB_. Your colleague's GOLD_POC,
      GOLD_STG_POC, GOLD_BUILD_POC, GOVERNANCE_POC, SILVER_POC and
      POC_SCHEMA are left exactly as they are, and 99_teardown.sql
      drops our seven NB_ schemas by name rather than the database.
   4. This file is re-runnable from the top. If a run stops part way,
      fix the cause and run it again from line 1 - every statement is
      IF NOT EXISTS, OR REPLACE or otherwise idempotent. The one thing
      it will NOT do is pick up an edit to the masking policy body;
      for that, run 99_teardown.sql first.

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

SET wh = 'POC_WH';              -- the warehouse from your Snowsight context

USE SECONDARY ROLES NONE;

/* =====================================================================
   1. ROLES
   ===================================================================== */
USE ROLE SECURITYADMIN;

CREATE ROLE IF NOT EXISTS NB_BASE_OWNER      COMMENT = 'owns the Zone 3 base tables and the source views';
CREATE ROLE IF NOT EXISTS NB_PUBLISH_ROLE    COMMENT = 'owns NB_D_LIVE, NB_D_STAGE and NB_CTRL. Builds and swaps';
CREATE ROLE IF NOT EXISTS NB_VIEW_OWNER      COMMENT = 'owns NB_D_VIEWS, the thin reader views';
CREATE ROLE IF NOT EXISTS NB_READER_OK       COMMENT = 'a report user ENTITLED to see real values';
CREATE ROLE IF NOT EXISTS NB_READER_NO       COMMENT = 'a report user NOT entitled - sees masked values';
CREATE ROLE IF NOT EXISTS NB_PROBE_ROLE      COMMENT = 'grant target for the grants scenario. No work of its own';
CREATE ROLE IF NOT EXISTS NB_BATCH_NOENT     COMMENT = 'a batch identity with NO entitlement row - writes masks';

/* every NB role to SYSADMIN so one person can switch between them */
GRANT ROLE NB_BASE_OWNER   TO ROLE SYSADMIN;
GRANT ROLE NB_PUBLISH_ROLE TO ROLE SYSADMIN;
GRANT ROLE NB_VIEW_OWNER   TO ROLE SYSADMIN;
GRANT ROLE NB_READER_OK    TO ROLE SYSADMIN;
GRANT ROLE NB_READER_NO    TO ROLE SYSADMIN;
GRANT ROLE NB_PROBE_ROLE   TO ROLE SYSADMIN;
GRANT ROLE NB_BATCH_NOENT  TO ROLE SYSADMIN;

/* and to you, so USE ROLE works in your own session */
SET me = CURRENT_USER();
GRANT ROLE NB_BASE_OWNER   TO USER IDENTIFIER($me);
GRANT ROLE NB_PUBLISH_ROLE TO USER IDENTIFIER($me);
GRANT ROLE NB_VIEW_OWNER   TO USER IDENTIFIER($me);
GRANT ROLE NB_READER_OK    TO USER IDENTIFIER($me);
GRANT ROLE NB_READER_NO    TO USER IDENTIFIER($me);
GRANT ROLE NB_PROBE_ROLE   TO USER IDENTIFIER($me);
GRANT ROLE NB_BATCH_NOENT  TO USER IDENTIFIER($me);

/* =====================================================================
   2. SCHEMAS AND GRANTS
   ---------------------------------------------------------------------
   NB_D_LIVE and NB_D_STAGE are the swap pair. NB_D_VIEWS and NB_CTRL
   sit OUTSIDE it - a view inside a swapped schema would be swapped out
   with the tables, and NB_CTRL would lose its own state mid-run.
   ===================================================================== */
/* ---------------------------------------------------------------------
   LM_POC_DB and POC_WH ALREADY EXIST and are not ours - the database is
   shared with your colleague's POC objects. So this file never creates
   or drops either one, and never touches a schema that does not start
   NB_.

   Every grant ON the database or the warehouse therefore comes from
   SECURITYADMIN, which holds MANAGE GRANTS and can grant on objects it
   does not own. SYSADMIN almost certainly does NOT own LM_POC_DB, so
   issuing these as SYSADMIN would fail with "Insufficient privileges".
   --------------------------------------------------------------------- */
USE ROLE SECURITYADMIN;

/* SYSADMIN needs this much to create our seven schemas below */
GRANT USAGE          ON DATABASE LM_POC_DB TO ROLE SYSADMIN;
GRANT CREATE SCHEMA  ON DATABASE LM_POC_DB TO ROLE SYSADMIN;

GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE NB_BASE_OWNER;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE NB_PUBLISH_ROLE;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE NB_VIEW_OWNER;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE NB_READER_OK;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE NB_READER_NO;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE NB_PROBE_ROLE;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE NB_BATCH_NOENT;

GRANT USAGE ON DATABASE LM_POC_DB TO ROLE NB_BASE_OWNER;
GRANT USAGE ON DATABASE LM_POC_DB TO ROLE NB_PUBLISH_ROLE;
GRANT USAGE ON DATABASE LM_POC_DB TO ROLE NB_VIEW_OWNER;
GRANT USAGE ON DATABASE LM_POC_DB TO ROLE NB_READER_OK;
GRANT USAGE ON DATABASE LM_POC_DB TO ROLE NB_READER_NO;
GRANT USAGE ON DATABASE LM_POC_DB TO ROLE NB_PROBE_ROLE;
GRANT USAGE ON DATABASE LM_POC_DB TO ROLE NB_BATCH_NOENT;

/* Our seven schemas, created by SYSADMIN so it owns them and can hand
   each one to the role that should be tested on its own rights.      */
USE ROLE SYSADMIN;
USE DATABASE LM_POC_DB;

CREATE SCHEMA IF NOT EXISTS NB_GOV;        -- tags, masking, entitlement. Never swapped
CREATE SCHEMA IF NOT EXISTS NB_BASE;       -- Zone 3 base tables, loaded by "ETL"
CREATE SCHEMA IF NOT EXISTS NB_SRC_VIEWS;  -- the existing complex views
CREATE SCHEMA IF NOT EXISTS NB_D_LIVE;     -- published tables            ) the
CREATE SCHEMA IF NOT EXISTS NB_D_STAGE;    -- next batch is built here    ) swap pair
CREATE SCHEMA IF NOT EXISTS NB_D_VIEWS;    -- thin reader views. NEVER swapped
CREATE SCHEMA IF NOT EXISTS NB_CTRL;       -- control tables. NEVER swapped

/* Ownership of each schema, so each role really is tested on its own
   rights. REVOKE CURRENT GRANTS wipes existing grants on the schema,
   which is why every USAGE grant below comes AFTER this, not before.  */
GRANT OWNERSHIP ON SCHEMA NB_BASE      TO ROLE NB_BASE_OWNER   REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA NB_SRC_VIEWS TO ROLE NB_BASE_OWNER   REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA NB_D_LIVE    TO ROLE NB_PUBLISH_ROLE REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA NB_D_STAGE   TO ROLE NB_PUBLISH_ROLE REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA NB_CTRL      TO ROLE NB_PUBLISH_ROLE REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA NB_D_VIEWS   TO ROLE NB_VIEW_OWNER   REVOKE CURRENT GRANTS;

/* ---------------------------------------------------------------------
   The USAGE grants below are issued by SECURITYADMIN, NOT SYSADMIN.

   Ownership of these schemas was just transferred away, so SYSADMIN no
   longer owns them and cannot grant on them. The transfer also used
   REVOKE CURRENT GRANTS, so the grants cannot simply be moved earlier
   either - they would be wiped by the transfer.

   SECURITYADMIN holds MANAGE GRANTS, so it can grant on any of them.
   Names are fully qualified because SECURITYADMIN has no USAGE of its
   own on this database.
   --------------------------------------------------------------------- */
USE ROLE SECURITYADMIN;

/* the publishing role must be able to read the source views to build from them */
GRANT USAGE ON SCHEMA LM_POC_DB.NB_SRC_VIEWS TO ROLE NB_PUBLISH_ROLE;
GRANT USAGE ON SCHEMA LM_POC_DB.NB_BASE      TO ROLE NB_PUBLISH_ROLE;
GRANT USAGE ON SCHEMA LM_POC_DB.NB_GOV       TO ROLE NB_PUBLISH_ROLE;
GRANT USAGE ON SCHEMA LM_POC_DB.NB_GOV       TO ROLE NB_BASE_OWNER;

/* the view owner reads both swapped schemas so its views resolve after a swap.
   NOTE: this is exactly the standing access S04 TC-04.7 measures.          */
GRANT USAGE ON SCHEMA LM_POC_DB.NB_D_LIVE  TO ROLE NB_VIEW_OWNER;
GRANT USAGE ON SCHEMA LM_POC_DB.NB_D_STAGE TO ROLE NB_VIEW_OWNER;

/* readers reach NB_D_VIEWS and nothing else */
GRANT USAGE ON SCHEMA LM_POC_DB.NB_D_VIEWS TO ROLE NB_READER_OK;
GRANT USAGE ON SCHEMA LM_POC_DB.NB_D_VIEWS TO ROLE NB_READER_NO;

/* the no-entitlement batch identity needs to build, like the real one */
GRANT USAGE ON SCHEMA LM_POC_DB.NB_SRC_VIEWS TO ROLE NB_BATCH_NOENT;
GRANT USAGE ON SCHEMA LM_POC_DB.NB_BASE      TO ROLE NB_BATCH_NOENT;
GRANT USAGE ON SCHEMA LM_POC_DB.NB_D_STAGE   TO ROLE NB_BATCH_NOENT;

/* =====================================================================
   3. GOVERNANCE - tags, entitlement, masking
   ===================================================================== */
USE ROLE SYSADMIN;
USE DATABASE LM_POC_DB;
USE SCHEMA NB_GOV;

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
DELETE FROM ENTITLEMENT WHERE role_name LIKE 'NB_%';
INSERT INTO ENTITLEMENT (role_name, can_see_pii, note) VALUES
  ('NB_READER_OK'   , TRUE , 'an approved report user'),
  ('NB_PUBLISH_ROLE', TRUE , 'the batch identity - MUST be entitled or the CTAS writes masks'),
  ('NB_BASE_OWNER'  , TRUE , 'owns the raw data'),
  ('NB_READER_NO'   , FALSE, 'an unapproved report user'),
  ('NB_PROBE_ROLE'  , FALSE, 'grant target only'),
  ('NB_VIEW_OWNER'  , FALSE, 'deliberately NOT entitled, so TC-04.7 shows what it can read'),
  ('NB_BATCH_NOENT' , FALSE, 'deliberately NOT entitled - proves a writer stores masks');

/* the masking rule. Attached to the PII tag below, so tagging a column
   is what protects it - and losing the tag is what exposes it.        */
/* IF NOT EXISTS, not OR REPLACE: a masking policy CANNOT be dropped
   while it is attached to a tag, so OR REPLACE fails on any re-run of
   this file. To change the policy body, run 99_teardown.sql and start
   clean - that is the supported path, not editing in place.          */
CREATE MASKING POLICY IF NOT EXISTS MASK_PII AS (val STRING) RETURNS STRING ->
  CASE
    WHEN EXISTS ( SELECT 1
                  FROM LM_POC_DB.NB_GOV.ENTITLEMENT e
                  WHERE e.role_name   = CURRENT_ROLE()
                    AND e.can_see_pii = TRUE )
    THEN val
    ELSE '***MASKED***'
  END;

/* FORCE makes this idempotent: it replaces a policy already set on the
   tag, and has no effect when none is set. Without it, a re-run fails
   because a tag may hold only one policy per data type.              */
ALTER TAG PII SET MASKING POLICY MASK_PII FORCE;

GRANT APPLY ON TAG LM_POC_DB.NB_GOV.PII       TO ROLE NB_PUBLISH_ROLE;
GRANT APPLY ON TAG LM_POC_DB.NB_GOV.PII_SCOPE TO ROLE NB_PUBLISH_ROLE;
GRANT APPLY ON TAG LM_POC_DB.NB_GOV.PII       TO ROLE NB_BASE_OWNER;
GRANT APPLY ON TAG LM_POC_DB.NB_GOV.PII_SCOPE TO ROLE NB_BASE_OWNER;
GRANT SELECT ON TABLE LM_POC_DB.NB_GOV.ENTITLEMENT TO ROLE NB_PUBLISH_ROLE;

/* =====================================================================
   4. THE NB_BASE LAYER - what the existing ETL loads
   ===================================================================== */
USE ROLE NB_BASE_OWNER;
USE DATABASE LM_POC_DB;
USE SCHEMA NB_BASE;

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

ALTER TABLE CUSTOMER MODIFY COLUMN email SET TAG LM_POC_DB.NB_GOV.PII = 'EMAIL';
ALTER TABLE CUSTOMER MODIFY COLUMN ssn   SET TAG LM_POC_DB.NB_GOV.PII = 'SSN';

GRANT SELECT ON ALL TABLES IN SCHEMA NB_BASE TO ROLE NB_PUBLISH_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA NB_BASE TO ROLE NB_BATCH_NOENT;

/* ---------------------------------------------------------------------
   FUTURE grants must be issued by SECURITYADMIN.
   A schema OWNER cannot create them - future grants require MANAGE
   GRANTS on the account, which an owner does not have. Confirmed on
   this account 27 Oct 2026: NB_BASE_OWNER is refused with
   "Insufficient privileges to operate on SCHEMA 'NB_BASE'".

   Do NOT fix this by granting MANAGE GRANTS to NB_BASE_OWNER - that is
   an account-wide privilege and would undo the least-privilege split
   this POC exists to test.
   --------------------------------------------------------------------- */
USE ROLE SECURITYADMIN;
GRANT SELECT ON FUTURE TABLES IN SCHEMA LM_POC_DB.NB_BASE TO ROLE NB_PUBLISH_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA LM_POC_DB.NB_BASE TO ROLE NB_BATCH_NOENT;

USE ROLE NB_BASE_OWNER; USE DATABASE LM_POC_DB; USE SCHEMA NB_BASE;

/* ---------------------------------------------------------------------
   The source views - the existing complex logic, text never edited.
   V_CUSTOMER_360 builds CUSTOMER_360;  V_POLICY_SUMMARY builds
   POLICY_SUMMARY.  (Convention: table name = view name without V_.)
   --------------------------------------------------------------------- */
USE SCHEMA NB_SRC_VIEWS;

CREATE OR REPLACE VIEW V_CUSTOMER_360 AS
SELECT c.customer_id,
       c.full_name,
       c.email,
       c.ssn,
       COUNT(p.policy_id) AS policy_count,
       c.batch_id
FROM NB_BASE.CUSTOMER c
LEFT JOIN NB_BASE.POLICY p ON p.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name, c.email, c.ssn, c.batch_id;

CREATE OR REPLACE VIEW V_POLICY_SUMMARY AS
SELECT p.policy_id,
       p.customer_id,
       p.premium,
       p.batch_id
FROM NB_BASE.POLICY p;

GRANT SELECT ON ALL VIEWS IN SCHEMA NB_SRC_VIEWS TO ROLE NB_PUBLISH_ROLE;
GRANT SELECT ON ALL VIEWS IN SCHEMA NB_SRC_VIEWS TO ROLE NB_BATCH_NOENT;

/* ---------------------------------------------------------------------
   FUTURE grants on the source views, as SECURITYADMIN - and these ones
   genuinely matter.

   S03 rebuilds these views with CREATE OR REPLACE VIEW several times.
   That REPLACES the object, so its grants go with it. Without a future
   grant, running S03 silently removes NB_BATCH_NOENT's access and S08
   then fails on every later run, in a different scenario, for a reason
   that is nowhere near the error.
   --------------------------------------------------------------------- */
USE ROLE SECURITYADMIN;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA LM_POC_DB.NB_SRC_VIEWS TO ROLE NB_PUBLISH_ROLE;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA LM_POC_DB.NB_SRC_VIEWS TO ROLE NB_BATCH_NOENT;

USE ROLE NB_BASE_OWNER; USE DATABASE LM_POC_DB;

/* =====================================================================
   5. CONTROL TABLES  (four, not nine)
   ===================================================================== */
USE ROLE NB_PUBLISH_ROLE;
USE DATABASE LM_POC_DB;
USE SCHEMA NB_CTRL;

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
  ('CUSTOMER_360'  ,'PUBLISHED','Y','NB_D_LIVE','NB_D_STAGE'),
  ('POLICY_SUMMARY','PUBLISHED','Y','NB_D_LIVE','NB_D_STAGE');

INSERT INTO OBJECT_DEPENDENCY (object_name, depends_on_object) VALUES
  ('CUSTOMER_360'  ,'CUSTOMER'),
  ('CUSTOMER_360'  ,'POLICY'),
  ('POLICY_SUMMARY','POLICY');

/* =====================================================================
   6. SETUP ASSERTIONS - read these before running any scenario
   ===================================================================== */
USE ROLE SYSADMIN;
USE DATABASE LM_POC_DB;

/* 6a. the schemas exist and are owned by the right roles */
SHOW SCHEMAS IN DATABASE LM_POC_DB;
SELECT '6a schema owners' AS check_name, "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" IN ('NB_BASE','NB_SRC_VIEWS','NB_GOV','NB_D_LIVE','NB_D_STAGE','NB_D_VIEWS','NB_CTRL')
ORDER BY "name";
/* EXPECT  NB_D_LIVE, NB_D_STAGE, NB_CTRL -> NB_PUBLISH_ROLE
           NB_D_VIEWS              -> NB_VIEW_OWNER
           NB_BASE, NB_SRC_VIEWS      -> NB_BASE_OWNER                        */

/* 6b. the base columns carry their tags */
SELECT '6b base tags' AS check_name, column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_BASE.CUSTOMER','table'))
ORDER BY column_name;
/* EXPECT  email -> PII = EMAIL,  ssn -> PII = SSN                       */

/* 6c. masking really is driven by the tag.
       Load one row, read it as an entitled role and an unentitled one. */
USE ROLE NB_BASE_OWNER;
INSERT INTO LM_POC_DB.NB_BASE.CUSTOMER
VALUES (999,'Setup Check','setup@example.invalid','000-00-0000','B0');

SELECT '6c entitled role (expect REAL values)' AS check_name, email, ssn
FROM LM_POC_DB.NB_BASE.CUSTOMER WHERE customer_id = 999;
/* EXPECT  setup@example.invalid  /  000-00-0000                         */

GRANT SELECT ON TABLE LM_POC_DB.NB_BASE.CUSTOMER TO ROLE NB_READER_NO;
GRANT USAGE  ON SCHEMA LM_POC_DB.NB_BASE         TO ROLE NB_READER_NO;

USE ROLE NB_READER_NO;
SELECT '6c unentitled role (expect ***MASKED***)' AS check_name, email, ssn
FROM LM_POC_DB.NB_BASE.CUSTOMER WHERE customer_id = 999;
/* EXPECT  ***MASKED***  /  ***MASKED***
   If this returns real values the masking policy is NOT attached to the
   tag - stop and fix setup before running any scenario.                 */

/* clean up the probe row and the temporary grant */
USE ROLE NB_BASE_OWNER;
DELETE FROM LM_POC_DB.NB_BASE.CUSTOMER WHERE customer_id = 999;
USE ROLE SECURITYADMIN;
REVOKE SELECT ON TABLE LM_POC_DB.NB_BASE.CUSTOMER FROM ROLE NB_READER_NO;
REVOKE USAGE  ON SCHEMA LM_POC_DB.NB_BASE         FROM ROLE NB_READER_NO;

/* SECURITYADMIN holds no warehouse. Hand back to SYSADMIN, which inherits
   one through the NB_ roles granted to it. */
USE ROLE SYSADMIN;
SELECT 'SETUP COMPLETE - run a scenario script next. Each one resets itself to day 1.' AS status;
