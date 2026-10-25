/* =====================================================================
   03 — VIEWS, SHAPE CHANGES & DEPENDENCIES   (TC-027 … TC-031, TC-033)
   Scenarios SC-04, SC-05, SC-09, SC-17, SC-18, SC-21
   ---------------------------------------------------------------------
   Question: does the view estate survive untouched (constraint C1), and
   what breaks around the edges — clustering, streams, Iceberg, and a
   view that self-references its own schema.
   ===================================================================== */

USE ROLE POC_ROLE; USE DATABASE POC_GATING_DB; USE WAREHOUSE POC_WH;

/* =====================================================================
   TC-027  V-a — a view over gated tables inherits consistency, with
           ZERO changes to the view
   Scenario SC-04. This is the cheap case the design depends on.
   Expected: f_cycle = p_cycle = b_cycle on every row, before and after
             publication. The view's DDL is never touched.
   ===================================================================== */
SELECT 'TC-027 view DDL before' AS tc, GET_DDL('VIEW','CONSUME.V_PREMIUM_REPORT') AS ddl;

SELECT 'TC-027 before publish' AS tc,
       COUNT(*) AS rows_,
       COUNT(DISTINCT f_cycle) AS f_cycles,
       COUNT(DISTINCT p_cycle) AS p_cycles,
       COUNT(DISTINCT b_cycle) AS b_cycles,
       SUM(CASE WHEN f_cycle <> p_cycle OR f_cycle <> b_cycle THEN 1 ELSE 0 END) AS mixed_rows
FROM CONSUME.V_PREMIUM_REPORT;
/* EXPECTED: mixed_rows = 0 */

/* publish a new cycle via O11 */
INSERT OVERWRITE INTO STG.FACT_PREMIUM SELECT premium_id, policy_id, broker_id, amt, 7 FROM SRC.FACT_PREMIUM;
INSERT OVERWRITE INTO STG.DIM_POLICY   SELECT policy_id, policy_no, 7 FROM SRC.DIM_POLICY;
INSERT OVERWRITE INTO STG.DIM_BROKER   SELECT broker_id, broker_cd, 7 FROM SRC.DIM_BROKER;
INSERT OVERWRITE INTO STG.DIM_DATE     SELECT date_key, cal_date, 7 FROM SRC.DIM_DATE;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-027|VA_VIEW_INHERITS';
BEGIN;
  INSERT OVERWRITE INTO PUB.FACT_PREMIUM SELECT * FROM STG.FACT_PREMIUM;
  INSERT OVERWRITE INTO PUB.DIM_POLICY   SELECT * FROM STG.DIM_POLICY;
  INSERT OVERWRITE INTO PUB.DIM_BROKER   SELECT * FROM STG.DIM_BROKER;
  INSERT OVERWRITE INTO PUB.DIM_DATE     SELECT * FROM STG.DIM_DATE;
COMMIT;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-027 after publish' AS tc,
       COUNT(*) AS rows_,
       MAX(f_cycle) AS cycle_now,
       SUM(CASE WHEN f_cycle <> p_cycle OR f_cycle <> b_cycle THEN 1 ELSE 0 END) AS mixed_rows
FROM CONSUME.V_PREMIUM_REPORT;
/* EXPECTED: mixed_rows = 0, cycle_now = 7, and the view DDL unchanged */

SELECT 'TC-027 view DDL after (expect identical)' AS tc,
       GET_DDL('VIEW','CONSUME.V_PREMIUM_REPORT') AS ddl;


/* =====================================================================
   TC-028  View SQL unchanged across a SCHEMA SWAP (name resolution)
   Proves constraint C1 holds for option O16: the view references
   PUB.<table> by name, and after the swap that name resolves to the
   other storage without the view being edited.
   Expected: the view returns the NEW cycle; its DDL is byte-identical.
   ===================================================================== */
INSERT OVERWRITE INTO STG.FACT_PREMIUM SELECT premium_id, policy_id, broker_id, amt, 8 FROM SRC.FACT_PREMIUM;
INSERT OVERWRITE INTO STG.DIM_POLICY   SELECT policy_id, policy_no, 8 FROM SRC.DIM_POLICY;
INSERT OVERWRITE INTO STG.DIM_BROKER   SELECT broker_id, broker_cd, 8 FROM SRC.DIM_BROKER;
INSERT OVERWRITE INTO STG.DIM_DATE     SELECT date_key, cal_date, 8 FROM SRC.DIM_DATE;

SELECT 'TC-028 before swap' AS tc, MAX(f_cycle) AS cyc FROM CONSUME.V_PREMIUM_REPORT;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-028|VIEW_SURVIVES_SWAP';
ALTER SCHEMA PUB SWAP WITH STG;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-028 after swap (expect cycle 8)' AS tc, MAX(f_cycle) AS cyc FROM CONSUME.V_PREMIUM_REPORT;
SELECT 'TC-028 view DDL (expect unchanged)' AS tc, GET_DDL('VIEW','CONSUME.V_PREMIUM_REPORT') AS ddl;


