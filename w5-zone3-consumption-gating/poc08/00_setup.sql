/* =====================================================================
   POC08 — control-table tags      00_setup.sql
   =====================================================================
   RUN ONCE, top to bottom, in ONE Snowsight worksheet.

   WHAT THIS USES THAT ALREADY EXISTS
     - database  LM_POC_DB   (shared - never created or dropped here)
     - warehouse POC_WH      (shared - never created or dropped here)

   WHAT THIS CREATES, all prefixed P8_
     - 4 roles     P8_BATCH, P8_GOV_ROLE, P8_READER_OK, P8_READER_NO
     - 6 schemas   P8_GOV, P8_SRC, P8_STG, P8_LIVE, P8_VIEWS, P8_CTRL

   IT USES NO OBJECT FROM ANY EARLIER POC. 99_teardown.sql removes only
   P8_ objects, so nothing else on the account is affected.

   YOU NEED to be able to USE ROLE both SECURITYADMIN and SYSADMIN.
   Every grant on LM_POC_DB and POC_WH is issued by SECURITYADMIN,
   which holds MANAGE GRANTS and can grant on objects it does not own.
   SYSADMIN almost certainly does NOT own either, so issuing them as
   SYSADMIN would fail on privileges.

   Re-runnable from line 1.
   ===================================================================== */

SET wh = 'POC_WH';
SET me = CURRENT_USER();

USE SECONDARY ROLES NONE;

/* =====================================================================
   1. ROLES
   ===================================================================== */
USE ROLE SECURITYADMIN;

CREATE ROLE IF NOT EXISTS P8_BATCH      COMMENT = 'the pipeline. Builds, tags, gates, swaps. MUST be entitled';
CREATE ROLE IF NOT EXISTS P8_GOV_ROLE   COMMENT = 'owns the tags and the control table. The only writer of OBJECT_TAGS';
CREATE ROLE IF NOT EXISTS P8_READER_OK  COMMENT = 'a report user entitled to see real values';
CREATE ROLE IF NOT EXISTS P8_READER_NO  COMMENT = 'a report user NOT entitled - sees masks';

GRANT ROLE P8_BATCH     TO ROLE SYSADMIN;
GRANT ROLE P8_GOV_ROLE  TO ROLE SYSADMIN;
GRANT ROLE P8_READER_OK TO ROLE SYSADMIN;
GRANT ROLE P8_READER_NO TO ROLE SYSADMIN;

GRANT ROLE P8_BATCH     TO USER IDENTIFIER($me);
GRANT ROLE P8_GOV_ROLE  TO USER IDENTIFIER($me);
GRANT ROLE P8_READER_OK TO USER IDENTIFIER($me);
GRANT ROLE P8_READER_NO TO USER IDENTIFIER($me);

/* =====================================================================
   2. GRANTS ON THE SHARED DATABASE AND WAREHOUSE
   ---------------------------------------------------------------------
   All from SECURITYADMIN - see the header.
   ===================================================================== */
GRANT USAGE         ON DATABASE LM_POC_DB TO ROLE SYSADMIN;
GRANT CREATE SCHEMA ON DATABASE LM_POC_DB TO ROLE SYSADMIN;

GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE SYSADMIN;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P8_BATCH;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P8_GOV_ROLE;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P8_READER_OK;
GRANT USAGE ON WAREHOUSE IDENTIFIER($wh) TO ROLE P8_READER_NO;

GRANT USAGE ON DATABASE LM_POC_DB TO ROLE P8_BATCH;
GRANT USAGE ON DATABASE LM_POC_DB TO ROLE P8_GOV_ROLE;
GRANT USAGE ON DATABASE LM_POC_DB TO ROLE P8_READER_OK;
GRANT USAGE ON DATABASE LM_POC_DB TO ROLE P8_READER_NO;

/* ---------------------------------------------------------------------
   ACCOUNT-LEVEL PRIVILEGE, and the one thing in this pack that is not
   scoped to LM_POC_DB.
   ---------------------------------------------------------------------
   Attaching a masking policy to a TAG - the ALTER TAG ... SET MASKING
   POLICY in section 4 - needs APPLY MASKING POLICY on the ACCOUNT.
   OWNING THE TAG AND THE POLICY IS NOT ENOUGH. Without this grant that
   statement fails with:

     SQL access control error: Insufficient privileges to operate on
     tag 'P8_PII'. Your primary role P8_GOV_ROLE must have APPLY
     MASKING POLICY granted on ACCOUNT <account>.

   SECURITYADMIN can issue it because it holds MANAGE GRANTS. If your
   account refuses it here, run this one line as ACCOUNTADMIN and then
   carry on from section 3 - nothing else in this pack needs that role.

   NOTE FOR THE WRITE-UP: this is a real operating consequence of
   tag-based masking, not a quirk of the POC. Whoever attaches policies
   to tags needs an account-wide privilege, so that role is powerful and
   the grant is a decision, not a formality. The PIPELINE does not need
   it - P8_BATCH only SETS tags, which needs APPLY on the tag alone.
   --------------------------------------------------------------------- */
GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE P8_GOV_ROLE;

/* =====================================================================
   3. SCHEMAS
   ---------------------------------------------------------------------
   P8_STG and P8_LIVE exchange storage at every swap, so both must be
   owned by the role that swaps them.
   ===================================================================== */
USE ROLE SYSADMIN;
USE DATABASE LM_POC_DB;

CREATE SCHEMA IF NOT EXISTS P8_GOV;     -- tags, masking policy, entitlement
CREATE SCHEMA IF NOT EXISTS P8_CTRL;    -- the control table
CREATE SCHEMA IF NOT EXISTS P8_SRC;     -- base table and the Z3 view
CREATE SCHEMA IF NOT EXISTS P8_STG;     -- built here        ) the
CREATE SCHEMA IF NOT EXISTS P8_LIVE;    -- read from here    ) swap pair
CREATE SCHEMA IF NOT EXISTS P8_VIEWS;   -- thin reader views. NEVER swapped

GRANT OWNERSHIP ON SCHEMA P8_GOV   TO ROLE P8_GOV_ROLE REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA P8_CTRL  TO ROLE P8_GOV_ROLE REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA P8_SRC   TO ROLE P8_BATCH    REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA P8_STG   TO ROLE P8_BATCH    REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA P8_LIVE  TO ROLE P8_BATCH    REVOKE CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA P8_VIEWS TO ROLE P8_BATCH    REVOKE CURRENT GRANTS;

/* Ownership was just transferred away and the transfer wiped existing
   grants, so every USAGE below must come from SECURITYADMIN and must be
   fully qualified - SECURITYADMIN has no USAGE of its own on this
   database, so it has no current database to resolve a short name.   */
USE ROLE SECURITYADMIN;

GRANT USAGE ON SCHEMA LM_POC_DB.P8_GOV   TO ROLE P8_BATCH;
GRANT USAGE ON SCHEMA LM_POC_DB.P8_CTRL  TO ROLE P8_BATCH;
GRANT USAGE ON SCHEMA LM_POC_DB.P8_SRC   TO ROLE P8_GOV_ROLE;
GRANT USAGE ON SCHEMA LM_POC_DB.P8_STG   TO ROLE P8_GOV_ROLE;
GRANT USAGE ON SCHEMA LM_POC_DB.P8_LIVE  TO ROLE P8_GOV_ROLE;
GRANT USAGE ON SCHEMA LM_POC_DB.P8_VIEWS TO ROLE P8_READER_OK;
GRANT USAGE ON SCHEMA LM_POC_DB.P8_VIEWS TO ROLE P8_READER_NO;

/* The readers must keep SELECT on views the pipeline recreates. */
GRANT SELECT ON FUTURE VIEWS IN SCHEMA LM_POC_DB.P8_VIEWS TO ROLE P8_READER_OK;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA LM_POC_DB.P8_VIEWS TO ROLE P8_READER_NO;

/* The security gate needs an UNENTITLED identity to probe the staging
   table with. P8_READER_NO doubles as that, to keep the POC to four
   roles. NOTE for production: this gives a report role standing read
   access to unpublished data. Use a dedicated probe identity instead. */
/* BOTH HALVES OF THE SWAP PAIR, and this is not belt-and-braces.
   ALTER SCHEMA P8_STG SWAP WITH P8_LIVE exchanges the two schemas
   TOGETHER WITH THEIR GRANTS. A grant issued against the name P8_STG
   follows the object, which after one swap is called P8_LIVE - so a
   one-sided grant works on day 1 and is GONE on day 2, with the
   privilege sitting on the wrong schema.

   Every schema-level grant in a swap-pair design must therefore be
   applied to BOTH schemas. Then the pair is symmetric and no swap can
   move anything out from under a role.                                */
