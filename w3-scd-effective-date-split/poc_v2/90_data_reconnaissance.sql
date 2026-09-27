-- ===========================================================================
-- DATA RECONNAISSANCE -- run this against the REAL Zone1 / Zone2 tables
-- before integrating the POC logic with them.
--
-- Purpose: several of the questions left open by the test lead review
-- (../solution_design.md section 18) are answerable from real data rather than
-- by asking anyone. This file turns each of those questions into a query.
--
-- READ ONLY. Nothing here writes, creates or drops anything.
--
-- Replace the four names below with the real objects, then run top to bottom.
-- Each block prints a row count; 0 rows means "clean on that check".
--
--   SRC_1  -> the first Zone1 history table   (party / status history)
--   SRC_2  -> the second Zone1 history table  (commission / tier history)
--   TGT    -> the existing Zone2 SCD2 target
--   STG    -> the existing Zone2 stage table
--
-- IMPORTANT: run checks 1 and 2 over the FULL history, not a recent window.
-- The events that produce overlaps -- reloads, replays, late corrections --
-- are rare, so a narrow window can come back clean and mean nothing.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. OVERLAPPING PERIODS FOR ONE KEY   [answers section 18 A1 -- the blocking one]
--
-- The design assumes each key's history is a clean chain: one period ends where
-- the next begins, never two periods covering the same day. That assumption is
-- load-bearing and is currently stated nowhere.
--
-- ANY row returned here means the assumption is already violated in production
-- data, and the overlap guard is required rather than optional.
-- ---------------------------------------------------------------------------
SELECT 'SRC_1' AS SOURCE_TABLE, a.BROKER_ID,
       a.ROW_EFF_DTE AS A_EFF, a.ROW_EXP_DTE AS A_EXP,
       b.ROW_EFF_DTE AS B_EFF, b.ROW_EXP_DTE AS B_EXP
FROM   Z1_BROKER_PARTY_HIST a
JOIN   Z1_BROKER_PARTY_HIST b
  ON   a.BROKER_ID   = b.BROKER_ID
 AND   a.ROW_EFF_DTE < b.ROW_EFF_DTE      -- ordered pair, so each overlap appears once
 AND   b.ROW_EFF_DTE < a.ROW_EXP_DTE      -- b starts before a has ended  => overlap
UNION ALL
SELECT 'SRC_2', a.BROKER_ID,
       a.ROW_EFF_DTE, a.ROW_EXP_DTE, b.ROW_EFF_DTE, b.ROW_EXP_DTE
FROM   Z1_BROKER_COMMISSION_HIST a
JOIN   Z1_BROKER_COMMISSION_HIST b
  ON   a.BROKER_ID   = b.BROKER_ID
 AND   a.ROW_EFF_DTE < b.ROW_EFF_DTE
 AND   b.ROW_EFF_DTE < a.ROW_EXP_DTE
ORDER BY 1, 2, 3;


-- ---------------------------------------------------------------------------
-- 2. GAPS IN COVER, AND ZERO- OR NEGATIVE-WIDTH PERIODS
--
-- Not defects -- the design handles gaps deliberately -- but their frequency
-- tells you how much S05's gap handling actually matters in production, and a
-- negative-width row (exp before eff) is always bad data.
-- ---------------------------------------------------------------------------
SELECT 'SRC_1' AS SOURCE_TABLE,
       COUNT(CASE WHEN ROW_EXP_DTE <  ROW_EFF_DTE THEN 1 END) AS NEGATIVE_WIDTH,
       COUNT(CASE WHEN ROW_EXP_DTE =  ROW_EFF_DTE THEN 1 END) AS ZERO_WIDTH,
       COUNT(*)                                               AS TOTAL_ROWS
FROM   Z1_BROKER_PARTY_HIST
UNION ALL
SELECT 'SRC_2',
       COUNT(CASE WHEN ROW_EXP_DTE <  ROW_EFF_DTE THEN 1 END),
       COUNT(CASE WHEN ROW_EXP_DTE =  ROW_EFF_DTE THEN 1 END),
       COUNT(*)
FROM   Z1_BROKER_COMMISSION_HIST;


