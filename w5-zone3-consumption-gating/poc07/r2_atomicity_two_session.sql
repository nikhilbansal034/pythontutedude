/* =====================================================================
   POC07 — R2  ·  Can a reader observe a MIXTURE of two batches?
   =====================================================================
   THE TEST THE WHOLE POC EXISTS FOR.

   R2: "A publication makes the entire new state of an object visible or
        none of it. No reader can observe a mixture of the previous and
        the new state of the same object."

   This cannot be answered from one session. A swap is instantaneous; to
   see whether anything is visible mid-swap you need somebody reading
   while somebody else swaps. So this file is in TWO PARTS, run in TWO
   Snowsight worksheets at the same time.

   It supersedes s09 TC-09.2 and TC-09.3, which could not answer it: the
   earlier run captured READER_READINGS = 0 — 25 swaps happened and not
   one read was taken while any of them was in flight.

   ---------------------------------------------------------------------
   HOW TO RUN  (about 2 minutes of running, plus setup)
   ---------------------------------------------------------------------
   1. Open TWO worksheets. Call them A and B.
   2. In A, run PART 1 (setup). Once only. It leaves D_LIVE holding
      batch RA and D_STAGE holding RB, so every swap flips what a
      reader sees between two known values.
   3. In B, paste PART 3 (the reader) and get it ready. DO NOT RUN YET.
   4. In A, paste PART 2 (the publisher) and get it ready.
   5. Start B first, then A within a couple of seconds. The reader runs
      longer than the publisher on purpose, so the swaps land inside the
      reading window.
   6. When both finish, run PART 4 (the verdict) in either worksheet.

   ---------------------------------------------------------------------
   READING THE RESULT — the verdict says one of four things
   ---------------------------------------------------------------------
   NO EVIDENCE    the reader block never ran. Nothing is proven.
   INCONCLUSIVE   the reader never saw the batch id change, so its window
                  did not overlap the swaps. The run is void — start the
                  two blocks closer together and try again. THIS IS THE
                  CHECK THE EARLIER ATTEMPT LACKED, and why it reported
                  a clean result from zero readings.
   R2 FAILS       at least one reading saw two batch ids at once. Record
                  the reading and stop — the design does not hold.
   R2 HOLDS       N readings across M swaps, none mixed. The number
                  matters: quote it, do not write "it works".
   ===================================================================== */

USE SECONDARY ROLES NONE;

/* =====================================================================
   PART 1 — SETUP.  Worksheet A, once.
   ===================================================================== */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC; USE WAREHOUSE COMPUTE_WH;

/* Readings live OUTSIDE the control tables every scenario truncates, so
   a later scenario run cannot destroy this evidence.                  */
CREATE TABLE IF NOT EXISTS CTRL.R2_READINGS (
    run_id           STRING,
    probe            STRING,        -- swap | one-object | both-objects
    seq              NUMBER,
    session_tag      STRING,
    captured_at      TIMESTAMP_LTZ,
    distinct_batches NUMBER,
    lowest           STRING,
    highest          STRING
);
/* The reader needs USAGE on the schema as well as rights on the table —
   setup grants it USAGE on the views schema only, by design.          */
GRANT USAGE ON SCHEMA CTRL TO ROLE P7_READER_OK;
GRANT INSERT, SELECT ON TABLE CTRL.R2_READINGS TO ROLE P7_READER_OK;

DELETE FROM CTRL.R2_READINGS WHERE run_id = 'R2';

/* Two batches with DIFFERENT ids, one in each storage, so a mixture is
   detectable at all. Load RA and publish it, then load RB and leave it
   in staging. From here every swap flips the visible batch RA <-> RB. */
USE ROLE P7_BASE_OWNER; USE DATABASE P7_POC;
DELETE FROM BASE.CUSTOMER;
INSERT INTO BASE.CUSTOMER
SELECT seq4()+1, 'Customer '||(seq4()+1), 'cust'||(seq4()+1)||'@example.invalid',
       LPAD(TO_VARCHAR(seq4()+1),3,'0')||'-00-0000', 'RA'
FROM TABLE(GENERATOR(ROWCOUNT=>20));
DELETE FROM BASE.POLICY;
INSERT INTO BASE.POLICY
SELECT seq4()+1, MOD(seq4(),20)+1, 1000+seq4(), 'RA'
FROM TABLE(GENERATOR(ROWCOUNT=>50));

USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
CREATE OR REPLACE TABLE D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_CUSTOMER_360;
CREATE OR REPLACE TABLE D_STAGE.POLICY_SUMMARY COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_POLICY_SUMMARY;
ALTER SCHEMA D_STAGE SWAP WITH D_LIVE;          -- D_LIVE now holds RA

USE ROLE P7_BASE_OWNER; USE DATABASE P7_POC;
DELETE FROM BASE.CUSTOMER;
INSERT INTO BASE.CUSTOMER
SELECT seq4()+1, 'Customer '||(seq4()+1), 'cust'||(seq4()+1)||'@example.invalid',
       LPAD(TO_VARCHAR(seq4()+1),3,'0')||'-00-0000', 'RB'
FROM TABLE(GENERATOR(ROWCOUNT=>20));
DELETE FROM BASE.POLICY;
INSERT INTO BASE.POLICY
SELECT seq4()+1, MOD(seq4(),20)+1, 1000+seq4(), 'RB'
FROM TABLE(GENERATOR(ROWCOUNT=>50));

USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC;
CREATE OR REPLACE TABLE D_STAGE.CUSTOMER_360 COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_CUSTOMER_360;
CREATE OR REPLACE TABLE D_STAGE.POLICY_SUMMARY COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC_VIEWS.V_POLICY_SUMMARY;
                                                 -- D_STAGE now holds RB

/* Confirm the two storages really differ. If these are the same value,
   STOP — every later reading would be meaningless.                    */
SELECT 'PART 1 check — the two storages must differ' AS check_name,
       (SELECT MAX(batch_id) FROM D_LIVE.CUSTOMER_360)  AS live_batch,
       (SELECT MAX(batch_id) FROM D_STAGE.CUSTOMER_360) AS stage_batch;
/* EXPECT  live_batch = RA,  stage_batch = RB.  Different. */

/* What consistency mode is this account on? It changes how a lag reads.
   SESSION (the default) means another session may briefly still see the
   old value after a swap — that is a lag, not a mixture. A MIXTURE is
   two different ids inside ONE reading, and is a failure under either
   mode.                                                               */
SHOW PARAMETERS LIKE 'READ_CONSISTENCY_MODE' IN ACCOUNT;
SELECT 'PART 1 consistency mode' AS check_name,
       "key" AS parameter_name, "value" AS value_in_force, "default" AS default_value
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* RECORD  this value in the evidence. */


/* =====================================================================
   PART 2 — THE PUBLISHER.  Worksheet A.  START THIS SECOND.
   ---------------------------------------------------------------------
   40 swaps, two seconds apart — about 80 seconds. The reader's 600
   readings take roughly as long, so the windows overlap for most of
   the run. Each swap is logged so the verdict can count how many
   landed inside the reading window.
   ===================================================================== */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC; USE WAREHOUSE COMPUTE_WH;

BEGIN
  FOR i IN 1 TO 40 DO
    ALTER SCHEMA D_STAGE SWAP WITH D_LIVE;
    INSERT INTO CTRL.R2_READINGS
      (run_id, probe, seq, session_tag, captured_at, distinct_batches, lowest, highest)
    VALUES ('R2', 'swap', :i, 'A-publisher', CURRENT_TIMESTAMP(), NULL, NULL, NULL);
    CALL SYSTEM$WAIT(2);
  END FOR;
  RETURN 'publisher: 40 swaps done';
END;


/* =====================================================================
   PART 3 — THE READER.  Worksheet B.  START THIS FIRST.
   ---------------------------------------------------------------------
   Runs as a real report user, through the thin views, exactly as Power
   BI would. Two probes per iteration:

     one-object    all rows of ONE published object in ONE statement.
                   Two ids here = the swap is not atomic for a single
                   table. This is R2 in its strictest form.

     both-objects  both published objects in ONE statement. Two ids here
                   = the group did not flip together. That is R3, and it
                   is the form a report with two visuals would hit.

   No wait between iterations: read as hard as possible to maximise the
   chance of landing mid-swap.
   ===================================================================== */
USE ROLE P7_READER_OK; USE DATABASE P7_POC; USE WAREHOUSE COMPUTE_WH;

