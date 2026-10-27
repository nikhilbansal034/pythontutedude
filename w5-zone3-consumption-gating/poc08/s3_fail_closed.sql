/* =====================================================================
   POC08  ·  S3  —  THE GATE MUST FAIL CLOSED
   =====================================================================
   Five cases. In every one, REFUSING IS THE PASS CONDITION.

   The point: the control table is the source of truth, so anything
   wrong with it must stop the publish rather than quietly produce a
   half-protected table.

   Run AFTER s2. Restores the good state at the end.
   ===================================================================== */

USE SECONDARY ROLES NONE;
SET wh = 'POC_WH';

/* =====================================================================
   TC-3.1  No control row at all
   ===================================================================== */
USE ROLE P8_GOV_ROLE; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
DELETE FROM P8_CTRL.OBJECT_TAGS WHERE object_name = 'CUSTOMER_360';

USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
SELECT 'TC-3.1 pre-build check - is the object declared?' AS check_name,
       COUNT(*) AS declarations,
       CASE WHEN COUNT(*) = 0
            THEN 'REFUSE - object is not declared in the control table'
            ELSE 'proceed' END AS verdict
FROM LM_POC_DB.P8_CTRL.OBJECT_TAGS WHERE object_name = 'CUSTOMER_360';
/* EXPECT  declarations = 0, verdict = REFUSE.
   An undeclared object must never be built. Building it would produce
   an untagged table that the gate would then have nothing to check
   against - and it would pass.                                       */

/* put it back - the day-2 declaration, written out in full rather than
   stashed in a temp table: no statement in this pack sets a current
   schema, so an unqualified temp table would have nowhere to live.   */
USE ROLE P8_GOV_ROLE; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
INSERT INTO P8_CTRL.OBJECT_TAGS (object_name, column_tags, updated_by, updated_at, reason)
SELECT 'CUSTOMER_360',
       PARSE_JSON('{
         "EMAIL": { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "EMAIL_ADDRESS" },
         "PHONE": { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "PHONE" }
       }'),
       'governance.owner', CURRENT_TIMESTAMP(), 'restored after TC-3.1';

/* =====================================================================
   TC-3.2  The control row names a tag that does not exist
   ===================================================================== */
UPDATE P8_CTRL.OBJECT_TAGS
SET column_tags = PARSE_JSON('{
      "EMAIL": { "tag": "LM_POC_DB.P8_GOV.P8_PII",  "value": "EMAIL_ADDRESS" },
      "PHONE": { "tag": "LM_POC_DB.P8_GOV.P8_NOPE", "value": "PHONE" }
    }')
WHERE object_name = 'CUSTOMER_360';

USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);

/* First: can the pipeline see the tags at all? It holds APPLY on P8_PII
   but does not own it. If this returns ZERO rows the comparison below is
   void, and the finding is that the pipeline needs a further grant to
   validate its own declarations. Re-run as P8_GOV_ROLE to confirm the
   tags are really there.                                             */
SHOW TAGS IN SCHEMA LM_POC_DB.P8_GOV;
SELECT 'TC-3.2 can the pipeline see the tags?' AS check_name,
       COUNT(*) AS tags_visible,
       CASE WHEN COUNT(*) = 0
            THEN 'VOID - pipeline cannot read the tag list; record as a finding'
            ELSE 'ok - comparison below is valid' END AS validity
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* EXPECT  tags_visible >= 1 */

SHOW TAGS IN SCHEMA LM_POC_DB.P8_GOV;
WITH existing AS (
    SELECT "name"::STRING AS tag_name FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
), declared AS (
    SELECT DISTINCT SPLIT_PART(f.value:tag::STRING, '.', 3) AS tag_name
    FROM LM_POC_DB.P8_CTRL.OBJECT_TAGS t, LATERAL FLATTEN(input => t.column_tags) f
    WHERE t.object_name = 'CUSTOMER_360'
)
SELECT 'TC-3.2 declared tags that do not exist' AS check_name, d.tag_name
FROM declared d LEFT JOIN existing e ON e.tag_name = d.tag_name
WHERE e.tag_name IS NULL;
/* EXPECT  one row - P8_NOPE.  Any row here = REFUSE, naming the tag.
   Without this check the build would fail mid-tagging with a cryptic
   error, or worse, tag some columns and not others.                  */

/* =====================================================================
   TC-3.3  The control row names a column the view does not return
   ===================================================================== */
