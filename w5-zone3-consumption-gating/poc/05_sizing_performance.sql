/* =====================================================================
   05 — SIZING & PERFORMANCE   (TC-040, TC-041, TC-050 … TC-053)
   Scenarios SC-19, SC-20
   ---------------------------------------------------------------------
   Part 1 (TC-040/041) runs against the REAL account metadata, read-only,
   and answers the two questions that can change the design:
     - how many objects actually need gating?
     - does each consistency group fit inside one schema?

   Part 2 (TC-050..053) measures what Snowflake does not publish: the
   relative cost of INSERT OVERWRITE vs CTAS, and the duration of each
   publication mechanism at realistic group sizes.
   ===================================================================== */

USE ROLE POC_ROLE; USE WAREHOUSE POC_WH;

/* =====================================================================
   PART 1 — SIZING   (read-only, against the real account)
   Requires IMPORTED PRIVILEGES on the SNOWFLAKE database.
   NOTE: ACCOUNT_USAGE has replication latency of up to a few hours.
   That is fine for offline sizing. A GATE must never use it — use the
   INFORMATION_SCHEMA table functions there (as scripts 01 and 04 do).
   ===================================================================== */

/* ---------------------------------------------------------------------
   TC-040  Which objects do the reporting identities actually read?
   This scopes the real population. Replace the user list.
   Expected: a list materially SHORTER than the full view estate — that
             gap is the saving from gating only what is consumed.
   --------------------------------------------------------------------- */
SELECT 'TC-040' AS tc,
       bo.value:objectName::string   AS object_name,
       bo.value:objectDomain::string AS object_domain,
       COUNT(*)                      AS access_count,
       COUNT(DISTINCT user_name)      AS distinct_users
FROM   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
       LATERAL FLATTEN(base_objects_accessed) bo
WHERE  query_start_time > DATEADD(day, -90, CURRENT_TIMESTAMP())
  AND  user_name IN ('<POWERBI_SVC_USER>', '<REPORTING_SVC_USER>')   -- REPLACE
GROUP  BY 1,2,3
ORDER  BY access_count DESC;

/* Same question from the direct_objects side — what do reports NAME,
   as opposed to what Snowflake had to touch underneath. */
SELECT 'TC-040b' AS tc,
       do.value:objectName::string   AS object_named,
       do.value:objectDomain::string AS object_domain,
       COUNT(*) AS access_count
FROM   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
       LATERAL FLATTEN(direct_objects_accessed) do
WHERE  query_start_time > DATEADD(day, -90, CURRENT_TIMESTAMP())
  AND  user_name IN ('<POWERBI_SVC_USER>', '<REPORTING_SVC_USER>')   -- REPLACE
GROUP  BY 1,2
ORDER  BY access_count DESC;

/* ---------------------------------------------------------------------
   TC-041  Group membership, and THE design-critical question:
           do a report's base tables all live in ONE schema?
   Expected:
     - tables_to_gate per schema = the effort number
     - schemas_spanned per consumed view: if ANY value is > 1, that
       group spans schemas and option O16 (schema swap) cannot publish
       it atomically. O11 (transaction) then becomes the only viable
       publication mechanism for it.
   --------------------------------------------------------------------- */
WITH RECURSIVE consumed AS (
    /* seed: the views/tables reporting identities read.
       Replace this list with the result of TC-040, or inline it. */
    SELECT '<CONSUMED_VIEW_1>' AS obj UNION ALL
    SELECT '<CONSUMED_VIEW_2>'
),
dep AS (
    SELECT o.referencing_schema      AS root_schema,
           o.referencing_object_name AS root_object,
           o.referenced_database,
           o.referenced_schema,
           o.referenced_object_name,
           o.referenced_object_domain,
           1 AS lvl
    FROM   SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES o
    JOIN   consumed c ON c.obj = o.referencing_object_name
    UNION ALL
    SELECT d.root_schema, d.root_object,
           o.referenced_database, o.referenced_schema,
           o.referenced_object_name, o.referenced_object_domain,
           d.lvl + 1
    FROM   dep d
    JOIN   SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES o
      ON   o.referencing_object_name = d.referenced_object_name
     AND   o.referencing_schema      = d.referenced_schema
    WHERE  d.lvl < 10
)
/* a) the effort number */
SELECT 'TC-041a effort' AS tc,
       referenced_schema,
       COUNT(DISTINCT referenced_object_name) AS tables_to_gate