BEGIN
  FOR i IN 1 TO 300 DO
    INSERT INTO CTRL.R2_READINGS
      (run_id, probe, seq, session_tag, captured_at, distinct_batches, lowest, highest)
    SELECT 'R2', 'one-object', :i, 'B-reader', CURRENT_TIMESTAMP(),
           COUNT(DISTINCT batch_id), MIN(batch_id), MAX(batch_id)
    FROM D_VIEWS.V_CUSTOMER_360;

    INSERT INTO CTRL.R2_READINGS
      (run_id, probe, seq, session_tag, captured_at, distinct_batches, lowest, highest)
    SELECT 'R2', 'both-objects', :i, 'B-reader', CURRENT_TIMESTAMP(),
           COUNT(DISTINCT batch_id), MIN(batch_id), MAX(batch_id)
    FROM ( SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
           UNION ALL
           SELECT batch_id FROM D_VIEWS.V_POLICY_SUMMARY );
  END FOR;
  RETURN 'reader: 300 reading pairs done';
END;


/* =====================================================================
   PART 4 — THE VERDICT.  Either worksheet, after both blocks finish.
   ===================================================================== */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC; USE WAREHOUSE COMPUTE_WH;

/* 4a. Is the run even valid? Read this BEFORE the verdict below.      */
WITH r AS (SELECT * FROM CTRL.R2_READINGS WHERE run_id='R2' AND probe <> 'swap'),
     s AS (SELECT * FROM CTRL.R2_READINGS WHERE run_id='R2' AND probe  = 'swap')
SELECT 'R2 4a — is the run valid?' AS check_name,
       (SELECT COUNT(*) FROM r)                            AS readings,
       (SELECT COUNT(*) FROM s)                            AS swaps,
       (SELECT COUNT(DISTINCT lowest) FROM r)              AS batch_values_seen,
       (SELECT COUNT(*) FROM s
         WHERE s.captured_at BETWEEN (SELECT MIN(captured_at) FROM r)
                                 AND (SELECT MAX(captured_at) FROM r)) AS swaps_inside_window,
       CASE
         WHEN (SELECT COUNT(*) FROM r) = 0 THEN 'NO EVIDENCE — the reader block did not run'
         WHEN (SELECT COUNT(DISTINCT lowest) FROM r) < 2
              THEN 'INCONCLUSIVE — the reader never saw the batch change, so its window did not overlap the swaps. VOID: re-run, starting the blocks closer together'
         ELSE 'VALID — the reader observed the batch id change, so it was reading across swaps'
       END AS run_validity;
/* EXPECT  readings = 600, swaps = 40, batch_values_seen = 2,
   swaps_inside_window close to 40, run_validity = VALID.
   ANY other validity value and the verdict below means nothing.       */

/* 4b. The verdict itself.                                             */
SELECT 'R2 4b — verdict' AS check_name,
       probe,
       COUNT(*)                          AS readings,
       COUNT_IF(distinct_batches > 1)    AS mixed_readings,
       COUNT_IF(distinct_batches = 1)    AS clean_readings,
       CASE WHEN COUNT_IF(distinct_batches > 1) = 0 THEN 'no mixture in these readings'
            WHEN probe = 'one-object'
                 THEN 'R2 FAILS — one object showed two batches in a single read'
            ELSE 'R3 FAILS — the group did not flip together; one object was on the old batch and one on the new'
       END AS verdict
FROM CTRL.R2_READINGS
WHERE run_id = 'R2' AND probe <> 'swap'
GROUP BY probe ORDER BY probe;
/* EXPECT  mixed_readings = 0 for BOTH probes.
   THE TWO PROBES TEST DIFFERENT REQUIREMENTS. Do not report them as one:
     one-object   > 0  =>  R2 fails. The swap is not atomic for a single
                           table. This would sink the design outright.
     both-objects > 0  =>  R3 fails. Each table flipped atomically, but
                           not together — a reader saw one object on the
                           old batch and the other on the new. The design
                           survives; the group guarantee does not hold as
                           built, and PART 5 tests the likeliest cause.
   Quote readings and swaps alongside the counts: "1 mixed in 300 readings
   across 40 swaps" is evidence; "it works" or "it fails" is not.       */

/* 4c. Every mixed reading, if there are any. Empty is the good case.  */
SELECT 'R2 4c — the mixed readings' AS check_name,
       probe, seq, captured_at, distinct_batches, lowest, highest
