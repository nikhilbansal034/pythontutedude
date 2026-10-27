/* =====================================================================
   POC07 — CTAS + SWAP      S01  —  Day 1 — deployment and the first publish
   =====================================================================
   Proves: whether a published table built with COPY TAGS carries its tags on the very first build
   Batches: B1 – B2

   PREREQUISITE: 00_setup.sql has been run once.
   This script resets the swap pair, the reader views and the control
   tables back to DAY 1, so it can be run on its own and re-run.
   THIS SCENARIO IS MARKED **MUST REPORT** — its result is a deployment
   rule, not a pass/fail line, and goes in the summary either way.
   ===================================================================== */

USE SECONDARY ROLES NONE;
USE DATABASE LM_POC_DB;

/* ---------------------------------------------------------------------
   RESET TO DAY 1
   The published tables are created EMPTY in both schemas and NOT tagged at all — day 0, before any deployment of tags.
   The tables are NOT tagged, which is the whole point of TC-01.1.
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

-- deliberately NOT tagged, so the first build has nothing to copy from

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


/* =====================================================================
   TC-01.1   First build into an untagged staging schema
   ---------------------------------------------------------------------
   COPY TAGS copies from the table it REPLACES. Nothing here is tagged,
   so there is nothing to copy. RECORD what comes back.
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
SELECT 'TC-01.1 tags on the staging table' AS check_name, column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* EXPECT  ZERO ROWS — COPY TAGS had no predecessor to copy from.
   If tags DO appear, COPY TAGS reads from the source view and the rest
   of this scenario is unnecessary. Record that as the finding.       */

/* =====================================================================
   TC-01.2   The security check must refuse it
   ---------------------------------------------------------------------
   An untagged column has no masking. Confirm an unentitled role reads it
   in the clear, and that the publish is refused.
   ===================================================================== */
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
/* EXPECT  ZERO ROWS — this is the failure being demonstrated
   ZERO ROWS  =  REFUSE THE PUBLISH                                    */

/* Part 2 — does masking actually work on this build?
   NB_VIEW_OWNER is unentitled and can reach staging, so it is the
   natural probe.                                                      */
USE ROLE NB_VIEW_OWNER; USE DATABASE LM_POC_DB;
SELECT 'sec-2 unentitled read of staging' AS check_name, customer_id, email, ssn
FROM NB_D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  REAL e-mail and SSN values — the column is untagged, so nothing masks it
   Real values here mean the data is unprotected — REFUSE THE PUBLISH  */
/* REFUSE — nothing is published. Record why. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B1',CURRENT_TIMESTAMP(),'REFUSED','sec-1: no PII tags on NB_D_STAGE.CUSTOMER_360',NULL,CURRENT_ROLE());
/* VERIFY — what a report sees now */
USE ROLE NB_READER_OK; USE DATABASE LM_POC_DB;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM NB_D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM NB_D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 0,  batch_seen = NULL — the publish was REFUSED, so
   no swap happened and NB_D_LIVE still holds the empty tables the reset created.
   COUNT(DISTINCT batch_id) over zero rows is 0, not 1. */

/* =====================================================================
   TC-01.3   The fix — tag the table in BOTH schemas, then rebuild
   ---------------------------------------------------------------------
   This is the deployment rule. Tagging NB_D_LIVE alone is not enough:
   the schemas alternate, so each storage needs its own tags.
   ===================================================================== */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER TABLE NB_D_LIVE.CUSTOMER_360  MODIFY COLUMN email SET TAG LM_POC_DB.NB_GOV.PII = 'EMAIL';
ALTER TABLE NB_D_LIVE.CUSTOMER_360  MODIFY COLUMN ssn   SET TAG LM_POC_DB.NB_GOV.PII = 'SSN';
ALTER TABLE NB_D_STAGE.CUSTOMER_360 MODIFY COLUMN email SET TAG LM_POC_DB.NB_GOV.PII = 'EMAIL';
ALTER TABLE NB_D_STAGE.CUSTOMER_360 MODIFY COLUMN ssn   SET TAG LM_POC_DB.NB_GOV.PII = 'SSN';

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
SELECT 'TC-01.3 tags after re-tagging and rebuilding' AS check_name, column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* EXPECT  2 rows — email = EMAIL, ssn = SSN */

/* =====================================================================
   TC-01.4   Security check now passes — publish
   ---------------------------------------------------------------------
   Both readers then read through the thin views.
   ===================================================================== */
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
USE ROLE NB_READER_OK; USE DATABASE LM_POC_DB;
SELECT 'TC-01.4 entitled reader' AS check_name, customer_id, email, ssn
FROM NB_D_VIEWS.V_CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  real values */

USE ROLE NB_READER_NO; USE DATABASE LM_POC_DB;
SELECT 'TC-01.4 unentitled reader' AS check_name, customer_id, email, ssn
FROM NB_D_VIEWS.V_CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  ***MASKED*** in both columns */

/* =====================================================================
   TC-01.5   Batch B2 builds into the OTHER storage
   ---------------------------------------------------------------------
   After TC-01.4's swap the storages have exchanged. B2 builds into what
   was NB_D_LIVE. Because TC-01.3 tagged BOTH, the tags are there.
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
SELECT 'TC-01.5 tags on the other storage' AS check_name, column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* EXPECT  2 rows. ZERO ROWS here would mean only one schema was seeded —
   which is exactly what S03 TC-03.1 demonstrates deliberately. */
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

/* =====================================================================
   TC-01.6   Every published table shows B2
   ---------------------------------------------------------------------
   
   ===================================================================== */
/* VERIFY — what a report sees now */
USE ROLE NB_READER_OK; USE DATABASE LM_POC_DB;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM NB_D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM NB_D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 1,  batch_seen = B2 */

/* =====================================================================
   S01 RESULT — WRITE THIS DOWN
   ---------------------------------------------------------------------
   Whether a published table built with COPY TAGS carries its tags on the
   first build, what has to be deployed for it to, and in WHICH SCHEMAS.
   This goes in the testing summary whatever the outcome.
   ===================================================================== */