FROM   dep
WHERE  referenced_object_domain = 'TABLE'
GROUP  BY referenced_schema
ORDER  BY tables_to_gate DESC;

/* b) THE test of the frozen working position */
WITH RECURSIVE consumed AS (
    SELECT '<CONSUMED_VIEW_1>' AS obj UNION ALL SELECT '<CONSUMED_VIEW_2>'
),
dep AS (
    SELECT o.referencing_object_name AS root_object, o.referenced_database,
           o.referenced_schema, o.referenced_object_name, o.referenced_object_domain, 1 AS lvl
    FROM   SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES o
    JOIN   consumed c ON c.obj = o.referencing_object_name
    UNION ALL
    SELECT d.root_object, o.referenced_database, o.referenced_schema,
           o.referenced_object_name, o.referenced_object_domain, d.lvl + 1
    FROM   dep d
    JOIN   SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES o
      ON   o.referencing_object_name = d.referenced_object_name
     AND   o.referencing_schema      = d.referenced_schema
    WHERE  d.lvl < 10
)
SELECT 'TC-041b schema span' AS tc,
       root_object                                     AS consumed_object,
       COUNT(DISTINCT referenced_schema)               AS schemas_spanned,
       COUNT(DISTINCT referenced_database)             AS databases_spanned,
       COUNT(DISTINCT referenced_object_name)          AS base_tables,
       LISTAGG(DISTINCT referenced_schema, ', ')       AS schema_list,
       CASE WHEN COUNT(DISTINCT referenced_schema) > 1
            THEN 'O16 NOT VIABLE - use O11' ELSE 'O16 viable' END AS verdict
FROM   dep
WHERE  referenced_object_domain = 'TABLE'
GROUP  BY root_object
ORDER  BY schemas_spanned DESC;

/* c) view-estate ratio — quantifies "gate the tables, not the views" */
SELECT 'TC-041c estate ratio' AS tc,
       SUM(CASE WHEN table_type = 'VIEW'       THEN 1 ELSE 0 END) AS total_views,
       SUM(CASE WHEN table_type = 'BASE TABLE' THEN 1 ELSE 0 END) AS total_tables
FROM   SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE  deleted IS NULL
  AND  table_catalog = '<ZONE3_DATABASE>';     -- REPLACE


/* =====================================================================
   PART 2 — PERFORMANCE
   No published Snowflake benchmark exists for INSERT OVERWRITE vs CTAS.
   Both do the same fundamental work (read N rows, write N rows into new
   micro-partitions), so expect them close, with the SELECT dominating.
   The purpose of this part is to confirm performance does not VETO the
   recommendation, and to size the O11 publish window.

   DISCIPLINE
     - Fixed warehouse size for the whole run. Record it.
     - SUSPEND + RESUME before each timed statement (no warm cache).
     - USE_CACHED_RESULT = FALSE.
     - Three repetitions, alternating order, take the MEDIAN.
   ===================================================================== */

USE DATABASE POC_GATING_DB;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

/* ---- synthetic sources. Change ROWCOUNT for each volume tier. ---- */
SET vol = 1000000;        -- repeat the whole of Part 2 at 1e6, 1e7, 5e7

CREATE OR REPLACE TABLE SRC.PERF_NARROW AS
SELECT seq8()                                       AS id,
       UNIFORM(1, 1000000, RANDOM())                AS k,
       'cust' || seq8() || '@example.invalid'        AS email,
       UNIFORM(1, 100000, RANDOM())::NUMBER(12,2)    AS amt
FROM TABLE(GENERATOR(ROWCOUNT => 1000000));

