/* =====================================================================
   POC08  ·  S2  —  DAY 2, THE OTHER STORAGE, AFTER A GOVERNANCE CHANGE
   =====================================================================
   Day 1's swap moved the storages. The build now lands on the OTHER
   physical storage - the one that was live yesterday, which nobody has
   ever tagged.

   Between the two days governance makes all three kinds of change in a
   single edit:
       ADDS     PHONE
       CHANGES  the value on EMAIL
       REMOVES  SSN

   TWO RESULTS MATTER:
     1. the second storage is correctly tagged although nobody pre-tagged it
     2. the REMOVED tag actually disappears

   Run AFTER s1.
   ===================================================================== */

USE SECONDARY ROLES NONE;
SET wh = 'POC_WH';

/* =====================================================================
   TC-2.1  Governance edits the control row
   ===================================================================== */
USE ROLE P8_GOV_ROLE; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);

UPDATE P8_CTRL.OBJECT_TAGS
SET column_tags = PARSE_JSON('{
      "EMAIL": { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "EMAIL_ADDRESS" },
      "PHONE": { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "PHONE" }
    }'),
    updated_by = 'governance.owner',
    updated_at = CURRENT_TIMESTAMP(),
    reason     = 'phone reclassified as PII; ssn no longer held here; email value renamed'
WHERE object_name = 'CUSTOMER_360';

SELECT 'TC-2.1 the new declaration' AS check_name,
       f.key AS column_key, f.value:value::STRING AS tag_value,
       t.updated_by, t.reason
FROM P8_CTRL.OBJECT_TAGS t, LATERAL FLATTEN(input => t.column_tags) f
WHERE t.object_name = 'CUSTOMER_360' ORDER BY f.key;
/* EXPECT  two rows - EMAIL = EMAIL_ADDRESS, PHONE = PHONE.
   SSN is gone from the declaration. updated_by and reason populated. */

/* the ETL loads batch B2 */
USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
DELETE FROM P8_SRC.CUSTOMER;
INSERT INTO P8_SRC.CUSTOMER
SELECT seq4()+1,
       'Customer '||(seq4()+1),
       'cust'||(seq4()+1)||'@example.invalid',
       LPAD(TO_VARCHAR(seq4()+1),3,'0')||'-00-0000',
       '+44-0000-'||(seq4()+1),
       'B2'
FROM TABLE(GENERATOR(ROWCOUNT => 20));

/* =====================================================================
   TC-2.2  The other storage also inherits nothing
   ===================================================================== */
CREATE OR REPLACE TABLE P8_STG.CUSTOMER_360 COPY GRANTS
  AS SELECT * FROM P8_SRC.V_CUSTOMER_360;

SELECT 'TC-2.2 tags on the OTHER storage, BEFORE tagging' AS check_name,
       column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
             'LM_POC_DB.P8_STG.CUSTOMER_360','table'))
WHERE tag_name = 'P8_PII'
ORDER BY column_name;
/* EXPECT  ZERO ROWS, on this storage too. Nobody ever tagged it and the
   build inherits nothing, so there is nothing here.                   */

/* =====================================================================
   TC-2.3  Apply the NEW declaration — add, change and remove at once
   ===================================================================== */
EXECUTE IMMEDIATE $$
  BEGIN
    LET applied INTEGER := 0;
    LET c CURSOR FOR
      SELECT f.key::STRING         AS col_name,
             f.value:tag::STRING   AS tag_name,
             f.value:value::STRING AS tag_value
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

SELECT 'TC-2.3 tags after the governance change' AS check_name,
       column_name, tag_name, tag_value
FROM TABLE(LM_POC_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
             'LM_POC_DB.P8_STG.CUSTOMER_360','table'))
WHERE tag_name = 'P8_PII'
ORDER BY column_name;
/* EXPECT  EXACTLY two rows:
       EMAIL -> EMAIL_ADDRESS   the CHANGED value
       PHONE -> PHONE           the ADDED column
   and NO row for SSN           the REMOVED column

   THE SSN ROW BEING ABSENT IS THE HEADLINE RESULT. A design that
   inherits yesterday's tags can add and change but can never remove -
   it keeps re-applying what it was handed. This one starts from a clean
   slate every build, so removal propagates with no special handling. */

/* =====================================================================
   TC-2.4  GATE - assert against the CURRENT control row
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
SELECT 'TC-2.4 declared but NOT tagged' AS check_name, d.col_name
FROM declared d LEFT JOIN actual a ON a.column_name = d.col_name
WHERE a.column_name IS NULL;
/* EXPECT  ZERO ROWS. The gate reads today's declaration, not day 1's. */

/* This probe reads the OTHER schema of the swap pair than TC-1.4 did,
   because day 1's swap exchanged them. It only works because setup
   grants USAGE and future-table SELECT on BOTH halves - a grant on one
   half alone travels with the swap and is on the wrong schema by now. */
USE ROLE P8_READER_NO; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
SELECT 'TC-2.4 unentitled read of staging' AS check_name,
       customer_id, email, ssn, phone
FROM P8_STG.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  email MASKED, phone MASKED, ssn REAL.
   Exactly the inverse of day 1, because the declaration changed.     */

/* =====================================================================
   TC-2.5  PUBLISH and read through the thin view
   ===================================================================== */
USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
ALTER SCHEMA P8_STG SWAP WITH P8_LIVE;

USE ROLE P8_READER_NO; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
SELECT 'TC-2.5 unentitled reader after publish' AS check_name,
       customer_id, email, ssn, phone, batch_id
FROM P8_VIEWS.V_CUSTOMER_360 ORDER BY customer_id LIMIT 3;
/* EXPECT  batch_id = B2
           email  MASKED   - still declared, new value
           phone  MASKED   - newly declared, now protected
           ssn    REAL     - no longer declared, now readable

   The ssn column going from masked to readable is governance removing a
   tag and the next batch honouring it.                               */

USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
SELECT 'S2 COMPLETE - run s3_fail_closed.sql next' AS status;
