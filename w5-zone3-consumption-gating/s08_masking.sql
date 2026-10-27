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
USE DATABASE P7_POC;

/* ---------------------------------------------------------------------
   RESET TO DAY 1
   The published tables are created EMPTY in both schemas and tagged in BOTH schemas — the deployment rule from S01.
   --------------------------------------------------------------------- */
USE ROLE P7_PUBLISH_ROLE;
USE DATABASE P7_POC;

CREATE OR REPLACE TABLE D_LIVE.CUSTOMER_360 (
    customer_id NUMBER, full_name STRING, email STRING, ssn STRING,
    policy_count NUMBER, batch_id STRING);
CREATE OR REPLACE TABLE D_LIVE.POLICY_SUMMARY (
    policy_id NUMBER, customer_id NUMBER, premium NUMBER(12,2), batch_id STRING);
CREATE OR REPLACE TABLE D_STAGE.CUSTOMER_360 (
    customer_id NUMBER, full_name STRING, email STRING, ssn STRING,
    policy_count NUMBER, batch_id STRING);
CREATE OR REPLACE TABLE D_STAGE.POLICY_SUMMARY (
    policy_id NUMBER, customer_id NUMBER, premium NUMBER(12,2), batch_id STRING);

ALTER TABLE D_LIVE.CUSTOMER_360 MODIFY COLUMN email SET TAG P7_POC.GOV.PII = 'EMAIL';
ALTER TABLE D_LIVE.CUSTOMER_360 MODIFY COLUMN ssn   SET TAG P7_POC.GOV.PII = 'SSN';
ALTER TABLE D_STAGE.CUSTOMER_360 MODIFY COLUMN email SET TAG P7_POC.GOV.PII = 'EMAIL';
ALTER TABLE D_STAGE.CUSTOMER_360 MODIFY COLUMN ssn   SET TAG P7_POC.GOV.PII = 'SSN';

ALTER SCHEMA D_LIVE  SET TAG P7_POC.GOV.PII_SCOPE = 'P7_DOMAIN';
ALTER SCHEMA D_STAGE SET TAG P7_POC.GOV.PII_SCOPE = 'P7_DOMAIN';

TRUNCATE TABLE CTRL.BATCH_STATUS;
TRUNCATE TABLE CTRL.PUBLISH_LOG;

USE ROLE SECURITYADMIN;
GRANT SELECT ON FUTURE TABLES IN SCHEMA P7_POC.D_LIVE  TO ROLE P7_VIEW_OWNER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA P7_POC.D_STAGE TO ROLE P7_VIEW_OWNER;
GRANT SELECT ON ALL    TABLES IN SCHEMA P7_POC.D_LIVE  TO ROLE P7_VIEW_OWNER;
GRANT SELECT ON ALL    TABLES IN SCHEMA P7_POC.D_STAGE TO ROLE P7_VIEW_OWNER;

/* the thin reader views — outside the swap, keeping the V_ name so
   reports change schema only, never object name                     */
USE ROLE P7_VIEW_OWNER;
USE DATABASE P7_POC;
CREATE OR REPLACE VIEW D_VIEWS.V_CUSTOMER_360   AS SELECT * FROM D_LIVE.CUSTOMER_360;
CREATE OR REPLACE VIEW D_VIEWS.V_POLICY_SUMMARY AS SELECT * FROM D_LIVE.POLICY_SUMMARY;
GRANT SELECT ON ALL VIEWS IN SCHEMA P7_POC.D_VIEWS TO ROLE P7_READER_OK;
GRANT SELECT ON ALL VIEWS IN SCHEMA P7_POC.D_VIEWS TO ROLE P7_READER_NO;

SELECT 'RESET COMPLETE — environment is at day 1' AS status;