GRANT USAGE ON SCHEMA LM_POC_DB.P8_STG  TO ROLE P8_READER_NO;
GRANT USAGE ON SCHEMA LM_POC_DB.P8_LIVE TO ROLE P8_READER_NO;
GRANT SELECT ON FUTURE TABLES IN SCHEMA LM_POC_DB.P8_STG  TO ROLE P8_READER_NO;
GRANT SELECT ON FUTURE TABLES IN SCHEMA LM_POC_DB.P8_LIVE TO ROLE P8_READER_NO;

/* P8_GOV_ROLE reads the staging table to verify tags independently.
   Both halves, for the reason above. */
GRANT SELECT ON FUTURE TABLES IN SCHEMA LM_POC_DB.P8_STG  TO ROLE P8_GOV_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA LM_POC_DB.P8_LIVE TO ROLE P8_GOV_ROLE;

/* =====================================================================
   4. GOVERNANCE - entitlement, tag, masking policy
   ===================================================================== */
USE ROLE P8_GOV_ROLE;
USE DATABASE LM_POC_DB;
USE WAREHOUSE IDENTIFIER($wh);
USE SCHEMA P8_GOV;

CREATE OR REPLACE TABLE ENTITLEMENT (
    role_name STRING,
    can_see   BOOLEAN,
    note      STRING
);
INSERT INTO ENTITLEMENT VALUES
  ('P8_BATCH'    , TRUE , 'the pipeline must read real values or it would store masks'),
  ('P8_GOV_ROLE' , TRUE , 'governance'),
  ('P8_READER_OK', TRUE , 'an approved report user'),
  ('P8_READER_NO', FALSE, 'an unapproved report user');

CREATE TAG IF NOT EXISTS P8_PII
  COMMENT = 'marks a column as protected. Carries the masking policy';

/* A policy cannot be replaced while it is attached to a tag, so this is
   CREATE IF NOT EXISTS and the attach below is FORCE, which is
   idempotent. Trade-off: an edit to the policy body is NOT picked up on
   a re-run - run 99_teardown.sql first for that.                     */
CREATE MASKING POLICY IF NOT EXISTS P8_MASK AS (val STRING) RETURNS STRING ->
  CASE
    WHEN EXISTS ( SELECT 1 FROM LM_POC_DB.P8_GOV.ENTITLEMENT e
                  WHERE e.role_name = CURRENT_ROLE() AND e.can_see = TRUE )
    THEN val ELSE '***MASKED***'
  END;

/* Needs APPLY MASKING POLICY ON ACCOUNT, granted in section 2. */
ALTER TAG P8_PII SET MASKING POLICY P8_MASK FORCE;

/* =====================================================================
   5. THE CONTROL TABLE - the source of truth for column tags
   ===================================================================== */
USE SCHEMA P8_CTRL;

CREATE OR REPLACE TABLE OBJECT_TAGS (
    object_name  STRING,        -- CUSTOMER_360
    column_tags  VARIANT,       -- {"EMAIL":{"tag":"LM_POC_DB.P8_GOV.P8_PII","value":"EMAIL"}, ...}
    updated_by   STRING,
    updated_at   TIMESTAMP_LTZ,
    reason       STRING
);

/* Day 1 declaration: EMAIL and SSN protected, PHONE deliberately not. */
INSERT INTO OBJECT_TAGS (object_name, column_tags, updated_by, updated_at, reason)
SELECT 'CUSTOMER_360',
       PARSE_JSON('{
         "EMAIL": { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "EMAIL" },
         "SSN":   { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "SSN"   }
       }'),
       'governance.owner', CURRENT_TIMESTAMP(),
       'initial declaration for go-live';

/* =====================================================================
   6. SOURCE - the Zone 3 base table and the consumption view
   ===================================================================== */
USE ROLE P8_BATCH;
USE DATABASE LM_POC_DB;
USE WAREHOUSE IDENTIFIER($wh);
USE SCHEMA P8_SRC;

CREATE OR REPLACE TABLE CUSTOMER (
    customer_id NUMBER,
    full_name   STRING,
    email       STRING,
    ssn         STRING,
    phone       STRING,
    batch_id    STRING
);

CREATE OR REPLACE VIEW V_CUSTOMER_360 AS
SELECT customer_id, full_name, email, ssn, phone, batch_id FROM CUSTOMER;

/* =====================================================================
   7. PRIVILEGES THE PIPELINE NEEDS
   ---------------------------------------------------------------------
   Two that are specific to this design:
     - SELECT, and ONLY select, on the control table. Write access to it
       is the power to unprotect a column.
     - APPLY on the tag. Setting a tag requires it.
   ===================================================================== */
