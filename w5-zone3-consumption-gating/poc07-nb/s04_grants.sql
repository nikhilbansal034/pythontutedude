/* =====================================================================
   POC07 — CTAS + SWAP      S04  —  Grants — what survives the rebuild and the swap
   =====================================================================
   Proves: whether the swap carries grants, whether the CTAS drops them, and whether COPY GRANTS removes the need for future grants
   Batches: B1 – B4

   PREREQUISITE: 00_setup.sql has been run once.
   This script resets the swap pair, the reader views and the control
   tables back to DAY 1, so it can be run on its own and re-run.
   THIS SCENARIO IS MARKED **MUST REPORT**.
   It runs WITHOUT future grants on the swapped schemas, so that
   COPY GRANTS can be judged on its own.
   ===================================================================== */

USE SECONDARY ROLES NONE;
USE DATABASE LM_POC_DB;

/* ---------------------------------------------------------------------
   RESET TO DAY 1
   The published tables are created EMPTY in both schemas and tagged in BOTH schemas — the deployment rule from S01.
   --------------------------------------------------------------------- */
USE ROLE NB_PUBLISH_ROLE;
USE DATABASE LM_POC_DB;

CREATE OR REPLACE TABLE NB_D_LIVE.CUSTOMER_360 (
    customer_id NUMBER, full_name STRING, email STRING, ssn STRING,
    policy_count NUMBER, batch_id STRING);
CREATE OR REPLACE TABLE NB_D_LIVE.POLICY_SUMMARY (
    policy_id NUMBER, customer_id NUMBER, premium NUMBER(12,2), batch_id STRING);
CREATE OR REPLACE TABLE NB_D_STAGE.CUSTOMER_360 (
    customer_id NUMBER, full_name STRING, email STRING, ssn STRING,
    policy_count NUMBER, batch_id STRING);
CREATE OR REPLACE TABLE NB_D_STAGE.POLICY_SUMMARY (
    policy_id NUMBER, customer_id NUMBER, premium NUMBER(12,2), batch_id STRING);

ALTER TABLE NB_D_LIVE.CUSTOMER_360 MODIFY COLUMN email SET TAG LM_POC_DB.NB_GOV.PII = 'EMAIL';
ALTER TABLE NB_D_LIVE.CUSTOMER_360 MODIFY COLUMN ssn   SET TAG LM_POC_DB.NB_GOV.PII = 'SSN';
ALTER TABLE NB_D_STAGE.CUSTOMER_360 MODIFY COLUMN email SET TAG LM_POC_DB.NB_GOV.PII = 'EMAIL';
ALTER TABLE NB_D_STAGE.CUSTOMER_360 MODIFY COLUMN ssn   SET TAG LM_POC_DB.NB_GOV.PII = 'SSN';

ALTER SCHEMA NB_D_LIVE  SET TAG LM_POC_DB.NB_GOV.PII_SCOPE = 'NB_DOMAIN';
ALTER SCHEMA NB_D_STAGE SET TAG LM_POC_DB.NB_GOV.PII_SCOPE = 'NB_DOMAIN';

TRUNCATE TABLE NB_CTRL.BATCH_STATUS;
TRUNCATE TABLE NB_CTRL.PUBLISH_LOG;

USE ROLE SECURITYADMIN;
-- NO future grants. This scenario manages grants explicitly, so that
-- COPY GRANTS can be tested on its own.
GRANT SELECT ON ALL TABLES IN SCHEMA LM_POC_DB.NB_D_LIVE  TO ROLE NB_VIEW_OWNER;
GRANT SELECT ON ALL TABLES IN SCHEMA LM_POC_DB.NB_D_STAGE TO ROLE NB_VIEW_OWNER;

/* the thin reader views — outside the swap, keeping the V_ name so
   reports change schema only, never object name                     */
USE ROLE NB_VIEW_OWNER;
USE DATABASE LM_POC_DB;
CREATE OR REPLACE VIEW NB_D_VIEWS.V_CUSTOMER_360   AS SELECT * FROM NB_D_LIVE.CUSTOMER_360;
CREATE OR REPLACE VIEW NB_D_VIEWS.V_POLICY_SUMMARY AS SELECT * FROM NB_D_LIVE.POLICY_SUMMARY;
GRANT SELECT ON ALL VIEWS IN SCHEMA NB_D_VIEWS TO ROLE NB_READER_OK;
GRANT SELECT ON ALL VIEWS IN SCHEMA NB_D_VIEWS TO ROLE NB_READER_NO;

SELECT 'RESET COMPLETE — environment is at day 1' AS status;