/* load the Zone 3 base tables for batch B1 */
USE ROLE P7_BASE_OWNER; USE DATABASE P7_POC;
DELETE FROM BASE.CUSTOMER;
INSERT INTO BASE.CUSTOMER
SELECT seq4()+1, 'Customer '||(seq4()+1),
       'cust'||(seq4()+1)||'@example.invalid',
       LPAD(TO_VARCHAR(seq4()+1),3,'0')||'-00-0000', 'B1'
FROM TABLE(GENERATOR(ROWCOUNT=>20));
DELETE FROM BASE.POLICY;
INSERT INTO BASE.POLICY
SELECT seq4()+1, MOD(seq4(),20)+1, 1000+seq4(), 'B1'
FROM TABLE(GENERATOR(ROWCOUNT=>50));
/* the ETL reports what it did for batch B1 */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
INSERT INTO CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B1','CUSTOMER','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B1','POLICY','COMPLETED',CURRENT_TIMESTAMP(),'N');
/* BUILD — CTAS into staging for batch B1 */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
CREATE OR REPLACE TABLE D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_CUSTOMER_360;
CREATE OR REPLACE TABLE D_STAGE.POLICY_SUMMARY COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_POLICY_SUMMARY;

USE ROLE P7_PUBLISH_ROLE;
DELETE FROM CTRL.BATCH_STATUS WHERE batch_id='B1' AND object_name IN ('CUSTOMER_360','POLICY_SUMMARY');
INSERT INTO CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B1','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B1','POLICY_SUMMARY','COMPLETED',CURRENT_TIMESTAMP(),'N');
/* SECURITY CHECK on staging, before the swap.
   Part 1 — are the tags there?                                        */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT 'sec-1 tags on D_STAGE.CUSTOMER_360' AS check_name,
       column_name, tag_name, tag_value
FROM TABLE(P7_POC.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('P7_POC.D_STAGE.CUSTOMER_360','table'))
WHERE TAG_NAME = 'PII'   -- the ATTRIBUTE tag only; PII_SCOPE is inherited from the schema onto every column
ORDER BY column_name;
/* EXPECT  2 rows — email=EMAIL and ssn=SSN
   ZERO ROWS  =  REFUSE THE PUBLISH                                    */

/* Part 2 — does masking actually work on this build?
   P7_VIEW_OWNER is unentitled and can reach staging, so it is the
   natural probe.                                                      */
USE ROLE P7_VIEW_OWNER; USE DATABASE P7_POC;
SELECT 'sec-2 unentitled read of staging' AS check_name, customer_id, email, ssn
FROM D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  ***MASKED***
   Real values here mean the data is unprotected — REFUSE THE PUBLISH  */
/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
ALTER SCHEMA D_STAGE SWAP WITH D_LIVE;
INSERT INTO CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B1',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());

/* =====================================================================
   TC-08.1   The entitled reader sees real values
   ---------------------------------------------------------------------
   
   ===================================================================== */
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
SELECT 'TC-08.1 entitled reader' AS check_name, customer_id, full_name, email, ssn
FROM D_VIEWS.V_CUSTOMER_360 ORDER BY customer_id LIMIT 5;
/* EXPECT  real e-mail and SSN values */

/* =====================================================================
   TC-08.2   The unentitled reader sees masked values
   ---------------------------------------------------------------------
   
   ===================================================================== */
USE ROLE P7_READER_NO; USE DATABASE P7_POC;
SELECT 'TC-08.2 unentitled reader' AS check_name, customer_id, full_name, email, ssn
FROM D_VIEWS.V_CUSTOMER_360 ORDER BY customer_id LIMIT 5;
/* EXPECT  ***MASKED*** in email and ssn. full_name is untagged, so real. */

/* =====================================================================
   TC-08.3   Readers cannot reach the tables directly
   ---------------------------------------------------------------------
   Readers hold SELECT on D_VIEWS and nothing else.
   ===================================================================== */
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
/* BOTH of these are EXPECTED TO FAIL. Run them, copy the errors in. */
SELECT * FROM D_LIVE.CUSTOMER_360 LIMIT 1;
SELECT * FROM D_STAGE.CUSTOMER_360 LIMIT 1;
/* EXPECT  object does not exist / not authorised, on both */