/* =====================================================================
   TC-029  A view INSIDE a swapped schema, self-referencing by full path
   POC02 flagged this caveat. It is the reason §5.2 places the view
   estate OUTSIDE the swapped pair.
   Expected: after the swap, this view resolves to the WRONG storage
             (or errors) because its fully-qualified reference now
             points at the other schema.
   ===================================================================== */
CREATE OR REPLACE VIEW PUB.V_INSIDE_SWAPPED AS
SELECT premium_id, cycle_marker FROM POC_GATING_DB.PUB.FACT_PREMIUM;   -- fully qualified

SELECT 'TC-029 before swap' AS tc, MAX(cycle_marker) AS cyc FROM PUB.V_INSIDE_SWAPPED;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-029|VIEW_INSIDE_SWAPPED';
ALTER SCHEMA PUB SWAP WITH STG;
ALTER SESSION UNSET QUERY_TAG;

/* The view object itself has moved to the STG name along with everything
   else in the schema. Query BOTH names and record what each returns. */
SELECT 'TC-029 PUB.V_INSIDE_SWAPPED after' AS tc, MAX(cycle_marker) AS cyc FROM PUB.V_INSIDE_SWAPPED;
SELECT 'TC-029 STG.V_INSIDE_SWAPPED after' AS tc, MAX(cycle_marker) AS cyc FROM STG.V_INSIDE_SWAPPED;
SELECT 'TC-029 ddl PUB' AS tc, GET_DDL('VIEW','PUB.V_INSIDE_SWAPPED') AS ddl;
SELECT 'TC-029 ddl STG' AS tc, GET_DDL('VIEW','STG.V_INSIDE_SWAPPED') AS ddl;
/* Record whether either view now reads the storage its name implies.
   Expected: at least one of them does not. */

DROP VIEW IF EXISTS PUB.V_INSIDE_SWAPPED;
DROP VIEW IF EXISTS STG.V_INSIDE_SWAPPED;


/* =====================================================================
   TC-005b / SC-05  V-b — physicalizing a view with INSERT OVERWRITE
   The pattern that avoids rebuilding view logic as ETL (constraint C1,
   C6). The view supplies the SELECT; the table is pre-deployed.
   Expected: data lands; the pre-deployed table's tag, policy, grants
             and owner are all unchanged (cross-reference TC-004..007).
   ===================================================================== */
ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-005b|VB_PHYSICALIZE_VIEW';
INSERT OVERWRITE INTO PUB.CUSTOMER_360
SELECT customer_id, email, customer_name, premium_amt, cycle_marker
FROM CONSUME.V_CUSTOMER_360;          -- the EXISTING view is the transform
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-005b rows' AS tc, COUNT(*) FROM PUB.CUSTOMER_360;
SELECT 'TC-005b tags (expect intact)' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.CUSTOMER_360','table'));
SHOW TABLES LIKE 'CUSTOMER_360' IN SCHEMA PUB;
SELECT 'TC-005b owner (expect unchanged)' AS tc, "name","owner" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


/* =====================================================================
   TC-030  CLUSTERING KEY survival: INSERT OVERWRITE vs CTAS
   Documented: CLONE and LIKE inherit a clustering key; a plain CTAS
   requires the column definitions to be restated to keep one.
   Expected: INSERT OVERWRITE target keeps CLUSTER BY (policy_id);
             the CTAS target has NO cluster_by.
             A silently unclustered table is a recurring cost, since
             Automatic Clustering then pays to rebuild it each cycle.
   ===================================================================== */
CREATE OR REPLACE TABLE PUB.T030_IO LIKE SRC.FACT_PREMIUM;
ALTER TABLE PUB.T030_IO CLUSTER BY (policy_id);
INSERT INTO PUB.T030_IO SELECT * FROM SRC.FACT_PREMIUM;

SHOW TABLES LIKE 'T030_IO' IN SCHEMA PUB;
SELECT 'TC-030 IO before' AS tc, "name","cluster_by" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-030|CLUSTER_IO';
INSERT OVERWRITE INTO PUB.T030_IO SELECT * FROM SRC.FACT_PREMIUM;
ALTER SESSION UNSET QUERY_TAG;

SHOW TABLES LIKE 'T030_IO' IN SCHEMA PUB;
SELECT 'TC-030 IO after (expect cluster_by STILL set)' AS tc, "name","cluster_by"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-030|CLUSTER_CTAS';
CREATE OR REPLACE TABLE PUB.T030_CTAS COPY GRANTS COPY TAGS AS SELECT * FROM SRC.FACT_PREMIUM;
ALTER SESSION UNSET QUERY_TAG;

