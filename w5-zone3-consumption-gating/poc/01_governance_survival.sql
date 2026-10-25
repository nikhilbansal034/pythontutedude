/* =====================================================================
   01 — GOVERNANCE SURVIVAL   (TC-001 … TC-016)
   Scenarios SC-06, SC-07, SC-08, SC-09, SC-14, SC-15
   ---------------------------------------------------------------------
   Question: for each candidate refresh mechanism, do the tag, the
   masking policy, the grants and the OWNER survive?

   TC-004, TC-005 and TC-006 are the three the recommendation rests on.
   Snowflake does NOT document them. Run these first.
   ===================================================================== */

USE ROLE POC_ROLE; USE DATABASE POC_GATING_DB; USE WAREHOUSE POC_WH;

/* =====================================================================
   TC-001  BASELINE — capture all four controls before anything runs
   Expected: email tagged PII_EMAIL; MASK_EMAIL bound; reader has SELECT;
             owner = POC_DEPLOY_ROLE  <-- NOT the batch role. 00_setup
             transfers ownership so TC-003 and TC-006 mean something.
   ===================================================================== */
SELECT 'TC-001 tags' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.CUSTOMER_360','table'));

SELECT 'TC-001 policies' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => 'PUB.CUSTOMER_360', REF_ENTITY_DOMAIN => 'TABLE'));

SHOW GRANTS ON TABLE PUB.CUSTOMER_360;
SELECT 'TC-001 grants' AS tc, "privilege", "grantee_name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW TABLES LIKE 'CUSTOMER_360' IN SCHEMA PUB;
SELECT 'TC-001 owner' AS tc, "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


/* =====================================================================
   TC-002  CTAS, no clauses  (option O8 naive)
   Expected: tag GONE, policy GONE, reader SELECT GONE, owner = POC_ROLE
             (the role that ran it). This reproduces POC02's 4 -> 0.
   ===================================================================== */
CREATE OR REPLACE TABLE PUB.T002 LIKE PUB.CUSTOMER_360;
ALTER TABLE PUB.T002 MODIFY COLUMN email SET TAG GOV.PII_EMAIL = 'EMAIL';
GRANT SELECT ON TABLE PUB.T002 TO ROLE POC_READER_ROLE;
INSERT INTO PUB.T002 SELECT * FROM SRC.CUSTOMER_SRC;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-002|CTAS_PLAIN';
CREATE OR REPLACE TABLE PUB.T002 AS SELECT * FROM SRC.CUSTOMER_SRC;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-002 tags (expect ZERO rows)' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.T002','table'));

SHOW GRANTS ON TABLE PUB.T002;
SELECT 'TC-002 grants (expect OWNERSHIP only)' AS tc, "privilege", "grantee_name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


/* =====================================================================
   TC-003  CTAS + COPY GRANTS + COPY TAGS  (option O8 viable form)
   COPY TAGS for CREATE OR REPLACE TABLE went GA 2026-04-02. Note: the
   docs confirm the clause for CREATE OR REPLACE TABLE; that it also
   applies to the AS SELECT form is the design's reading and is exactly
   what this test settles.

   T003 is deliberately handed to the DEPLOY role first, so this test
   models the real thing: Liquibase owns the table, the batch identity
   runs the CTAS. Without that transfer the owner cell reads POC_ROLE
   before and after and proves nothing.

   Expected: tag PRESENT, reader SELECT PRESENT,
             owner = POC_ROLE  <-- OWNERSHIP MOVED off the deploy role.
             COPY GRANTS explicitly excludes OWNERSHIP. This is the
             discriminator that rules O8 out, and TC-006 is its mirror.
   ===================================================================== */