/* =====================================================================
   TC-08.4   An unentitled batch identity writes MASKS to disk
   ---------------------------------------------------------------------
   The CTAS reads before it writes. If the writing role is not entitled,
   what lands on disk is the mask — permanently, with no error.
   ===================================================================== */
/* load the Zone 3 base tables for batch B2 */
USE ROLE P7_BASE_OWNER; USE DATABASE P7_POC;
DELETE FROM BASE.CUSTOMER;
INSERT INTO BASE.CUSTOMER
SELECT seq4()+1, 'Customer '||(seq4()+1),
       'cust'||(seq4()+1)||'@example.invalid',
       LPAD(TO_VARCHAR(seq4()+1),3,'0')||'-00-0000', 'B2'
FROM TABLE(GENERATOR(ROWCOUNT=>20));
DELETE FROM BASE.POLICY;
INSERT INTO BASE.POLICY
SELECT seq4()+1, MOD(seq4(),20)+1, 1000+seq4(), 'B2'
FROM TABLE(GENERATOR(ROWCOUNT=>50));
/* the ETL reports what it did for batch B2 */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
INSERT INTO CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B2','CUSTOMER','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B2','POLICY','COMPLETED',CURRENT_TIMESTAMP(),'N');
/* grant the unentitled batch role what it needs to build.

   NARROWED 27 Oct — was GRANT ALL ON SCHEMA, which also hands over
   MODIFY and MONITOR on the schema and CREATE on every object type in
   it. The build needs USAGE and CREATE TABLE, nothing more.

   !! OPEN PRIVILEGE WINDOW !!  This grant stays in place for the next
   ~115 lines, and this scenario deliberately contains statements that
   may behave oddly or error. If the run stops anywhere before the
   REVOKE at the end of the file, P7_BATCH_NOENT is left able to create
   tables in the staging schema. ON ABORT, RUN THE REVOKE BY HAND:
       USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
       REVOKE CREATE TABLE, USAGE ON SCHEMA D_STAGE FROM ROLE P7_BATCH_NOENT;
   The end of the file verifies the revoke rather than assuming it.   */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
GRANT USAGE, CREATE TABLE ON SCHEMA D_STAGE TO ROLE P7_BATCH_NOENT;

/* ADDED 27 Oct — and ownership of the table it has to replace.

   Without this the case could not run at all. CREATE OR REPLACE on an object
   that ALREADY EXISTS requires OWNERSHIP of that object; CREATE TABLE on the
   schema only covers creating a new one. So the unentitled build failed with

     003041 (42710): Table 'CUSTOMER_360' already exists, but current role has
     no privileges on it.

   and the case never demonstrated the thing it exists to demonstrate. Verified
   that the original GRANT ALL ON SCHEMA was equally insufficient — schema-level
   privileges never confer ownership of pre-existing objects — so this is not a
   consequence of narrowing that grant.

   It also makes the rest of the case coherent: the repair below hands ownership
   BACK to P7_PUBLISH_ROLE, which only means something if P7_BATCH_NOENT held it.

   Runs as SECURITYADMIN: an ownership transfer WITH COPY CURRENT GRANTS needs
   MANAGE GRANTS, which the table's own owner does not have —
     "Insufficient privileges to operate on grant ownership 'with copy current
      grants'. Your primary role P7_PUBLISH_ROLE must have MANAGE GRANTS..." */
USE ROLE SECURITYADMIN;
GRANT OWNERSHIP ON TABLE P7_POC.D_STAGE.CUSTOMER_360 TO ROLE P7_BATCH_NOENT
  COPY CURRENT GRANTS;