SHOW TABLES LIKE 'T030_CTAS' IN SCHEMA PUB;
SELECT 'TC-030 CTAS (expect cluster_by EMPTY)' AS tc, "name","cluster_by"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT 'TC-030 clustering depth IO' AS tc,
       SYSTEM$CLUSTERING_INFORMATION('PUB.T030_IO','(policy_id)') AS info;


/* =====================================================================
   TC-031  STREAMS on a published object — state after each mechanism
   Scenario SC-18. Documented for clones of containers: unconsumed
   records in the clone are inaccessible. Not documented for swap or
   INSERT OVERWRITE.
   Expected (assumption): INSERT OVERWRITE registers as DML so the
             stream advances normally. A SWAP or OR REPLACE leaves the
             stream stale. Record SYSTEM$STREAM_HAS_DATA and whether
             reading the stream errors.
   ===================================================================== */
CREATE OR REPLACE TABLE PUB.T031_BASE (id NUMBER, v STRING);
INSERT INTO PUB.T031_BASE SELECT 1,'a';
CREATE OR REPLACE STREAM PUB.T031_STREAM ON TABLE PUB.T031_BASE;

SELECT 'TC-031 stream has data at start' AS tc, SYSTEM$STREAM_HAS_DATA('PUB.T031_STREAM') AS has_data;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-031|STREAM_AFTER_IO';
INSERT OVERWRITE INTO PUB.T031_BASE SELECT 2,'b';
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-031 after INSERT OVERWRITE' AS tc, SYSTEM$STREAM_HAS_DATA('PUB.T031_STREAM') AS has_data;
SELECT 'TC-031 stream contents after IO' AS tc, * FROM PUB.T031_STREAM;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-031|STREAM_AFTER_REPLACE';
CREATE OR REPLACE TABLE PUB.T031_BASE (id NUMBER, v STRING);
INSERT INTO PUB.T031_BASE SELECT 3,'c';
ALTER SESSION UNSET QUERY_TAG;

/* This read is expected to ERROR or return nothing usable — capture the
   exact message. A stale stream is silent until something consumes it. */
SELECT 'TC-031 stream after OR REPLACE' AS tc, * FROM PUB.T031_STREAM;
SHOW STREAMS LIKE 'T031_STREAM' IN SCHEMA PUB;
SELECT "name","stale","stale_after","invalid_reason" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


/* =====================================================================
   TC-033  INSERT OVERWRITE on a Snowflake-managed ICEBERG table
   Option O14. NOT NAMED in the documentation.
   Expected (assumption): supported, since v3 documents INSERT and
             TRUNCATE. If it is NOT supported, an Iceberg Zone 3 cannot
             use the recommended refresh mechanism.
   ---------------------------------------------------------------------
   PREREQUISITE: an EXTERNAL VOLUME. Replace <EXT_VOL> below, or skip
   this test and record it as BLOCKED in the tracker.
   ===================================================================== */
-- CREATE OR REPLACE ICEBERG TABLE PUB.T033_ICE (
--     id NUMBER, email STRING, cycle_marker NUMBER)
--   CATALOG = 'SNOWFLAKE'
--   EXTERNAL_VOLUME = '<EXT_VOL>'
--   BASE_LOCATION = 'poc_gating/t033/';
--
-- ALTER TABLE PUB.T033_ICE MODIFY COLUMN email SET TAG GOV.PII_EMAIL = 'EMAIL';
-- GRANT SELECT ON TABLE PUB.T033_ICE TO ROLE POC_READER_ROLE;
-- INSERT INTO PUB.T033_ICE SELECT customer_id, email, 1 FROM SRC.CUSTOMER_SRC LIMIT 100;
--
-- ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-033|ICEBERG_IO';
-- INSERT OVERWRITE INTO PUB.T033_ICE
--   SELECT customer_id, email, 2 FROM SRC.CUSTOMER_SRC LIMIT 100;
-- ALTER SESSION UNSET QUERY_TAG;
--
-- SELECT 'TC-033 rows' AS tc, COUNT(*), MAX(cycle_marker) FROM PUB.T033_ICE;
-- SELECT 'TC-033 tags (expect intact)' AS tc, *
-- FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.T033_ICE','table'));
-- /* Also attempt the group form inside a transaction, and record whether
--    Iceberg tables may participate:
--      BEGIN; INSERT OVERWRITE INTO PUB.T033_ICE SELECT ...; COMMIT;  */


/* =====================================================================
   SUMMARY
   ===================================================================== */
SELECT SPLIT_PART(query_tag,'|',2) AS tc,
       SPLIT_PART(query_tag,'|',3) AS mechanism,
       total_elapsed_time/1000     AS seconds, rows_produced, bytes_written
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
        END_TIME_RANGE_START => DATEADD('hour',-2,CURRENT_TIMESTAMP()),
        RESULT_LIMIT => 1000))
WHERE query_tag LIKE 'GATING_POC|TC-0%'
ORDER BY tc;
