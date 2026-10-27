/* =====================================================================
   POC07 — CTAS + SWAP      S03  —  Tags — what COPY TAGS carries and what it does not
   =====================================================================
   Proves: the table-level scope tag, a renamed column, a newly tagged base column, and seeding one schema only
   Batches: B1 – B4

   PREREQUISITE: 00_setup.sql has been run once.
   This script resets the swap pair, the reader views and the control
   tables back to DAY 1, so it can be run on its own and re-run.
   ===================================================================== */

USE SECONDARY ROLES NONE;
USE DATABASE LM_POC_DB;

/* ---------------------------------------------------------------------
   RESET TO DAY 1
   The published tables are created EMPTY in both schemas and tagged in NB_D_LIVE ONLY — deliberately wrong, to show the failure mode.
   ONLY NB_D_LIVE is tagged — deliberately wrong, for TC-03.1.
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

/* The SOURCE VIEWS are shared state too. S03 renames a column in
   V_CUSTOMER_360 and adds one, and S07 renames V_POLICY_SUMMARY away to
   inject a fault. Both put things back at the end - but S07's fault sits
   next to a statement that is MEANT to fail, so an interrupted run is
   likeliest exactly there, and it would leave every later scenario
   building from a view that no longer exists or lost a column.
   Rebuilding them to the canonical shape here costs nothing and makes
   each scenario independent of how the last one ended.                 */
USE ROLE NB_BASE_OWNER; USE DATABASE LM_POC_DB;
DROP VIEW IF EXISTS NB_SRC_VIEWS.V_POLICY_SUMMARY_BROKEN;
CREATE OR REPLACE VIEW NB_SRC_VIEWS.V_CUSTOMER_360 AS
SELECT c.customer_id, c.full_name, c.email, c.ssn,
       COUNT(p.policy_id) AS policy_count, c.batch_id
FROM NB_BASE.CUSTOMER c
LEFT JOIN NB_BASE.POLICY p ON p.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name, c.email, c.ssn, c.batch_id;
CREATE OR REPLACE VIEW NB_SRC_VIEWS.V_POLICY_SUMMARY AS
SELECT p.policy_id, p.customer_id, p.premium, p.batch_id FROM NB_BASE.POLICY p;

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
   TC-03.1   Seed one schema only, then run four batches
   ---------------------------------------------------------------------
   Expected: tags alternate present / absent, because each storage carries
   its own lineage. This is the failure mode when a new object is added
   to one schema and not the other.
   ===================================================================== */
/* ---- batch B1 ---- */
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
SELECT 'TC-03.1 staging tags before the B1 swap' AS check_name, column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B1',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
/* ---- batch B2 ---- */
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
SELECT 'TC-03.1 staging tags before the B2 swap' AS check_name, column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B2',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
/* ---- batch B3 ---- */
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
SELECT 'TC-03.1 staging tags before the B3 swap' AS check_name, column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B3',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
/* ---- batch B4 ---- */
/* load the Zone 3 base tables for batch B4 */
USE ROLE NB_BASE_OWNER; USE DATABASE LM_POC_DB;
DELETE FROM NB_BASE.CUSTOMER;
INSERT INTO NB_BASE.CUSTOMER
SELECT seq4()+1, 'Customer '||(seq4()+1),
       'cust'||(seq4()+1)||'@example.invalid',
       LPAD(TO_VARCHAR(seq4()+1),3,'0')||'-00-0000', 'B4'
FROM TABLE(GENERATOR(ROWCOUNT=>20));
DELETE FROM NB_BASE.POLICY;
INSERT INTO NB_BASE.POLICY
SELECT seq4()+1, MOD(seq4(),20)+1, 1000+seq4(), 'B4'
FROM TABLE(GENERATOR(ROWCOUNT=>50));
/* the ETL reports what it did for batch B4 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B4','CUSTOMER','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B4','POLICY','COMPLETED',CURRENT_TIMESTAMP(),'N');
/* BUILD — CTAS into staging for batch B4 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
CREATE OR REPLACE TABLE NB_D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_CUSTOMER_360;
CREATE OR REPLACE TABLE NB_D_STAGE.POLICY_SUMMARY COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_POLICY_SUMMARY;

USE ROLE NB_PUBLISH_ROLE;
DELETE FROM NB_CTRL.BATCH_STATUS WHERE batch_id='B4' AND object_name IN ('CUSTOMER_360','POLICY_SUMMARY');
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B4','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B4','POLICY_SUMMARY','COMPLETED',CURRENT_TIMESTAMP(),'N');
SELECT 'TC-03.1 staging tags before the B4 swap' AS check_name, column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER SCHEMA NB_D_STAGE SWAP WITH NB_D_LIVE;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B4',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
/* EXPECT  tags present on the batches that build into the storage seeded
   in RESET, and ABSENT on the others. Record which batches had none.  */


