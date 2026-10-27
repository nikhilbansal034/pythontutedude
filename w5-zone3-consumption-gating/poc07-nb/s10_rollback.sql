/* =====================================================================
   POC07 — CTAS + SWAP      S10  —  Rollback to the previous batch
   =====================================================================
   Proves: that a bad publish can be undone by swapping back, with tags and grants intact
   Batches: B1 – B3

   PREREQUISITE: 00_setup.sql has been run once.
   This script resets the swap pair, the reader views and the control
   tables back to DAY 1, so it can be run on its own and re-run.
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
GRANT SELECT ON FUTURE TABLES IN SCHEMA LM_POC_DB.NB_D_LIVE  TO ROLE NB_VIEW_OWNER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA LM_POC_DB.NB_D_STAGE TO ROLE NB_VIEW_OWNER;
GRANT SELECT ON ALL    TABLES IN SCHEMA LM_POC_DB.NB_D_LIVE  TO ROLE NB_VIEW_OWNER;
GRANT SELECT ON ALL    TABLES IN SCHEMA LM_POC_DB.NB_D_STAGE TO ROLE NB_VIEW_OWNER;

/* the thin reader views — outside the swap, keeping the V_ name so
   reports change schema only, never object name                     */
USE ROLE NB_VIEW_OWNER;
USE DATABASE LM_POC_DB;
CREATE OR REPLACE VIEW NB_D_VIEWS.V_CUSTOMER_360   AS SELECT * FROM NB_D_LIVE.CUSTOMER_360;
CREATE OR REPLACE VIEW NB_D_VIEWS.V_POLICY_SUMMARY AS SELECT * FROM NB_D_LIVE.POLICY_SUMMARY;
GRANT SELECT ON ALL VIEWS IN SCHEMA NB_D_VIEWS TO ROLE NB_READER_OK;
GRANT SELECT ON ALL VIEWS IN SCHEMA NB_D_VIEWS TO ROLE NB_READER_NO;

SELECT 'RESET COMPLETE — environment is at day 1' AS status;

USE ROLE SECURITYADMIN;
GRANT SELECT ON TABLE LM_POC_DB.NB_D_LIVE.CUSTOMER_360  TO ROLE NB_PROBE_ROLE;
GRANT SELECT ON TABLE LM_POC_DB.NB_D_STAGE.CUSTOMER_360 TO ROLE NB_PROBE_ROLE;


/* =====================================================================
   TC-10.1   Publish B1
   ---------------------------------------------------------------------
   
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
/* SECURITY CHECK on staging, before the swap.
   Part 1 — are the tags there?                                        */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
SELECT 'sec-1 tags on NB_D_STAGE.CUSTOMER_360' AS check_name,
       column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* EXPECT  2 rows — email=EMAIL and ssn=SSN
   ZERO ROWS  =  REFUSE THE PUBLISH                                    */

/* Part 2 — does masking actually work on this build?
   NB_VIEW_OWNER is unentitled and can reach staging, so it is the
   natural probe.                                                      */
USE ROLE NB_VIEW_OWNER; USE DATABASE LM_POC_DB;
SELECT 'sec-2 unentitled read of staging' AS check_name, customer_id, email, ssn
FROM NB_D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  ***MASKED***
   Real values here mean the data is unprotected — REFUSE THE PUBLISH  */
/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B1',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
/* VERIFY — what a report sees now */
USE ROLE NB_READER_OK; USE DATABASE LM_POC_DB;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM NB_D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM NB_D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 1,  batch_seen = B1 */

/* =====================================================================
   TC-10.2   Publish B2
   ---------------------------------------------------------------------
   
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
/* BUILD — CTAS into staging for batch B2 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
CREATE OR REPLACE TABLE NB_D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_CUSTOMER_360;
CREATE OR REPLACE TABLE NB_D_STAGE.POLICY_SUMMARY COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_POLICY_SUMMARY;

USE ROLE NB_PUBLISH_ROLE;
DELETE FROM NB_CTRL.BATCH_STATUS WHERE batch_id='B2' AND object_name IN ('CUSTOMER_360','POLICY_SUMMARY');
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B2','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B2','POLICY_SUMMARY','COMPLETED',CURRENT_TIMESTAMP(),'N');
/* SECURITY CHECK on staging, before the swap.
   Part 1 — are the tags there?                                        */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
SELECT 'sec-1 tags on NB_D_STAGE.CUSTOMER_360' AS check_name,
       column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* EXPECT  2 rows — email=EMAIL and ssn=SSN
   ZERO ROWS  =  REFUSE THE PUBLISH                                    */

/* Part 2 — does masking actually work on this build?
   NB_VIEW_OWNER is unentitled and can reach staging, so it is the
   natural probe.                                                      */
