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
/* VERIFY — what a report sees now */
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
SELECT 'batch ids across the thin views' AS check_name,
       COUNT(DISTINCT batch_id) AS distinct_batches, MAX(batch_id) AS batch_seen
FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY );
/* EXPECT  distinct_batches = 1,  batch_seen = B1 */
/* stage batch B2 and STOP. Do not swap yet. */
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
   USE ROLE P7_READER_OK; USE DATABASE P7_POC;
   SELECT 'TC-09.1 reader spanning the swap' AS check_name,
          COUNT(DISTINCT batch_id) AS distinct_batches,
          MIN(batch_id) AS lowest, MAX(batch_id) AS highest
   FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
          UNION ALL SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY )
   WHERE SYSTEM$WAIT(45) IS NOT NULL;
   -- EXPECT  distinct_batches = 1.  A 2 means the reader saw a mixture
   -- and the design does not hold.
   --------------------------------------------------------------------- */

/* ---------------------------------------------------------------------
   SESSION A  —  run this WHILE session B is waiting
   --------------------------------------------------------------------- */
/* PUBLISH — the swap. One metadata operation, no data moves. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
ALTER SCHEMA D_STAGE SWAP WITH D_LIVE;
INSERT INTO CTRL.PUBLISH_LOG (batch_id,attempted_at,outcome,refused_reason,exceptions_used,run_by)
VALUES ('B2',CURRENT_TIMESTAMP(),'PUBLISHED',NULL,NULL,CURRENT_ROLE());
SELECT 'TC-09.1 swap done — now read session B''s result' AS check_name;

/* =====================================================================
   TC-09.2   Repeat it
   ---------------------------------------------------------------------
   One pass shows a mixture did not happen in that run, not that it
   cannot. This must be repeated many times and every reading recorded.

   FIXED 27 Oct — as written this case was a bare SWAP plus a prose
   instruction to "repeat at least 50 times", with nothing to loop and
   nothing to capture, so it could not be run or evidenced. It is now two
   runnable blocks, one per session, both writing to a results table.
   No stored procedure is created: these are anonymous blocks, so the
   suite's deliberate "no procedure" stance is unchanged.
   ===================================================================== */

/* The results table. Readings must be captured as they happen — every
   scenario in this suite TRUNCATEs the control tables on reset, so an
   eyeballed number is lost the moment the next scenario runs.          */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
CREATE TABLE IF NOT EXISTS CTRL.ATOMICITY_RESULTS (
    case_id          STRING,
    rep_no           NUMBER,
    session_tag      STRING,
    captured_at      TIMESTAMP_LTZ,
    distinct_batches NUMBER,
    lowest           STRING,
    highest          STRING,
    note             STRING);
GRANT INSERT, SELECT ON TABLE CTRL.ATOMICITY_RESULTS TO ROLE P7_READER_OK;

DELETE FROM CTRL.ATOMICITY_RESULTS WHERE case_id = 'TC-09.2';

/* ---------------------------------------------------------------------
   SESSION B  —  THE READER.  Start this FIRST and leave it running.
   50 repetitions, each one a fresh statement reading both thin views
   and recording what it saw. SYSTEM$WAIT spaces them out so session A's
   swaps land in the middle of the run rather than all before or after.
   --------------------------------------------------------------------- */
/*
USE SECONDARY ROLES NONE;
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
BEGIN
  FOR i IN 1 TO 50 DO
    INSERT INTO CTRL.ATOMICITY_RESULTS
      (case_id, rep_no, session_tag, captured_at, distinct_batches, lowest, highest, note)
    SELECT 'TC-09.2', :i, 'B-reader', CURRENT_TIMESTAMP(),
           COUNT(DISTINCT batch_id), MIN(batch_id), MAX(batch_id), NULL
    FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
           UNION ALL SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY );
    CALL SYSTEM$WAIT(1);
  END FOR;
  RETURN 'TC-09.2 reader finished 50 repetitions';
END;
*/

/* ---------------------------------------------------------------------
   SESSION A  —  THE PUBLISHER.  Run this WHILE session B is looping.
   25 swaps, so the storages alternate back and forth underneath the
   reader. The batch id a reader sees alternates too — what must NEVER
   change is that it sees exactly ONE id.
   --------------------------------------------------------------------- */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
BEGIN
  FOR i IN 1 TO 25 DO
    ALTER SCHEMA D_STAGE SWAP WITH D_LIVE;
    INSERT INTO CTRL.ATOMICITY_RESULTS
      (case_id, rep_no, session_tag, captured_at, distinct_batches, lowest, highest, note)
    VALUES ('TC-09.2', :i, 'A-publisher', CURRENT_TIMESTAMP(), NULL, NULL, NULL, 'swap');
    CALL SYSTEM$WAIT(2);
  END FOR;
  RETURN 'TC-09.2 publisher finished 25 swaps';
