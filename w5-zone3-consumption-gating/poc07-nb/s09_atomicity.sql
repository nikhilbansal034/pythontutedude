/* =====================================================================
   POC07 — CTAS + SWAP      S09  —  Atomicity at the swap
   =====================================================================
   Proves: that a reader never sees one table new and another old
   Batches: B1 – B2

   PREREQUISITE: 00_setup.sql has been run once.
   This script resets the swap pair, the reader views and the control
   tables back to DAY 1, so it can be run on its own and re-run.
   TWO SESSIONS ARE NEEDED. Open a second worksheet before you start.
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
/* stage batch B2 and STOP. Do not swap yet. */
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

/* =====================================================================
   TC-09.1   A reader holding a query open across the swap
   ---------------------------------------------------------------------
   SESSION B starts a long query joining both thin views.
   SESSION A runs the swap while it is still running.
   ===================================================================== */
/* ---------------------------------------------------------------------
   SESSION B  —  run this FIRST, and leave it running
   ---------------------------------------------------------------------
   USE SECONDARY ROLES NONE;
   USE ROLE NB_READER_OK; USE DATABASE LM_POC_DB;
   SELECT 'TC-09.1 reader spanning the swap' AS check_name,
          COUNT(DISTINCT batch_id) AS distinct_batches,
          MIN(batch_id) AS lowest, MAX(batch_id) AS highest
   FROM ( SELECT batch_id FROM NB_D_VIEWS.V_CUSTOMER_360
          UNION ALL SELECT batch_id FROM NB_D_VIEWS.V_POLICY_SUMMARY )
   WHERE SYSTEM$WAIT(45) IS NOT NULL;
   -- EXPECT  distinct_batches = 1.  A 2 means the reader saw a mixture
   -- and the design does not hold.
   --------------------------------------------------------------------- */

/* ---------------------------------------------------------------------
   SESSION A  —  run this WHILE session B is waiting
   --------------------------------------------------------------------- */
/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B2',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
SELECT 'TC-09.1 swap done — now read session B''s result' AS check_name;

/* =====================================================================
   TC-09.2   Repeat it
   ---------------------------------------------------------------------
   One pass shows a mixture did not happen in these runs, not that it
   cannot. Repeat at least 50 times, alternating the swap back and forth.
   ===================================================================== */
/* Each repetition: SESSION B starts the query above, SESSION A runs
   one swap. The swap alternates the storages, so the batch id a reader
   sees alternates too — what must NEVER change is that it is ONE id.

   SESSION A, one repetition:                                         */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;

/* RECORD  how many repetitions were run and how many showed
   distinct_batches > 1.  Expected: 0 out of N.                       */

/* =====================================================================
   TC-09.3   A NEW statement immediately after the swap returns
   ---------------------------------------------------------------------
   The different question: not a query spanning the swap, but one issued
   the instant it completes.
   ===================================================================== */
/* SESSION A: swap, then IMMEDIATELY run the read in SESSION B */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;

/* SESSION B, run at once:
   USE ROLE NB_READER_OK; USE DATABASE LM_POC_DB;
   SELECT COUNT(DISTINCT batch_id) AS distinct_batches
   FROM ( SELECT batch_id FROM NB_D_VIEWS.V_CUSTOMER_360
          UNION ALL SELECT batch_id FROM NB_D_VIEWS.V_POLICY_SUMMARY );
   -- EXPECT  1                                                       */
