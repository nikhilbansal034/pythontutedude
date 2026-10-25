/* =====================================================================
   04 — GATE, ROLLBACK & CONTROL   (TC-034 … TC-039)
   Scenarios SC-07, SC-08, SC-10, SC-11, SC-12
   ---------------------------------------------------------------------
   Question: does the gate actually stop a bad cycle, can the business
   authorise a partial release on the record, can we roll back, and is
   a governance removal ever reinstated by a publish?

   TC-039 is the specific non-reinstatement clause in Part B.
   ===================================================================== */

USE ROLE POC_ROLE; USE DATABASE POC_GATING_DB; USE WAREHOUSE POC_WH;

/* ---------------------------------------------------------------------
   The gate, as a set of checks writing results to CTRL.GATE_RESULT.
   Gate output is DATA, not an exit code — so a failed cycle is
   diagnosable afterwards and an authorisation decision has something
   to reference (solution_design.md §7).
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW CTRL.V_GATE_CHECKS AS
SELECT 'G1' AS check_id, 'All group tables populated' AS check_name,
       CASE WHEN (SELECT COUNT(*) FROM STG.FACT_PREMIUM) > 0
             AND (SELECT COUNT(*) FROM STG.DIM_POLICY)   > 0
             AND (SELECT COUNT(*) FROM STG.DIM_BROKER)   > 0
             AND (SELECT COUNT(*) FROM STG.DIM_DATE)     > 0
            THEN 'PASS' ELSE 'FAIL' END AS status,
       'row counts: ' ||
       (SELECT COUNT(*) FROM STG.FACT_PREMIUM) || '/' ||
       (SELECT COUNT(*) FROM STG.DIM_POLICY)   || '/' ||
       (SELECT COUNT(*) FROM STG.DIM_BROKER)   || '/' ||
       (SELECT COUNT(*) FROM STG.DIM_DATE)     AS detail
UNION ALL
SELECT 'G2', 'Staging group is internally one cycle',
       CASE WHEN (SELECT COUNT(DISTINCT c) FROM (
                    SELECT cycle_marker AS c FROM STG.FACT_PREMIUM
                    UNION ALL SELECT cycle_marker FROM STG.DIM_POLICY
                    UNION ALL SELECT cycle_marker FROM STG.DIM_BROKER
                    UNION ALL SELECT cycle_marker FROM STG.DIM_DATE)) = 1
            THEN 'PASS' ELSE 'FAIL' END,
       'distinct cycles in staging: ' || (SELECT COUNT(DISTINCT c) FROM (
                    SELECT cycle_marker AS c FROM STG.FACT_PREMIUM
                    UNION ALL SELECT cycle_marker FROM STG.DIM_POLICY
                    UNION ALL SELECT cycle_marker FROM STG.DIM_BROKER
                    UNION ALL SELECT cycle_marker FROM STG.DIM_DATE))
UNION ALL
SELECT 'G3', 'Referential integrity: no orphan facts',
       CASE WHEN (SELECT COUNT(*) FROM STG.FACT_PREMIUM f
                  LEFT JOIN STG.DIM_POLICY p ON p.policy_id = f.policy_id
                  WHERE p.policy_id IS NULL) = 0
            THEN 'PASS' ELSE 'FAIL' END,
       'orphan facts: ' || (SELECT COUNT(*) FROM STG.FACT_PREMIUM f
                  LEFT JOIN STG.DIM_POLICY p ON p.policy_id = f.policy_id
                  WHERE p.policy_id IS NULL)
UNION ALL
SELECT 'G4', 'Governance reconciles to declared baseline',
       CASE WHEN (SELECT COUNT(*) FROM CTRL.V_GATE_TAG_DIFF) = 0
            THEN 'PASS' ELSE 'FAIL' END,
       'governance defects: ' || (SELECT COUNT(*) FROM CTRL.V_GATE_TAG_DIFF);


/* =====================================================================
   TC-034  Gate FAIL -> publish NOTHING; consumers keep the previous
           version
   Scenario SC-10. Part A: "a failed cycle publishes nothing."
   Expected: G1 FAILs because one group table is empty; the publish is
             not attempted; PUB is unchanged.
   ===================================================================== */
/* record what consumers currently see */
SELECT 'TC-034 published cycle before' AS tc, MAX(cycle_marker) AS cyc FROM PUB.FACT_PREMIUM;

