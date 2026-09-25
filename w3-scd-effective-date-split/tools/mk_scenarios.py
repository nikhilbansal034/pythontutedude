#!/usr/bin/env python3
"""Emits poc_v2/scenarios/S*.sql — one file per scenario, chained runs inside.

Structure is identical everywhere: ONE reset, then each test case is the NEXT
RUN against whatever the previous one left. The apply MERGE is lifted verbatim
from 00_objects.sql so every copy stays byte-identical (check_merge_drift.py).
"""
import os, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "poc_v2")

def canonical_merge():
    src = open(os.path.join(ROOT, "00_objects.sql")).read()
    i = src.index("MERGE INTO Z2_BROKER_PARTY_DIM T")
    j = src.index("CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());", i) + len("CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());")
    return src[i:j].rstrip()

MERGE = canonical_merge()

# three runs a day: 08:00, 12:00, 16:00
def schedule(n):
    """n-th run (0-based) -> (label, run_id, window_start, window_end)"""
    days  = ["2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25"]
    times = ["08:00", "12:00", "16:00"]
    d, t = divmod(n, 3)
    label = f"D{d+1}R{t+1}"
    end   = f"{days[d]} {times[t]}"
    if n == 0: start = "2026-09-01 00:00"
    else:
        pd, pt = divmod(n-1, 3)
        start = f"{days[pd]} {times[pt]}"
    return label, 101 + n, start, end

def tc_block(scen, idx, run_idx, kind, title, what, expect, changes, conds, rerun_of=None,
             exec_type='NEW', job_status='Completed'):
    label, run_id, w0, w1 = schedule(run_idx)
    if rerun_of is not None:                       # a re-run repeats an earlier window
        _, _, w0, w1 = schedule(rerun_of)
    lines = []
    for i, c in enumerate(conds):
        comment, sql = c if isinstance(c, tuple) else (None, c)
        if comment:
            lines += [f"            -- {ln}" for ln in comment.split("\n")]
        lines.append(f"       {'CASE WHEN' if i == 0 else '            AND'} {sql}")
    assertion = "\n".join(lines)
    s = f"""

-- ###########################################################################
-- TC{idx:02d}  ({label})  |  {kind}  |  {title}
--
-- WHAT   {what}
-- EXPECT {expect}
-- ###########################################################################

INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 ({run_id},1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  TIMESTAMP '{w0}', TIMESTAMP '{w1}','{exec_type}','{job_status}'),
 ({run_id},1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  TIMESTAMP '{w0}', TIMESTAMP '{w1}','{exec_type}','{job_status}');
"""
    s += ("\n-- ---- what Zone1 did between the last run and this one -------------------"
          + changes + "\n") if changes else \
         "\n-- ---- NO source change. This run re-reads the same window ----------------\n"
    s += f"""
SELECT '{scen} TC{idx:02d} {label} — SRC_1' AS EVIDENCE, BROKER_ID, BROKER_STATUS_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_PARTY_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT '{scen} TC{idx:02d} {label} — SRC_2' AS EVIDENCE, BROKER_ID, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE, GRS_REFINED_TIMESTAMP
FROM   Z1_BROKER_COMMISSION_HIST ORDER BY BROKER_ID, ROW_EFF_DTE;

-- ---- STEP 1 : build the stage --------------------------------------------
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

SELECT '{scen} TC{idx:02d} {label} — stage' AS EVIDENCE, RULE_NO, ACTION_FLAG, DEL_IND,
       BROKER_PARTY_DIM_SK, BROKER_ID, BROKER_STATUS_CDE, COMMISSION_TIER_CDE,
       ROW_EFF_DTE, ROW_EXP_DTE
FROM   STG_Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, ACTION_FLAG;

-- ---- STEP 2 : apply, one atomic MERGE ------------------------------------
{MERGE}

-- ---- verify ---------------------------------------------------------------
SELECT '{scen} TC{idx:02d} {label} — target AFTER' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE, IS_DEL, AUDIT_BATCH_ID
FROM   Z2_BROKER_PARTY_DIM ORDER BY BROKER_ID, ROW_EFF_DTE, BROKER_PARTY_DIM_SK;

SELECT '{scen} TC{idx:02d} {label} — live view' AS EVIDENCE, BROKER_PARTY_DIM_SK, BROKER_ID,
       BROKER_STATUS_CDE, COMMISSION_TIER_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   V_Z2_BROKER_PARTY_DIM_LIVE ORDER BY BROKER_ID, ROW_EFF_DTE;

SELECT '{scen} TC{idx:02d} {label}' AS TEST,
{assertion}
       THEN 'PASS' ELSE 'FAIL' END AS RESULT;
"""
    return s