/* =====================================================================
   TC-03.2   Does COPY TAGS carry a TABLE-level tag?
   ---------------------------------------------------------------------
   Column tags are documented. A table-level scope override drives which
   approvals apply, so losing it silently changes who sees real values.
   ===================================================================== */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER TABLE NB_D_STAGE.CUSTOMER_360 SET TAG LM_POC_DB.NB_GOV.PII_SCOPE = 'NB_OVERRIDE';
SELECT 'TC-03.2 table tag BEFORE the rebuild' AS check_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'));
/* EXPECT  PII_SCOPE = NB_OVERRIDE */

/* BUILD — CTAS into staging for batch B5 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
CREATE OR REPLACE TABLE NB_D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_CUSTOMER_360;

USE ROLE NB_PUBLISH_ROLE;
DELETE FROM NB_CTRL.BATCH_STATUS WHERE batch_id='B5' AND object_name IN ('CUSTOMER_360');
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B5','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N');
SELECT 'TC-03.2 table tag AFTER the rebuild' AS check_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'));
/* RECORD  does PII_SCOPE = NB_OVERRIDE survive COPY TAGS, or only the
   column tags?  The documentation says "the replaced table AND its
   columns" — this is the check of that on our account.               */


/* =====================================================================
   TC-03.3   A renamed column loses its tag
   ---------------------------------------------------------------------
   Documented in the CREATE TABLE usage notes. The security check must
   catch it rather than publishing an unmasked column.
   ===================================================================== */
/* TC-03.1 deliberately left the UNSEEDED storage sitting in NB_D_STAGE, so the
   table below carries no column tags at all. Re-seed BOTH schemas first, or
   this case cannot tell "the renamed column lost its tag" apart from
   "nothing was tagged to begin with".                                     */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER TABLE NB_D_LIVE.CUSTOMER_360  MODIFY COLUMN email SET TAG LM_POC_DB.NB_GOV.PII = 'EMAIL';
ALTER TABLE NB_D_LIVE.CUSTOMER_360  MODIFY COLUMN ssn   SET TAG LM_POC_DB.NB_GOV.PII = 'SSN';
ALTER TABLE NB_D_STAGE.CUSTOMER_360 MODIFY COLUMN email SET TAG LM_POC_DB.NB_GOV.PII = 'EMAIL';
ALTER TABLE NB_D_STAGE.CUSTOMER_360 MODIFY COLUMN ssn   SET TAG LM_POC_DB.NB_GOV.PII = 'SSN';

USE ROLE NB_BASE_OWNER; USE DATABASE LM_POC_DB;
CREATE OR REPLACE VIEW NB_SRC_VIEWS.V_CUSTOMER_360 AS
SELECT c.customer_id, c.full_name,
       c.email AS email_address,          -- RENAMED
       c.ssn,
       COUNT(p.policy_id) AS policy_count, c.batch_id
FROM NB_BASE.CUSTOMER c
LEFT JOIN NB_BASE.POLICY p ON p.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name, c.email, c.ssn, c.batch_id;

/* BUILD — CTAS into staging for batch B6 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
CREATE OR REPLACE TABLE NB_D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_CUSTOMER_360;

USE ROLE NB_PUBLISH_ROLE;
DELETE FROM NB_CTRL.BATCH_STATUS WHERE batch_id='B6' AND object_name IN ('CUSTOMER_360');
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B6','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N');
SELECT 'TC-03.3 tags after the column rename' AS check_name, column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* EXPECT  the renamed column (email_address) carries NO tag.
   RECORD whether 'ssn' kept its tag.                                  */

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
/* EXPECT  FEWER rows than before — the renamed column lost its tag
   ZERO ROWS  =  REFUSE THE PUBLISH                                    */

/* Part 2 — does masking actually work on this build?
   NB_VIEW_OWNER is unentitled and can reach staging, so it is the
   natural probe.                                                      */
USE ROLE NB_VIEW_OWNER; USE DATABASE LM_POC_DB;
SELECT 'sec-2 unentitled read of staging' AS check_name, customer_id, email, ssn
FROM NB_D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  REAL values in email_address — it is untagged, so nothing masks it
   Real values here mean the data is unprotected — REFUSE THE PUBLISH  */