CREATE OR REPLACE TABLE PUB.T003 LIKE PUB.CUSTOMER_360;
ALTER TABLE PUB.T003 MODIFY COLUMN email SET TAG GOV.PII_EMAIL = 'EMAIL';
GRANT SELECT ON TABLE PUB.T003 TO ROLE POC_READER_ROLE;
INSERT INTO PUB.T003 SELECT * FROM SRC.CUSTOMER_SRC;

/* model the deployment: hand it to the deploy role, keep the batch
   role's DML. Confirm the owner BEFORE the CTAS so the move is visible. */
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE PUB.T003 TO ROLE POC_ROLE;
GRANT OWNERSHIP ON TABLE PUB.T003 TO ROLE POC_DEPLOY_ROLE COPY CURRENT GRANTS;

SHOW TABLES LIKE 'T003' IN SCHEMA PUB;
SELECT 'TC-003 owner BEFORE ctas (expect POC_DEPLOY_ROLE)' AS tc, "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-003|CTAS_COPY_TAGS';
CREATE OR REPLACE TABLE PUB.T003
  COPY GRANTS COPY TAGS
  AS SELECT * FROM SRC.CUSTOMER_SRC;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-003 tags (expect 1 row on EMAIL)' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.T003','table'));

SHOW GRANTS ON TABLE PUB.T003;
SELECT 'TC-003 grants (expect reader SELECT present)' AS tc, "privilege", "grantee_name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW TABLES LIKE 'T003' IN SCHEMA PUB;
SELECT 'TC-003 owner AFTER ctas (the key cell — expect POC_ROLE)' AS tc, "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* If before = POC_DEPLOY_ROLE and after = POC_ROLE, O8 moves ownership
   every cycle and C7 bites nightly. That is the finding. */


/* =====================================================================
   TC-004  *** CRITICAL *** INSERT OVERWRITE — do TAGS survive?
   Not documented. Design assumes YES because the object is not replaced.
   Expected: tag PRESENT on EMAIL, identical to TC-001.
   ===================================================================== */
ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-004|INSERT_OVERWRITE_TAGS';
INSERT OVERWRITE INTO PUB.CUSTOMER_360 SELECT * FROM SRC.CUSTOMER_SRC;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-004 tags (expect 1 row on EMAIL)' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.CUSTOMER_360','table'));


/* =====================================================================
   TC-005  *** CRITICAL *** INSERT OVERWRITE — is MASKING still enforced?
   A surviving tag is necessary but not sufficient; prove the policy
   actually still masks.
   Expected: POC_ROLE sees cust0@example.invalid (clear);
             POC_READER_ROLE sees a 64-char SHA2 hash.
   ===================================================================== */
SELECT 'TC-005 policy binding' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => 'PUB.CUSTOMER_360', REF_ENTITY_DOMAIN => 'TABLE'));

SELECT 'TC-005 as POC_ROLE (expect CLEAR)' AS tc, email
FROM PUB.CUSTOMER_360 ORDER BY customer_id LIMIT 3;

/* --- now run this part in a SEPARATE session as the reporting role --- */
-- USE ROLE POC_READER_ROLE;
-- USE DATABASE POC_GATING_DB; USE WAREHOUSE POC_WH;
-- SELECT 'TC-005 as READER (expect 64-char SHA2)' AS tc, email
-- FROM PUB.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
-- SELECT LENGTH(email) AS hash_len FROM PUB.CUSTOMER_360 LIMIT 1;  -- expect 64


/* =====================================================================
   TC-006  *** CRITICAL *** INSERT OVERWRITE — does OWNER change?
   This is the whole reason O10 is preferred over O8, and it is only a
   real test because the table is owned by POC_DEPLOY_ROLE while the
   INSERT OVERWRITE in TC-004 was run by POC_ROLE. Two different roles.
   If both were POC_ROLE this would pass whatever the answer was.

   Expected: owner = POC_DEPLOY_ROLE, i.e. UNCHANGED from TC-001 and
             still NOT the role that just rewrote every row.
   Read it against TC-003, where the same two roles produce a move.
   ===================================================================== */