/* ADDED 27 Oct — and the publishing role needs SELECT back, explicitly.

   This is part of the finding, not a workaround. P7_PUBLISH_ROLE's access to the
   staging table came from OWNERSHIP, not from a SELECT grant, so the moment
   ownership moves it can no longer read the table at all — not even to inspect
   what the unentitled writer put there. COPY CURRENT GRANTS does not help: there
   was no SELECT grant to copy.

   Without this the case's own checks failed with
     "Object 'P7_POC.D_STAGE.CUSTOMER_360' does not exist or not authorized"
   which is the ownership churn of section 2.4 row 23 doing exactly what the
   design says it does — blocking the publishing role from its own domain.    */
GRANT SELECT ON TABLE P7_POC.D_STAGE.CUSTOMER_360 TO ROLE P7_PUBLISH_ROLE;

/* BUILD — CTAS into staging for batch B2 */
USE ROLE P7_BATCH_NOENT; USE DATABASE P7_POC;
CREATE OR REPLACE TABLE D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_CUSTOMER_360;

USE ROLE P7_PUBLISH_ROLE;
DELETE FROM CTRL.BATCH_STATUS WHERE batch_id='B2' AND object_name IN ('CUSTOMER_360');
INSERT INTO CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B2','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N');
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT 'TC-08.4 what the unentitled identity WROTE' AS check_name, customer_id, email, ssn
FROM D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 5;
/* EXPECT  ***MASKED*** STORED AS DATA. P7_PUBLISH_ROLE is entitled, so
   if it still reads ***MASKED*** the mask is in the table, not applied
   on read. THIS IS THE FINDING.                                      */

/* SECURITY CHECK on staging, before the swap.
   Part 1 — are the tags there?                                        */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT 'sec-1 tags on D_STAGE.CUSTOMER_360' AS check_name,
       column_name, tag_name, tag_value
FROM TABLE(P7_POC.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('P7_POC.D_STAGE.CUSTOMER_360','table'))
WHERE TAG_NAME = 'PII'   -- the ATTRIBUTE tag only; PII_SCOPE is inherited from the schema onto every column
ORDER BY column_name;
/* EXPECT  2 rows — the tags survived
   ZERO ROWS  =  REFUSE THE PUBLISH                                    */

/* Part 2 — does masking actually work on this build?
   P7_VIEW_OWNER is unentitled and can reach staging, so it is the
   natural probe.                                                      */
USE ROLE P7_VIEW_OWNER; USE DATABASE P7_POC;
SELECT 'sec-2 unentitled read of staging' AS check_name, customer_id, email, ssn
FROM D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  ***MASKED*** — but see TC-08.4: these are STORED masks, not applied ones
   Real values here mean the data is unprotected — REFUSE THE PUBLISH  */
/* REFUSE — nothing is published. Record why. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
INSERT INTO CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B2',CURRENT_TIMESTAMP(),'REFUSED','sec-2: stored values are masks — the writing identity was not entitled',NULL,CURRENT_ROLE());

/* The CTAS above was run by P7_BATCH_NOENT, so that role now OWNS the
   staging table — and P7_PUBLISH_ROLE can no longer replace it. Hand
   ownership back before continuing.
   RECORD THIS: every rebuild makes the role that ran it the owner,
   which is the per-cycle ownership churn CTAS introduces.             */
USE ROLE P7_BATCH_NOENT; USE DATABASE P7_POC;
SHOW TABLES LIKE 'CUSTOMER_360' IN SCHEMA D_STAGE;
SELECT 'TC-08.4 owner after an unentitled build' AS check_name, "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* EXPECT  owner = P7_BATCH_NOENT, not P7_PUBLISH_ROLE */

/* THE OWNERSHIP REPAIR. Without this the publishing role can no longer
   replace this table on the next batch, and the run fails on a privilege
   error that has nothing to do with the data. This is the practical face
   of the ownership churn recorded above — not a tidy-up, a prerequisite.

   FIXED 27 Oct — ran as P7_BATCH_NOENT, which cannot do it: an ownership
   transfer WITH COPY CURRENT GRANTS requires MANAGE GRANTS, and the losing
   owner does not have it. SECURITYADMIN does. */
