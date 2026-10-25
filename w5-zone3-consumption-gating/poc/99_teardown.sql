/* =====================================================================
   99 — TEARDOWN
   One statement. Nothing is left behind.
   ---------------------------------------------------------------------
   Before running this, make sure every evidence grid has been captured
   and recorded in Zone3_Gating_Test_Tracker.xlsx — the POC database is
   the only place the results exist.
   ===================================================================== */

USE ROLE POC_ROLE;

/* The schema-level tag set in TC-010 must be unset before the database
   is dropped. Tag-based masking restricts DROP of a schema or database
   in some tag/policy layouts, so clear the binding first. */
ALTER SCHEMA POC_GATING_DB.SCHEMA_TAG UNSET TAG POC_GATING_DB.GOV.PII_EMAIL_SCHEMA;

ALTER TAG POC_GATING_DB.GOV.PII_EMAIL        UNSET MASKING POLICY POC_GATING_DB.GOV.MASK_EMAIL;
ALTER TAG POC_GATING_DB.GOV.PII_EMAIL_SCHEMA UNSET MASKING POLICY POC_GATING_DB.GOV.MASK_EMAIL_2;

DROP DATABASE IF EXISTS POC_GATING_DB;

/* Optional: revoke what 00_setup granted to the reader and deploy
   roles. Dropping the database removes the object-level grants with it,
   including the published tables the deploy role owned — DROP DATABASE
   needs ownership of the database, not of every object inside it. */
REVOKE USAGE ON WAREHOUSE POC_WH FROM ROLE POC_READER_ROLE;
REVOKE USAGE ON WAREHOUSE POC_WH FROM ROLE POC_DEPLOY_ROLE;

SELECT 'TEARDOWN COMPLETE' AS status;