SHOW TABLES LIKE 'CUSTOMER_360' IN SCHEMA PUB;
SELECT 'TC-006 owner (expect POC_DEPLOY_ROLE, unchanged)' AS tc, "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
/* FAILS THE DESIGN if this reads POC_ROLE: INSERT OVERWRITE would be
   moving ownership too, O10 loses its only advantage over O8, and the
   recommendation collapses. Record the result either way. */


/* =====================================================================
   TC-007  INSERT OVERWRITE — do GRANTS survive?
   DOCUMENTED: "specifying this option does not affect the access
   control privileges on the table". Confirming the documented claim.
   Expected: reader SELECT present, identical to TC-001.
   ===================================================================== */
SHOW GRANTS ON TABLE PUB.CUSTOMER_360;
SELECT 'TC-007 grants (expect reader SELECT present)' AS tc, "privilege", "grantee_name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


/* =====================================================================
   TC-008  CLONE within the same schema, with COPY GRANTS
   PUB.CUSTOMER_360 is owned by POC_DEPLOY_ROLE and this runs as
   POC_ROLE, so the owner cell is a real test, not a tautology.
   Expected: tag PRESENT, policy PRESENT, reader SELECT PRESENT,
             owner = POC_ROLE  <-- OWNERSHIP MOVES. COPY GRANTS copies
             every privilege EXCEPT ownership, so a clone taken each
             cycle hands the batch identity a new object every time,
             exactly as CTAS does in TC-003.
   ===================================================================== */
ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-008|CLONE_SAME_SCHEMA';
CREATE OR REPLACE TABLE PUB.T008 CLONE PUB.CUSTOMER_360 COPY GRANTS;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-008 tags (expect present)' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.T008','table'));

SHOW GRANTS ON TABLE PUB.T008;
SELECT 'TC-008 grants' AS tc, "privilege", "grantee_name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW TABLES LIKE 'T008' IN SCHEMA PUB;
SELECT 'TC-008 owner (expect POC_ROLE — i.e. MOVED off the deploy role)' AS tc,
       "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


/* =====================================================================
   TC-009  CLONE ACROSS schemas — column-level tag
   Answers "is clone only viable within the same schema?"
   Expected: tag PRESENT. Column-level tags travel across schemas.
   ===================================================================== */
ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-009|CLONE_CROSS_SCHEMA_COLTAG';
CREATE OR REPLACE TABLE STG.T009 CLONE PUB.CUSTOMER_360 COPY GRANTS;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-009 tags (expect present)' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('STG.T009','table'));

/* As the reader role, confirm it still masks:
   SELECT email FROM STG.T009 LIMIT 1;   -- expect SHA2 hash  */


/* =====================================================================
   TC-010  CLONE ACROSS schemas — SCHEMA-LEVEL tag-based policy
   DOCUMENTED: "A table moved or cloned out of a schema with a
   tag-based masking policy is not protected by the tag-based masking
   policy set on the source schema or database."
   Expected: the clone in PUB is NOT masked by SCHEMA_TAG's policy.
             This is why §5.3 mandates column-level binding.
   ===================================================================== */
CREATE OR REPLACE TABLE SCHEMA_TAG.CUSTOMER_SCHEMALEVEL AS
SELECT * FROM SRC.CUSTOMER_SRC;
ALTER SCHEMA SCHEMA_TAG SET TAG GOV.PII_EMAIL_SCHEMA = 'EMAIL';
GRANT USAGE  ON SCHEMA SCHEMA_TAG TO ROLE POC_READER_ROLE;
GRANT SELECT ON TABLE SCHEMA_TAG.CUSTOMER_SCHEMALEVEL TO ROLE POC_READER_ROLE;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-010|CLONE_OUT_OF_TAGGED_SCHEMA';
CREATE OR REPLACE TABLE PUB.T010 CLONE SCHEMA_TAG.CUSTOMER_SCHEMALEVEL COPY GRANTS;
ALTER SESSION UNSET QUERY_TAG;

