/* =====================================================================
   POC07 — CTAS + SWAP      99_teardown.sql
   =====================================================================
   Removes exactly what 00_setup.sql created and nothing else.
   Run only AFTER the evidence has been captured — once the objects are
   gone the results cannot be regenerated.
   ===================================================================== */

USE SECONDARY ROLES NONE;

/* Detach the masking policy from the tag first. Neither a policy nor a
   tag can be dropped while the policy is assigned to the tag, and
   although DROP DATABASE normally cascades, detaching first makes the
   teardown work regardless.                                          */
USE ROLE SYSADMIN;
USE DATABASE P7_POC;
ALTER TAG IF EXISTS GOV.PII UNSET MASKING POLICY GOV.MASK_PII;

DROP DATABASE IF EXISTS P7_POC;

USE ROLE SECURITYADMIN;
DROP ROLE IF EXISTS P7_BASE_OWNER;
DROP ROLE IF EXISTS P7_PUBLISH_ROLE;
DROP ROLE IF EXISTS P7_VIEW_OWNER;
DROP ROLE IF EXISTS P7_READER_OK;
DROP ROLE IF EXISTS P7_READER_NO;
DROP ROLE IF EXISTS P7_PROBE_ROLE;
DROP ROLE IF EXISTS P7_BATCH_NOENT;

/* confirm nothing P7_ is left */
SHOW ROLES LIKE 'P7_%';
SELECT 'roles remaining (expect zero rows)' AS check_name, "name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW DATABASES LIKE 'P7_POC';
SELECT 'databases remaining (expect zero rows)' AS check_name, "name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT 'TEARDOWN COMPLETE' AS status;
