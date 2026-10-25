/* =====================================================================
   02 — ATOMICITY & PUBLICATION   (TC-020 … TC-026, TC-032)
   Scenarios SC-01, SC-02, SC-03, SC-13, SC-16
   ---------------------------------------------------------------------
   Question: does each publication mechanism ever let a reader see a
   MIXED state across a consistency group?

   METHOD. cycle_marker is the proof. Cycle 1 is already published by
   00_setup. We load cycle 2 into staging, publish, and check that no
   reader ever sees cycle 1 in one table and cycle 2 in another.

   TC-020 is the most important test in the whole pack: it is the only
   evidence that option O11 actually delivers Part A.

   TWO SESSIONS ARE REQUIRED for TC-020, TC-023, TC-025 and TC-026.
   Session A = this script (the writer). Session B = a reader.
   Blocks marked [SESSION B] must be run in a separate worksheet,
   concurrently, as instructed.
   ===================================================================== */

USE ROLE POC_ROLE; USE DATABASE POC_GATING_DB; USE WAREHOUSE POC_WH;

/* ---------------------------------------------------------------------
   Helper the reader uses to detect a mixed state in one query.
   distinct_cycles = 1  -> consistent
   distinct_cycles > 1  -> MIXED STATE  (the defect)
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW CONSUME.V_GROUP_CONSISTENCY AS
SELECT COUNT(DISTINCT c) AS distinct_cycles, MIN(c) AS min_cycle, MAX(c) AS max_cycle
FROM (
    SELECT cycle_marker AS c FROM PUB.FACT_PREMIUM
    UNION ALL SELECT cycle_marker FROM PUB.DIM_POLICY
    UNION ALL SELECT cycle_marker FROM PUB.DIM_BROKER
    UNION ALL SELECT cycle_marker FROM PUB.DIM_DATE
);
GRANT SELECT ON VIEW CONSUME.V_GROUP_CONSISTENCY TO ROLE POC_READER_ROLE;

/* Stage cycle 2 for the whole group. This is the slow build, done
   OUTSIDE any transaction — hours in real life. */
INSERT OVERWRITE INTO STG.FACT_PREMIUM SELECT premium_id, policy_id, broker_id, amt, 2 FROM SRC.FACT_PREMIUM;
INSERT OVERWRITE INTO STG.DIM_POLICY   SELECT policy_id, policy_no, 2             FROM SRC.DIM_POLICY;
INSERT OVERWRITE INTO STG.DIM_BROKER   SELECT broker_id, broker_cd, 2             FROM SRC.DIM_BROKER;
INSERT OVERWRITE INTO STG.DIM_DATE     SELECT date_key, cal_date, 2               FROM SRC.DIM_DATE;

SELECT 'pre-publish: PUB should be all cycle 1' AS note, * FROM CONSUME.V_GROUP_CONSISTENCY;


/* =====================================================================
   TC-025  Single-table INSERT OVERWRITE — never empty, never partial
   Scenario SC-01. Option O10 as its own publication mechanism.
   Expected: the reader's rowcount is either the old count or the new
             count, NEVER 0 and never anything between.
   ===================================================================== */
-- [SESSION B] start this loop FIRST, leave it running, then run the
-- INSERT OVERWRITE below in session A:
--
--   USE ROLE POC_READER_ROLE; USE DATABASE POC_GATING_DB; USE WAREHOUSE POC_WH;
--   -- run this repeatedly (or in a loop from your client) for ~30s:
--   SELECT CURRENT_TIMESTAMP() AS t, COUNT(*) AS rows_, MAX(cycle_marker) AS cyc
--   FROM PUB.FACT_PREMIUM;
--   -- EXPECTED: rows_ is always 5000, cyc flips 1 -> 2 in one step.
--   --           rows_ must NEVER be 0 and never a partial count.

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-025|IO_SINGLE_TABLE';
INSERT OVERWRITE INTO PUB.FACT_PREMIUM SELECT * FROM STG.FACT_PREMIUM;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-025 after' AS tc, COUNT(*) AS rows_, MAX(cycle_marker) AS cyc FROM PUB.FACT_PREMIUM;

/* reset to cycle 1 for the next tests */
INSERT OVERWRITE INTO PUB.FACT_PREMIUM SELECT premium_id, policy_id, broker_id, amt, 1 FROM SRC.FACT_PREMIUM;


/* =====================================================================
   TC-026  COUNTER-EXAMPLE: TRUNCATE + INSERT is NOT atomic
   Documented: "No (table is empty between the two statements)".
   Expected: the reader DOES observe rows_ = 0.
             This is the evidence that INSERT OVERWRITE is required and
             that a TRUNCATE-then-load pattern would not satisfy Part A.
   ===================================================================== */