/* As the reader role, compare the two:
   SELECT 'in tagged schema'  AS where_, email FROM SCHEMA_TAG.CUSTOMER_SCHEMALEVEL LIMIT 1;
       -- expect ***SCHEMA-MASKED***
   SELECT 'cloned out of it'  AS where_, email FROM PUB.T010 LIMIT 1;
       -- expect CLEAR  <-- the documented protection loss  */


/* =====================================================================
   TC-011  CREATE OR ALTER TABLE — add a column, keep governance
   Option O18. Resolves O10's shape-change dependency.
   Expected: existing EMAIL tag still present; new column added;
             grants and owner unchanged; existing data retained.
   ===================================================================== */
SELECT 'TC-011 rowcount before' AS tc, COUNT(*) FROM PUB.CUSTOMER_360;

/* CREATE OR ALTER requires OWNERSHIP, which now sits with the deploy
   role — correctly, because this is a DEPLOYMENT operation, not a
   refresh. In production Liquibase runs it, never the batch identity.
   Switch roles for it, then switch back. */
USE ROLE POC_DEPLOY_ROLE;
ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-011|CREATE_OR_ALTER';
CREATE OR ALTER TABLE PUB.CUSTOMER_360 (
    customer_id   NUMBER,
    email         STRING,
    customer_name STRING,
    premium_amt   NUMBER,
    cycle_marker  NUMBER,
    new_col       STRING          -- the added column
);
ALTER SESSION UNSET QUERY_TAG;
USE ROLE POC_ROLE;

SELECT 'TC-011 rowcount after (expect unchanged)' AS tc, COUNT(*) FROM PUB.CUSTOMER_360;

SELECT 'TC-011 tags (expect EMAIL tag intact)' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.CUSTOMER_360','table'));

SHOW GRANTS ON TABLE PUB.CUSTOMER_360;
SELECT 'TC-011 grants (expect intact)' AS tc, "privilege", "grantee_name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

/* NOTE: new_col carries NO tag. Documented: CREATE OR ALTER TABLE cannot
   set or unset a tag. The deployment must ALTER it in separately —
   which is exactly where the "new column is unprotected" risk lives. */

/* restore the shape for later scripts — deploy role again */
USE ROLE POC_DEPLOY_ROLE;
CREATE OR ALTER TABLE PUB.CUSTOMER_360 (
    customer_id NUMBER, email STRING, customer_name STRING,
    premium_amt NUMBER, cycle_marker NUMBER
);
USE ROLE POC_ROLE;   -- back to the batch identity for everything after this


/* =====================================================================
   TC-012  CTAS + COPY TAGS with a RENAMED column
   DOCUMENTED: a renamed column does not keep its tag.
   Expected: EMAIL's tag is LOST because the column is renamed.
             An ordinary view edit becomes a silent protection gap.
   ===================================================================== */
CREATE OR REPLACE TABLE PUB.T012 LIKE PUB.CUSTOMER_360;
ALTER TABLE PUB.T012 MODIFY COLUMN email SET TAG GOV.PII_EMAIL = 'EMAIL';
INSERT INTO PUB.T012 SELECT * FROM SRC.CUSTOMER_SRC;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-012|CTAS_RENAMED_COL';
CREATE OR REPLACE TABLE PUB.T012 COPY TAGS AS
SELECT customer_id, email AS email_address, customer_name, premium_amt, cycle_marker
FROM SRC.CUSTOMER_SRC;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-012 tags (expect NO tag on email_address)' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.T012','table'));


/* =====================================================================
   TC-013  CREATE TABLE IF NOT EXISTS ... AS SELECT, table already exists
   NOT DOCUMENTED. Settles option O15.
   Expected: the statement is a no-op — no error, and crucially NO data
             change. If so, O15 would freeze consumers on Day-1 data
             permanently and silently.
   ===================================================================== */
