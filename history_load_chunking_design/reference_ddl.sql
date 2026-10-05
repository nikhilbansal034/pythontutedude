-- Reference DDL for the chunk planner, transcribed from the screenshots in sources/
-- (ddl_current_raw.png, ddl_history_raw.png), shared 2026-10-05.
-- One source table, PRDSCT1D_SCOUT_APLD_COVRG_INSRBL_OBJ, in both Zone1 layers.
-- All other tables are expected to follow the same structure and differ only in their business columns.
-- Column roles are annotated on the right; see design_review.md §3.

-- CURRENT layer: mirrors the source as it is now; rows are updated/deleted in place (called SCD1)
CREATE OR REPLACE ICEBERG TABLE GRS_DIAI_CURRENT_RAW_DB.UNDERWRITING_LMPW.PRDSCT1D_SCOUT_APLD_COVRG_INSRBL_OBJ (
    OP                       STRING,            -- CDC header: operation (Qlik Replicate)
    AR_H_TIMESTAMP           STRING,            -- CDC header: change timestamp, Replicate-server local time, as STRING
    APLD_COVRG_INSRBL_OBJ_ID INT,               -- business: source primary key (<table suffix>_ID)
    APLD_COVRG_ID            INT,               -- business
    INSRBL_OBJ_ID            INT,               -- business
    EFFCTV_TS                TIMESTAMP_LTZ(6),  -- business: source-maintained validity start
    EXPRTN_TS                TIMESTAMP_LTZ(6),  -- business: source-maintained validity end (changes when a version closes)
    CREAT_TS                 TIMESTAMP_LTZ(6),  -- business: source audit
    CREAT_ID                 INT,               -- business: source audit
    LAST_UPDT_TS             TIMESTAMP_LTZ(6),  -- business: source audit (changes on update)
    LAST_UPDT_ID             INT,               -- business: source audit
    STAT_TYP_ID              INT,               -- business
    CNCRCY_NBR               INT,               -- business
    OPRTN_TRX_ID             INT,               -- business
    CHANGE_SEQ_NUM           STRING,            -- CDC header: monotonic change sequence (Qlik), as STRING
    GRS_LANDING_SOURCE_PATH  STRING,            -- GRS audit
    GRS_LANDING_DATE         STRING,            -- GRS audit, as STRING
    GRS_EXECUTION_UUID       STRING,            -- GRS audit: one value per pipeline run
    ROW_HASH                 STRING,            -- GRS audit: CURRENT-layer only
    GRS_RAW_TIMESTAMP        TIMESTAMP_LTZ(6),  -- GRS watermark: landed in raw
    GRS_UNIQUE_ID            STRING,            -- GRS audit: unique per record (UUID)
    GRS_RAW_SOURCE_PATH      STRING,            -- GRS audit
    GRS_REFINED_TIMESTAMP    TIMESTAMP_LTZ(6),  -- GRS watermark: landed in refined
    GRS_PROCESS_DATE         DATE               -- GRS partition column (CURRENT layer)
)
PARTITION BY (GRS_PROCESS_DATE)
EXTERNAL_VOLUME = 'EV_GRSDIAI_REFINED_FULL_BUCKET_ICEBERG'
ICEBERG_VERSION = 3
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'current/tokenized_data/underwriting/lmpw/PRDSCT1D/scout/apld_covrg_insrbl_obj/';

-- HISTORY layer: append-only; every change is a new row and nothing is overwritten (called SCD2)
CREATE OR REPLACE ICEBERG TABLE GRS_DIAI_HISTORY_RAW_DB.UNDERWRITING_LMPW.PRDSCT1D_SCOUT_APLD_COVRG_INSRBL_OBJ (
    OP                       STRING,
    AR_H_TIMESTAMP           STRING,
    APLD_COVRG_INSRBL_OBJ_ID INT,
    APLD_COVRG_ID            INT,
    INSRBL_OBJ_ID            INT,
    EFFCTV_TS                TIMESTAMP_LTZ(6),
    EXPRTN_TS                TIMESTAMP_LTZ(6),
    CREAT_TS                 TIMESTAMP_LTZ(6),
    CREAT_ID                 INT,
    LAST_UPDT_TS             TIMESTAMP_LTZ(6),
    LAST_UPDT_ID             INT,
    STAT_TYP_ID              INT,
    CNCRCY_NBR               INT,
    OPRTN_TRX_ID             INT,
    CHANGE_SEQ_NUM           STRING,
    GRS_LANDING_SOURCE_PATH  STRING,
    GRS_LANDING_DATE         STRING,
    GRS_EXECUTION_UUID       STRING,
    NEW_ROW_HASH             STRING,            -- GRS audit: HISTORY-layer only (replaces ROW_HASH)
    LAST_ROW_HASH            STRING,            -- GRS audit: HISTORY-layer only
    GRS_RAW_TIMESTAMP        TIMESTAMP_LTZ(6),
    GRS_UNIQUE_ID            STRING,
    GRS_RAW_SOURCE_PATH      STRING,
    GRS_REFINED_TIMESTAMP    TIMESTAMP_LTZ(6),
    GRS_PROCESS_YEAR         INT,               -- GRS partition column (HISTORY layer)
    GRS_PROCESS_MONTH        INT,               -- GRS partition column (HISTORY layer)
    GRS_PROCESS_DAY          INT                -- GRS partition column (HISTORY layer)
)
PARTITION BY (GRS_PROCESS_YEAR, GRS_PROCESS_MONTH, GRS_PROCESS_DAY)
EXTERNAL_VOLUME = 'EV_GRSDIAI_REFINED_FULL_BUCKET_ICEBERG'
ICEBERG_VERSION = 3
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'history/tokenized_data/underwriting/lmpw/PRDSCT1D/scout/apld_covrg_insrbl_obj/';