/* 60-column shape, closer to a real consumption object */
CREATE OR REPLACE TABLE SRC.PERF_WIDE AS
SELECT id, k, email, amt,
       amt*1.01 AS c05, amt*1.02 AS c06, amt*1.03 AS c07, amt*1.04 AS c08,
       'v'||k   AS c09, 'v'||id  AS c10, k+1      AS c11, k+2      AS c12,
       amt*1.05 AS c13, amt*1.06 AS c14, amt*1.07 AS c15, amt*1.08 AS c16,
       'v'||k   AS c17, 'v'||id  AS c18, k+3      AS c19, k+4      AS c20,
       amt*1.09 AS c21, amt*1.10 AS c22, amt*1.11 AS c23, amt*1.12 AS c24,
       'v'||k   AS c25, 'v'||id  AS c26, k+5      AS c27, k+6      AS c28,
       amt*1.13 AS c29, amt*1.14 AS c30, amt*1.15 AS c31, amt*1.16 AS c32,
       'v'||k   AS c33, 'v'||id  AS c34, k+7      AS c35, k+8      AS c36,
       amt*1.17 AS c37, amt*1.18 AS c38, amt*1.19 AS c39, amt*1.20 AS c40,
       'v'||k   AS c41, 'v'||id  AS c42, k+9      AS c43, k+10     AS c44,
       amt*1.21 AS c45, amt*1.22 AS c46, amt*1.23 AS c47, amt*1.24 AS c48,
       'v'||k   AS c49, 'v'||id  AS c50, k+11     AS c51, k+12     AS c52,
       amt*1.25 AS c53, amt*1.26 AS c54, amt*1.27 AS c55, amt*1.28 AS c56,
       'v'||k   AS c57, 'v'||id  AS c58, k+13     AS c59, k+14     AS c60
FROM SRC.PERF_NARROW;

CREATE OR REPLACE TABLE PUB.PERF_TGT_NARROW LIKE SRC.PERF_NARROW;
CREATE OR REPLACE TABLE PUB.PERF_TGT_WIDE   LIKE SRC.PERF_WIDE;

/* ---------------------------------------------------------------------
   TC-050  INSERT OVERWRITE vs CTAS, NARROW (4 columns)
   Run this block three times, alternating which statement goes first.
   --------------------------------------------------------------------- */
ALTER WAREHOUSE POC_WH SUSPEND; ALTER WAREHOUSE POC_WH RESUME;
ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-050|IO|narrow|1M|run1';
INSERT OVERWRITE INTO PUB.PERF_TGT_NARROW SELECT * FROM SRC.PERF_NARROW;
ALTER SESSION UNSET QUERY_TAG;

ALTER WAREHOUSE POC_WH SUSPEND; ALTER WAREHOUSE POC_WH RESUME;
ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-050|CTAS|narrow|1M|run1';
CREATE OR REPLACE TABLE PUB.PERF_CTAS_NARROW COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC.PERF_NARROW;
ALTER SESSION UNSET QUERY_TAG;

/* ---------------------------------------------------------------------
   TC-051  INSERT OVERWRITE vs CTAS, WIDE (60 columns)
   --------------------------------------------------------------------- */
ALTER WAREHOUSE POC_WH SUSPEND; ALTER WAREHOUSE POC_WH RESUME;
ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-051|IO|wide|1M|run1';
INSERT OVERWRITE INTO PUB.PERF_TGT_WIDE SELECT * FROM SRC.PERF_WIDE;
ALTER SESSION UNSET QUERY_TAG;

ALTER WAREHOUSE POC_WH SUSPEND; ALTER WAREHOUSE POC_WH RESUME;
ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-051|CTAS|wide|1M|run1';
CREATE OR REPLACE TABLE PUB.PERF_CTAS_WIDE COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC.PERF_WIDE;
ALTER SESSION UNSET QUERY_TAG;

/* clustering check — the one place the two genuinely diverge */
SHOW TABLES LIKE 'PERF_%' IN SCHEMA PUB;
SELECT 'TC-050/051 clustering' AS tc, "name","cluster_by","rows","bytes"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

