/* =====================================================================
   POC07 — CTAS + SWAP      S05  —  Dependency gating
   =====================================================================
   Proves: that a failed or missing dependency stops the publish, and a non-required one does not
   Batches: B1 – B4

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


/* =====================================================================
   TC-05.1   All dependencies COMPLETED — publishes
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
/* THE DEPENDENCY GATE for batch B1.  Any row returned = DO NOT PUBLISH. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT r.object_name AS published_table, d.depends_on_object AS blocked_by,
       NVL(s.status,'NO STATUS ROW') AS status, NVL(s.exception_flag,'N') AS exception_flag
FROM      CTRL.OBJECT_REGISTRY   r
JOIN      CTRL.OBJECT_DEPENDENCY d ON d.object_name = r.object_name
LEFT JOIN CTRL.BATCH_STATUS      s ON s.object_name = d.depends_on_object
                                  AND s.batch_id    = 'B1'
WHERE r.object_type = 'PUBLISHED'
  AND r.is_required = 'Y'
  AND ( s.status IS NULL OR s.status <> 'COMPLETED' )
  AND NVL(s.exception_flag,'N') <> 'Y';
/* EXPECT  ZERO ROWS */
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
   TC-05.2   A required dependency FAILED — refused
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
  ('B2','POLICY','FAILED',CURRENT_TIMESTAMP(),'N');
/* THE DEPENDENCY GATE for batch B2.  Any row returned = DO NOT PUBLISH. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT r.object_name AS published_table, d.depends_on_object AS blocked_by,
       NVL(s.status,'NO STATUS ROW') AS status, NVL(s.exception_flag,'N') AS exception_flag
FROM      CTRL.OBJECT_REGISTRY   r
JOIN      CTRL.OBJECT_DEPENDENCY d ON d.object_name = r.object_name
LEFT JOIN CTRL.BATCH_STATUS      s ON s.object_name = d.depends_on_object
                                  AND s.batch_id    = 'B2'
WHERE r.object_type = 'PUBLISHED'
  AND r.is_required = 'Y'
  AND ( s.status IS NULL OR s.status <> 'COMPLETED' )
  AND NVL(s.exception_flag,'N') <> 'Y';
/* EXPECT  2 ROWS — CUSTOMER_360 and POLICY_SUMMARY, both blocked by POLICY */
/* REFUSE — nothing is published. Record why. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
INSERT INTO CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B2',CURRENT_TIMESTAMP(),'REFUSED','gate: POLICY reported FAILED for B2',NULL,CURRENT_ROLE());
/* VERIFY — what a report sees now */
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  batch_seen = B1. The failed batch published nothing. */

/* =====================================================================
   TC-05.3   A dependency with NO status row at all — refused
   ---------------------------------------------------------------------
   The row is missing entirely, not FAILED. This is the case that passes
   silently if the gate only looks for status = 'FAILED'.
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
/* NOTE: no status row is written for POLICY at all — the missing-row case */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
INSERT INTO CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B3','CUSTOMER','COMPLETED',CURRENT_TIMESTAMP(),'N');
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
/* EXPECT  2 ROWS — status shows NO STATUS ROW */
/* REFUSE — nothing is published. Record why. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
INSERT INTO CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B3',CURRENT_TIMESTAMP(),'REFUSED','gate: POLICY reported no status at all for B3',NULL,CURRENT_ROLE());
/* VERIFY — what a report sees now */
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  batch_seen = B1 still. */

/* =====================================================================
   TC-05.3b   The missing row cannot be exception-approved  (ADDED 27 Oct)
   ---------------------------------------------------------------------
   A gap in the gate, found by review. TC-05.3 proves the block. Nothing
   proved it can be CLEARED — and as the gate is written, it cannot.

   The gate reads exception_flag from the DEPENDENCY'S OWN BATCH_STATUS
   row. For TC-05.2 that works: POLICY reported FAILED, so there is a row
   to set the flag on. Here POLICY reported nothing, so there is no row,
   NVL(s.exception_flag,'N') is always 'N', and the business cannot
   approve its way past it. The domain is stuck until someone writes a
   status the ETL never reported — which puts a fiction in the control
   table that every later audit will read as fact.

   This case proves the dead end. TC-05.3c shows the fix.
   ===================================================================== */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
