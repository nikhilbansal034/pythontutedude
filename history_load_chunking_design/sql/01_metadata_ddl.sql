-- =====================================================================================
-- 01_metadata_ddl.sql — the two metadata tables the chunk planner writes
-- =====================================================================================
-- Run once, before anything else. Plain SQL: run statement by statement, or "Run all".
--
-- Location: test_db.test_schema for now (decision D3 in design_review.md). When the
-- final location is decided, change the two names below AND the metadata_database /
-- metadata_schema variables at the top of 04_chunk_planner.sql and 05_validate.sql.
--
-- Range semantics for HIST_PLAN_CHUNK (see design_review.md §4.8):
--   * A row belongs to a chunk when  start <= value < end   (half-open).
--   * NULL start / NULL end = unbounded on that side.
--   * DAY_* columns are dates of the table's chunk axis (HIST_PLAN_TABLE.CHUNK_AXIS):
--       PARTITION_DAY  -> the DATE partition column itself
--       PARTITION_YMD  -> DATE_FROM_PARTS(year, month, day) of the three partition columns
--       REFINED_TS_DAY -> the UTC date of GRS_REFINED_TIMESTAMP
--   * SUB_* timestamps bound GRS_REFINED_TIMESTAMP inside one split day (TIMESTAMP_TZ, UTC).
--   * HASH chunks:  MOD(ABS(HASH(<SUB_COLUMN>)), HASH_MODULUS) = HASH_BUCKET
-- =====================================================================================

-- CREATE DATABASE IF NOT EXISTS test_db;           -- uncomment only if you may create databases
CREATE SCHEMA IF NOT EXISTS test_db.test_schema;
USE SCHEMA test_db.test_schema;

CREATE TABLE IF NOT EXISTS HIST_PLAN_TABLE (
    PLAN_ID               VARCHAR       NOT NULL COMMENT 'One plan per table per planning; a re-plan gets a new PLAN_ID',
    RUN_ID                VARCHAR       NOT NULL COMMENT 'Groups all rows written by one execution of the planner',
    DATABASE_NAME         VARCHAR       NOT NULL,
    SCHEMA_NAME           VARCHAR       NOT NULL,
    TABLE_NAME            VARCHAR       NOT NULL,
    OBJECT_TYPE           VARCHAR                COMMENT 'ICEBERG TABLE, BASE TABLE, VIEW, ... (explains SKIPPED rows)',
    LAYER                 VARCHAR                COMMENT 'CURRENT / HISTORY / UNKNOWN - information only, never used to decide',
    CHUNK_AXIS            VARCHAR                COMMENT 'PARTITION_DAY / PARTITION_YMD / REFINED_TS_DAY / UNIQUE_ID_HASH / NONE',
    AXIS_COLUMNS          VARCHAR                COMMENT 'Column(s) the chunks are divided on, comma separated (year,month,day for PARTITION_YMD)',
    PARTITION_VERIFIED    BOOLEAN                COMMENT 'TRUE = the Iceberg partition spec confirms the axis columns; FALSE = taken from the GRS_PROCESS_* naming convention',
    CHUNK_METHOD          VARCHAR                COMMENT 'SINGLE / DAY_RANGES / DAY_RANGES_WITH_SPLITS / HASH_BUCKETS',
    PROFILED_AT           TIMESTAMP_TZ           COMMENT 'Point in time the profile describes',
    TOTAL_ROWS            NUMBER(38,0),
    TOTAL_BYTES           NUMBER(38,0)           COMMENT 'Sum of Iceberg data file sizes (compressed Parquet)',
    COLUMN_COUNT          NUMBER(38,0),
    AVG_ROW_BYTES         NUMBER(38,4),
    FILE_COUNT            NUMBER(38,0),
    AVG_FILE_BYTES        NUMBER(38,2),
    DAY_COUNT             NUMBER(38,0)           COMMENT 'Distinct non-NULL axis days',
    SPLIT_DAY_COUNT       NUMBER(38,0)           COMMENT 'Days too big for one chunk, split into sub-ranges or hash buckets',
    CHUNK_COUNT           NUMBER(38,0)           COMMENT 'How many chunks this table has',
    TARGET_CHUNK_BYTES    NUMBER(38,0)           COMMENT 'Size target used (10 GB default, Medium-warehouse assumption)',
    TARGET_ROWS_PER_CHUNK NUMBER(38,0)           COMMENT 'target bytes / avg row bytes, capped at max_chunk_rows',
    PLAN_STATUS           VARCHAR       NOT NULL COMMENT 'PLANNED / FAILED / SKIPPED / SUPERSEDED',
    STATUS_REASON         VARCHAR                COMMENT 'Why FAILED or SKIPPED; notes for PLANNED',
    IS_ACTIVE             BOOLEAN       NOT NULL COMMENT 'One active row per table',
    PLANNED_AT            TIMESTAMP_TZ  NOT NULL
)
COMMENT = 'History-load chunk planner: one row per table per plan. Status lives here (D11).';

CREATE TABLE IF NOT EXISTS HIST_PLAN_CHUNK (
    PLAN_ID         VARCHAR       NOT NULL,
    CHUNK_SEQ       NUMBER(38,0)  NOT NULL COMMENT 'Order of the chunk within the table, from 1',
    DATABASE_NAME   VARCHAR       NOT NULL,
    SCHEMA_NAME     VARCHAR       NOT NULL,
    TABLE_NAME      VARCHAR       NOT NULL,
    CHUNK_TYPE      VARCHAR       NOT NULL COMMENT 'ALL / DAY_RANGE / DAY_SUBRANGE / DAY_HASH / HASH / NULL_VALUES',
    DAY_START       DATE                   COMMENT 'Half-open day range start on the chunk axis; NULL = unbounded',
    DAY_END         DATE                   COMMENT 'Half-open day range end on the chunk axis; NULL = unbounded',
    SUB_COLUMN      VARCHAR                COMMENT 'GRS_REFINED_TIMESTAMP for DAY_SUBRANGE; GRS_UNIQUE_ID for DAY_HASH / HASH',
    SUB_START_TS    TIMESTAMP_TZ           COMMENT 'DAY_SUBRANGE only: SUB_COLUMN >= this; NULL = open at the day edge',
    SUB_END_TS      TIMESTAMP_TZ           COMMENT 'DAY_SUBRANGE only: SUB_COLUMN <  this; NULL = open at the day edge',
    HASH_BUCKET     NUMBER(38,0)           COMMENT 'DAY_HASH / HASH only',
    HASH_MODULUS    NUMBER(38,0)           COMMENT 'DAY_HASH / HASH only',
    ESTIMATED_ROWS  NUMBER(38,0)           COMMENT 'Exact at PROFILED_AT for range chunks; even share for hash chunks',
    ESTIMATED_BYTES NUMBER(38,0)           COMMENT 'ESTIMATED_ROWS x AVG_ROW_BYTES'
)
COMMENT = 'History-load chunk planner: one row per chunk. Half-open ranges, NULL = unbounded.';

-- Evidence E01: both tables exist
SHOW TABLES LIKE 'HIST_PLAN%' IN SCHEMA test_db.test_schema;