USE ROLE SECURITYADMIN;

GRANT SELECT ON TABLE LM_POC_DB.P8_CTRL.OBJECT_TAGS TO ROLE P8_BATCH;
GRANT APPLY  ON TAG   LM_POC_DB.P8_GOV.P8_PII       TO ROLE P8_BATCH;
GRANT SELECT ON TABLE LM_POC_DB.P8_GOV.ENTITLEMENT  TO ROLE P8_BATCH;

/* The masking policy body reads ENTITLEMENT. Snowflake evaluates a policy
   body with the policy OWNER's privileges, so these two grants should not
   be needed - but if that ever changed, a reader's query would ERROR
   instead of returning a mask, and the POC would read as a masking
   failure. Granting the read costs nothing and removes the doubt.    */
GRANT USAGE  ON SCHEMA LM_POC_DB.P8_GOV             TO ROLE P8_READER_OK;
GRANT USAGE  ON SCHEMA LM_POC_DB.P8_GOV             TO ROLE P8_READER_NO;
GRANT SELECT ON TABLE LM_POC_DB.P8_GOV.ENTITLEMENT  TO ROLE P8_READER_OK;
GRANT SELECT ON TABLE LM_POC_DB.P8_GOV.ENTITLEMENT  TO ROLE P8_READER_NO;

/* =====================================================================
   8. SETUP CHECKS - all three must pass before any scenario is run
   ===================================================================== */
/* Run the checks as P8_BATCH, not SYSADMIN: nothing here grants SYSADMIN
   USAGE on POC_WH, and these checks need a warehouse. P8_BATCH owns four
   of the six schemas and holds USAGE on the other two, so it can see all
   six, and it holds SELECT on the control table.                      */
USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);

/* 8a. the six schemas exist and are owned by the right roles */
SHOW SCHEMAS IN DATABASE LM_POC_DB;
SELECT '8a schema owners' AS check_name, "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" LIKE 'P8_%' ORDER BY "name";
/* EXPECT  P8_GOV and P8_CTRL  -> P8_GOV_ROLE
           the other four      -> P8_BATCH                            */

/* 8b. the control row is present and its keys are UPPERCASE */
SELECT '8b control row' AS check_name,
       object_name, f.key AS column_key, f.value:tag::STRING AS tag, f.value:value::STRING AS val
FROM LM_POC_DB.P8_CTRL.OBJECT_TAGS t, LATERAL FLATTEN(input => t.column_tags) f
ORDER BY f.key;
/* EXPECT  two rows - EMAIL and SSN, both uppercase, tag LM_POC_DB.P8_GOV.P8_PII */

/* 8c. masking is live. Without this nothing later means anything.     */
USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
INSERT INTO P8_SRC.CUSTOMER VALUES (999,'Setup Check','setup@example.invalid','000-00-0000','+44-000-999','B0');
ALTER TABLE P8_SRC.CUSTOMER MODIFY COLUMN email SET TAG LM_POC_DB.P8_GOV.P8_PII = 'EMAIL';

SELECT '8c entitled role (expect REAL)' AS check_name, email
FROM P8_SRC.CUSTOMER WHERE customer_id = 999;
/* EXPECT  setup@example.invalid */

USE ROLE SECURITYADMIN;
GRANT USAGE  ON SCHEMA LM_POC_DB.P8_SRC          TO ROLE P8_READER_NO;
GRANT SELECT ON TABLE  LM_POC_DB.P8_SRC.CUSTOMER TO ROLE P8_READER_NO;

USE ROLE P8_READER_NO; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
SELECT '8c unentitled role (expect ***MASKED***)' AS check_name, email
FROM P8_SRC.CUSTOMER WHERE customer_id = 999;
/* EXPECT  ***MASKED***
   Real values here mean the masking policy is not attached to the tag.
   STOP and fix setup before running any scenario.                     */

/* clean up the probe */
USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
ALTER TABLE P8_SRC.CUSTOMER MODIFY COLUMN email UNSET TAG LM_POC_DB.P8_GOV.P8_PII;
DELETE FROM P8_SRC.CUSTOMER WHERE customer_id = 999;

USE ROLE SECURITYADMIN;
REVOKE SELECT ON TABLE  LM_POC_DB.P8_SRC.CUSTOMER FROM ROLE P8_READER_NO;
REVOKE USAGE  ON SCHEMA LM_POC_DB.P8_SRC          FROM ROLE P8_READER_NO;

USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
SELECT 'SETUP COMPLETE - run s0_day0_deployment.sql next' AS status;
