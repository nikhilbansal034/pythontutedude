/* =====================================================================
   POC07 — CTAS + SWAP      S06  —  Exception approval and its expiry
   =====================================================================
   Proves: that an approved exception lets a batch through, and does NOT carry into the next batch
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

/* OBJECT_REGISTRY and OBJECT_DEPENDENCY describe the graph, not the run.
   S05 mutates both and restores them at the end, but a run that stops part
   way would leave them changed and silently weaken every later scenario.
   Rebuilding them here makes each scenario independent of that.        */
DELETE FROM CTRL.OBJECT_DEPENDENCY;
DELETE FROM CTRL.OBJECT_REGISTRY;
INSERT INTO CTRL.OBJECT_REGISTRY (object_name, object_type, is_required, live_schema, stage_schema) VALUES
  ('CUSTOMER'      ,'SOURCE'   ,'Y','',''),
  ('POLICY'        ,'SOURCE'   ,'Y','',''),
  ('CUSTOMER_360'  ,'PUBLISHED','Y','D_LIVE','D_STAGE'),
  ('POLICY_SUMMARY','PUBLISHED','Y','D_LIVE','D_STAGE');
INSERT INTO CTRL.OBJECT_DEPENDENCY (object_name, depends_on_object) VALUES
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
USE ROLE P7_BASE_OWNER; USE DATABASE P7_POC;
DROP VIEW IF EXISTS SRC_VIEWS.V_POLICY_SUMMARY_BROKEN;
CREATE OR REPLACE VIEW SRC_VIEWS.V_CUSTOMER_360 AS
SELECT c.customer_id, c.full_name, c.email, c.ssn,
       COUNT(p.policy_id) AS policy_count, c.batch_id
FROM BASE.CUSTOMER c
LEFT JOIN BASE.POLICY p ON p.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name, c.email, c.ssn, c.batch_id;
CREATE OR REPLACE VIEW SRC_VIEWS.V_POLICY_SUMMARY AS
SELECT p.policy_id, p.customer_id, p.premium, p.batch_id FROM BASE.POLICY p;

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
GRANT SELECT ON ALL VIEWS IN SCHEMA D_VIEWS TO ROLE P7_READER_OK;
GRANT SELECT ON ALL VIEWS IN SCHEMA D_VIEWS TO ROLE P7_READER_NO;

SELECT 'RESET COMPLETE — environment is at day 1' AS status;


/* =====================================================================
   TC-06.1   Baseline — a clean publish
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
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
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
   TC-06.2   A required dependency fails — refused
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
/* EXPECT  2 ROWS — blocked by POLICY */
/* REFUSE — nothing is published. Record why. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
INSERT INTO CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B2',CURRENT_TIMESTAMP(),'REFUSED','gate: POLICY reported FAILED for B2',NULL,CURRENT_ROLE());

/* =====================================================================
   TC-06.3   The business approves an exception for THIS batch
   ---------------------------------------------------------------------
   The approval names the object and the batch, and records who and why.
   ===================================================================== */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
UPDATE CTRL.BATCH_STATUS
   SET exception_flag = 'Y',
       approved_by    = 'business.owner@example.invalid',
       approved_at    = CURRENT_TIMESTAMP(),
       reason         = 'Month-end reporting deadline. Policy feed delayed upstream.'
 WHERE batch_id = 'B2' AND object_name = 'POLICY';

SELECT 'TC-06.3 the approval row' AS check_name, batch_id, object_name, status,
       exception_flag, approved_by, approved_at, reason
FROM CTRL.BATCH_STATUS WHERE batch_id='B2' AND object_name='POLICY';
/* EXPECT  status FAILED, exception_flag Y, with approver and reason */

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
/* EXPECT  ZERO ROWS — the exception clears the block */
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
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
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
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
UPDATE CTRL.PUBLISH_LOG
   SET exceptions_used = 'POLICY (approved by business.owner@example.invalid)'
 WHERE batch_id = 'B2' AND outcome = 'PUBLISHED';

SELECT 'TC-06.3 publish log' AS check_name, batch_id, outcome, exceptions_used, run_by
FROM CTRL.PUBLISH_LOG ORDER BY attempted_at;
/* EXPECT  B2 PUBLISHED, with the exception recorded against it */

/* VERIFY — what a report sees now */
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 1,  batch_seen = B2 */

/* =====================================================================
   TC-06.4   THE RESET TEST — the next batch must not inherit it
   ---------------------------------------------------------------------
   Same object fails again in B3. No new approval is given. The B2 flag
   must not reach B3.
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
  ('B3','POLICY','FAILED',CURRENT_TIMESTAMP(),'N');
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT 'TC-06.4 exception flags by batch' AS check_name, batch_id, object_name,
       status, exception_flag, approved_by
FROM CTRL.BATCH_STATUS WHERE object_name='POLICY' ORDER BY batch_id;
/* EXPECT  B2 -> Y with an approver,  B3 -> N with none.
   The B2 approval stays as the audit record; it does not carry forward. */

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
/* EXPECT  2 ROWS — blocked again, because B3 has no exception */
/* REFUSE — nothing is published. Record why. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
INSERT INTO CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B3',CURRENT_TIMESTAMP(),'REFUSED','gate: POLICY FAILED for B3 and no exception was approved for B3',NULL,CURRENT_ROLE());
/* VERIFY — what a report sees now */
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 1,  batch_seen = B2 — B3 was refused and published
   nothing, so the views still read B2. B3 here would mean the exception was
   applied when it should not have been. */

/* =====================================================================
   TC-06.5   Normal publishing resumes
   ---------------------------------------------------------------------
   
   ===================================================================== */
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
  ('B4','POLICY','COMPLETED',CURRENT_TIMESTAMP(),'N');
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
/* EXPECT  ZERO ROWS */
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
WHERE tag_name = 'PII'   /* the schema carries PII_SCOPE, and Snowflake inherits a
                            schema tag down to EVERY column - so an unfiltered call
                            returns one PII_SCOPE row per column and buries the
                            answer. This check is about the column-level PII tag. */
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