UPDATE CTRL.BATCH_STATUS SET exception_flag='Y'
 WHERE batch_id='B3' AND object_name='POLICY';
SELECT 'TC-05.3b rows the approval could be written to' AS check_name,
       COUNT(*) AS rows_updated
FROM CTRL.BATCH_STATUS WHERE batch_id='B3' AND object_name='POLICY';
/* EXPECT  rows_updated = 0. There is no row, so the UPDATE did nothing
   and reported success. A silent no-op is the worst possible outcome
   for an approval step: the approver believes they cleared the block. */

/* THE GATE AGAIN — unchanged, to show the approval had no effect. */
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
/* EXPECT  STILL 2 ROWS. The block is unclearable by this route. */

/* =====================================================================
   TC-05.3c   The fix — approvals in their own table  (ADDED 27 Oct)
   ---------------------------------------------------------------------
   Record the approval against (batch_id, dependency) in
   CTRL.EXCEPTION_APPROVAL, and have the gate LEFT JOIN it. The approval
   then exists whether or not the dependency reported anything, carries
   an approver and a reason, and expires with the batch because it is
   keyed on batch_id.
   ===================================================================== */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
INSERT INTO CTRL.EXCEPTION_APPROVAL (batch_id,object_name,approved_by,approved_at,reason)
VALUES ('B3','POLICY','business.owner',CURRENT_TIMESTAMP(),
        'POLICY load did not report for B3; publishing B3 without it, agreed for this batch only');

/* THE REVISED GATE. One extra LEFT JOIN; everything else unchanged.
   Any row returned = DO NOT PUBLISH.                                 */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT r.object_name AS published_table, d.depends_on_object AS blocked_by,
       NVL(s.status,'NO STATUS ROW')      AS status,
       NVL(s.exception_flag,'N')          AS status_row_flag,
       NVL(e.approved_by,'(none)')        AS approved_by
FROM      CTRL.OBJECT_REGISTRY     r
JOIN      CTRL.OBJECT_DEPENDENCY   d ON d.object_name = r.object_name
LEFT JOIN CTRL.BATCH_STATUS        s ON s.object_name = d.depends_on_object
                                    AND s.batch_id    = 'B3'
LEFT JOIN CTRL.EXCEPTION_APPROVAL  e ON e.object_name = d.depends_on_object
                                    AND e.batch_id    = 'B3'
WHERE r.object_type = 'PUBLISHED'
  AND r.is_required = 'Y'
  AND ( s.status IS NULL OR s.status <> 'COMPLETED' )
  AND NVL(s.exception_flag,'N') <> 'Y'
  AND e.object_name IS NULL;
/* EXPECT  ZERO ROWS — the approval clears the missing-row block. */

/* Who approved what, for the record. This is what the publish log's
   exceptions_used must carry.                                       */
SELECT 'TC-05.3c approvals in force for B3' AS check_name,
       object_name, approved_by, approved_at, reason
FROM CTRL.EXCEPTION_APPROVAL WHERE batch_id='B3' ORDER BY object_name;
/* EXPECT  1 row — POLICY, with an approver and a reason. */

/* THE RESET TEST — the approval must not survive into the next batch. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT 'TC-05.3c approvals in force for B4' AS check_name,
       COUNT(*) AS approvals_for_next_batch
FROM CTRL.EXCEPTION_APPROVAL WHERE batch_id='B4';
/* EXPECT  0. Keyed on batch_id, so it cannot leak forward. This is the
   same property s06 TC-06.4 tests for the status-row route.          */