-- [SESSION B] same polling loop as TC-025, then run:

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-026|TRUNCATE_INSERT';
TRUNCATE TABLE PUB.FACT_PREMIUM;
-- pause here deliberately; the reader should now see 0 rows
SELECT 'TC-026 mid-state (reader sees this)' AS tc, COUNT(*) AS rows_ FROM PUB.FACT_PREMIUM;
INSERT INTO PUB.FACT_PREMIUM SELECT premium_id, policy_id, broker_id, amt, 1 FROM SRC.FACT_PREMIUM;
ALTER SESSION UNSET QUERY_TAG;


/* =====================================================================
   TC-020  *** CRITICAL *** O11 — group publish inside ONE transaction
   Scenario SC-02 / SC-03. The core claim of the recommended design.
   Expected: the reader NEVER observes distinct_cycles = 2.
             Before COMMIT -> all cycle 1. After COMMIT -> all cycle 2.
   ===================================================================== */
SELECT 'TC-020 before' AS tc, * FROM CONSUME.V_GROUP_CONSISTENCY;  -- expect 1 / 1 / 1

-- [SESSION B] start this polling loop FIRST and keep it running:
--
--   USE ROLE POC_READER_ROLE; USE DATABASE POC_GATING_DB; USE WAREHOUSE POC_WH;
--   SELECT CURRENT_TIMESTAMP() AS t, * FROM CONSUME.V_GROUP_CONSISTENCY;
--   -- EXPECTED on every single execution: distinct_cycles = 1.
--   -- If you ever see distinct_cycles = 2, O11 does NOT deliver Part A.
--   --
--   -- Poll for the WHOLE 30s and capture at least one grid showing
--   -- min_cycle = max_cycle = 1 while session A is mid-transaction.
--   -- Evidence that catches no poll inside the window proves nothing;
--   -- the timestamps must straddle session A's BEGIN and COMMIT.
--
-- Then, in session A, run the transaction below.
--
-- THE WAITS ARE DELIBERATE — DO NOT REMOVE THEM.
-- Without them the four statements finish in milliseconds, the reader
-- never polls inside the open transaction, and this test reports a PASS
-- having never exercised the window it exists to exercise. The waits
-- hold the transaction open ~30s so the reader genuinely reads
-- mid-publish. A green TC-020 with the waits removed is meaningless.

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-020|O11_TRANSACTION';
BEGIN;
  INSERT OVERWRITE INTO PUB.FACT_PREMIUM SELECT * FROM STG.FACT_PREMIUM;
  CALL SYSTEM$WAIT(10);
  INSERT OVERWRITE INTO PUB.DIM_POLICY   SELECT * FROM STG.DIM_POLICY;
  CALL SYSTEM$WAIT(10);
  INSERT OVERWRITE INTO PUB.DIM_BROKER   SELECT * FROM STG.DIM_BROKER;
  CALL SYSTEM$WAIT(10);
  INSERT OVERWRITE INTO PUB.DIM_DATE     SELECT * FROM STG.DIM_DATE;

  /* Inside the transaction, the WRITER sees its own uncommitted changes.
     Documented: "a statement can see earlier statements' changes even
     before they are committed." The reader must not. */
  SELECT 'TC-020 writer view inside txn (expect cycle 2)' AS tc, * FROM CONSUME.V_GROUP_CONSISTENCY;
COMMIT;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-020 after commit (expect 1 / 2 / 2)' AS tc, * FROM CONSUME.V_GROUP_CONSISTENCY;


/* =====================================================================
   TC-024  O11 ROLLBACK — a failed cycle publishes NOTHING
   Scenario SC-10. Part A's "a failed cycle publishes nothing".
   Expected: after ROLLBACK, PUB is entirely back on cycle 2
             (unchanged by the abandoned cycle 3).
   ===================================================================== */
INSERT OVERWRITE INTO STG.FACT_PREMIUM SELECT premium_id, policy_id, broker_id, amt, 3 FROM SRC.FACT_PREMIUM;
INSERT OVERWRITE INTO STG.DIM_POLICY   SELECT policy_id, policy_no, 3 FROM SRC.DIM_POLICY;

SELECT 'TC-024 before' AS tc, * FROM CONSUME.V_GROUP_CONSISTENCY;  -- expect cycle 2

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-024|O11_ROLLBACK';
BEGIN;
  INSERT OVERWRITE INTO PUB.FACT_PREMIUM SELECT * FROM STG.FACT_PREMIUM;  -- cycle 3
  INSERT OVERWRITE INTO PUB.DIM_POLICY   SELECT * FROM STG.DIM_POLICY;    -- cycle 3
  /* simulate the gate failing */
ROLLBACK;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-024 after rollback (expect still cycle 2)' AS tc, * FROM CONSUME.V_GROUP_CONSISTENCY;