USE ROLE SECURITYADMIN;
GRANT OWNERSHIP ON TABLE P7_POC.D_STAGE.CUSTOMER_360
  TO ROLE P7_PUBLISH_ROLE COPY CURRENT GRANTS;

/* Confirm the repair took, before relying on it. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SHOW TABLES LIKE 'CUSTOMER_360' IN SCHEMA D_STAGE;
SELECT 'TC-08.4 owner after the repair' AS check_name, "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* EXPECT  owner = P7_PUBLISH_ROLE.
   Anything else means the next rebuild will fail on privileges.      */

/* =====================================================================
   TC-08.5   The entitled batch identity writes real values
   ---------------------------------------------------------------------
   
   ===================================================================== */
/* BUILD — CTAS into staging for batch B2 */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
CREATE OR REPLACE TABLE D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_CUSTOMER_360;

USE ROLE P7_PUBLISH_ROLE;
DELETE FROM CTRL.BATCH_STATUS WHERE batch_id='B2' AND object_name IN ('CUSTOMER_360');
INSERT INTO CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B2','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N');
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT 'TC-08.5 what the entitled identity wrote' AS check_name, customer_id, email, ssn
FROM D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 5;
/* EXPECT  real values */

/* BUILD — CTAS into staging for batch B2 */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
CREATE OR REPLACE TABLE D_STAGE.POLICY_SUMMARY COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_POLICY_SUMMARY;

USE ROLE P7_PUBLISH_ROLE;
DELETE FROM CTRL.BATCH_STATUS WHERE batch_id='B2' AND object_name IN ('POLICY_SUMMARY');
INSERT INTO CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B2','POLICY_SUMMARY','COMPLETED',CURRENT_TIMESTAMP(),'N');
/* SECURITY CHECK on staging, before the swap.
   Part 1 — are the tags there?                                        */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT 'sec-1 tags on D_STAGE.CUSTOMER_360' AS check_name,
       column_name, tag_name, tag_value
FROM TABLE(P7_POC.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('P7_POC.D_STAGE.CUSTOMER_360','table'))
WHERE TAG_NAME = 'PII'   -- the ATTRIBUTE tag only; PII_SCOPE is inherited from the schema onto every column
ORDER BY column_name;
/* EXPECT  2 rows — email=EMAIL and ssn=SSN
   ZERO ROWS  =  REFUSE THE PUBLISH                                    */

/* Part 2 — does masking actually work on this build?
   P7_VIEW_OWNER is unentitled and can reach staging, so it is the
   natural probe.                                                      */
USE ROLE P7_VIEW_OWNER; USE DATABASE P7_POC;
SELECT 'sec-2 unentitled read of staging' AS check_name, customer_id, email, ssn
FROM D_STAGE.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  ***MASKED***
   Real values here mean the data is unprotected — REFUSE THE PUBLISH  */
/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
ALTER SCHEMA D_STAGE SWAP WITH D_LIVE;
INSERT INTO CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B2',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
/* VERIFY — what a report sees now */
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 1,  batch_seen = B2 */
/* tidy up the extra grant — and PROVE it is gone. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
REVOKE CREATE TABLE, USAGE ON SCHEMA D_STAGE FROM ROLE P7_BATCH_NOENT;

SHOW GRANTS TO ROLE P7_BATCH_NOENT;
SELECT 'TC-08 privilege window closed' AS check_name,
       COUNT(*) AS remaining_stage_grants
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "granted_on" = 'SCHEMA' AND "name" LIKE '%D_STAGE%';
/* EXPECT  remaining_stage_grants = 0.
   Any other number means the window is still open. Do not finish the
   scenario on an assumption — this is the check that closes it.      */
