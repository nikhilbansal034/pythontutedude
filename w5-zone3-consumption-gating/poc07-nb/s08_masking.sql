/* =====================================================================
   POC07 — CTAS + SWAP      S08  —  Masking through the thin reader views
   =====================================================================
   Proves: that readers see the right thing, and that an unentitled batch identity writes masks to disk
   Batches: B1 – B2

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

/* OBJECT_REGISTRY and OBJECT_DEPENDENCY describe the graph, not the run.
   S05 mutates both and restores them at the end, but a run that stops part
   way would leave them changed and silently weaken every later scenario.
   Rebuilding them here makes each scenario independent of that.        */
DELETE FROM NB_CTRL.OBJECT_DEPENDENCY;
DELETE FROM NB_CTRL.OBJECT_REGISTRY;
INSERT INTO NB_CTRL.OBJECT_REGISTRY (object_name, object_type, is_required, live_schema, stage_schema) VALUES
  ('CUSTOMER'      ,'SOURCE'   ,'Y','',''),
  ('POLICY'        ,'SOURCE'   ,'Y','',''),
  ('CUSTOMER_360'  ,'PUBLISHED','Y','NB_D_LIVE','NB_D_STAGE'),
  ('POLICY_SUMMARY','PUBLISHED','Y','NB_D_LIVE','NB_D_STAGE');
INSERT INTO NB_CTRL.OBJECT_DEPENDENCY (object_name, depends_on_object) VALUES
  ('CUSTOMER_360'  ,'CUSTOMER'),
  ('CUSTOMER_360'  ,'POLICY'),
  ('POLICY_SUMMARY','POLICY');

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

/* =====================================================================
   TC-08.1   The entitled reader sees real values
   ---------------------------------------------------------------------
   
   ===================================================================== */
USE ROLE NB_READER_OK; USE DATABASE LM_POC_DB;
SELECT 'TC-08.1 entitled reader' AS check_name, customer_id, full_name, email, ssn
FROM NB_D_VIEWS.V_CUSTOMER_360 ORDER BY customer_id LIMIT 5;
/* EXPECT  real e-mail and SSN values */

/* =====================================================================
   TC-08.2   The unentitled reader sees masked values
   ---------------------------------------------------------------------
   
   ===================================================================== */
USE ROLE NB_READER_NO; USE DATABASE LM_POC_DB;
SELECT 'TC-08.2 unentitled reader' AS check_name, customer_id, full_name, email, ssn
FROM NB_D_VIEWS.V_CUSTOMER_360 ORDER BY customer_id LIMIT 5;
/* EXPECT  ***MASKED*** in email and ssn. full_name is untagged, so real. */

/* =====================================================================
   TC-08.3   Readers cannot reach the tables directly
   ---------------------------------------------------------------------
   Readers hold SELECT on NB_D_VIEWS and nothing else.
   ===================================================================== */
USE ROLE NB_READER_OK; USE DATABASE LM_POC_DB;
/* BOTH of these are EXPECTED TO FAIL. Run them, copy the errors in. */
SELECT * FROM NB_D_LIVE.CUSTOMER_360 LIMIT 1;
SELECT * FROM NB_D_STAGE.CUSTOMER_360 LIMIT 1;
/* EXPECT  object does not exist / not authorised, on both */

/* =====================================================================
   TC-08.4   An unentitled batch identity writes MASKS to disk
   ---------------------------------------------------------------------
   The CTAS reads before it writes. If the writing role is not entitled,
   what lands on disk is the mask — permanently, with no error.
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
/* grant the unentitled batch role what it needs to build */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
GRANT ALL ON SCHEMA NB_D_STAGE TO ROLE NB_BATCH_NOENT;

/* BUILD — CTAS into staging for batch B2 */
USE ROLE NB_BATCH_NOENT; USE DATABASE LM_POC_DB;
CREATE OR REPLACE TABLE NB_D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_CUSTOMER_360;

USE ROLE NB_PUBLISH_ROLE;
DELETE FROM NB_CTRL.BATCH_STATUS WHERE batch_id='B2' AND object_name IN ('CUSTOMER_360');
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B2','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N');
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
SELECT 'TC-08.4 what the unentitled identity WROTE' AS check_name, customer_id, email, ssn
FROM NB_D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 5;
/* EXPECT  ***MASKED*** STORED AS DATA. NB_PUBLISH_ROLE is entitled, so
   if it still reads ***MASKED*** the mask is in the table, not applied
   on read. THIS IS THE FINDING.                                      */

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
/* EXPECT  2 rows — the tags survived
   ZERO ROWS  =  REFUSE THE PUBLISH                                    */

/* Part 2 — does masking actually work on this build?
   NB_VIEW_OWNER is unentitled and can reach staging, so it is the
   natural probe.                                                      */
USE ROLE NB_VIEW_OWNER; USE DATABASE LM_POC_DB;
SELECT 'sec-2 unentitled read of staging' AS check_name, customer_id, email, ssn
FROM NB_D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  ***MASKED*** — but see TC-08.4: these are STORED masks, not applied ones
   Real values here mean the data is unprotected — REFUSE THE PUBLISH  */
/* REFUSE — nothing is published. Record why. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B2',CURRENT_TIMESTAMP(),'REFUSED','sec-2: stored values are masks — the writing identity was not entitled',NULL,CURRENT_ROLE());

/* The CTAS above was run by NB_BATCH_NOENT, so that role now OWNS the
   staging table — and NB_PUBLISH_ROLE can no longer replace it. Hand
   ownership back before continuing.
   RECORD THIS: every rebuild makes the role that ran it the owner,
   which is the per-cycle ownership churn CTAS introduces.             */
USE ROLE NB_BATCH_NOENT; USE DATABASE LM_POC_DB;
SHOW TABLES LIKE 'CUSTOMER_360' IN SCHEMA NB_D_STAGE;
SELECT 'TC-08.4 owner after an unentitled build' AS check_name, "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* EXPECT  owner = NB_BATCH_NOENT, not NB_PUBLISH_ROLE */

GRANT OWNERSHIP ON TABLE LM_POC_DB.NB_D_STAGE.CUSTOMER_360
  TO ROLE NB_PUBLISH_ROLE COPY CURRENT GRANTS;

/* =====================================================================
   TC-08.5   The entitled batch identity writes real values
   ---------------------------------------------------------------------
   
   ===================================================================== */
/* BUILD — CTAS into staging for batch B2 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
CREATE OR REPLACE TABLE NB_D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_CUSTOMER_360;

USE ROLE NB_PUBLISH_ROLE;
DELETE FROM NB_CTRL.BATCH_STATUS WHERE batch_id='B2' AND object_name IN ('CUSTOMER_360');
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B2','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N');
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
SELECT 'TC-08.5 what the entitled identity wrote' AS check_name, customer_id, email, ssn
FROM NB_D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 5;
/* EXPECT  real values */

/* BUILD — CTAS into staging for batch B2 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
CREATE OR REPLACE TABLE NB_D_STAGE.POLICY_SUMMARY COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_POLICY_SUMMARY;

USE ROLE NB_PUBLISH_ROLE;
DELETE FROM NB_CTRL.BATCH_STATUS WHERE batch_id='B2' AND object_name IN ('POLICY_SUMMARY');
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
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
/* tidy up the extra grant */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
REVOKE ALL ON SCHEMA NB_D_STAGE FROM ROLE NB_BATCH_NOENT;