/* stage a DELIBERATELY INCOMPLETE cycle 10 — DIM_BROKER never loaded */
INSERT OVERWRITE INTO STG.FACT_PREMIUM SELECT premium_id, policy_id, broker_id, amt, 10 FROM SRC.FACT_PREMIUM;
INSERT OVERWRITE INTO STG.DIM_POLICY   SELECT policy_id, policy_no, 10 FROM SRC.DIM_POLICY;
INSERT OVERWRITE INTO STG.DIM_DATE     SELECT date_key, cal_date, 10 FROM SRC.DIM_DATE;
DELETE FROM STG.DIM_BROKER;                        -- the failed job

INSERT INTO CTRL.GATE_RESULT (group_name, cycle_id, check_id, check_name, status, detail)
SELECT 'PREMIUM', 'CYCLE-10', check_id, check_name, status, detail FROM CTRL.V_GATE_CHECKS;

SELECT 'TC-034 gate results (expect at least one FAIL)' AS tc, *
FROM CTRL.GATE_RESULT WHERE cycle_id = 'CYCLE-10' ORDER BY check_id;

/* The publish is gated on this. Do NOT run the transaction. */
SELECT 'TC-034 gate verdict' AS tc,
       CASE WHEN EXISTS (SELECT 1 FROM CTRL.GATE_RESULT
                         WHERE cycle_id='CYCLE-10' AND status='FAIL')
            THEN 'BLOCKED - publish nothing' ELSE 'CLEAR TO PUBLISH' END AS verdict;

INSERT INTO CTRL.PUBLICATION_LOG
  (group_name, cycle_id, published_at, published_by, jobs_expected, jobs_succeeded,
   gate_result, authorisation_ref, previous_cycle_id, mechanism)
SELECT 'PREMIUM','CYCLE-10', NULL, CURRENT_USER(), 4, 3, 'FAIL', NULL, 'CYCLE-07', 'O11';

SELECT 'TC-034 published cycle after (expect UNCHANGED)' AS tc, MAX(cycle_marker) AS cyc FROM PUB.FACT_PREMIUM;


/* =====================================================================
   TC-035  Business-authorised PARTIAL RELEASE, on the record
   Scenario SC-11. The requirement's exceptional path.
   Expected: the authorisation record exists and names who, when, why
             and which jobs failed; the publish then proceeds and is
             logged as AUTHORISED_PARTIAL, not PASS.
   ===================================================================== */
INSERT INTO CTRL.PARTIAL_RELEASE_AUTH (group_name, cycle_id, authorised_by, authorised_at, reason, failed_jobs)
SELECT 'PREMIUM','CYCLE-10','<business approver name>', CURRENT_TIMESTAMP(),
       'Month-end reporting deadline; broker dimension unchanged since prior cycle',
       'LOAD_DIM_BROKER';

/* Carry forward the unchanged object rather than publishing an empty one.
   This is the "carry forward" step of the cycle (solution_design.md §5.4). */
INSERT OVERWRITE INTO STG.DIM_BROKER SELECT * FROM PUB.DIM_BROKER;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-035|AUTHORISED_PARTIAL';
BEGIN;
  INSERT OVERWRITE INTO PUB.FACT_PREMIUM SELECT * FROM STG.FACT_PREMIUM;
  INSERT OVERWRITE INTO PUB.DIM_POLICY   SELECT * FROM STG.DIM_POLICY;
  INSERT OVERWRITE INTO PUB.DIM_BROKER   SELECT * FROM STG.DIM_BROKER;
  INSERT OVERWRITE INTO PUB.DIM_DATE     SELECT * FROM STG.DIM_DATE;
COMMIT;
ALTER SESSION UNSET QUERY_TAG;

INSERT INTO CTRL.PUBLICATION_LOG
  (group_name, cycle_id, published_at, published_by, jobs_expected, jobs_succeeded,
   gate_result, authorisation_ref, previous_cycle_id, mechanism)
SELECT 'PREMIUM','CYCLE-10', CURRENT_TIMESTAMP(), CURRENT_USER(), 4, 3,
       'AUTHORISED_PARTIAL', 'AUTH-CYCLE-10', 'CYCLE-07', 'O11';

