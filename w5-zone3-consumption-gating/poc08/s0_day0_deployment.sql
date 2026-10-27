/* =====================================================================
   POC08  ·  S0  —  DAY 0, DEPLOYMENT
   =====================================================================
   Verifies the state the pipeline is allowed to start from.

   THE CLAIM BEING TESTED: no published table is deployed at all. No
   placeholder, no pre-applied tags. If the design is right, Day 1 can
   build correctly from nothing.

   Run AFTER 00_setup.sql. Order: s0 -> s1 -> s2 -> s3.
   ===================================================================== */

USE SECONDARY ROLES NONE;
SET wh = 'POC_WH';

/* ---------------------------------------------------------------------
   TC-0.1  Both swap schemas exist and NEITHER holds the published table
   --------------------------------------------------------------------- */
USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);

DROP TABLE IF EXISTS P8_STG.CUSTOMER_360;
DROP TABLE IF EXISTS P8_LIVE.CUSTOMER_360;
DROP VIEW  IF EXISTS P8_VIEWS.V_CUSTOMER_360;

SELECT 'TC-0.1 published table must not exist anywhere' AS check_name,
       COUNT(*) AS tables_found
FROM LM_POC_DB.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA IN ('P8_STG','P8_LIVE') AND TABLE_NAME = 'CUSTOMER_360';
/* EXPECT  tables_found = 0.  This is the point of the design. */

/* ---------------------------------------------------------------------
   TC-0.2  The control row exists, and its keys are UPPERCASE
   --------------------------------------------------------------------- */
SELECT 'TC-0.2 the declaration' AS check_name,
       t.object_name, f.key AS column_key,
       f.value:tag::STRING AS tag, f.value:value::STRING AS tag_value
FROM LM_POC_DB.P8_CTRL.OBJECT_TAGS t, LATERAL FLATTEN(input => t.column_tags) f
WHERE t.object_name = 'CUSTOMER_360'
ORDER BY f.key;
/* EXPECT  two rows - EMAIL and SSN. Keys UPPERCASE: a lowercase key
   matches no column and that column would publish untagged.          */

/* ---------------------------------------------------------------------
   TC-0.3  Every tag the control row names actually resolves
   --------------------------------------------------------------------- */
USE ROLE P8_GOV_ROLE; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
SHOW TAGS IN SCHEMA LM_POC_DB.P8_GOV;
SELECT 'TC-0.3 tags that exist in governance' AS check_name, "name" AS tag_name
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* EXPECT  P8_PII present.  Compare by eye against TC-0.2's tag column -
   the gate in s3 TC-3.2 does this comparison mechanically.           */

/* ---------------------------------------------------------------------
   TC-0.4  Masking is live
   --------------------------------------------------------------------- */
SELECT 'TC-0.4 policy attached to the tag' AS check_name,
       POLICY_DB, POLICY_SCHEMA, POLICY_NAME, REF_ENTITY_NAME, REF_ENTITY_DOMAIN
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.POLICY_REFERENCES(
             POLICY_NAME => 'LM_POC_DB.P8_GOV.P8_MASK'));
/* EXPECT  one row with REF_ENTITY_DOMAIN = TAG and REF_ENTITY_NAME =
   P8_PII. The policy existing is not the same as it being attached.   */

SELECT 'S0 COMPLETE - run s1_day1_first_publish.sql next' AS status;