def header(scen, title, blurb, tcs, extra=""):
    rows = []
    for i, t in enumerate(tcs, 1):
        label, run_id, w0, w1 = schedule(t["run_idx"])
        if t.get("rerun_of") is not None:
            _, _, w0, w1 = schedule(t["rerun_of"])
            note = "  (re-run)"
        else:
            note = ""
        rows.append(f"--   TC{i:02d}  {label}  run {run_id}   window  {w0} -> {w1}{note}")
    sched = "\n".join(rows)
    return f"""-- ===========================================================================
-- POC v2  —  {scen}  |  {title}
--
{blurb}
--
-- HOW THIS SCENARIO IS STRUCTURED
--
-- The target is NEVER hand-seeded. TC01 loads an empty target through the real
-- pipeline, and every later test case is the NEXT RUN against whatever the
-- previous one left behind -- which is what a real ETL schedule does, and the
-- only way to test that older rows stay untouched.
--
-- There is ONE reset, at the top of this file. Test cases do not reset. They
-- must therefore be run IN ORDER, top to bottom; each is still a self-contained
-- section to execute and screenshot. Scenarios are independent of each other.
--
-- TWO CLOCKS:
--   BUSINESS TIME  ROW_EFF_DTE / ROW_EXP_DTE -- when the fact was true
--   PROCESS TIME   GRS_REFINED_TIMESTAMP, windows, AUDIT_* -- when it was loaded
--
-- Windows are half-open: GRS_REFINED_TIMESTAMP > WINDOW_START AND <= WINDOW_END.
-- Three runs a day, 08:00 / 12:00 / 16:00.
--
{sched}
--
-- Rules exercised : see ../TEST_PLAN.md
-- Prerequisite    : ../00_objects.sql has been run
-- ==========================================================================={extra}

USE ROLE      POC_ROLE;
USE WAREHOUSE POC_WH;
USE DATABASE  LM_POC_DB;
USE SCHEMA    POC_SCHEMA;


-- ###########################################################################
-- RESET -- the ONLY one in this file. Everything after this accumulates.
-- The surrogate-key sequence is deliberately NOT reset: production never
-- reuses a key, so neither do we. See ../TEST_PLAN.md.
-- ###########################################################################
TRUNCATE TABLE ETL_DATA_INGESTION_SOURCE_WINDOW;
TRUNCATE TABLE Z1_BROKER_PARTY_HIST;
TRUNCATE TABLE Z1_BROKER_COMMISSION_HIST;
TRUNCATE TABLE Z2_BROKER_PARTY_DIM;
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
"""

def build(scen, spec):
    out = [header(scen, spec["title"], spec["blurb"], spec["tcs"], spec.get("extra",""))]
    for i, t in enumerate(spec["tcs"], 1):
        out.append(tc_block(scen, i, t["run_idx"], t["kind"], t["title"], t["what"],
                            t["expect"], t.get("changes"), t["conds"], t.get("rerun_of"),
                            t.get("exec_type","NEW"), t.get("job_status","Completed")))
    path = os.path.join(ROOT, "scenarios", f"{scen}.sql")
    open(path, "w").write("".join(out))
    return path


def step1_view(hash_expr=None):
    """The Step 1 view, lifted from 00_objects.sql, optionally with a DIFFERENT
    hash expression. Used by S14 to simulate a hash-definition change -- the
    only honest way to test one, since the hash lives in the view."""
    src = open(os.path.join(ROOT, "00_objects.sql")).read()
    i = src.index("CREATE OR REPLACE VIEW V_STEP1_BROKER_PARTY_DIM_DIFF AS")
    j = src.index("\n", src.index("WHERE  c.RULE_NO = 17", i))
    view = src[i:j].rstrip().rstrip(";") + ";"
    if hash_expr:
        old = "SHA2(COALESCE(a.VAL,'~') || '|' || COALESCE(b.VAL,'~'), 256) AS ROW_HASH"
        assert old in view, "hash expression moved -- update step1_view()"
        view = view.replace(old, hash_expr + " AS ROW_HASH")
    return view

# shorthand for the counts every assertion needs
STG   = "(SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM)"
TGT   = "(SELECT count(*) FROM Z2_BROKER_PARTY_DIM)"
LIVE  = "(SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE)"
def RULE(n): return f"(SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE RULE_NO = {n})"
def FLAG(f): return f"(SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE ACTION_FLAG = '{f}')"
def TGTQ(w): return f"(SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE {w})"
def LIVEQ(w): return f"(SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE WHERE {w})"
def BATCH(n): return f"(SELECT count(*) FROM Z2_BROKER_PARTY_DIM WHERE AUDIT_BATCH_ID = {n})"

if __name__ == "__main__":
    from scenario_specs import SPECS
    only = sys.argv[1:] or sorted(SPECS)
    for scen in only:
        print(f"  wrote {build(scen, SPECS[scen])}")