USE ROLE P8_GOV_ROLE; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
UPDATE P8_CTRL.OBJECT_TAGS
SET column_tags = PARSE_JSON('{
      "EMAIL":     { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "EMAIL_ADDRESS" },
      "NOSUCHCOL": { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "PHONE" }
    }')
WHERE object_name = 'CUSTOMER_360';

USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
WITH declared AS (
    SELECT f.key::STRING AS col_name
    FROM LM_POC_DB.P8_CTRL.OBJECT_TAGS t, LATERAL FLATTEN(input => t.column_tags) f
    WHERE t.object_name = 'CUSTOMER_360'
), in_view AS (
    SELECT COLUMN_NAME AS col_name
    FROM LM_POC_DB.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'P8_SRC' AND TABLE_NAME = 'V_CUSTOMER_360'
)
SELECT 'TC-3.3 declared columns missing from the source view' AS check_name, d.col_name
FROM declared d LEFT JOIN in_view v ON v.col_name = d.col_name
WHERE v.col_name IS NULL;
/* EXPECT  one row - NOSUCHCOL.  Any row here = REFUSE.
   The declaration and the data have diverged. Proceeding would protect
   fewer columns than governance believes are protected.              */

/* =====================================================================
   TC-3.4  The pipeline loses APPLY on the tag
   ===================================================================== */
USE ROLE P8_GOV_ROLE; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
UPDATE P8_CTRL.OBJECT_TAGS
SET column_tags = PARSE_JSON('{ "EMAIL": { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "EMAIL_ADDRESS" } }')
WHERE object_name = 'CUSTOMER_360';

USE ROLE SECURITYADMIN;
REVOKE APPLY ON TAG LM_POC_DB.P8_GOV.P8_PII FROM ROLE P8_BATCH;

USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
CREATE OR REPLACE TABLE P8_STG.CUSTOMER_360 COPY GRANTS
  AS SELECT * FROM P8_SRC.V_CUSTOMER_360;

/* THIS STATEMENT IS EXPECTED TO FAIL - insufficient privileges on the
   tag. Run it, copy the error into the evidence, then continue.      */
ALTER TABLE P8_STG.CUSTOMER_360 MODIFY COLUMN email
  SET TAG LM_POC_DB.P8_GOV.P8_PII = 'EMAIL_ADDRESS';

/* and the gate catches the consequence */
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
SELECT 'TC-3.4 declared but NOT tagged' AS check_name, d.col_name
FROM declared d LEFT JOIN actual a ON a.column_name = d.col_name
WHERE a.column_name IS NULL;
/* EXPECT  one row - EMAIL.  The tagging step failed, so the gate
   refuses. NO SWAP HAPPENS. A privilege the pipeline silently lost must
   not become a published table with no protection.                   */

USE ROLE SECURITYADMIN;
GRANT APPLY ON TAG LM_POC_DB.P8_GOV.P8_PII TO ROLE P8_BATCH;

/* =====================================================================
   TC-3.5  The pipeline must not be able to edit its own rulebook
   ===================================================================== */
USE ROLE P8_BATCH; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);

/* THIS STATEMENT IS EXPECTED TO FAIL - P8_BATCH holds SELECT only.
   Run it, copy the error into the evidence, then continue.           */
UPDATE LM_POC_DB.P8_CTRL.OBJECT_TAGS
SET column_tags = PARSE_JSON('{}')
WHERE object_name = 'CUSTOMER_360';
/* EXPECT  a privilege error.
   Write access to this table is the power to unprotect a column: empty
   the row and the next batch publishes everything in the clear, with
   the gate passing because the gate checks against this same table.  */

/* =====================================================================
   RESTORE the good day-2 state
   ===================================================================== */
USE ROLE P8_GOV_ROLE; USE DATABASE LM_POC_DB; USE WAREHOUSE IDENTIFIER($wh);
UPDATE P8_CTRL.OBJECT_TAGS
SET column_tags = PARSE_JSON('{
      "EMAIL": { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "EMAIL_ADDRESS" },
      "PHONE": { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "PHONE" }
    }'),
    updated_by = 'governance.owner',
    updated_at = CURRENT_TIMESTAMP(),
    reason     = 'restored after s3 fail-closed tests'
WHERE object_name = 'CUSTOMER_360';

SELECT 'S3 COMPLETE - all scenarios run' AS status;