/* =====================================================================
   TC-032  DDL inside an O11 transaction silently commits
   Documented: "DDL statements implicitly commit active transactions".
   Expected: the DDL commits the first INSERT OVERWRITE, so the ROLLBACK
             does NOT undo it -> a MIXED state is left published.
             This is the failure mode the build standard must prevent.
   ===================================================================== */
INSERT OVERWRITE INTO STG.FACT_PREMIUM SELECT premium_id, policy_id, broker_id, amt, 4 FROM SRC.FACT_PREMIUM;
INSERT OVERWRITE INTO STG.DIM_POLICY   SELECT policy_id, policy_no, 4 FROM SRC.DIM_POLICY;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-032|DDL_IN_TXN';
BEGIN;
  INSERT OVERWRITE INTO PUB.FACT_PREMIUM SELECT * FROM STG.FACT_PREMIUM;  -- cycle 4
  CREATE OR REPLACE TABLE PUB.T032_SCRATCH (x NUMBER);   -- <-- DDL. commits!
  INSERT OVERWRITE INTO PUB.DIM_POLICY   SELECT * FROM STG.DIM_POLICY;    -- cycle 4
ROLLBACK;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-032 after rollback (expect MIXED: distinct_cycles = 2)' AS tc,
       * FROM CONSUME.V_GROUP_CONSISTENCY;
/* Record which tables are on which cycle — this is the evidence that
   "no DDL inside the publish transaction" must be a hard build rule. */
SELECT 'FACT_PREMIUM' AS t, MAX(cycle_marker) AS cyc FROM PUB.FACT_PREMIUM
UNION ALL SELECT 'DIM_POLICY', MAX(cycle_marker) FROM PUB.DIM_POLICY
UNION ALL SELECT 'DIM_BROKER', MAX(cycle_marker) FROM PUB.DIM_BROKER
UNION ALL SELECT 'DIM_DATE',   MAX(cycle_marker) FROM PUB.DIM_DATE;

/* re-level everything to cycle 2 before the swap tests */
BEGIN;
  INSERT OVERWRITE INTO PUB.FACT_PREMIUM SELECT premium_id, policy_id, broker_id, amt, 2 FROM SRC.FACT_PREMIUM;
  INSERT OVERWRITE INTO PUB.DIM_POLICY   SELECT policy_id, policy_no, 2 FROM SRC.DIM_POLICY;
  INSERT OVERWRITE INTO PUB.DIM_BROKER   SELECT broker_id, broker_cd, 2 FROM SRC.DIM_BROKER;
  INSERT OVERWRITE INTO PUB.DIM_DATE     SELECT date_key, cal_date, 2 FROM SRC.DIM_DATE;
COMMIT;


/* =====================================================================
   TC-021  Table-level SWAP — do GRANTS follow the object?
   NOT DOCUMENTED. The ALTER TABLE page says only that swap "renames two
   tables in a single transaction"; it is silent on grants. Schema swap
   documents that grants swap; table swap does not.
   Expected (assumption): grants follow the OBJECT, so after the swap the
             table now named PUB.T021_A carries T021_B's grants.
   ===================================================================== */
CREATE OR REPLACE TABLE PUB.T021_A (id NUMBER, label STRING);
CREATE OR REPLACE TABLE PUB.T021_B (id NUMBER, label STRING);
INSERT INTO PUB.T021_A SELECT 1,'A-side';
INSERT INTO PUB.T021_B SELECT 2,'B-side';
GRANT SELECT ON TABLE PUB.T021_A TO ROLE POC_READER_ROLE;   -- only A is granted

SHOW GRANTS ON TABLE PUB.T021_A;
SELECT 'TC-021 A before' AS tc, "privilege", "grantee_name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
SHOW GRANTS ON TABLE PUB.T021_B;
SELECT 'TC-021 B before (expect no reader)' AS tc, "privilege", "grantee_name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-021|TABLE_SWAP_GRANTS';
ALTER TABLE PUB.T021_A SWAP WITH PUB.T021_B;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-021 A after (expect label = B-side)' AS tc, * FROM PUB.T021_A;
SHOW GRANTS ON TABLE PUB.T021_A;
SELECT 'TC-021 A grants after' AS tc, "privilege", "grantee_name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
SHOW GRANTS ON TABLE PUB.T021_B;
SELECT 'TC-021 B grants after' AS tc, "privilege", "grantee_name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* Record which NAME the reader's SELECT ends up on. That answers
   whether grants track the object or the name. */


/* =====================================================================
   TC-022  Schema SWAP — grants, schema USAGE, and whether the PREVIOUS
           version is still reachable under the staging name
   Scenario SC-16. The open consequence in solution_design.md §5.5,
   which bears on constraint C4 (no consumer access to earlier versions).
   Expected: documented — all privileges on the schemas and the objects
             they contain are swapped. UNDOCUMENTED and the real question
             — can the reader still query STG.* after the swap?
   ===================================================================== */
