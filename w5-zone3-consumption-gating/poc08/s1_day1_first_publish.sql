/* =====================================================================
   POC08  ·  S1  —  DAY 1, THE FIRST PUBLISH
   =====================================================================
   Build lands on the storage currently behind P8_STG. There is no
   predecessor table of any kind, and nothing was pre-tagged.

   THE RESULT THAT MATTERS: a first build is correctly protected.

   Run AFTER s0. Re-runnable - it returns to day-0 state first.
   ===================================================================== */

USE SECONDARY ROLES NONE;
SET wh = 'POC_WH';

/* ---------------------------------------------------------------------
   RESET to day 0, so this file can be re-run
   --------------------------------------------------------------------- */
USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
DROP TABLE IF EXISTS P8_STG.CUSTOMER_360;
DROP TABLE IF EXISTS P8_LIVE.CUSTOMER_360;
DROP VIEW  IF EXISTS P8_VIEWS.V_CUSTOMER_360;

USE ROLE P8_GOV_ROLE; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
DELETE FROM P8_CTRL.OBJECT_TAGS WHERE object_name = 'CUSTOMER_360';
INSERT INTO P8_CTRL.OBJECT_TAGS (object_name, column_tags, updated_by, updated_at, reason)
SELECT 'CUSTOMER_360',
       PARSE_JSON('{
         "EMAIL": { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "EMAIL" },
         "SSN":   { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "SSN"   }
       }'),
       'governance.owner', CURRENT_TIMESTAMP(), 'day 1 declaration';

/* the ETL loads batch B1 into the Zone 3 base table */
USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
DELETE FROM P8_SRC.CUSTOMER;
INSERT INTO P8_SRC.CUSTOMER
SELECT seq4()+1,
       'Customer '||(seq4()+1),
       'cust'||(seq4()+1)||'@example.invalid',
       LPAD(TO_VARCHAR(seq4()+1),3,'0')||'-00-0000',
       '+44-0000-'||(seq4()+1),
       'B1'
FROM TABLE(GENERATOR(ROWCOUNT => 20));

/* =====================================================================
   TC-1.1  The build inherits nothing
   ===================================================================== */
CREATE OR REPLACE TABLE P8_STG.CUSTOMER_360 COPY GRANTS
  AS SELECT * FROM P8_SRC.V_CUSTOMER_360;

SELECT 'TC-1.1 tags on the fresh build, BEFORE tagging' AS check_name,
       column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
             'LM_POC_DB.P8_STG.CUSTOMER_360','table'))
WHERE tag_name = 'P8_PII'
ORDER BY column_name;
/* EXPECT  ZERO ROWS. No COPY TAGS clause, so nothing is inherited.
   Every build starts from a clean slate - that is what lets a REMOVED
   tag actually disappear later.                                      */

/* =====================================================================
   TC-1.2  Apply the tags the control row declares
   ---------------------------------------------------------------------
   First look at what will run, then run it. If the block below fails,
   copy the statements from this preview and run them by hand, and
   record the block failure as a finding.
   ===================================================================== */
SELECT 'TC-1.2 preview - the statements the control row generates' AS check_name,
       'ALTER TABLE LM_POC_DB.P8_STG.CUSTOMER_360 MODIFY COLUMN ' || f.key ||
       ' SET TAG ' || f.value:tag::STRING ||
       ' = ''' || f.value:value::STRING || '''' AS statement_to_run
FROM LM_POC_DB.P8_CTRL.OBJECT_TAGS t, LATERAL FLATTEN(input => t.column_tags) f
WHERE t.object_name = 'CUSTOMER_360'
ORDER BY f.key;
/* EXPECT  two statements, for EMAIL and SSN. */

EXECUTE IMMEDIATE $$
  BEGIN
    LET applied INTEGER := 0;
    LET c CURSOR FOR
      SELECT f.key::STRING            AS col_name,
             f.value:tag::STRING      AS tag_name,
             f.value:value::STRING    AS tag_value
      FROM LM_POC_DB.P8_CTRL.OBJECT_TAGS t,
           LATERAL FLATTEN(input => t.column_tags) f
      WHERE t.object_name = 'CUSTOMER_360';
    FOR r IN c DO
      EXECUTE IMMEDIATE
        'ALTER TABLE LM_POC_DB.P8_STG.CUSTOMER_360 MODIFY COLUMN ' || r.col_name ||
        ' SET TAG ' || r.tag_name || ' = ''' || r.tag_value || '''';
      applied := applied + 1;
    END FOR;
    RETURN 'tags applied: ' || applied;
  END;
$$;
/* EXPECT  tags applied: 2 */

SELECT 'TC-1.2 tags after applying the control row' AS check_name,
       column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
             'LM_POC_DB.P8_STG.CUSTOMER_360','table'))
WHERE tag_name = 'P8_PII'
ORDER BY column_name;
/* EXPECT  EXACTLY two rows - EMAIL = EMAIL, SSN = SSN.
   No more and no fewer. PHONE must NOT appear: the control row does not
   declare it on day 1.                                               */

/* =====================================================================
   TC-1.3  GATE, part 1 - is every declared column actually tagged?
   ---------------------------------------------------------------------
   This is an assertion against the control table, not against a number
   a person remembers.
   ===================================================================== */
WITH declared AS (
    SELECT f.key::STRING AS col_name
    FROM LM_POC_DB.P8_CTRL.OBJECT_TAGS t, LATERAL FLATTEN(input => t.column_tags) f
    WHERE t.object_name = 'CUSTOMER_360'
), actual AS (
    SELECT column_name
    FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
                 'LM_POC_DB.P8_STG.CUSTOMER_360','table'))
    WHERE tag_name = 'P8_PII'
)
SELECT 'TC-1.3 declared but NOT tagged' AS check_name, d.col_name
FROM declared d LEFT JOIN actual a ON a.column_name = d.col_name
WHERE a.column_name IS NULL;
/* EXPECT  ZERO ROWS. Any row here = DO NOT PUBLISH. */

/* =====================================================================
   TC-1.4  GATE, part 2 - does an unentitled identity read masks?
   ===================================================================== */
USE ROLE P8_READER_NO; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
SELECT 'TC-1.4 unentitled read of staging' AS check_name,
       customer_id, email, ssn, phone
FROM P8_STG.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  email and ssn = ***MASKED***
           phone = REAL - it is not declared on day 1, so it is not
           protected. That is correct behaviour, not a defect: the table
           carries exactly what the control row declares.             */

/* =====================================================================
   TC-1.5  PUBLISH - swap, then stand up the reader views
   ---------------------------------------------------------------------
   The thin view cannot be created before the first publish: there is no
   table for it to read. So it is deployed here, once, and never again.
   ===================================================================== */
USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
ALTER SCHEMA P8_STG SWAP WITH P8_LIVE;

CREATE OR REPLACE VIEW P8_VIEWS.V_CUSTOMER_360 AS
SELECT * FROM P8_LIVE.CUSTOMER_360;

USE ROLE P8_READER_OK; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
SELECT 'TC-1.5 entitled reader' AS check_name, customer_id, email, ssn, phone, batch_id
FROM P8_VIEWS.V_CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  real values in all columns, batch_id = B1 */

USE ROLE P8_READER_NO; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
SELECT 'TC-1.5 unentitled reader' AS check_name, customer_id, email, ssn, phone, batch_id
FROM P8_VIEWS.V_CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  email and ssn MASKED, phone real, batch_id = B1 */

USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
SELECT 'S1 COMPLETE - run s2_day2_governance_change.sql next' AS status;