END;

/* THE VERDICT — run after both blocks finish. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT 'TC-09.2 verdict' AS check_name,
       COUNT(*)                                            AS reader_readings,
       COUNT_IF(distinct_batches > 1)                      AS mixed_readings,
       COUNT_IF(distinct_batches = 1)                      AS clean_readings,
       COUNT(DISTINCT highest)                             AS distinct_batch_ids_seen
FROM CTRL.ATOMICITY_RESULTS
WHERE case_id = 'TC-09.2' AND session_tag = 'B-reader';
/* EXPECT  mixed_readings = 0 out of N.
   ANY non-zero value means a reader saw two batches at once and the
   design does not hold — this is the whole point of the POC.
   RECORD  reader_readings and the number of swaps, so the evidence says
   how many repetitions the zero is out of. distinct_batch_ids_seen
   should be 2 or more: if it is 1, the reader never actually spanned a
   swap and the test proved nothing.                                    */

SELECT 'TC-09.2 every reading' AS check_name, rep_no, session_tag,
       captured_at, distinct_batches, lowest, highest, note
FROM CTRL.ATOMICITY_RESULTS
WHERE case_id = 'TC-09.2'
ORDER BY captured_at, session_tag, rep_no;
/* KEEP this output. It is the evidence. */

/* =====================================================================
   TC-09.3   A NEW statement immediately after the swap returns
   ---------------------------------------------------------------------
   The different question: not a query spanning the swap, but one issued
   the instant it completes — and from ANOTHER session, which is what
   makes it a real test.

   FIXED 27 Oct — the reader side was left commented out, so nothing was
   executed and nothing captured. Both sides are now runnable and both
   record their reading.

   NOTE  this is the case that bears on READ_CONSISTENCY_MODE. Under the
   default 'SESSION', another session "might not see" a just-committed
   change straight away. A reading of the OLD batch here is therefore not
   necessarily a fault — but a reading of BOTH batches is.

   VERIFIED on this account, 27 Oct 2026:
       READ_CONSISTENCY_MODE = SESSION  (the default, set at no level)
   So the lag is in force. The SHOW below is kept so the run records the
   value in force AT THE TIME, not the value someone wrote down earlier.
   ===================================================================== */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SHOW PARAMETERS LIKE 'READ_CONSISTENCY_MODE' IN ACCOUNT;
SELECT 'TC-09.3 consistency mode in force' AS check_name,
       "key" AS parameter_name, "value" AS parameter_value, "default" AS parameter_default
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

DELETE FROM CTRL.ATOMICITY_RESULTS WHERE case_id = 'TC-09.3';

/* SESSION A: the swap, then its own immediate reading. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
ALTER SCHEMA D_STAGE SWAP WITH D_LIVE;

INSERT INTO CTRL.ATOMICITY_RESULTS
  (case_id, rep_no, session_tag, captured_at, distinct_batches, lowest, highest, note)
SELECT 'TC-09.3', 1, 'A-same-session', CURRENT_TIMESTAMP(),
       COUNT(DISTINCT batch_id), MIN(batch_id), MAX(batch_id),
       'read from the swapping session'
FROM ( SELECT batch_id FROM D_LIVE.CUSTOMER_360
       UNION ALL SELECT batch_id FROM D_LIVE.POLICY_SUMMARY );

/* SESSION B: run AT ONCE, in a second connection. This is the reading
   that matters — a different session, immediately after the commit.    */
/*
USE SECONDARY ROLES NONE;
USE ROLE P7_READER_OK; USE DATABASE P7_POC;
INSERT INTO CTRL.ATOMICITY_RESULTS
  (case_id, rep_no, session_tag, captured_at, distinct_batches, lowest, highest, note)
SELECT 'TC-09.3', 1, 'B-other-session', CURRENT_TIMESTAMP(),
       COUNT(DISTINCT batch_id), MIN(batch_id), MAX(batch_id),
       'new statement straight after the swap'
FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
       UNION ALL SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY );
*/

/* THE VERDICT */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
SELECT 'TC-09.3 verdict' AS check_name, session_tag, captured_at,
       distinct_batches, lowest, highest, note
FROM CTRL.ATOMICITY_RESULTS
WHERE case_id = 'TC-09.3'
ORDER BY session_tag;
/* EXPECT  distinct_batches = 1 in BOTH rows.
   A 2 in either row is a failure of the design.
   If B-other-session shows the OLD batch id while A-same-session shows
   the new one, that is the documented SESSION-mode lag, not a mixture —
   record it, because it decides whether 'GLOBAL' is needed.            */

