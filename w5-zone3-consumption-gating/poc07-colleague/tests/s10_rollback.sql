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

USE ROLE SECURITYADMIN;
GRANT SELECT ON TABLE P7_POC.D_LIVE.CUSTOMER_360  TO ROLE P7_PROBE_ROLE;
GRANT SELECT ON TABLE P7_POC.D_STAGE.CUSTOMER_360 TO ROLE P7_PROBE_ROLE;


/* =====================================================================
   TC-10.1   Publish B1
   ---------------------------------------------------------------------
   
   ===================================================================== */
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
/* VERIFY — what a report sees now */
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 1,  batch_seen = B1 */

/* =====================================================================
   TC-10.2   Publish B2
   ---------------------------------------------------------------------
   
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
/* BUILD — CTAS into staging for batch B2 */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
CREATE OR REPLACE TABLE D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_CUSTOMER_360;
CREATE OR REPLACE TABLE D_STAGE.POLICY_SUMMARY COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_POLICY_SUMMARY;

USE ROLE P7_PUBLISH_ROLE;
DELETE FROM CTRL.BATCH_STATUS WHERE batch_id='B2' AND object_name IN ('CUSTOMER_360','POLICY_SUMMARY');
INSERT INTO CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B2','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N'),
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
/* EXPECT  batch_seen = B2 */

/* =====================================================================
   TC-10.3   A problem is found — roll back
   ---------------------------------------------------------------------
   The previous version is still sitting in the other storage, so the
   rollback is one more swap. It holds only until the next batch
   overwrites that storage.
   ===================================================================== */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
ALTER SCHEMA D_STAGE SWAP WITH D_LIVE;
INSERT INTO CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B2',CURRENT_TIMESTAMP(),'ROLLED_BACK','rolled back after publication — reverted to B1',NULL,CURRENT_ROLE());
/* FIXED 27 Oct — was logged as 'REFUSED'. B2 WAS published: readers saw
   it, for however long it took to spot the problem. Logging that as
   'REFUSED' says it never went out, which is the opposite of the truth
   and the one fact an incident review needs. See 00_setup.sql.       */

/* VERIFY — what a report sees now */
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  batch_seen = B1. The rollback worked. */

/* FIXED 27 Oct — the fingerprint reads D_LIVE, which the reader role cannot see.
   Without this switch it inherited P7_READER_OK from the check above and failed
   with "Schema 'P7_POC.D_LIVE' does not exist or not authorized", taking the
   SHOW GRANTS + RESULT_SCAN pair down with it. Same defect as s02. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT 'TC-10.3 tags after the rollback' AS check_name, column_name, tag_name, tag_value
FROM TABLE(P7_POC.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('P7_POC.D_LIVE.CUSTOMER_360','table'))
WHERE TAG_NAME = 'PII'   -- the ATTRIBUTE tag only; PII_SCOPE is inherited from the schema onto every column
ORDER BY column_name;
/* EXPECT  2 rows — tags came back with the storage */

SHOW GRANTS ON TABLE P7_POC.D_LIVE.CUSTOMER_360;
SELECT 'TC-10.3 grants after the rollback' AS check_name,
       "privilege", "grantee_name", "granted_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "grantee_name" LIKE 'P7_%' ORDER BY "grantee_name","privilege";
/* EXPECT  P7_PROBE_ROLE still holds SELECT */

USE ROLE P7_READER_NO; USE DATABASE P7_POC;
SELECT 'TC-10.3 unentitled reader after rollback' AS check_name, customer_id, email, ssn
FROM D_VIEWS.V_CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  ***MASKED*** — the thin views still resolve and masking still applies */

/* =====================================================================
   TC-10.4   The next batch publishes normally
   ---------------------------------------------------------------------
   A rollback must not leave the domain stuck.
   ===================================================================== */