SELECT 'TC-035 authorisation record' AS tc, * FROM CTRL.PARTIAL_RELEASE_AUTH WHERE cycle_id='CYCLE-10';
SELECT 'TC-035 publication log' AS tc, * FROM CTRL.PUBLICATION_LOG WHERE cycle_id='CYCLE-10';
SELECT 'TC-035 what consumers see now' AS tc,
       (SELECT MAX(cycle_marker) FROM PUB.FACT_PREMIUM) AS fact_cycle,
       (SELECT MAX(cycle_marker) FROM PUB.DIM_BROKER)   AS broker_cycle;
/* NOTE: broker_cycle legitimately differs — it is the carried-forward
   prior version. Record this: a partial release means the group is
   deliberately NOT all one cycle, and that must be visible in the log. */


/* =====================================================================
   TC-038  Publication record is written and queryable (alerting basis)
   Expected: one row per group per cycle, and a stale-data query that
             Ops can alert on.
   ===================================================================== */
SELECT 'TC-038 log' AS tc, * FROM CTRL.PUBLICATION_LOG ORDER BY cycle_id;

SELECT 'TC-038 staleness (the Ops alert)' AS tc,
       group_name,
       MAX(published_at) AS last_successful_publish,
       DATEDIFF('minute', MAX(published_at), CURRENT_TIMESTAMP()) AS minutes_stale
FROM CTRL.PUBLICATION_LOG
WHERE gate_result IN ('PASS','AUTHORISED_PARTIAL') AND published_at IS NOT NULL
GROUP BY group_name;


/* =====================================================================
   TC-036  ROLLBACK via re-swap (option O16)
   Scenario SC-12. Expected: one further ALTER SCHEMA SWAP WITH returns
             consumers to the previous version.
   ===================================================================== */
SELECT 'TC-036 PUB before rollback' AS tc, MAX(cycle_marker) AS cyc FROM PUB.FACT_PREMIUM;
SELECT 'TC-036 STG before rollback' AS tc, MAX(cycle_marker) AS cyc FROM STG.FACT_PREMIUM;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-036|ROLLBACK_RESWAP';
ALTER SCHEMA PUB SWAP WITH STG;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-036 PUB after rollback' AS tc, MAX(cycle_marker) AS cyc FROM PUB.FACT_PREMIUM;
/* roll forward again so later scripts start from the newer cycle */
ALTER SCHEMA PUB SWAP WITH STG;


/* =====================================================================
   TC-037  ROLLBACK via re-publish from the retained previous version
           (option O11 — there is no name to swap back)
   Expected: the retained prior version is still in staging, so one more
             transaction restores it. Note the rollback window closes as
             soon as the next cycle overwrites staging.
   ===================================================================== */
SELECT 'TC-037 retained prior version in STG' AS tc, MAX(cycle_marker) AS cyc FROM STG.FACT_PREMIUM;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-037|ROLLBACK_REPUBLISH';
BEGIN;
  INSERT OVERWRITE INTO PUB.FACT_PREMIUM SELECT * FROM STG.FACT_PREMIUM;
  INSERT OVERWRITE INTO PUB.DIM_POLICY   SELECT * FROM STG.DIM_POLICY;
  INSERT OVERWRITE INTO PUB.DIM_BROKER   SELECT * FROM STG.DIM_BROKER;
  INSERT OVERWRITE INTO PUB.DIM_DATE     SELECT * FROM STG.DIM_DATE;
COMMIT;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-037 PUB after rollback' AS tc, * FROM CONSUME.V_GROUP_CONSISTENCY;


/* =====================================================================
   TC-039  *** Part B *** NON-REINSTATEMENT
   Governance removes a tag mid-cycle. A publish must NOT bring it back.
   Scenario SC-08.
   ---------------------------------------------------------------------
   Expected, per mechanism:
     O10 INSERT OVERWRITE : tag stays REMOVED (the object is never
                            recreated, so there is nothing to restore)
     O16 SCHEMA SWAP      : the staging copy still carries the tag, so
                            the swap REINSTATES it unless the gate
                            reconciled staging first  <-- the defect
   This test is what proves the gate's governance step is mandatory and
   not optional.
   ===================================================================== */
/* start from a governed state.
   Binding a tag to a PUBLISHED table needs OWNERSHIP on it, which now
   sits with the deploy role — correctly, since this is a governance
   act, not a refresh. STG is the batch role's working area, so that
   half needs no switch. */
