/* =====================================================================
   POC07 (NB) — CTAS + SWAP      99_teardown.sql
   =====================================================================
   Removes exactly what 00_setup.sql created and nothing else.
   Run only AFTER the evidence has been captured — once the objects are
   gone the results cannot be regenerated.

   ---------------------------------------------------------------------
   READ THIS BEFORE RUNNING
   ---------------------------------------------------------------------
   LM_POC_DB IS SHARED. It holds your colleague's POC schemas as well as
   ours. This file therefore drops the SEVEN NB_ SCHEMAS BY NAME and the
   seven NB_ roles — it does NOT drop the database, and it does not
   touch GOLD_POC, GOLD_STG_POC, GOLD_BUILD_POC, GOVERNANCE_POC,
   SILVER_POC, POC_SCHEMA or PUBLIC.

   Do not "simplify" this to DROP DATABASE LM_POC_DB. That would delete
   your colleague's work.
   ===================================================================== */

SET wh = 'POC_WH';              -- same warehouse as 00_setup.sql

USE SECONDARY ROLES NONE;

/* Detach the masking policy from the tag first. Neither a policy nor a
   tag can be dropped while the policy is assigned to the tag, and
   dropping the schema does not always cascade in the right order.   */
USE ROLE SYSADMIN;
USE DATABASE LM_POC_DB;
ALTER TAG IF EXISTS NB_GOV.PII UNSET MASKING POLICY NB_GOV.MASK_PII;

/* Our seven schemas. SYSADMIN can drop all of them: every NB_ role was
   granted to it in setup, so it inherits each schema's ownership.
   NB_D_LIVE and NB_D_STAGE may have exchanged storage any number of
   times by now — dropping both names covers either arrangement.     */
DROP SCHEMA IF EXISTS LM_POC_DB.NB_D_VIEWS   CASCADE;
DROP SCHEMA IF EXISTS LM_POC_DB.NB_D_LIVE    CASCADE;
DROP SCHEMA IF EXISTS LM_POC_DB.NB_D_STAGE   CASCADE;
DROP SCHEMA IF EXISTS LM_POC_DB.NB_SRC_VIEWS CASCADE;
DROP SCHEMA IF EXISTS LM_POC_DB.NB_BASE      CASCADE;
DROP SCHEMA IF EXISTS LM_POC_DB.NB_CTRL      CASCADE;
DROP SCHEMA IF EXISTS LM_POC_DB.NB_GOV       CASCADE;

USE ROLE SECURITYADMIN;
DROP ROLE IF EXISTS NB_BASE_OWNER;
DROP ROLE IF EXISTS NB_PUBLISH_ROLE;
DROP ROLE IF EXISTS NB_VIEW_OWNER;
DROP ROLE IF EXISTS NB_READER_OK;
DROP ROLE IF EXISTS NB_READER_NO;
DROP ROLE IF EXISTS NB_PROBE_ROLE;
DROP ROLE IF EXISTS NB_BATCH_NOENT;

/* ---------------------------------------------------------------------
   Confirm our objects are gone AND the shared database is intact.
   The RESULT_SCANs below are SELECTs and need a warehouse, which
   SECURITYADMIN was never granted — and the NB_ roles that lent
   SYSADMIN one have just been dropped. ACCOUNTADMIN reaches every
   warehouse.
   --------------------------------------------------------------------- */
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE IDENTIFIER($wh);
USE DATABASE LM_POC_DB;

SHOW ROLES LIKE 'NB_%';
SELECT 'NB_ roles remaining' AS check_name, "name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* EXPECT  zero rows */

SHOW SCHEMAS LIKE 'NB_%' IN DATABASE LM_POC_DB;
SELECT 'NB_ schemas remaining' AS check_name, "name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* EXPECT  zero rows */

SHOW SCHEMAS IN DATABASE LM_POC_DB;
SELECT 'schemas left in the shared database' AS check_name, "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";
/* EXPECT  your colleague's schemas, untouched, and nothing starting NB_:
           GOLD_BUILD_POC, GOLD_POC, GOLD_STG_POC, GOVERNANCE_POC,
           INFORMATION_SCHEMA, POC_SCHEMA, PUBLIC, SILVER_POC          */

SELECT 'TEARDOWN COMPLETE' AS status;