CREATE OR REPLACE TABLE PUB.T013 AS
SELECT * FROM SRC.CUSTOMER_SRC WHERE customer_id < 10;   -- 10 rows, cycle 1

SELECT 'TC-013 before' AS tc, COUNT(*) AS rows_, MAX(cycle_marker) AS cyc FROM PUB.T013;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-013|IF_NOT_EXISTS_CTAS';
CREATE TABLE IF NOT EXISTS PUB.T013 AS
SELECT customer_id, email, customer_name, premium_amt, 2 AS cycle_marker
FROM SRC.CUSTOMER_SRC;                                   -- 1000 rows, cycle 2
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-013 after (expect UNCHANGED: 10 rows, cycle 1)' AS tc,
       COUNT(*) AS rows_, MAX(cycle_marker) AS cyc FROM PUB.T013;
/* Also record: did the statement error, warn, or succeed silently? */


/* =====================================================================
   TC-014  Masked read by the batch identity  (scenario SC-15, §8.1)
   The security question: if the batch identity cannot read clear
   values, physicalization writes MASKED values to disk, violating C5.
   Expected: POC_ROLE (allowed by the policy) writes CLEAR values.
             Then repeat with a role NOT allowed by the policy and
             confirm the masked value is what lands on disk.
   ===================================================================== */
INSERT OVERWRITE INTO STG.CUSTOMER_360
SELECT customer_id, email, customer_name, premium_amt, cycle_marker
FROM PUB.CUSTOMER_360;

SELECT 'TC-014 written by POC_ROLE (expect CLEAR)' AS tc, email
FROM STG.CUSTOMER_360 LIMIT 3;

/* Now the negative case. Run as a role the policy does NOT allow, e.g.
   POC_READER_ROLE, after granting it INSERT + DELETE on STG.CUSTOMER_360.
   The rows it writes will be SHA2 hashes stored as though genuine —
   this is the "at-rest trap" C5 forbids. Capture it as evidence. */


/* =====================================================================
   TC-015  Gate reconciliation query — detects missing AND extra tags
   Implements the §8.2 check. Expected: ZERO rows when governance
   matches the declared baseline.
   ===================================================================== */
CREATE OR REPLACE VIEW CTRL.V_GATE_TAG_DIFF AS
WITH declared AS (
    SELECT UPPER(object_schema) AS object_schema, UPPER(object_name) AS object_name,
           UPPER(column_name)   AS column_name,   UPPER(tag_name)    AS tag_name,
           tag_value
    FROM   GOV.GOVERNANCE_BASELINE
    WHERE  group_name = 'PREMIUM'
),
actual AS (
    SELECT UPPER(object_schema) AS object_schema, UPPER(object_name) AS object_name,
           UPPER(column_name)   AS column_name,   UPPER(tag_name)    AS tag_name,
           tag_value
    FROM   TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.CUSTOMER_360','table'))
)
SELECT 'MISSING_TAG' AS defect, d.* FROM declared d
WHERE NOT EXISTS (SELECT 1 FROM actual a
                  WHERE a.object_schema = d.object_schema AND a.object_name = d.object_name
                    AND a.column_name  = d.column_name   AND a.tag_name    = d.tag_name
                    AND a.tag_value    = d.tag_value)
UNION ALL
SELECT 'EXTRA_TAG'   AS defect, a.* FROM actual a
WHERE NOT EXISTS (SELECT 1 FROM declared d
                  WHERE d.object_schema = a.object_schema AND d.object_name = a.object_name
                    AND d.column_name  = a.column_name   AND d.tag_name    = a.tag_name
                    AND d.tag_value    = a.tag_value);

SELECT 'TC-015 gate diff (expect ZERO rows)' AS tc, * FROM CTRL.V_GATE_TAG_DIFF;

