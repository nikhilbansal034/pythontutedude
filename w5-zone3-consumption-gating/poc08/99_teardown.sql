/* =====================================================================
   POC08 — control-table tags      99_teardown.sql
   =====================================================================
   Removes exactly what 00_setup.sql created, and nothing else.

   LM_POC_DB IS SHARED. This file drops the SIX P8_ SCHEMAS BY NAME and
   the four P8_ roles. It does NOT drop the database and it does not
   drop the warehouse. No object from any other POC is touched.

   Do not "simplify" this to DROP DATABASE LM_POC_DB.
   ===================================================================== */

SET wh = 'POC_WH';
USE SECONDARY ROLES NONE;

/* A masking policy cannot be dropped while attached to a tag.
   ON A SECOND RUN of this file the P8_ roles are already gone, so the
   next line fails on USE ROLE. That is harmless - skip to the DROP
   SCHEMA block below, which removes tag and policy together.         */
USE ROLE P8_GOV_ROLE; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
ALTER TAG IF EXISTS P8_GOV.P8_PII UNSET MASKING POLICY P8_GOV.P8_MASK;

USE ROLE SYSADMIN; USE DATABASE LM_POC_DB;
DROP SCHEMA IF EXISTS LM_POC_DB.P8_VIEWS CASCADE;
DROP SCHEMA IF EXISTS LM_POC_DB.P8_LIVE  CASCADE;
DROP SCHEMA IF EXISTS LM_POC_DB.P8_STG   CASCADE;
DROP SCHEMA IF EXISTS LM_POC_DB.P8_SRC   CASCADE;
DROP SCHEMA IF EXISTS LM_POC_DB.P8_CTRL  CASCADE;
DROP SCHEMA IF EXISTS LM_POC_DB.P8_GOV   CASCADE;

USE ROLE SECURITYADMIN;
DROP ROLE IF EXISTS P8_BATCH;
DROP ROLE IF EXISTS P8_GOV_ROLE;
DROP ROLE IF EXISTS P8_READER_OK;
DROP ROLE IF EXISTS P8_READER_NO;

/* ---------------------------------------------------------------------
   Confirm, by eye.
   Deliberately bare SHOW commands with no RESULT_SCAN wrapper: the roles
   that held USAGE on POC_WH have just been dropped, and SECURITYADMIN
   never had any, so a SELECT here would fail for want of a warehouse.
   A bare SHOW needs no warehouse. It also avoids needing ACCOUNTADMIN,
   which this POC never requires.
   --------------------------------------------------------------------- */
USE ROLE SECURITYADMIN;
SHOW ROLES LIKE 'P8_%';
/* EXPECT  no rows. */

USE ROLE SYSADMIN;
SHOW SCHEMAS LIKE 'P8_%' IN DATABASE LM_POC_DB;
/* EXPECT  no rows, and every other schema in LM_POC_DB untouched. */

SHOW SCHEMAS IN DATABASE LM_POC_DB;
/* EXPECT  the schemas that were there before POC08, unchanged. */