/* tidy up, so TC-05.4 starts from a known state */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
DELETE FROM CTRL.EXCEPTION_APPROVAL WHERE batch_id='B3';

/* =====================================================================
   TC-05.4   A NON-required dependency FAILED — publishes
   ---------------------------------------------------------------------
   
   ===================================================================== */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
UPDATE CTRL.OBJECT_REGISTRY SET is_required='N' WHERE object_name='POLICY_SUMMARY';
DELETE FROM CTRL.OBJECT_DEPENDENCY WHERE object_name='CUSTOMER_360' AND depends_on_object='POLICY';
/* CUSTOMER_360 no longer depends on POLICY, and POLICY_SUMMARY is no
   longer required — so a POLICY failure must not block the publish.  */

/* load the Zone 3 base tables for batch B4 */
USE ROLE P7_BASE_OWNER; USE DATABASE P7_POC;
DELETE FROM BASE.CUSTOMER;
INSERT INTO BASE.CUSTOMER
SELECT seq4()+1, 'Customer '||(seq4()+1),
       'cust'||(seq4()+1)||'@example.invalid',
       LPAD(TO_VARCHAR(seq4()+1),3,'0')||'-00-0000', 'B4'
FROM TABLE(GENERATOR(ROWCOUNT=>20));
DELETE FROM BASE.POLICY;
INSERT INTO BASE.POLICY
SELECT seq4()+1, MOD(seq4(),20)+1, 1000+seq4(), 'B4'
FROM TABLE(GENERATOR(ROWCOUNT=>50));
/* the ETL reports what it did for batch B4 */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
INSERT INTO CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B4','CUSTOMER','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B4','POLICY','FAILED',CURRENT_TIMESTAMP(),'N');
/* THE DEPENDENCY GATE for batch B4.  Any row returned = DO NOT PUBLISH. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT r.object_name AS published_table, d.depends_on_object AS blocked_by,
       NVL(s.status,'NO STATUS ROW') AS status, NVL(s.exception_flag,'N') AS exception_flag
FROM      CTRL.OBJECT_REGISTRY   r
JOIN      CTRL.OBJECT_DEPENDENCY d ON d.object_name = r.object_name
LEFT JOIN CTRL.BATCH_STATUS      s ON s.object_name = d.depends_on_object
                                  AND s.batch_id    = 'B4'
WHERE r.object_type = 'PUBLISHED'
  AND r.is_required = 'Y'
  AND ( s.status IS NULL OR s.status <> 'COMPLETED' )
  AND NVL(s.exception_flag,'N') <> 'Y';
/* EXPECT  ZERO ROWS — nothing required is blocked */
/* BUILD — CTAS into staging for batch B4 */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
CREATE OR REPLACE TABLE D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_CUSTOMER_360;
CREATE OR REPLACE TABLE D_STAGE.POLICY_SUMMARY COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_POLICY_SUMMARY;

USE ROLE P7_PUBLISH_ROLE;
DELETE FROM CTRL.BATCH_STATUS WHERE batch_id='B4' AND object_name IN ('CUSTOMER_360','POLICY_SUMMARY');
INSERT INTO CTRL.BATCH_STATUS (batch_id,object_name,status,status_at,exception_flag) VALUES
  ('B4','CUSTOMER_360','COMPLETED',CURRENT_TIMESTAMP(),'N'),
  ('B4','POLICY_SUMMARY','COMPLETED',CURRENT_TIMESTAMP(),'N');
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
VALUES ('B4',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
/* VERIFY — what a report sees now */
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 1,  batch_seen = B4 */
/* restore the registry so the scenario can be re-run */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
UPDATE CTRL.OBJECT_REGISTRY SET is_required='Y' WHERE object_name='POLICY_SUMMARY';
INSERT INTO CTRL.OBJECT_DEPENDENCY VALUES ('CUSTOMER_360','POLICY');