/* stage cycle 5 */
INSERT OVERWRITE INTO STG.FACT_PREMIUM SELECT premium_id, policy_id, broker_id, amt, 5 FROM SRC.FACT_PREMIUM;
INSERT OVERWRITE INTO STG.DIM_POLICY   SELECT policy_id, policy_no, 5 FROM SRC.DIM_POLICY;
INSERT OVERWRITE INTO STG.DIM_BROKER   SELECT broker_id, broker_cd, 5 FROM SRC.DIM_BROKER;
INSERT OVERWRITE INTO STG.DIM_DATE     SELECT date_key, cal_date, 5 FROM SRC.DIM_DATE;

SHOW GRANTS ON SCHEMA PUB;
SELECT 'TC-022 PUB schema grants before' AS tc, "privilege", "grantee_name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
SHOW GRANTS ON SCHEMA STG;
SELECT 'TC-022 STG schema grants before' AS tc, "privilege", "grantee_name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-022|SCHEMA_SWAP';
ALTER SCHEMA PUB SWAP WITH STG;
ALTER SESSION UNSET QUERY_TAG;

SHOW GRANTS ON SCHEMA PUB;
SELECT 'TC-022 PUB schema grants after' AS tc, "privilege", "grantee_name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
SHOW GRANTS ON SCHEMA STG;
SELECT 'TC-022 STG schema grants after' AS tc, "privilege", "grantee_name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT 'TC-022 PUB after (expect cycle 5)' AS tc, MAX(cycle_marker) FROM PUB.FACT_PREMIUM;
SELECT 'TC-022 STG after (expect cycle 2 = the old published version)' AS tc, MAX(cycle_marker) FROM STG.FACT_PREMIUM;

-- [SESSION B] THE DECISIVE CHECK. As the reporting role:
--   SELECT MAX(cycle_marker) FROM PUB.FACT_PREMIUM;   -- expect 5 (new)
--   SELECT MAX(cycle_marker) FROM STG.FACT_PREMIUM;   -- CAN THEY? expect 2
--   -- If the second SUCCEEDS, the previous version is reachable by name
--   -- and C4 needs an explicit decision. Capture the result either way.


/* =====================================================================
   TC-023  Schema SWAP — held-open read spanning the swap
   Mirrors POC02's held-open join, extended to a 4-object group.
   Expected: a single query that begins before the swap returns one
             whole consistent cycle, never a mixture.
   ===================================================================== */
/* stage cycle 6 */
INSERT OVERWRITE INTO STG.FACT_PREMIUM SELECT premium_id, policy_id, broker_id, amt, 6 FROM SRC.FACT_PREMIUM;
INSERT OVERWRITE INTO STG.DIM_POLICY   SELECT policy_id, policy_no, 6 FROM SRC.DIM_POLICY;
INSERT OVERWRITE INTO STG.DIM_BROKER   SELECT broker_id, broker_cd, 6 FROM SRC.DIM_BROKER;
INSERT OVERWRITE INTO STG.DIM_DATE     SELECT date_key, cal_date, 6 FROM SRC.DIM_DATE;

-- [SESSION B] start this long-running read FIRST (it holds for ~60s),
-- then run the swap in session A while it is still executing:
--
--   USE ROLE POC_READER_ROLE; USE DATABASE POC_GATING_DB; USE WAREHOUSE POC_WH;
--   SELECT COUNT(DISTINCT c) AS distinct_cycles, MIN(c), MAX(c)
--   FROM (
--       SELECT cycle_marker AS c FROM PUB.FACT_PREMIUM
--       UNION ALL SELECT cycle_marker FROM PUB.DIM_POLICY
--       UNION ALL SELECT cycle_marker FROM PUB.DIM_BROKER
--       UNION ALL SELECT cycle_marker FROM PUB.DIM_DATE
--   ) WHERE SYSTEM$WAIT(60) IS NOT NULL;
--   -- EXPECTED: distinct_cycles = 1

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-023|SWAP_HELD_OPEN_READ';
ALTER SCHEMA PUB SWAP WITH STG;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-023 after swap' AS tc, * FROM CONSUME.V_GROUP_CONSISTENCY;


/* =====================================================================
   SUMMARY
   ===================================================================== */
SELECT SPLIT_PART(query_tag,'|',2) AS tc,
       SPLIT_PART(query_tag,'|',3) AS mechanism,
       total_elapsed_time/1000     AS seconds,
       rows_produced, bytes_written, transaction_blocked_time
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
        END_TIME_RANGE_START => DATEADD('hour',-2,CURRENT_TIMESTAMP()),
        RESULT_LIMIT => 1000))
WHERE query_tag LIKE 'GATING_POC|TC-02%' OR query_tag LIKE 'GATING_POC|TC-032%'
ORDER BY tc;