/* =====================================================================
   TC-04.1   Re-validate: does the swap carry grants?
   ---------------------------------------------------------------------
   Documented and proven previously. Re-validated here because it is
   load-bearing — if it fails, every publish removes reporting access.
   ===================================================================== */
/* load the Zone 3 base tables for batch B1 */
USE ROLE NB_BASE_OWNER; USE DATABASE LM_POC_DB;
DELETE FROM NB_BASE.CUSTOMER;
INSERT INTO NB_BASE.CUSTOMER
SELECT seq4()+1, 'Customer '||(seq4()+1),
       'cust'||(seq4()+1)||'@example.invalid',
       LPAD(TO_VARCHAR(seq4()+1),3,'0')||'-00-0000', 'B1'
FROM TABLE(GENERATOR(ROWCOUNT=>20));
DELETE FROM NB_BASE.POLICY;
INSERT INTO NB_BASE.POLICY
SELECT seq4()+1, MOD(seq4(),20)+1, 1000+seq4(), 'B1'
FROM TABLE(GENERATOR(ROWCOUNT=>50));
/* the ETL reports what it did for batch B1 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B1','CUSTOMER','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B1','POLICY','COMPLETED',CURRENT_TIMESTAMP(),'N');
/* BUILD — CTAS into staging for batch B1 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
CREATE OR REPLACE TABLE NB_D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_CUSTOMER_360;
CREATE OR REPLACE TABLE NB_D_STAGE.POLICY_SUMMARY COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_POLICY_SUMMARY;

USE ROLE NB_PUBLISH_ROLE;
DELETE FROM NB_CTRL.BATCH_STATUS WHERE batch_id='B1' AND object_name IN ('CUSTOMER_360','POLICY_SUMMARY');
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B1','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B1','POLICY_SUMMARY','COMPLETED',CURRENT_TIMESTAMP(),'N');
USE ROLE SECURITYADMIN;
GRANT SELECT ON TABLE LM_POC_DB.NB_D_STAGE.CUSTOMER_360 TO ROLE NB_PROBE_ROLE;

/* SECURITYADMIN was granted no warehouse, so the RESULT_SCAN below cannot
   run under it. Read the grants as the schema owner instead. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
SHOW GRANTS ON TABLE LM_POC_DB.NB_D_STAGE.CUSTOMER_360;
SELECT 'TC-04.1 grants BEFORE the swap' AS check_name,
       "privilege", "grantee_name", "granted_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "grantee_name" LIKE 'NB_%' ORDER BY "grantee_name","privilege";
/* EXPECT  NB_PROBE_ROLE holds SELECT */

/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B1',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
SHOW GRANTS ON TABLE LM_POC_DB.NB_D_LIVE.CUSTOMER_360;
SELECT 'TC-04.1 grants AFTER the swap (same storage, new name)' AS check_name,
       "privilege", "grantee_name", "granted_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "grantee_name" LIKE 'NB_%' ORDER BY "grantee_name","privilege";
/* EXPECT  NB_PROBE_ROLE still holds SELECT. The swap moved it. */

/* =====================================================================
   TC-04.2   Does a plain CTAS drop the grants?
   ---------------------------------------------------------------------
   No COPY GRANTS, no future grants. This establishes that the REBUILD,
   not the swap, is what loses grants — the reason the future-grant rule
   exists at all.
   ===================================================================== */
/* load the Zone 3 base tables for batch B2 */
USE ROLE NB_BASE_OWNER; USE DATABASE LM_POC_DB;
DELETE FROM NB_BASE.CUSTOMER;
INSERT INTO NB_BASE.CUSTOMER
SELECT seq4()+1, 'Customer '||(seq4()+1),
       'cust'||(seq4()+1)||'@example.invalid',
       LPAD(TO_VARCHAR(seq4()+1),3,'0')||'-00-0000', 'B2'