FROM CTRL.R2_READINGS
WHERE run_id = 'R2' AND probe <> 'swap' AND distinct_batches > 1
ORDER BY captured_at;
/* EXPECT  zero rows. Any row here is the finding — screenshot it. */

/* 4d. Proof the reader really was spanning swaps: the batch id it saw,
       over time. This should alternate RA / RB.                       */
SELECT 'R2 4d — what the reader saw, over time' AS check_name,
       seq, captured_at, lowest AS batch_seen
FROM CTRL.R2_READINGS
WHERE run_id = 'R2' AND probe = 'both-objects'
ORDER BY seq LIMIT 60;
/* RECORD  the alternation. If batch_seen never changes, the windows did
   not overlap and 4a will already have said VOID.                     */


/* =====================================================================
   PART 5 — FOLLOW-UP.  Only if the both-objects probe found a mixture.
   ---------------------------------------------------------------------
   A mixture on both-objects, with none on one-object, says each table
   flipped atomically but the two did not flip together FOR A READER IN
   ANOTHER SESSION. The leading explanation is the account's read
   consistency mode.

   Snowflake documents READ_CONSISTENCY_MODE as: SESSION (the default)
   gives consistency within a session, but a concurrent session may not
   see another session's changes straight away; GLOBAL makes changes
   immediately visible across concurrent sessions, at a cost of
   milliseconds. Our swap runs in session A and our read in session B,
   which is exactly that case.

   The docs do NOT state how this interacts with ALTER SCHEMA ... SWAP,
   so this is a hypothesis, and PART 5 is the test that settles it.

   ---------------------------------------------------------------------
   BEFORE YOU RUN THIS — it is an ACCOUNT-LEVEL change
   ---------------------------------------------------------------------
   READ_CONSISTENCY_MODE can only be set on the whole account, and only
   by ACCOUNTADMIN. It will affect every other workload on
   P7_POC and every other POC on this account for as long as it is
   set. Agree it first, keep the window short, and run 5c to put it back.
   ===================================================================== */

/* 5a. Keep the SESSION-mode evidence, then switch the account to GLOBAL. */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC; USE WAREHOUSE COMPUTE_WH;
UPDATE CTRL.R2_READINGS SET run_id = 'R2-SESSION' WHERE run_id = 'R2';

USE ROLE ACCOUNTADMIN;
ALTER ACCOUNT SET READ_CONSISTENCY_MODE = GLOBAL;
SHOW PARAMETERS LIKE 'READ_CONSISTENCY_MODE' IN ACCOUNT;
SELECT 'R2 5a — mode now in force' AS check_name, "key" AS parameter_name, "value" AS value_in_force
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* EXPECT  GLOBAL */

/* 5b. Re-run PART 2 and PART 3 exactly as before, in the same two
       worksheets, same order. They write run_id 'R2' again, so the
       SESSION run is preserved under 'R2-SESSION'. Then run this: */
USE ROLE P7_PUBLISH_ROLE; USE DATABASE P7_POC; USE WAREHOUSE COMPUTE_WH;
SELECT 'R2 5b — SESSION vs GLOBAL' AS check_name,
       CASE run_id WHEN 'R2-SESSION' THEN 'SESSION mode' ELSE 'GLOBAL mode' END AS mode,
       probe,
       COUNT(*)                       AS readings,
       COUNT_IF(distinct_batches > 1) AS mixed_readings
FROM CTRL.R2_READINGS
WHERE run_id IN ('R2','R2-SESSION') AND probe <> 'swap'
GROUP BY run_id, probe ORDER BY mode DESC, probe;
/* EXPECT, if the hypothesis holds:
     SESSION mode · both-objects  -> mixed_readings > 0
     GLOBAL  mode · both-objects  -> mixed_readings = 0
   If GLOBAL is also non-zero, the cause is NOT the consistency mode and
   the finding is a property of the swap itself. Either way, RECORD IT —
   this is the result that decides whether the group guarantee is
   reachable with a configuration change or needs a design change.     */

/* 5c. PUT THE ACCOUNT BACK. Do not skip this. */
USE ROLE ACCOUNTADMIN;
ALTER ACCOUNT SET READ_CONSISTENCY_MODE = SESSION;
SHOW PARAMETERS LIKE 'READ_CONSISTENCY_MODE' IN ACCOUNT;
SELECT 'R2 5c — mode restored' AS check_name, "key" AS parameter_name, "value" AS value_in_force
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* EXPECT  SESSION */