/* REFUSE — nothing is published. Record why. */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
INSERT INTO NB_CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B6',CURRENT_TIMESTAMP(),'REFUSED','sec-1: renamed column email_address carries no PII tag',NULL,CURRENT_ROLE());
/* restore the view for the next test case */
USE ROLE NB_BASE_OWNER; USE DATABASE LM_POC_DB;
CREATE OR REPLACE VIEW NB_SRC_VIEWS.V_CUSTOMER_360 AS
SELECT c.customer_id, c.full_name, c.email, c.ssn,
       COUNT(p.policy_id) AS policy_count, c.batch_id
FROM NB_BASE.CUSTOMER c
LEFT JOIN NB_BASE.POLICY p ON p.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name, c.email, c.ssn, c.batch_id;


/* =====================================================================
   TC-03.4   A newly tagged base column arrives UNTAGGED
   ---------------------------------------------------------------------
   Governance tags a column in the base layer. COPY TAGS carries forward
   yesterday's tag set, so the new column arrives unprotected.
   ===================================================================== */
/* Re-seed the control column. TC-03.3 renamed email, so ssn is the column
   used to prove the predecessor WAS tagged - without it, 'phone has no tag'
   would be true of every column and would prove nothing.                  */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
ALTER TABLE NB_D_LIVE.CUSTOMER_360  MODIFY COLUMN ssn SET TAG LM_POC_DB.NB_GOV.PII = 'SSN';
ALTER TABLE NB_D_STAGE.CUSTOMER_360 MODIFY COLUMN ssn SET TAG LM_POC_DB.NB_GOV.PII = 'SSN';

USE ROLE NB_BASE_OWNER; USE DATABASE LM_POC_DB;
ALTER TABLE NB_BASE.CUSTOMER ADD COLUMN phone STRING;
UPDATE NB_BASE.CUSTOMER SET phone = '+44-0000-'||customer_id;
ALTER TABLE NB_BASE.CUSTOMER MODIFY COLUMN phone SET TAG LM_POC_DB.NB_GOV.PII = 'PHONE';

CREATE OR REPLACE VIEW NB_SRC_VIEWS.V_CUSTOMER_360 AS
SELECT c.customer_id, c.full_name, c.email, c.ssn, c.phone,
       COUNT(p.policy_id) AS policy_count, c.batch_id
FROM NB_BASE.CUSTOMER c
LEFT JOIN NB_BASE.POLICY p ON p.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name, c.email, c.ssn, c.phone, c.batch_id;

/* BUILD — CTAS into staging for batch B7 */
USE ROLE NB_PUBLISH_ROLE; USE DATABASE LM_POC_DB;
CREATE OR REPLACE TABLE NB_D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM NB_SRC_VIEWS.V_CUSTOMER_360;

USE ROLE NB_PUBLISH_ROLE;
DELETE FROM NB_CTRL.BATCH_STATUS WHERE batch_id='B7' AND object_name IN ('CUSTOMER_360');
INSERT INTO NB_CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B7','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N');
SELECT 'TC-03.4 tags after adding a tagged base column' AS check_name, column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('LM_POC_DB.NB_D_STAGE.CUSTOMER_360','table'))
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
ORDER BY column_name;
/* EXPECT  'ssn' IS tagged (the control) and 'phone' carries NO tag on the
          published table, even though the
   NB_BASE column is tagged. COPY TAGS copies from the previous table, not
   from the source.                                                     */

USE ROLE NB_VIEW_OWNER; USE DATABASE LM_POC_DB;
SELECT 'TC-03.4 unentitled read of the new column' AS check_name, customer_id, phone
FROM NB_D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* RECORD  real phone numbers here = a tagged base column published
   unmasked. THIS IS THE FINDING. Does any check catch it?             */

/* clean up so the scenario can be re-run */
USE ROLE NB_BASE_OWNER; USE DATABASE LM_POC_DB;
ALTER TABLE NB_BASE.CUSTOMER DROP COLUMN phone;
CREATE OR REPLACE VIEW NB_SRC_VIEWS.V_CUSTOMER_360 AS
SELECT c.customer_id, c.full_name, c.email, c.ssn,
       COUNT(p.policy_id) AS policy_count, c.batch_id
FROM NB_BASE.CUSTOMER c
LEFT JOIN NB_BASE.POLICY p ON p.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name, c.email, c.ssn, c.batch_id;