-- ---------------------------------------------------------------------------
-- 3. DUPLICATE (KEY, EFFECTIVE DATE)   [answers section 18 B2]
--
-- The de-duplication rule keeps the copy with the latest GRS_REFINED_TIMESTAMP.
-- Two things worth knowing from real data:
--   DISTINCT_TS  -- duplicates the tie-break can actually resolve. If this is
--                   0 in production, the "latest wins" rule has never fired.
--   IDENTICAL_TS -- duplicates it CANNOT resolve. If this is non-zero, the
--                   choice between them is arbitrary today, and that needs a
--                   documented rule rather than whatever the optimiser does.
-- ---------------------------------------------------------------------------
SELECT 'SRC_1' AS SOURCE_TABLE,
       COUNT(*)                                        AS DUPLICATE_GROUPS,
       COUNT(CASE WHEN TS_VARIANTS > 1 THEN 1 END)     AS DISTINCT_TS,
       COUNT(CASE WHEN TS_VARIANTS = 1 THEN 1 END)     AS IDENTICAL_TS
FROM ( SELECT BROKER_ID, ROW_EFF_DTE,
              COUNT(*) AS COPIES, COUNT(DISTINCT GRS_REFINED_TIMESTAMP) AS TS_VARIANTS
       FROM   Z1_BROKER_PARTY_HIST
       GROUP  BY BROKER_ID, ROW_EFF_DTE
       HAVING COUNT(*) > 1 ) d
UNION ALL
SELECT 'SRC_2',
       COUNT(*),
       COUNT(CASE WHEN TS_VARIANTS > 1 THEN 1 END),
       COUNT(CASE WHEN TS_VARIANTS = 1 THEN 1 END)
FROM ( SELECT BROKER_ID, ROW_EFF_DTE,
              COUNT(*) AS COPIES, COUNT(DISTINCT GRS_REFINED_TIMESTAMP) AS TS_VARIANTS
       FROM   Z1_BROKER_COMMISSION_HIST
       GROUP  BY BROKER_ID, ROW_EFF_DTE
       HAVING COUNT(*) > 1 ) d;


-- ---------------------------------------------------------------------------
-- 4. NULL BUSINESS KEYS
--
-- The design drops these silently. Confirm that is acceptable at real volumes,
-- and that nobody downstream is relying on them arriving.
-- ---------------------------------------------------------------------------
SELECT 'SRC_1' AS SOURCE_TABLE, COUNT(*) AS NULL_KEY_ROWS
FROM   Z1_BROKER_PARTY_HIST      WHERE BROKER_ID IS NULL
UNION ALL
SELECT 'SRC_2', COUNT(*)
FROM   Z1_BROKER_COMMISSION_HIST WHERE BROKER_ID IS NULL;


-- ---------------------------------------------------------------------------
-- 5. WHAT UUID ACTUALLY IS   [answers section 18 A2]
--
-- Rules 2 and 4 exist only to restamp this column, and it cannot be asserted in
-- test until its meaning is settled. The existing target answers it:
--
--   UUID unique on nearly every row        -> generated per row. Restamping is
--                                             correct; add the assertion.
--   UUID repeats across a key's versions   -> carried from somewhere and meant
--                                             to be stable. Restamping it on a
--                                             rerun would then be WRONG, and
--                                             rules 2 and 4 need revisiting.
-- ---------------------------------------------------------------------------
SELECT COUNT(*)             AS TARGET_ROWS,
       COUNT(DISTINCT UUID) AS DISTINCT_UUIDS,
       COUNT(*) - COUNT(UUID) AS NULL_UUIDS
FROM   Z2_BROKER_PARTY_DIM;

-- and the rows that share a UUID, if any:
SELECT UUID, COUNT(*) AS ROWS_SHARING_IT
FROM   Z2_BROKER_PARTY_DIM
GROUP  BY UUID
HAVING COUNT(*) > 1
ORDER  BY 2 DESC
LIMIT  20;


-- ---------------------------------------------------------------------------
-- 6. DOES THE REAL STAGE TABLE ALREADY CARRY AN OPERATION / CDC COLUMN?
--
-- If it does, ACTION_FLAG takes that column's name and the apply needs NO
-- schema change at all. If it does not, ACTION_FLAG is the one genuine ALTER.
-- This is the cheapest open question in the pack to close.
-- ---------------------------------------------------------------------------
SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COMMENT
FROM   INFORMATION_SCHEMA.COLUMNS
WHERE  TABLE_NAME = 'STG_Z2_BROKER_PARTY_DIM'      -- the REAL stage table name
ORDER  BY ORDINAL_POSITION;