/* Negative case — prove it detects an EXTRA tag (the reinstatement case):
   ALTER TABLE PUB.CUSTOMER_360 MODIFY COLUMN customer_name SET TAG GOV.PII_EMAIL = 'EMAIL';
   SELECT * FROM CTRL.V_GATE_TAG_DIFF;        -- expect one EXTRA_TAG row
   ALTER TABLE PUB.CUSTOMER_360 MODIFY COLUMN customer_name UNSET TAG GOV.PII_EMAIL;

   Negative case — prove it detects a MISSING tag:
   ALTER TABLE PUB.CUSTOMER_360 MODIFY COLUMN email UNSET TAG GOV.PII_EMAIL;
   SELECT * FROM CTRL.V_GATE_TAG_DIFF;        -- expect one MISSING_TAG row
   ALTER TABLE PUB.CUSTOMER_360 MODIFY COLUMN email SET TAG GOV.PII_EMAIL = 'EMAIL';  */


/* =====================================================================
   TC-016  Is stored data actually plaintext under a masking policy?
   ---------------------------------------------------------------------
   This underpins the whole governance argument: if masking were applied
   on WRITE, losing a tag would be harmless, and R15 (no masked value
   persisted as real) would be a non-issue. Everything in Part B assumes
   the opposite — that storage is plaintext and the tag is the only thing
   standing between a consumer and the real value.

   Snowflake does NOT state this outright. It follows by inference from
   the documented enforcement model: masking is a query rewrite applied
   at READ time, so nothing transforms the value on write. Inference is
   not evidence, and third-party blogs are not a source. Prove it.

   Method: unbind the policy from the tag, read the column back, rebind.
   Expected: the real value reads back in the clear once the policy is
             unbound — proving the stored bytes were never masked.
   If instead it reads back masked or NULL, the storage model is not what
   this design assumes and Part B needs rethinking from the ground up.
   ===================================================================== */
SELECT 'TC-016 with policy bound (POC_ROLE sees clear anyway)' AS tc, email
FROM PUB.CUSTOMER_360 ORDER BY customer_id LIMIT 3;

/* Unbind, then read as a role the policy would otherwise mask.
   Run the middle SELECT in a SECOND session as POC_READER_ROLE. */
ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-016|PLAINTEXT_AT_REST';
ALTER TAG GOV.PII_EMAIL UNSET MASKING POLICY GOV.MASK_EMAIL;

-- [SESSION B]  USE ROLE POC_READER_ROLE; USE DATABASE POC_GATING_DB; USE WAREHOUSE POC_WH;
--   SELECT 'TC-016 as READER, policy UNBOUND' AS tc, email
--   FROM PUB.CUSTOMER_360 ORDER BY customer_id LIMIT 3;
--   -- EXPECTED: cust0@example.invalid etc — the REAL value, in the clear.
--   -- That is the proof: the stored bytes were never masked, only the
--   -- read was. Capture this grid; it is the evidence for fact #27.

/* rebind immediately — the window above is exactly the exposure this
   design exists to prevent, so do not leave it open. */
ALTER TAG GOV.PII_EMAIL SET MASKING POLICY GOV.MASK_EMAIL;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-016 policy rebound (confirm before moving on)' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => 'PUB.CUSTOMER_360', REF_ENTITY_DOMAIN => 'TABLE'));


/* =====================================================================
   SUMMARY — timings for this script's statements
   ===================================================================== */
SELECT SPLIT_PART(query_tag,'|',2) AS tc,
       SPLIT_PART(query_tag,'|',3) AS mechanism,
       total_elapsed_time/1000     AS seconds,
       rows_produced, bytes_written
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
        END_TIME_RANGE_START => DATEADD('hour',-2,CURRENT_TIMESTAMP()),
        RESULT_LIMIT => 1000))
WHERE query_tag LIKE 'GATING_POC|TC-0%'
ORDER BY tc;