FROM TABLE(GENERATOR(ROWCOUNT=>20));
DELETE FROM NB_BASE.POLICY;
INSERT INTO NB_BASE.POLICY
SELECT seq4()+1, MOD(seq4(),20)+1, 1000+seq4(), 'B2'
FROM TABLE(GENERATOR(ROWCOUNT=>50));
/* the ETL reports what it did for batch B2 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B2','CUSTOMER','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B2','POLICY','COMPLETED',CURRENT_TIMESTAMP(),'N');
USE ROLE SECURITYADMIN;
GRANT SELECT ON TABLE LM_POC_DB.NB_D_STAGE.CUSTOMER_360 TO ROLE NB_PROBE_ROLE;

/* SECURITYADMIN was granted no warehouse, so the RESULT_SCAN below cannot
   run under it. Read the grants as the schema owner instead. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
SHOW GRANTS ON TABLE LM_POC_DB.NB_D_STAGE.CUSTOMER_360;
SELECT 'TC-04.2 grants before the plain rebuild' AS check_name,
       "privilege", "grantee_name", "granted_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "grantee_name" LIKE 'NB_%' ORDER BY "grantee_name","privilege";

/* BUILD — CTAS into staging for batch B2 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
CREATE OR REPLACE TABLE NB_D_STAGE.CUSTOMER_360 
  AS SELECT * FROM NB_SRC_VIEWS.V_CUSTOMER_360;

USE ROLE NB_PUBLISH_ROLE;
DELETE FROM NB_CTRL.BATCH_STATUS WHERE batch_id='B2' AND object_name IN ('CUSTOMER_360');
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B2','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N');
SHOW GRANTS ON TABLE LM_POC_DB.NB_D_STAGE.CUSTOMER_360;
SELECT 'TC-04.2 grants AFTER the plain rebuild' AS check_name,
       "privilege", "grantee_name", "granted_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "grantee_name" LIKE 'NB_%' ORDER BY "grantee_name","privilege";
/* EXPECT  NB_PROBE_ROLE's SELECT is GONE. CREATE OR REPLACE replaced
   the object and its grants went with it. */

/* The plain rebuild above stripped EVERY grant on the table, including
   the view owner's. Put them back, or TC-04.3's COPY GRANTS would copy
   an empty set and prove nothing.                                      */
USE ROLE SECURITYADMIN;
GRANT SELECT ON TABLE LM_POC_DB.NB_D_STAGE.CUSTOMER_360 TO ROLE NB_VIEW_OWNER;

/* =====================================================================
   TC-04.3   Does COPY GRANTS keep them?
   ---------------------------------------------------------------------
   The companion to COPY TAGS. If this works, one clause handles both
   and the two-schema future-grant rule can be dropped.
   ===================================================================== */
USE ROLE SECURITYADMIN;
GRANT SELECT ON TABLE LM_POC_DB.NB_D_STAGE.CUSTOMER_360 TO ROLE NB_PROBE_ROLE;

/* BUILD — CTAS into staging for batch B2 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
CREATE OR REPLACE TABLE NB_D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_CUSTOMER_360;

USE ROLE NB_PUBLISH_ROLE;
DELETE FROM NB_CTRL.BATCH_STATUS WHERE batch_id='B2' AND object_name IN ('CUSTOMER_360');
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B2','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N');
SHOW GRANTS ON TABLE LM_POC_DB.NB_D_STAGE.CUSTOMER_360;
SELECT 'TC-04.3 grants after a COPY GRANTS rebuild' AS check_name,
       "privilege", "grantee_name", "granted_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "grantee_name" LIKE 'NB_%' ORDER BY "grantee_name","privilege";
/* EXPECT  NB_PROBE_ROLE still holds SELECT, with NO future grants in
   place anywhere. */

/* BUILD — CTAS into staging for batch B2 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
CREATE OR REPLACE TABLE NB_D_STAGE.POLICY_SUMMARY COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_POLICY_SUMMARY;

USE ROLE NB_PUBLISH_ROLE;
DELETE FROM NB_CTRL.BATCH_STATUS WHERE batch_id='B2' AND object_name IN ('POLICY_SUMMARY');
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B2','POLICY_SUMMARY','COMPLETED',CURRENT_TIMESTAMP(),'N');
/* SECURITY CHECK (tags only) for batch B2.
   This scenario deliberately runs with NO future grants, so the usual
   unentitled-read probe cannot reach a newly created staging table.
   Masking itself is proved in S08; here we check only that the tags
   survived, which is what the grant tests depend on.                  */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
SELECT 'sec-1 tags on NB_D_STAGE.CUSTOMER_360' AS check_name,
       column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* EXPECT  2 rows — email=EMAIL and ssn=SSN */
/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B2',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
/* VERIFY — what a report sees now.
   NOTE: with no future grants anywhere, the thin views keep working ONLY
   if COPY GRANTS carried the view owner's SELECT onto each new table.
   If this query fails, that IS the result of TC-04.3 — record it.     */
USE ROLE NB_READER_OK; USE DATABASE LM_POC_DB;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM NB_D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM NB_D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 1,  batch_seen = B2 */

/* =====================================================================
   TC-04.4   Stable across a further batch and the other storage
   ---------------------------------------------------------------------
   
   ===================================================================== */