/* ---------------------------------------------------------------------
   TC-052  O11 publish-transaction duration by group size
   This is the cost of the second write. It is the number that decides
   whether O11 or O16 is right for a large group, and it must stay well
   inside the documented 4-hour non-blocking transaction limit.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE STG.PERF_G1 LIKE SRC.PERF_WIDE;
CREATE OR REPLACE TABLE STG.PERF_G2 LIKE SRC.PERF_WIDE;
CREATE OR REPLACE TABLE STG.PERF_G3 LIKE SRC.PERF_WIDE;
CREATE OR REPLACE TABLE STG.PERF_G4 LIKE SRC.PERF_WIDE;
CREATE OR REPLACE TABLE PUB.PERF_G1 LIKE SRC.PERF_WIDE;
CREATE OR REPLACE TABLE PUB.PERF_G2 LIKE SRC.PERF_WIDE;
CREATE OR REPLACE TABLE PUB.PERF_G3 LIKE SRC.PERF_WIDE;
CREATE OR REPLACE TABLE PUB.PERF_G4 LIKE SRC.PERF_WIDE;
INSERT INTO STG.PERF_G1 SELECT * FROM SRC.PERF_WIDE;
INSERT INTO STG.PERF_G2 SELECT * FROM SRC.PERF_WIDE;
INSERT INTO STG.PERF_G3 SELECT * FROM SRC.PERF_WIDE;
INSERT INTO STG.PERF_G4 SELECT * FROM SRC.PERF_WIDE;

ALTER WAREHOUSE POC_WH SUSPEND; ALTER WAREHOUSE POC_WH RESUME;
ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-052|O11_TXN|4tables|1M|run1';
BEGIN;
  INSERT OVERWRITE INTO PUB.PERF_G1 SELECT * FROM STG.PERF_G1;
  INSERT OVERWRITE INTO PUB.PERF_G2 SELECT * FROM STG.PERF_G2;
  INSERT OVERWRITE INTO PUB.PERF_G3 SELECT * FROM STG.PERF_G3;
  INSERT OVERWRITE INTO PUB.PERF_G4 SELECT * FROM STG.PERF_G4;
COMMIT;
ALTER SESSION UNSET QUERY_TAG;

/* ---------------------------------------------------------------------
   TC-053  O16 schema-swap duration by object count
   Expected: effectively constant and sub-second regardless of data
   volume, because it is a rename. This is O16's whole advantage, and
   TC-052 vs TC-053 is the trade-off made concrete.
   --------------------------------------------------------------------- */
ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-053|O16_SWAP|allobjects|1M|run1';
ALTER SCHEMA PUB SWAP WITH STG;
ALTER SESSION UNSET QUERY_TAG;
ALTER SCHEMA PUB SWAP WITH STG;   -- swap back


/* =====================================================================
   COLLECT THE NUMBERS
   QUERY_HISTORY via INFORMATION_SCHEMA is real-time; ACCOUNT_USAGE is
   not. Warehouse credits are not in QUERY_HISTORY — pair with
   WAREHOUSE_METERING_HISTORY over the same window for compute cost.
   ===================================================================== */
SELECT SPLIT_PART(query_tag,'|',2)              AS tc,
       SPLIT_PART(query_tag,'|',3)              AS mechanism,
       SPLIT_PART(query_tag,'|',4)              AS shape,
       SPLIT_PART(query_tag,'|',5)              AS volume,
       COUNT(*)                                 AS runs,
       MEDIAN(total_elapsed_time)/1000          AS median_seconds,
       MEDIAN(bytes_scanned)/POWER(1024,3)      AS median_gb_scanned,
       MEDIAN(bytes_written)/POWER(1024,3)      AS median_gb_written,
       MEDIAN(partitions_scanned)               AS median_parts_scanned,
       MEDIAN(credits_used_cloud_services)      AS median_cloud_credits
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
        END_TIME_RANGE_START => DATEADD('hour',-6,CURRENT_TIMESTAMP()),
        RESULT_LIMIT => 10000))
WHERE query_tag LIKE 'GATING_POC|TC-05%'
GROUP BY 1,2,3,4
ORDER BY shape, volume, mechanism;

SELECT 'warehouse credits over the run' AS section,
       warehouse_name, SUM(credits_used) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time > DATEADD('hour',-6,CURRENT_TIMESTAMP())
  AND warehouse_name = 'POC_WH'
GROUP BY warehouse_name;

/* RECORD IN THE TRACKER, alongside every performance row:
     - warehouse size
     - CURRENT_VERSION() (the account's Snowflake release)
     - whether the clustering key survived each mechanism            */