USE ROLE NB_VIEW_OWNER; USE DATABASE LM_POC_DB;
SELECT 'sec-2 unentitled read of staging' AS check_name, customer_id, email, ssn
FROM NB_D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  ***MASKED***
   Real values here mean the data is unprotected — REFUSE THE PUBLISH  */
/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B2',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
/* VERIFY — what a report sees now */
USE ROLE NB_READER_OK; USE DATABASE LM_POC_DB;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM NB_D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM NB_D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 1,  batch_seen = B2 */
/* EXPECT  batch_seen = B2 */

/* =====================================================================
   TC-10.3   A problem is found — roll back
   ---------------------------------------------------------------------
   The previous version is still sitting in the other storage, so the
   rollback is one more swap. It holds only until the next batch
   overwrites that storage.
   ===================================================================== */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B2',CURRENT_TIMESTAMP(),'REFUSED','rolled back after publication — reverted to B1',NULL,CURRENT_ROLE());

/* VERIFY — what a report sees now */
USE ROLE NB_READER_OK; USE DATABASE LM_POC_DB;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM NB_D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM NB_D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 1,  batch_seen = B1 */
/* EXPECT  batch_seen = B1. The rollback worked. */

/* These read object metadata, so they need a role with privileges ON the
   object and a warehouse. A reader role has neither on NB_D_LIVE, and would
   return ZERO ROWS rather than an error - which reads like lost tags. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
SELECT 'TC-10.3 tags after the rollback' AS check_name, column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_LIVE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* EXPECT  2 rows — tags came back with the storage */

SHOW GRANTS ON TABLE LM_POC_DB.NB_D_LIVE.CUSTOMER_360;
SELECT 'TC-10.3 grants after the rollback' AS check_name,
       "privilege", "grantee_name", "granted_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "grantee_name" LIKE 'NB_%' ORDER BY "grantee_name","privilege";
/* EXPECT  NB_PROBE_ROLE still holds SELECT */

USE ROLE NB_READER_NO; USE DATABASE LM_POC_DB;
SELECT 'TC-10.3 unentitled reader after rollback' AS check_name, customer_id, email, ssn
FROM NB_D_VIEWS.V_CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  ***MASKED*** — the thin views still resolve and masking still applies */

/* =====================================================================
   TC-10.4   The next batch publishes normally
   ---------------------------------------------------------------------
   A rollback must not leave the domain stuck.
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
/* THE DEPENDENCY GATE for batch B3.  Any row returned = DO NOT PUBLISH. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
SELECT r.object_name AS published_table, d.depends_on_object AS blocked_by,
       NVL(s.status,'NO STATUS ROW') AS status, NVL(s.exception_flag,'N') AS exception_flag
FROM      NB_CTRL.OBJECT_REGISTRY   r
JOIN      NB_CTRL.OBJECT_DEPENDENCY d ON d.object_name = r.object_name
LEFT JOIN NB_CTRL.BATCH_STATUS      s ON s.object_name = d.depends_on_object
                                  AND s.batch_id    = 'B3'
WHERE r.object_type = 'PUBLISHED'
  AND r.is_required = 'Y'
  AND ( s.status IS NULL OR s.status <> 'COMPLETED' )
  AND NVL(s.exception_flag,'N') <> 'Y';
/* EXPECT  ZERO ROWS */
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
/* SECURITY CHECK on staging, before the swap.
   Part 1 — are the tags there?                                        */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
SELECT 'sec-1 tags on NB_D_STAGE.CUSTOMER_360' AS check_name,
       column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* EXPECT  2 rows — email=EMAIL and ssn=SSN
   ZERO ROWS  =  REFUSE THE PUBLISH                                    */

/* Part 2 — does masking actually work on this build?
   NB_VIEW_OWNER is unentitled and can reach staging, so it is the
   natural probe.                                                      */
USE ROLE NB_VIEW_OWNER; USE DATABASE LM_POC_DB;
SELECT 'sec-2 unentitled read of staging' AS check_name, customer_id, email, ssn
FROM NB_D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  ***MASKED***
   Real values here mean the data is unprotected — REFUSE THE PUBLISH  */
/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B3',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
/* VERIFY — what a report sees now */
USE ROLE NB_READER_OK; USE DATABASE LM_POC_DB;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM NB_D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM NB_D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 1,  batch_seen = B3 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
SELECT 'TC-10.4 full publish history' AS check_name, batch_id, outcome, refused_reason, attempted_at
FROM NB_CTRL.PUBLISH_LOG ORDER BY attempted_at;
/* EXPECT  B1 PUBLISHED, B2 PUBLISHED, B2 REFUSED (the rollback), B3 PUBLISHED */
