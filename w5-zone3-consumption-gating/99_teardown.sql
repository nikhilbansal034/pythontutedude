/* =====================================================================
   POC07 — CTAS + SWAP      99_teardown.sql
   =====================================================================
   Removes exactly what 00_setup.sql created and nothing else.
   Run only AFTER the evidence has been captured — once the objects are
   gone the results cannot be regenerated.
   ===================================================================== */

USE SECONDARY ROLES NONE;

USE ROLE SYSADMIN;
DROP DATABASE IF EXISTS P7_POC;

USE ROLE SECURITYADMIN;
DROP ROLE IF EXISTS P7_BASE_OWNER;
DROP ROLE IF EXISTS P7_PUBLISH_ROLE;
DROP ROLE IF EXISTS P7_VIEW_OWNER;
DROP ROLE IF EXISTS P7_READER_OK;
DROP ROLE IF EXISTS P7_READER_NO;
DROP ROLE IF EXISTS P7_PROBE_ROLE;
DROP ROLE IF EXISTS P7_BATCH_NOENT;

/* confirm nothing P7_ is left.

   FIXED 27 Oct — these statements ran under SECURITYADMIN, which holds no grant
   on the warehouse, so both RESULT_SCAN queries failed with
     "000606 (57P03): No active warehouse selected in the current session."
   The DROPs above had succeeded, so teardown reported nothing either way. A
   verification step that cannot run is worse than none, because it looks like it
   passed. ACCOUNTADMIN owns the warehouse, so it can read these back.       */
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE LM_PII_POC_WH;

SHOW ROLES LIKE 'P7_%';
SELECT 'roles remaining (expect zero rows)' AS check_name, "name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW DATABASES LIKE 'P7_POC';
SELECT 'databases remaining (expect zero rows)' AS check_name, "name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT 'TEARDOWN COMPLETE' AS status;