/* load the Zone 3 base tables for batch B3 */
USE ROLE NB_BASE_OWNER; USE DATABASE LM_POC_DB;
DELETE FROM NB_BASE.CUSTOMER;
INSERT INTO NB_BASE.CUSTOMER
SELECT seq4()+1, 'Customer '||(seq4()+1),
       'cust'||(seq4()+1)||'@example.invalid',
       LPAD(TO_VARCHAR(seq4()+1),3,'0')||'-00-0000', 'B3'
FROM TABLE(GENERATOR(ROWCOUNT=>20));
DELETE FROM NB_BASE.POLICY;
INSERT INTO NB_BASE.POLICY
SELECT seq4()+1, MOD(seq4(),20)+1, 1000+seq4(), 'B3'
FROM TABLE(GENERATOR(ROWCOUNT=>50));
/* the ETL reports what it did for batch B3 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B3','CUSTOMER','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B3','POLICY','COMPLETED',CURRENT_TIMESTAMP(),'N');
/* BUILD — CTAS into staging for batch B3 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
CREATE OR REPLACE TABLE NB_D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_CUSTOMER_360;
CREATE OR REPLACE TABLE NB_D_STAGE.POLICY_SUMMARY COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_POLICY_SUMMARY;

USE ROLE NB_PUBLISH_ROLE;
DELETE FROM NB_CTRL.BATCH_STATUS WHERE batch_id='B3' AND object_name IN ('CUSTOMER_360','POLICY_SUMMARY');
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B3','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B3','POLICY_SUMMARY','COMPLETED',CURRENT_TIMESTAMP(),'N');
/* SECURITY CHECK (tags only) for batch B3.
   This scenario deliberately runs with NO future grants, so the usual
   unentitled-read probe cannot reach a newly created staging table.
   Masking itself is proved in S08; here we check only that the tags
   survived, which is what the grant tests depend on.                  */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
SELECT 'sec-1 tags on NB_D_STAGE.CUSTOMER_360' AS check_name,
       column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* EXPECT  2 rows — email=EMAIL and ssn=SSN */
/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B3',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
SHOW GRANTS ON TABLE LM_POC_DB.NB_D_LIVE.CUSTOMER_360;
SELECT 'TC-04.4 grants after B3' AS check_name,
       "privilege", "grantee_name", "granted_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "grantee_name" LIKE 'NB_%' ORDER BY "grantee_name","privilege";
/* EXPECT  unchanged. If so, record that future grants are unnecessary. */

/* =====================================================================
   TC-04.5   The grant bootstrap
   ---------------------------------------------------------------------
   COPY GRANTS has the same predecessor requirement as COPY TAGS.
   ===================================================================== */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
DROP TABLE IF EXISTS NB_D_STAGE.POLICY_SUMMARY;
CREATE OR REPLACE TABLE NB_D_STAGE.POLICY_SUMMARY COPY GRANTS
  AS SELECT * FROM NB_SRC_VIEWS.V_POLICY_SUMMARY;

SHOW GRANTS ON TABLE LM_POC_DB.NB_D_STAGE.POLICY_SUMMARY;
SELECT 'TC-04.5 grants on a first build with COPY GRANTS' AS check_name,
       "privilege", "grantee_name", "granted_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "grantee_name" LIKE 'NB_%' ORDER BY "grantee_name","privilege";
/* EXPECT  no NB_ grants — there was no predecessor to copy from.
   The same bootstrap gap as tags, so grants must be deployed too. */

/* =====================================================================
   TC-04.6   Who owns the rebuilt table?
   ---------------------------------------------------------------------
   COPY GRANTS does not carry OWNERSHIP.
   ===================================================================== */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
SHOW TABLES LIKE 'CUSTOMER_360' IN SCHEMA NB_D_LIVE;
SELECT 'TC-04.6 owner of the published table' AS check_name, "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* RECORD  the owner. It must still be a role that can swap both schemas. */

/* =====================================================================
   TC-04.7   Can the view owner read staging?
   ---------------------------------------------------------------------
   The future-grant rule gives this role standing access to BOTH swapped
   schemas. TC-04.3 passing would remove the need for it.
   ===================================================================== */
USE ROLE NB_VIEW_OWNER; USE DATABASE LM_POC_DB;
SELECT 'TC-04.7 view owner reading staging' AS check_name, customer_id, email, ssn
FROM NB_D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* RECORD  does the SELECT succeed at all, and are the values masked?
   Masked = the tag is doing its job. Plaintext = the untagged window
   from S01, seen from the grants side.                                */

/* =====================================================================
   S04 RESULT — WRITE THIS DOWN
   ---------------------------------------------------------------------
   Whether COPY GRANTS removes the need for future grants on both
   swapped schemas. If it does, the design loses a rule that is easy to
   get wrong, and the view owner loses standing access to staging.
   ===================================================================== */