USE ROLE POC_DEPLOY_ROLE;
ALTER TABLE PUB.CUSTOMER_360 MODIFY COLUMN email SET TAG GOV.PII_EMAIL = 'EMAIL';
USE ROLE POC_ROLE;
ALTER TABLE STG.CUSTOMER_360 MODIFY COLUMN email SET TAG GOV.PII_EMAIL = 'EMAIL';

SELECT 'TC-039 tags before' AS tc, 'PUB' AS half, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.CUSTOMER_360','table'));

/* ---- governance makes a deliberate removal, mid-cycle ----
   Governance acts as the deploy role; the batch identity never gets to
   change what is protected. That separation is the point of TC-039. */
USE ROLE POC_DEPLOY_ROLE;
ALTER TABLE PUB.CUSTOMER_360 MODIFY COLUMN email UNSET TAG GOV.PII_EMAIL;
USE ROLE POC_ROLE;
DELETE FROM GOV.GOVERNANCE_BASELINE
WHERE group_name='PREMIUM' AND object_name='CUSTOMER_360' AND column_name='EMAIL';

SELECT 'TC-039 after governance removal (expect ZERO tag rows on PUB)' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.CUSTOMER_360','table'));

/* ---- part A: publish via O10. Tag must stay removed. ---- */
INSERT OVERWRITE INTO STG.CUSTOMER_360
SELECT customer_id, email, customer_name, premium_amt, 11 FROM SRC.CUSTOMER_SRC;

ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-039a|NONREINSTATE_O10';
INSERT OVERWRITE INTO PUB.CUSTOMER_360 SELECT * FROM STG.CUSTOMER_360;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-039a after O10 publish (expect STILL ZERO tag rows)' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.CUSTOMER_360','table'));

/* ---- part B: the gate must catch that STAGING still carries it ---- */
SELECT 'TC-039b staging still tagged? (expect 1 row = the hazard)' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('STG.CUSTOMER_360','table'));

/* The gate's EXTRA_TAG arm must fire against staging. Expected: 1 row. */
WITH declared AS (
    SELECT UPPER(column_name) AS column_name, UPPER(tag_name) AS tag_name, tag_value
    FROM GOV.GOVERNANCE_BASELINE
    WHERE group_name='PREMIUM' AND UPPER(object_name)='CUSTOMER_360'
),
actual AS (
    SELECT UPPER(column_name) AS column_name, UPPER(tag_name) AS tag_name, tag_value
    FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('STG.CUSTOMER_360','table'))
)
SELECT 'TC-039b gate on staging (expect EXTRA_TAG)' AS tc, 'EXTRA_TAG' AS defect, a.*
FROM actual a
WHERE NOT EXISTS (SELECT 1 FROM declared d
                  WHERE d.column_name=a.column_name AND d.tag_name=a.tag_name);

/* ---- part C: publish via O16 WITHOUT reconciling. Tag comes back. ---- */
ALTER SESSION SET QUERY_TAG = 'GATING_POC|TC-039c|NONREINSTATE_O16';
ALTER SCHEMA PUB SWAP WITH STG;
ALTER SESSION UNSET QUERY_TAG;

SELECT 'TC-039c after O16 swap (expect tag REINSTATED = the defect)' AS tc, *
FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('PUB.CUSTOMER_360','table'));
/* If a tag row appears here, option O16 CANNOT satisfy Part B without a
   mandatory gate step that reconciles staging before the swap. Capture
   this grid — it is the justification for gate check G4. */

/* restore */
ALTER SCHEMA PUB SWAP WITH STG;
INSERT INTO GOV.GOVERNANCE_BASELINE
  (group_name, object_schema, object_name, column_name, tag_database, tag_schema, tag_name, tag_value)
SELECT 'PREMIUM','PUB','CUSTOMER_360','EMAIL',CURRENT_DATABASE(),'GOV','PII_EMAIL','EMAIL';
USE ROLE POC_DEPLOY_ROLE;
ALTER TABLE PUB.CUSTOMER_360 MODIFY COLUMN email SET TAG GOV.PII_EMAIL = 'EMAIL';
USE ROLE POC_ROLE;


/* =====================================================================
   SUMMARY
   ===================================================================== */
SELECT 'gate results' AS section, * FROM CTRL.GATE_RESULT ORDER BY cycle_id, check_id;
SELECT 'publication log' AS section, * FROM CTRL.PUBLICATION_LOG ORDER BY cycle_id;