/* load the Zone 3 base tables for batch B3 */
USE ROLE P7_BASE_OWNER; USE DATABASE P7_POC;
DELETE FROM BASE.CUSTOMER;
INSERT INTO BASE.CUSTOMER
SELECT seq4()+1, 'Customer '||(seq4()+1),
       'cust'||(seq4()+1)||'@example.invalid',
       LPAD(TO_VARCHAR(seq4()+1),3,'0')||'-00-0000', 'B3'
FROM TABLE(GENERATOR(ROWCOUNT=>20));
DELETE FROM BASE.POLICY;
INSERT INTO BASE.POLICY
SELECT seq4()+1, MOD(seq4(),20)+1, 1000+seq4(), 'B3'
FROM TABLE(GENERATOR(ROWCOUNT=>50));
/* the ETL reports what it did for batch B3 */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
INSERT INTO CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B3','CUSTOMER','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B3','POLICY','COMPLETED',CURRENT_TIMESTAMP(),'N');
/* THE DEPENDENCY GATE for batch B3.  Any row returned = DO NOT PUBLISH. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT r.object_name AS published_table, d.depends_on_object AS blocked_by,
       NVL(s.status,'NO STATUS ROW') AS status, NVL(s.exception_flag,'N') AS exception_flag
FROM      CTRL.OBJECT_REGISTRY   r
JOIN      CTRL.OBJECT_DEPENDENCY d ON d.object_name = r.object_name
LEFT JOIN CTRL.BATCH_STATUS      s ON s.object_name = d.depends_on_object
                                  AND s.batch_id    = 'B3'
WHERE r.object_type = 'PUBLISHED'
  AND r.is_required = 'Y'
  AND ( s.status IS NULL OR s.status <> 'COMPLETED' )
  AND NVL(s.exception_flag,'N') <> 'Y';
/* EXPECT  ZERO ROWS */
/* BUILD — CTAS into staging for batch B3 */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
CREATE OR REPLACE TABLE D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_CUSTOMER_360;
CREATE OR REPLACE TABLE D_STAGE.POLICY_SUMMARY COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_POLICY_SUMMARY;

USE ROLE P7_PUBLISH_ROLE;
DELETE FROM CTRL.BATCH_STATUS WHERE batch_id='B3' AND object_name IN ('CUSTOMER_360','POLICY_SUMMARY');
INSERT INTO CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B3','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B3','POLICY_SUMMARY','COMPLETED',CURRENT_TIMESTAMP(),'N');
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
VALUES ('B3',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
/* VERIFY — what a report sees now */
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 1,  batch_seen = B3 */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT 'TC-10.4 full publish history' AS check_name, batch_id, outcome, refused_reason, attempted_at
FROM CTRL.PUBLISH_LOG ORDER BY attempted_at;
/* EXPECT  B1 PUBLISHED, B2 PUBLISHED, B2 ROLLED_BACK, B3 PUBLISHED
   FIXED 27 Oct — the third row was 'REFUSED' here too.               */

/* THE AUDIT QUESTION the log has to answer without reading free text:
   which batches actually reached readers, and which of those were
   later pulled back?                                                 */
SELECT 'TC-10.4 what readers actually saw' AS check_name,
       batch_id,
       COUNT_IF(outcome = 'PUBLISHED')   AS times_published,
       COUNT_IF(outcome = 'ROLLED_BACK') AS times_rolled_back,
       COUNT_IF(outcome = 'REFUSED')     AS times_refused,
       CASE WHEN COUNT_IF(outcome = 'PUBLISHED') = 0 THEN 'never reached readers'
            WHEN COUNT_IF(outcome = 'ROLLED_BACK') > 0 THEN 'reached readers, then withdrawn'
            ELSE 'reached readers and stands' END AS verdict
FROM CTRL.PUBLISH_LOG
GROUP BY batch_id ORDER BY batch_id;
/* EXPECT  B1 'reached readers and stands'
           B2 'reached readers, then withdrawn'
           B3 'reached readers and stands'
   This query is the reason ROLLED_BACK has to be its own outcome: with
   B2's rollback logged as REFUSED, B2 reads as both published and
   refused and the verdict cannot be computed.                        */
