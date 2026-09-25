"""Per-scenario data for mk_scenarios.py.

Each test case says what Zone1 did since the last run, and what the target must
look like afterwards. Expected counts are stated by hand -- derived from the 18
rules -- never read back from a run, or the assertion would pass on a bug.
"""
from mk_scenarios import STG, TGT, LIVE, RULE, FLAG, TGTQ, LIVEQ, BATCH

# GRS timestamp for run n -- the window END of that run
_G = ["2026-09-21 08:00","2026-09-21 12:00","2026-09-21 16:00",
      "2026-09-22 08:00","2026-09-22 12:00","2026-09-22 16:00",
      "2026-09-23 08:00","2026-09-23 12:00","2026-09-23 16:00"]
def G(n): return _G[n]

def _ins(table, col, rows, n):
    """INSERT .. SELECT .. UNION ALL -- never VALUES, Snowflake rejects functions there."""
    parts = []
    for i,(k,v,eff,exp,uid) in enumerate(rows):
        kw = "SELECT    " if i == 0 else "UNION ALL SELECT "
        ks = "NULL" if k is None else f"'{k}'"
        vs = "NULL" if v is None else f"'{v}'"
        parts.append(f"{kw}{ks},{vs},NULL,DATE '{eff}',DATE '{exp}','{uid}',TIMESTAMP '{G(n)}'")
    return f"\nINSERT INTO {table}\n" + "\n".join(parts) + ";"

def P_INS(rows, n): return _ins("Z1_BROKER_PARTY_HIST", "BROKER_STATUS_CDE", rows, n)
def C_INS(rows, n): return _ins("Z1_BROKER_COMMISSION_HIST", "COMMISSION_TIER_CDE", rows, n)

def _close(table, key, eff, new_exp, n):
    return (f"\nUPDATE {table}\nSET    ROW_EXP_DTE = DATE '{new_exp}', "
            f"GRS_REFINED_TIMESTAMP = TIMESTAMP '{G(n)}'\n"
            f"WHERE  BROKER_ID = '{key}' AND ROW_EFF_DTE = DATE '{eff}';")
def P_CLOSE(key, eff, exp, n): return _close("Z1_BROKER_PARTY_HIST", key, eff, exp, n)
def C_CLOSE(key, eff, exp, n): return _close("Z1_BROKER_COMMISSION_HIST", key, eff, exp, n)

def _restate(table, col, key, eff, val, n):
    v = "NULL" if val is None else f"'{val}'"
    return (f"\nUPDATE {table}\nSET    {col} = {v}, "
            f"GRS_REFINED_TIMESTAMP = TIMESTAMP '{G(n)}'\n"
            f"WHERE  BROKER_ID = '{key}' AND ROW_EFF_DTE = DATE '{eff}';")
def P_SET(key, eff, val, n): return _restate("Z1_BROKER_PARTY_HIST","BROKER_STATUS_CDE",key,eff,val,n)
def C_SET(key, eff, val, n): return _restate("Z1_BROKER_COMMISSION_HIST","COMMISSION_TIER_CDE",key,eff,val,n)

def NOTE(table, key, eff, txt, n):
    return (f"\nUPDATE {table}\nSET    NOTE_TEXT = '{txt}', "
            f"GRS_REFINED_TIMESTAMP = TIMESTAMP '{G(n)}'\n"
            f"WHERE  BROKER_ID = '{key}' AND ROW_EFF_DTE = DATE '{eff}';")

def IDEMPOTENT(tgt, live, run_id):
    return [f"{STG}  = 0", f"{TGT} = {tgt}", f"{LIVE} = {live}", f"{BATCH(run_id)} = 0"]

SPECS = {}

# ===========================================================================
SPECS["S01"] = {
 "title": "One source changes, the other does not",
 "blurb": ("-- The core problem in one picture: SRC_1 is not touched at all, yet its target\n"
           "-- rows still have to move, because neither source can decide the target's\n"
           "-- dates alone."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"initial load into an empty target",
   "what":"Zone1's first delivery. SRC_2 holds ONE version covering the whole period.",
   "expect":"3 stage rows, all rule 17. Target 0 -> 3.",
   "changes": P_INS([("K1","A1","2026-08-10","2026-08-21","U-001"),
                     ("K1","A2","2026-08-21","9999-12-31","U-002")],0)
            + C_INS([("K1","B1","2026-08-09","9999-12-31","U-101")],0),
   "conds":[f"{STG}  = 3", f"{RULE(17)} = 3", f"{TGT} = 3", f"{LIVE} = 3", f"{BATCH(101)} = 3"]},

  {"run_idx":1,"kind":"POSITIVE","title":"SRC_2 splits one version into three",
   "what":"Zone1 closes B1 early and adds B2, B3. SRC_1 is NOT touched -- its timestamps stay at D1R1.",
   "expect":"6 stage rows: rules 3, 7, 13, 17. Target 3 -> 7, live 5.",
   "changes": C_CLOSE("K1","2026-08-09","2026-08-15",1)
            + C_INS([("K1","B2","2026-08-15","2026-08-22","U-102"),
                     ("K1","B3","2026-08-22","9999-12-31","U-103")],1),
   "conds":[f"{STG}  = 6", f"{FLAG('D')} = 2", f"{FLAG('I')} = 4",
            f"{TGT} = 7", f"{LIVE} = 5",
            ("retired by DELETE INDICATOR: its expiry was a real date",
             TGTQ("ROW_EFF_DTE = DATE '2026-08-10' AND IS_DEL = 'Y'\n                      AND ROW_EXP_DTE = DATE '2026-08-21'") + " = 1"),
            ("retired as a DEAD RECORD: its expiry was the high end date",
             TGTQ("ROW_EFF_DTE = DATE '2026-08-21' AND IS_DEL = 'N'\n                      AND ROW_EXP_DTE = DATE '2026-08-21'") + " = 1"),
            ("OLDER ROW UNTOUCHED: still run 101's, still live, dates unchanged",
             TGTQ("AUDIT_BATCH_ID = 101 AND ROW_EFF_DTE = DATE '2026-08-09'\n                      AND ROW_EXP_DTE = DATE '2026-08-10' AND IS_DEL = 'N'") + " = 1")]},

  {"run_idx":2,"rerun_of":1,"kind":"IDEMPOTENT","title":"re-run of the same window, nothing changed",
   "what":"Same window as D1R2, so K1 is STILL impacted and the diff really does look at it.",
   "expect":"0 stage rows. MERGE writes nothing.",
   "changes":None, "conds":IDEMPOTENT(7,5,103)},

  {"run_idx":3,"kind":"EDGE","title":"SRC_2 splits on a boundary SRC_1 already uses",
   "what":"B2 is split at 2026-08-21 -- the date SRC_1 already changes on -- so NO new interval appears.",
   "expect":"2 stage rows, rule 11. Target 7 -> 8, live stays 5.",
   "changes": C_CLOSE("K1","2026-08-15","2026-08-21",3)
            + C_INS([("K1","B9","2026-08-21","2026-08-22","U-104")],3),
   "conds":[f"{STG}  = 2", f"{RULE(11)} = 2", f"{TGT} = 8", f"{LIVE} = 5",
            LIVEQ("ROW_EFF_DTE = DATE '2026-08-21' AND COMMISSION_TIER_CDE = 'B9'") + " = 1",
            ("OLDER ROWS UNTOUCHED",
             TGTQ("AUDIT_BATCH_ID = 101 AND ROW_EFF_DTE = DATE '2026-08-09'\n                      AND ROW_EXP_DTE = DATE '2026-08-10' AND IS_DEL = 'N'") + " = 1"),
            TGTQ("AUDIT_BATCH_ID = 102 AND IS_DEL = 'N'\n                      AND ROW_EFF_DTE IN (DATE '2026-08-10', DATE '2026-08-15', DATE '2026-08-22')") + " = 3"]},

  {"run_idx":4,"kind":"EDGE","title":"a value corrected in place, dates unchanged",
   "what":"Zone1 restates B3 as B7 over the SAME interval. Hash changes, both dates stay, target sits at 9999.",
   "expect":"2 stage rows, rule 9 -- dead record plus insert. Target 8 -> 9.",
   "changes": C_SET("K1","2026-08-22","B7",4),
   "conds":[f"{STG}  = 2", f"{RULE(9)} = 2", f"{TGT} = 9", f"{LIVE} = 5",
            ("the replaced row became a DEAD RECORD, not a delete indicator",
             TGTQ("ROW_EFF_DTE = DATE '2026-08-22' AND ROW_EXP_DTE = DATE '2026-08-22'\n                      AND IS_DEL = 'N'") + " = 1"),
            LIVEQ("ROW_EFF_DTE = DATE '2026-08-22' AND COMMISSION_TIER_CDE = 'B7'") + " = 1",
            TGTQ("AUDIT_BATCH_ID = 101 AND ROW_EFF_DTE = DATE '2026-08-09'\n                      AND ROW_EXP_DTE = DATE '2026-08-10' AND IS_DEL = 'N'") + " = 1"]},

  {"run_idx":5,"kind":"CORRUPT","title":"a NULL business key arrives",
   "what":"Zone1 delivers a row with no BROKER_ID. Nothing else changes in this window.",
   "expect":"Dropped SILENTLY -- 0 stage rows, MERGE writes nothing, target stays 9.",
   "changes": C_INS([(None,"BX","2026-08-10","9999-12-31","U-999")],5),
   "conds":[f"{STG}  = 0", f"{TGT} = 9", f"{LIVE} = 5",
            TGTQ("BROKER_ID IS NULL") + " = 0", f"{BATCH(106)} = 0"]},

  {"run_idx":6,"kind":"POSITIVE","title":"a new version arrives ahead of the open row",
   "what":"B7 is closed at 2026-08-25 and B8 takes over. The open row's VALUES do not change -- only its expiry.",
   "expect":"2 stage rows: rule 5 (expire in place) and 17. The surrogate key SURVIVES. Target 9 -> 10, live 6.",
   "changes": C_CLOSE("K1","2026-08-22","2026-08-25",6)
            + C_INS([("K1","B8","2026-08-25","9999-12-31","U-107")],6),
   "conds":[f"{STG}  = 2", f"{FLAG('U')} = 1", f"{RULE(5)} = 1", f"{RULE(17)} = 1",
            f"{TGT} = 10", f"{LIVE} = 6",
            ("EXPIRED IN PLACE: one LIVE row at 08-22, still run 105's, only the\nexpiry moved. The table also holds TC05's DEAD RECORD at that date\n(eff = exp), so a base-table count would find 2 and say nothing.",
             LIVEQ("ROW_EFF_DTE = DATE '2026-08-22'") + " = 1"),
            TGTQ("ROW_EFF_DTE = DATE '2026-08-22' AND ROW_EXP_DTE = DATE '2026-08-25'\n"
                 "                      AND IS_DEL = 'N' AND COMMISSION_TIER_CDE = 'B7'\n"
                 "                      AND AUDIT_BATCH_ID = 105") + " = 1",
            ("and NOTHING was retired by this run",
             TGTQ("ROW_EFF_DTE = DATE '2026-08-22' AND IS_DEL = 'Y'") + " = 0")]},
 ]}

# ===========================================================================
SPECS["S02"] = {
 "title": "Both sources change in the same run",
 "blurb": ("-- Neither source alone can decide the target's dates, and here both move at\n"
           "-- once. The rebuilt timeline has to take boundaries from both."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"initial load into an empty target",
   "what":"One version in each source, covering the same period.",
   "expect":"1 stage row, rule 17. Target 0 -> 1.",
   "changes": P_INS([("K1","A1","2026-08-10","9999-12-31","U-001")],0)
            + C_INS([("K1","B1","2026-08-10","9999-12-31","U-101")],0),
   "conds":[f"{STG}  = 1", f"{RULE(17)} = 1", f"{TGT} = 1", f"{LIVE} = 1"]},

  {"run_idx":1,"kind":"POSITIVE","title":"both sources split in the same run",
   "what":"SRC_1 changes at 08-20 and SRC_2 at 08-25. The target row sat at the high end date.",
   "expect":"3 stage rows: rule 5 (expire in place) + two rule 17. Target 1 -> 3, live 3.",
   "changes": P_CLOSE("K1","2026-08-10","2026-08-20",1)
            + P_INS([("K1","A2","2026-08-20","9999-12-31","U-002")],1)
            + C_CLOSE("K1","2026-08-10","2026-08-25",1)
            + C_INS([("K1","B2","2026-08-25","9999-12-31","U-102")],1),
   "conds":[f"{STG}  = 3", f"{RULE(5)} = 1", f"{RULE(17)} = 2", f"{FLAG('U')} = 1",
            f"{TGT} = 3", f"{LIVE} = 3",
            ("the original row EXPIRED IN PLACE -- no retire, key survives",
             TGTQ("ROW_EFF_DTE = DATE '2026-08-10' AND ROW_EXP_DTE = DATE '2026-08-20'\n"
                  "                      AND IS_DEL = 'N' AND AUDIT_BATCH_ID = 101") + " = 1"),
            ("a boundary from EACH source is present",
             LIVEQ("ROW_EFF_DTE = DATE '2026-08-20'") + " = 1"),
            LIVEQ("ROW_EFF_DTE = DATE '2026-08-25'") + " = 1"]},

  {"run_idx":2,"rerun_of":1,"kind":"IDEMPOTENT","title":"re-run of the same window",
   "what":"Both keys still impacted, nothing changed.","expect":"0 stage rows.",
   "changes":None, "conds":IDEMPOTENT(3,3,103)},

  {"run_idx":3,"kind":"EDGE","title":"both sources close on the SAME date",
   "what":"SRC_1 and SRC_2 both change at 2026-08-30, so the two boundaries coincide.",
   "expect":"2 stage rows: rule 5 + rule 17. One new interval, not two. Target 3 -> 4, live 4.",
   "changes": P_CLOSE("K1","2026-08-20","2026-08-30",3)
            + P_INS([("K1","A3","2026-08-30","9999-12-31","U-003")],3)
            + C_CLOSE("K1","2026-08-25","2026-08-30",3)
            + C_INS([("K1","B3","2026-08-30","9999-12-31","U-103")],3),
   "conds":[f"{STG}  = 2", f"{RULE(5)} = 1", f"{RULE(17)} = 1", f"{TGT} = 4", f"{LIVE} = 4",
            ("ONE interval starts at 08-30, not one per source",
             LIVEQ("ROW_EFF_DTE = DATE '2026-08-30'") + " = 1"),
            LIVEQ("ROW_EFF_DTE = DATE '2026-08-30' AND BROKER_STATUS_CDE = 'A3'\n"
                  "                      AND COMMISSION_TIER_CDE = 'B3'") + " = 1",
            ("OLDER ROWS UNTOUCHED", TGTQ("AUDIT_BATCH_ID = 101") + " = 1")]},
 ]}

# ===========================================================================
SPECS["S03"] = {
 "title": "A change in a column the target never carries",
 "blurb": ("-- NOTE_TEXT exists in both Zone1 tables and reaches neither the hash nor the\n"
           "-- target. A run that only touches it must impact the key, read it, and then\n"
           "-- write NOTHING."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"initial load into an empty target",
   "what":"One version in each source.","expect":"1 stage row, rule 17. Target 0 -> 1.",
   "changes": P_INS([("K1","A1","2026-08-10","9999-12-31","U-001")],0)
            + C_INS([("K1","B1","2026-08-10","9999-12-31","U-101")],0),
   "conds":[f"{STG}  = 1", f"{TGT} = 1", f"{LIVE} = 1"]},

  {"run_idx":1,"kind":"NEGATIVE","title":"only NOTE_TEXT changes",
   "what":"Zone1 restates a column the target never carries. GRS moves, so K1 IS impacted and IS read.",
   "expect":"0 stage rows, 0 written. Reading a key is not the same as changing it.",
   "changes": NOTE("Z1_BROKER_COMMISSION_HIST","K1","2026-08-10","commission recalculated",1),
   "conds":[f"{STG}  = 0", f"{TGT} = 1", f"{LIVE} = 1", f"{BATCH(102)} = 0",
            ("the row still carries run 101's batch id -- nothing rewrote it",
             TGTQ("AUDIT_BATCH_ID = 101 AND ROW_EXP_DTE = DATE '9999-12-31'") + " = 1")]},

  {"run_idx":2,"kind":"POSITIVE","title":"a real split, so there are several versions to test against",
   "what":"SRC_2 splits into three. This is setup for TC04, and a rule 5 + 17 case in its own right.",
   "expect":"3 stage rows. Target 1 -> 3, live 3.",
   "changes": C_CLOSE("K1","2026-08-10","2026-08-20",2)
            + C_INS([("K1","B2","2026-08-20","2026-08-25","U-102"),
                     ("K1","B3","2026-08-25","9999-12-31","U-103")],2),
   "conds":[f"{STG}  = 3", f"{RULE(5)} = 1", f"{RULE(17)} = 2", f"{TGT} = 3", f"{LIVE} = 3"]},

  {"run_idx":3,"kind":"NEGATIVE","title":"NOTE_TEXT changes on EVERY version at once",
   "what":"All three SRC_2 versions get a new note in the same run.",
   "expect":"Still 0 stage rows. The target is untouched however many rows carry the change.",
   "changes": NOTE("Z1_BROKER_COMMISSION_HIST","K1","2026-08-10","bulk restated",3)
            + NOTE("Z1_BROKER_COMMISSION_HIST","K1","2026-08-20","bulk restated",3)
            + NOTE("Z1_BROKER_COMMISSION_HIST","K1","2026-08-25","bulk restated",3),
   "conds":[f"{STG}  = 0", f"{TGT} = 3", f"{LIVE} = 3", f"{BATCH(104)} = 0",
            ("every target row still belongs to the run that created it",
             TGTQ("AUDIT_BATCH_ID IN (101, 103)") + " = 3")]},
 ]}

# ===========================================================================
SPECS["S04"] = {
 "title": "A value comes back after a different one",
 "blurb": ("-- A1 -> A2 -> A1. The two A1 stretches are NOT the same version and must not\n"
           "-- collapse into one interval. Island detection has to require adjacency, not\n"
           "-- just an equal value."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"initial load with a value that already repeats",
   "what":"SRC_1 runs A1, then A2, then A1 again. SRC_2 covers the lot with B1.",
   "expect":"3 stage rows, rule 17. The two A1 stretches stay SEPARATE. Target 0 -> 3.",
   "changes": P_INS([("K1","A1","2026-08-01","2026-08-10","U-001"),
                     ("K1","A2","2026-08-10","2026-08-20","U-002"),
                     ("K1","A1","2026-08-20","9999-12-31","U-003")],0)
            + C_INS([("K1","B1","2026-08-01","9999-12-31","U-101")],0),
   "conds":[f"{STG}  = 3", f"{RULE(17)} = 3", f"{TGT} = 3", f"{LIVE} = 3",
            ("TWO separate A1 intervals, not one collapsed row",
             LIVEQ("BROKER_STATUS_CDE = 'A1'") + " = 2"),
            LIVEQ("BROKER_STATUS_CDE = 'A1' AND ROW_EFF_DTE = DATE '2026-08-01'\n"
                  "                      AND ROW_EXP_DTE = DATE '2026-08-10'") + " = 1",
            LIVEQ("BROKER_STATUS_CDE = 'A1' AND ROW_EFF_DTE = DATE '2026-08-20'\n"
                  "                      AND ROW_EXP_DTE = DATE '9999-12-31'") + " = 1"]},

  {"run_idx":1,"rerun_of":0,"kind":"IDEMPOTENT","title":"re-run -- the two A1 runs must still not collapse",
   "what":"Nothing changed. If island detection compared values without adjacency, this run would merge them.",
   "expect":"0 stage rows, still two separate A1 intervals.",
   "changes":None,
   "conds":[f"{STG}  = 0", f"{TGT} = 3", f"{LIVE} = 3",
            LIVEQ("BROKER_STATUS_CDE = 'A1'") + " = 2", f"{BATCH(102)} = 0"]},

  {"run_idx":2,"kind":"EDGE","title":"a third alternation",
   "what":"The open A1 is closed at 08-30 and A2 takes over again.",
   "expect":"2 stage rows: rule 5 + 17. Target 3 -> 4, live 4.",
   "changes": P_CLOSE("K1","2026-08-20","2026-08-30",2)
            + P_INS([("K1","A2","2026-08-30","9999-12-31","U-004")],2),
   "conds":[f"{STG}  = 2", f"{RULE(5)} = 1", f"{RULE(17)} = 1", f"{TGT} = 4", f"{LIVE} = 4",
            LIVEQ("BROKER_STATUS_CDE = 'A1'") + " = 2",
            LIVEQ("BROKER_STATUS_CDE = 'A2'") + " = 2"]},

  {"run_idx":3,"kind":"EDGE","title":"a fourth alternation, back to A1 again",
   "what":"A2 is closed at 2026-09-05 and A1 returns for a THIRD separate stretch.",
   "expect":"2 stage rows. Three distinct A1 intervals, none merged. Target 4 -> 5, live 5.",
   "changes": P_CLOSE("K1","2026-08-30","2026-09-05",3)
            + P_INS([("K1","A1","2026-09-05","9999-12-31","U-005")],3),
   "conds":[f"{STG}  = 2", f"{RULE(5)} = 1", f"{RULE(17)} = 1", f"{TGT} = 5", f"{LIVE} = 5",
            ("THREE separate A1 stretches survive",
             LIVEQ("BROKER_STATUS_CDE = 'A1'") + " = 3"),
            ("and the timeline is still gapless from 08-01 to the high end date",
             LIVEQ("ROW_EFF_DTE = DATE '2026-08-01'") + " = 1"),
            LIVEQ("ROW_EXP_DTE = DATE '9999-12-31'") + " = 1"]},
 ]}

# ===========================================================================
SPECS["S05"] = {
 "title": "A gap in cover, with the same value either side",
 "blurb": ("-- SRC_1 stops covering a stretch and starts again later. The uncovered\n"
           "-- interval must appear as its own row carrying a blank, NOT be swallowed by\n"
           "-- the versions either side."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"initial load with a hole in SRC_1",
   "what":"SRC_1 covers 08-01 to 08-10 and 08-20 onward. Nothing covers 08-10 to 08-20.",
   "expect":"3 stage rows, rule 17. The middle row carries a NULL status. Target 0 -> 3.",
   "changes": P_INS([("K1","A1","2026-08-01","2026-08-10","U-001"),
                     ("K1","A2","2026-08-20","9999-12-31","U-002")],0)
            + C_INS([("K1","B1","2026-08-01","9999-12-31","U-101")],0),
   "conds":[f"{STG}  = 3", f"{RULE(17)} = 3", f"{TGT} = 3", f"{LIVE} = 3",
            ("the GAP is its own row, with no status",
             LIVEQ("ROW_EFF_DTE = DATE '2026-08-10' AND ROW_EXP_DTE = DATE '2026-08-20'\n"
                   "                      AND BROKER_STATUS_CDE IS NULL\n"
                   "                      AND COMMISSION_TIER_CDE = 'B1'") + " = 1"),
            ("and it did NOT swallow the versions either side",
             LIVEQ("BROKER_STATUS_CDE IS NOT NULL") + " = 2")]},

  {"run_idx":1,"rerun_of":0,"kind":"IDEMPOTENT","title":"re-run -- the gap must survive",
   "what":"Nothing changed. A rebuild that filled the gap would write here.",
   "expect":"0 stage rows, gap still present.",
   "changes":None,
   "conds":[f"{STG}  = 0", f"{TGT} = 3", f"{LIVE} = 3",
            LIVEQ("BROKER_STATUS_CDE IS NULL") + " = 1", f"{BATCH(102)} = 0"]},

  {"run_idx":2,"kind":"EDGE","title":"a gap at the START of the timeline",
   "what":"SRC_2 delivers an earlier version, so cover now begins before SRC_1 does.",
   "expect":"1 stage row, rule 17. A SECOND blank-status row appears, at the front. Target 3 -> 4.",
   "changes": C_INS([("K1","B0","2026-07-25","2026-08-01","U-100")],2),
   "conds":[f"{STG}  = 1", f"{RULE(17)} = 1", f"{TGT} = 4", f"{LIVE} = 4",
            ("leading gap: covered by SRC_2 only",
             LIVEQ("ROW_EFF_DTE = DATE '2026-07-25' AND BROKER_STATUS_CDE IS NULL\n"
                   "                      AND COMMISSION_TIER_CDE = 'B0'") + " = 1"),
            LIVEQ("BROKER_STATUS_CDE IS NULL") + " = 2"]},

  {"run_idx":3,"kind":"EDGE","title":"a gap that runs to the high end date",
   "what":"SRC_1's last version is closed at 2026-09-01 with no successor, so cover lapses at the end.",
   "expect":"2 stage rows: rule 5 + 17. A THIRD blank-status row, open-ended. Target 4 -> 5.",
   "changes": P_CLOSE("K1","2026-08-20","2026-09-01",3),
   "conds":[f"{STG}  = 2", f"{RULE(5)} = 1", f"{RULE(17)} = 1", f"{TGT} = 5", f"{LIVE} = 5",
            ("trailing gap, open ended",
             LIVEQ("ROW_EFF_DTE = DATE '2026-09-01' AND ROW_EXP_DTE = DATE '9999-12-31'\n"
                   "                      AND BROKER_STATUS_CDE IS NULL") + " = 1"),
            ("three separate gaps now: leading, middle and trailing",
             LIVEQ("BROKER_STATUS_CDE IS NULL") + " = 3")]},
 ]}

# ===========================================================================
SPECS["S06"] = {
 "title": "A value corrected with no change to its dates",
 "blurb": ("-- Zone1 restates a value over exactly the same interval. The hash moves, both\n"
           "-- dates stay, and the target row sits at the high end date -- the definition\n"
           "-- of rule 9, which retires by DEAD RECORD rather than delete indicator."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"initial load into an empty target",
   "what":"One version in each source.","expect":"1 stage row, rule 17. Target 0 -> 1.",
   "changes": P_INS([("K1","A1","2026-08-10","9999-12-31","U-001")],0)
            + C_INS([("K1","B1","2026-08-10","9999-12-31","U-101")],0),
   "conds":[f"{STG}  = 1", f"{TGT} = 1", f"{LIVE} = 1"]},

  {"run_idx":1,"kind":"POSITIVE","title":"the value is corrected, both dates unchanged",
   "what":"B1 becomes B5 over exactly the same interval.",
   "expect":"2 stage rows, rule 9. The old row becomes a DEAD RECORD -- expiry pulled back to its own effective date, IS_DEL left at 'N'. Target 1 -> 2, live stays 1.",
   "changes": C_SET("K1","2026-08-10","B5",1),
   "conds":[f"{STG}  = 2", f"{RULE(9)} = 2", f"{FLAG('D')} = 1", f"{FLAG('I')} = 1",
            f"{TGT} = 2", f"{LIVE} = 1",
            ("DEAD RECORD: eff = exp, and IS_DEL is still 'N'",
             TGTQ("ROW_EFF_DTE = DATE '2026-08-10' AND ROW_EXP_DTE = DATE '2026-08-10'\n"
                  "                      AND IS_DEL = 'N' AND COMMISSION_TIER_CDE = 'B1'") + " = 1"),
            ("nothing was retired by delete indicator",
             TGTQ("IS_DEL = 'Y'") + " = 0"),
            LIVEQ("COMMISSION_TIER_CDE = 'B5'") + " = 1"]},

  {"run_idx":2,"rerun_of":1,"kind":"IDEMPOTENT","title":"re-run of the same window",
   "what":"The dead record must not re-enter the diff. If the target read forgot its eff < exp filter, this run would see two rows at one effective date.",
   "expect":"0 stage rows.",
   "changes":None, "conds":IDEMPOTENT(2,1,103)},

  {"run_idx":3,"kind":"EDGE","title":"corrected to NULL",
   "what":"B5 is restated as NULL -- a correction TO absence, which the hash must treat as a change.",
   "expect":"2 stage rows, rule 9 again. Target 2 -> 3, live stays 1 and now carries no tier.",
   "changes": C_SET("K1","2026-08-10",None,3),
   "conds":[f"{STG}  = 2", f"{RULE(9)} = 2", f"{TGT} = 3", f"{LIVE} = 1",
            ("the live row now carries NO tier",
             LIVEQ("COMMISSION_TIER_CDE IS NULL") + " = 1"),
            ("two dead records now, one per correction",
             TGTQ("ROW_EFF_DTE = ROW_EXP_DTE AND IS_DEL = 'N'") + " = 2")]},
 ]}

# ===========================================================================
SPECS["S07"] = {
 "title": "Several runs in one day against the same key",
 "blurb": ("-- Three runs a day is the real schedule. Each run must see what the previous\n"
           "-- one left, and two deliveries inside ONE window must rebuild as one answer."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"day 1 run 1 -- initial load",
   "what":"One version in each source.","expect":"1 stage row. Target 0 -> 1.",
   "changes": P_INS([("K1","A1","2026-08-10","9999-12-31","U-001")],0)
            + C_INS([("K1","B1","2026-08-10","9999-12-31","U-101")],0),
   "conds":[f"{STG}  = 1", f"{TGT} = 1", f"{LIVE} = 1"]},

  {"run_idx":1,"kind":"POSITIVE","title":"day 1 run 2 -- SRC_2 moves",
   "what":"B1 closes at 08-20, B2 takes over.",
   "expect":"2 stage rows: rule 5 + 17. Target 1 -> 2.",
   "changes": C_CLOSE("K1","2026-08-10","2026-08-20",1)
            + C_INS([("K1","B2","2026-08-20","9999-12-31","U-102")],1),
   "conds":[f"{STG}  = 2", f"{RULE(5)} = 1", f"{RULE(17)} = 1", f"{TGT} = 2", f"{LIVE} = 2"]},

  {"run_idx":2,"kind":"POSITIVE","title":"day 1 run 3 -- and it sees what run 2 left",
   "what":"B2 closes at 08-25, B3 takes over. This run builds on run 2's output, not on run 1's.",
   "expect":"2 stage rows. The row run 2 created at 08-20 is the one that expires. Target 2 -> 3.",
   "changes": C_CLOSE("K1","2026-08-20","2026-08-25",2)
            + C_INS([("K1","B3","2026-08-25","9999-12-31","U-103")],2),
   "conds":[f"{STG}  = 2", f"{RULE(5)} = 1", f"{RULE(17)} = 1", f"{TGT} = 3", f"{LIVE} = 3",
            ("run 2's row is the one this run expired -- proof the runs chain",
             TGTQ("AUDIT_BATCH_ID = 102 AND ROW_EFF_DTE = DATE '2026-08-20'\n"
                  "                      AND ROW_EXP_DTE = DATE '2026-08-25'") + " = 1")]},

  {"run_idx":3,"kind":"POSITIVE","title":"TWO deliveries inside ONE window",
   "what":"Zone1 wrote at 2026-09-21 18:00 and again at 2026-09-22 08:00. Both fall inside run 104's window, so one run must reconcile both.",
   "expect":"3 stage rows. One rebuild, not two. Target 3 -> 5.",
   "changes": """
-- first delivery, 2026-09-21 18:00
UPDATE Z1_BROKER_COMMISSION_HIST
SET    ROW_EXP_DTE = DATE '2026-08-30', GRS_REFINED_TIMESTAMP = TIMESTAMP '2026-09-21 18:00'
WHERE  BROKER_ID = 'K1' AND ROW_EFF_DTE = DATE '2026-08-25';

INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT 'K1','B4',NULL,DATE '2026-08-30',DATE '2026-09-05','U-104',TIMESTAMP '2026-09-21 18:00';

-- second delivery, 2026-09-22 08:00 -- still inside the SAME window
INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT 'K1','B5',NULL,DATE '2026-09-05',DATE '9999-12-31','U-105',TIMESTAMP '2026-09-22 08:00';""",
   "conds":[f"{STG}  = 3", f"{RULE(5)} = 1", f"{RULE(17)} = 2", f"{TGT} = 5", f"{LIVE} = 5",
            ("both deliveries landed, in one rebuild",
             LIVEQ("COMMISSION_TIER_CDE = 'B4' AND ROW_EFF_DTE = DATE '2026-08-30'") + " = 1"),
            LIVEQ("COMMISSION_TIER_CDE = 'B5' AND ROW_EFF_DTE = DATE '2026-09-05'") + " = 1"]},

  {"run_idx":4,"kind":"CORRUPT","title":"duplicate (key, effective date) with IDENTICAL timestamps",
   "what":"Two SRC_2 rows share a business key and effective date and carry the same GRS_REFINED_TIMESTAMP, so there is NO tie-break available.",
   "expect":"Still exactly ONE live row at that date -- no duplicate, no error. WHICH value wins is ARBITRARY, so the target ends at 5 or 6 rows depending on the pick. That arbitrariness is the finding: de-duplication belongs upstream.",
   "changes": """
-- make the existing row and the duplicate indistinguishable
UPDATE Z1_BROKER_COMMISSION_HIST
SET    GRS_REFINED_TIMESTAMP = TIMESTAMP '2026-09-22 12:00'
WHERE  BROKER_ID = 'K1' AND ROW_EFF_DTE = DATE '2026-09-05';

INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT 'K1','BZ',NULL,DATE '2026-09-05',DATE '9999-12-31','U-999',TIMESTAMP '2026-09-22 12:00';""",
   "conds":[("exactly ONE live row at the duplicated date -- never two",
             LIVEQ("ROW_EFF_DTE = DATE '2026-09-05'") + " = 1"),
            ("the winner is arbitrary, so accept either",
             LIVEQ("ROW_EFF_DTE = DATE '2026-09-05'\n"
                   "                      AND COMMISSION_TIER_CDE IN ('B5','BZ')") + " = 1"),
            (f"5 if B5 won (rule 1, nothing written), 6 if BZ won (rule 9)",
             f"{TGT} IN (5, 6)"), f"{LIVE} = 5"]},
 ]}

# ===========================================================================
SPECS["S08"] = {
 "title": "A key no source touched this run",
 "blurb": ("-- Only keys whose GRS_REFINED_TIMESTAMP moved inside the window are impacted.\n"
           "-- Everything else must be neither read nor written -- this is what keeps the\n"
           "-- job incremental instead of a full rebuild."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"initial load of TWO keys",
   "what":"K1 and K8 both arrive.","expect":"2 stage rows, rule 17. Target 0 -> 2.",
   "changes": P_INS([("K1","A1","2026-08-10","9999-12-31","U-001"),
                     ("K8","C1","2026-08-10","9999-12-31","U-801")],0)
            + C_INS([("K1","B1","2026-08-10","9999-12-31","U-101"),
                     ("K8","D1","2026-08-10","9999-12-31","U-901")],0),
   "conds":[f"{STG}  = 2", f"{RULE(17)} = 2", f"{TGT} = 2", f"{LIVE} = 2",
            TGTQ("BROKER_ID = 'K8'") + " = 1"]},

  {"run_idx":1,"kind":"POSITIVE","title":"only K1 changes -- K8 is outside the window",
   "what":"K1's SRC_2 splits. K8's timestamps stay at D1R1, so it is not impacted.",
   "expect":"Stage carries K1 rows ONLY. K8's target row is not read and not written. Target 2 -> 3.",
   "changes": C_CLOSE("K1","2026-08-10","2026-08-20",1)
            + C_INS([("K1","B2","2026-08-20","9999-12-31","U-102")],1),
   "conds":[f"{STG}  = 2", f"{TGT} = 3", f"{LIVE} = 3",
            ("NOT ONE stage row mentions K8",
             "(SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'K8') = 0"),
            ("K8's row is byte-for-byte what run 101 wrote",
             TGTQ("BROKER_ID = 'K8' AND AUDIT_BATCH_ID = 101\n"
                  "                      AND ROW_EFF_DTE = DATE '2026-08-10'\n"
                  "                      AND ROW_EXP_DTE = DATE '9999-12-31' AND IS_DEL = 'N'") + " = 1")]},

  {"run_idx":2,"rerun_of":1,"kind":"IDEMPOTENT","title":"re-run -- K8 still untouched",
   "what":"Nothing changed.","expect":"0 stage rows.",
   "changes":None,
   "conds":[f"{STG}  = 0", f"{TGT} = 3", f"{LIVE} = 3",
            TGTQ("BROKER_ID = 'K8' AND AUDIT_BATCH_ID = 101") + " = 1", f"{BATCH(103)} = 0"]},

  {"run_idx":3,"kind":"EDGE","title":"K8 IS impacted, but its content is identical",
   "what":"K8's NOTE_TEXT moves, so K8 enters the window and IS read. Nothing about it actually changed.",
   "expect":"K8 is read and produces NOTHING. Impacted is not the same as changed. 0 stage rows.",
   "changes": NOTE("Z1_BROKER_COMMISSION_HIST","K8","2026-08-10","reviewed, no change",3),
   "conds":[f"{STG}  = 0", f"{TGT} = 3", f"{LIVE} = 3",
            TGTQ("BROKER_ID = 'K8' AND AUDIT_BATCH_ID = 101") + " = 1", f"{BATCH(104)} = 0"]},
 ]}

# ===========================================================================
SPECS["S09"] = {
 "title": "A key appearing for the first time",
 "blurb": ("-- Rule 17 in isolation: nothing in the target to match, so every rebuilt\n"
           "-- interval inserts. Existing keys must not move while a new one arrives."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"an empty target -- everything inserts",
   "what":"K1 arrives with two versions in SRC_1 and one in SRC_2.",
   "expect":"2 stage rows, both rule 17. Target 0 -> 2.",
   "changes": P_INS([("K1","A1","2026-08-10","2026-08-20","U-001"),
                     ("K1","A2","2026-08-20","9999-12-31","U-002")],0)
            + C_INS([("K1","B1","2026-08-10","9999-12-31","U-101")],0),
   "conds":[f"{STG}  = 2", f"{RULE(17)} = 2", f"{FLAG('I')} = 2", f"{TGT} = 2", f"{LIVE} = 2",
            ("nothing was retired -- there was nothing to retire",
             TGTQ("IS_DEL = 'Y' OR ROW_EFF_DTE = ROW_EXP_DTE") + " = 0")]},

  {"run_idx":1,"kind":"POSITIVE","title":"a second brand-new key, alongside an existing one",
   "what":"K2 appears for the first time. K1 is not touched.",
   "expect":"1 stage row, rule 17, for K2 only. Target 2 -> 3.",
   "changes": P_INS([("K2","C1","2026-08-15","9999-12-31","U-201")],1)
            + C_INS([("K2","D1","2026-08-15","9999-12-31","U-301")],1),
   "conds":[f"{STG}  = 1", f"{RULE(17)} = 1", f"{TGT} = 3", f"{LIVE} = 3",
            "(SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE BROKER_ID = 'K2') = 1",
            ("K1 untouched",
             TGTQ("BROKER_ID = 'K1' AND AUDIT_BATCH_ID = 101") + " = 2")]},

  {"run_idx":2,"kind":"EDGE","title":"a new key arriving with SEVERAL versions at once",
   "what":"K3 has never been seen and shows up with a full history, its two sources starting on different dates.",
   "expect":"3 stage rows, all rule 17, including a leading interval SRC_2 does not cover. Target 3 -> 6.",
   "changes": P_INS([("K3","E1","2026-08-01","2026-08-10","U-401"),
                     ("K3","E2","2026-08-10","9999-12-31","U-402")],2)
            + C_INS([("K3","F1","2026-08-05","9999-12-31","U-501")],2),
   "conds":[f"{STG}  = 3", f"{RULE(17)} = 3", f"{TGT} = 6", f"{LIVE} = 6",
            ("the leading interval has a status but NO tier",
             LIVEQ("BROKER_ID = 'K3' AND ROW_EFF_DTE = DATE '2026-08-01'\n"
                   "                      AND COMMISSION_TIER_CDE IS NULL") + " = 1"),
            LIVEQ("BROKER_ID = 'K3'") + " = 3"]},

  {"run_idx":3,"rerun_of":2,"kind":"IDEMPOTENT","title":"re-run -- no key inserts twice",
   "what":"Nothing changed.","expect":"0 stage rows, still 6 target rows.",
   "changes":None, "conds":IDEMPOTENT(6,6,104)},
 ]}

# ===========================================================================
SPECS["S10"] = {
 "title": "A back-dated correction to an already-closed interval",
 "blurb": ("-- The case retirement exists for. A row whose expiry is a REAL DATE cannot be\n"
           "-- made a dead record -- pulling its expiry back would destroy the interval --\n"
           "-- so it is retired by DELETE INDICATOR and replaced. Rules 11 and 15."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"initial load with closed intervals to correct later",
   "what":"K1 arrives with three SRC_1 versions, so two target rows have real expiry dates.",
   "expect":"3 stage rows, rule 17. Target 0 -> 3.",
   "changes": P_INS([("K1","A1","2026-08-01","2026-08-10","U-001"),
                     ("K1","A2","2026-08-10","2026-08-20","U-002"),
                     ("K1","A3","2026-08-20","9999-12-31","U-003")],0)
            + C_INS([("K1","B1","2026-08-01","9999-12-31","U-101")],0),
   "conds":[f"{STG}  = 3", f"{RULE(17)} = 3", f"{TGT} = 3", f"{LIVE} = 3",
            ("two rows are CLOSED -- expiry is a real date, not 9999",
             TGTQ("ROW_EXP_DTE <> DATE '9999-12-31'") + " = 2")]},

  {"run_idx":1,"kind":"POSITIVE","title":"hash changes on a closed row, expiry unchanged",
   "what":"A2 is restated as A9 over the same 08-10 to 08-20 interval.",
   "expect":"2 stage rows, rule 11. Retired by DELETE INDICATOR -- IS_DEL 'Y', both dates left alone -- and replaced. Target 3 -> 4, live stays 3.",
   "changes": P_SET("K1","2026-08-10","A9",1),
   "conds":[f"{STG}  = 2", f"{RULE(11)} = 2", f"{FLAG('D')} = 1", f"{FLAG('I')} = 1",
            f"{TGT} = 4", f"{LIVE} = 3",
            ("retired by DELETE INDICATOR, dates intact -- NOT a dead record",
             TGTQ("BROKER_STATUS_CDE = 'A2' AND IS_DEL = 'Y'\n"
                  "                      AND ROW_EFF_DTE = DATE '2026-08-10'\n"
                  "                      AND ROW_EXP_DTE = DATE '2026-08-20'") + " = 1"),
            ("no dead record was created",
             TGTQ("ROW_EFF_DTE = ROW_EXP_DTE") + " = 0"),
            LIVEQ("BROKER_STATUS_CDE = 'A9'") + " = 1"]},

  {"run_idx":2,"rerun_of":1,"kind":"IDEMPOTENT","title":"re-run of the same window",
   "what":"The retired row must not re-enter the diff.","expect":"0 stage rows.",
   "changes":None, "conds":IDEMPOTENT(4,3,103)},

  {"run_idx":3,"kind":"EDGE","title":"hash AND expiry both change on a closed row",
   "what":"The OLDEST row is restated as A8 and closed earlier, at 08-05, leaving 08-05 to 08-10 uncovered.",
   "expect":"3 stage rows: rule 15 (retire + insert) plus rule 17 for the gap that opens. Target 4 -> 6, live 4.",
   "changes": P_SET("K1","2026-08-01","A8",3) + P_CLOSE("K1","2026-08-01","2026-08-05",3),
   "conds":[f"{STG}  = 3", f"{RULE(15)} = 2", f"{RULE(17)} = 1", f"{TGT} = 6", f"{LIVE} = 4",
            ("the oldest row retired by DELETE INDICATOR, dates untouched",
             TGTQ("BROKER_STATUS_CDE = 'A1' AND IS_DEL = 'Y'\n"
                  "                      AND ROW_EFF_DTE = DATE '2026-08-01'\n"
                  "                      AND ROW_EXP_DTE = DATE '2026-08-10'") + " = 1"),
            LIVEQ("BROKER_STATUS_CDE = 'A8' AND ROW_EFF_DTE = DATE '2026-08-01'\n"
                  "                      AND ROW_EXP_DTE = DATE '2026-08-05'") + " = 1",
            ("and the hole it left is its own row",
             LIVEQ("ROW_EFF_DTE = DATE '2026-08-05' AND BROKER_STATUS_CDE IS NULL") + " = 1")]},
 ]}

NO_OVERLAP = """(SELECT count(*) FROM V_Z2_BROKER_PARTY_DIM_LIVE a
                   JOIN V_Z2_BROKER_PARTY_DIM_LIVE b
                     ON a.BROKER_ID          = b.BROKER_ID
                    AND a.BROKER_PARTY_DIM_SK < b.BROKER_PARTY_DIM_SK
                    AND a.ROW_EFF_DTE  < b.ROW_EXP_DTE
                    AND b.ROW_EFF_DTE  < a.ROW_EXP_DTE) = 0"""

# ===========================================================================
SPECS["S11"] = {
 "title": "A stale / orphan row after Zone1 loses history",
 "blurb": ("-- Zone1 loses part of its history, so a target row's effective date vanishes\n"
           "-- from the rebuilt timeline. Rule 18: the row is left LIVE and UNTOUCHED,\n"
           "-- deliberately. See solution_design.md section 14."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"initial load, three intervals",
   "what":"K1 arrives with a full history.","expect":"3 stage rows, rule 17. Target 0 -> 3.",
   "changes": P_INS([("K1","A1","2026-08-01","2026-08-10","U-001"),
                     ("K1","A2","2026-08-10","2026-08-20","U-002"),
                     ("K1","A3","2026-08-20","9999-12-31","U-003")],0)
            + C_INS([("K1","B1","2026-08-01","9999-12-31","U-101")],0),
   "conds":[f"{STG}  = 3", f"{TGT} = 3", f"{LIVE} = 3", NO_OVERLAP]},

  {"run_idx":1,"kind":"POSITIVE","title":"Zone1 loses its early history",
   "what":"Both buckets drop everything before 2026-08-10. The target row at 08-01 now has NO counterpart in the rebuilt timeline.",
   "expect":"Rule 18: ZERO stage rows and ZERO writes. The orphan is left LIVE and untouched -- not retired, not deleted.",
   "changes": """
DELETE FROM Z1_BROKER_PARTY_HIST      WHERE BROKER_ID = 'K1' AND ROW_EFF_DTE = DATE '2026-08-01';
DELETE FROM Z1_BROKER_COMMISSION_HIST WHERE BROKER_ID = 'K1' AND ROW_EFF_DTE = DATE '2026-08-01';

INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT 'K1','B1',NULL,DATE '2026-08-10',DATE '9999-12-31','U-101',TIMESTAMP '2026-09-21 12:00';""",
   "conds":[f"{STG}  = 0", f"{TGT} = 3", f"{LIVE} = 3", f"{BATCH(102)} = 0",
            ("the ORPHAN is still live, still run 101's, dates untouched",
             LIVEQ("ROW_EFF_DTE = DATE '2026-08-01' AND ROW_EXP_DTE = DATE '2026-08-10'\n"
                   "                      AND BROKER_STATUS_CDE = 'A1'") + " = 1"),
            ("nothing was retired",
             TGTQ("IS_DEL = 'Y' OR ROW_EFF_DTE = ROW_EXP_DTE") + " = 0"),
            NO_OVERLAP]},

  {"run_idx":2,"rerun_of":1,"kind":"IDEMPOTENT","title":"re-run while still degraded",
   "what":"Nothing changed. The orphan must not drift into being retired on later passes.",
   "expect":"0 stage rows, orphan still live.",
   "changes":None,
   "conds":[f"{STG}  = 0", f"{TGT} = 3", f"{LIVE} = 3",
            LIVEQ("ROW_EFF_DTE = DATE '2026-08-01'") + " = 1", f"{BATCH(103)} = 0"]},

  {"run_idx":3,"kind":"EDGE","title":"PARTIAL recovery -- and this is where it costs",
   "what":"Cover returns, but from 2026-08-05 rather than 08-01, so a new interval is written that the orphan already spans.",
   "expect":"1 stage row, rule 17. TWO live rows now cover 2026-08-07. This is the accepted cost recorded in section 14 -- read by effective date, never by load order.",
   "changes": """
DELETE FROM Z1_BROKER_COMMISSION_HIST WHERE BROKER_ID = 'K1' AND ROW_EFF_DTE = DATE '2026-08-10';

INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT 'K1','B1',NULL,DATE '2026-08-05',DATE '9999-12-31','U-101',TIMESTAMP '2026-09-22 08:00';""",
   "conds":[f"{STG}  = 1", f"{RULE(17)} = 1", f"{TGT} = 4", f"{LIVE} = 4",
            ("TWO live rows cover 2026-08-07 -- the documented cost of rule 18",
             LIVEQ("ROW_EFF_DTE <= DATE '2026-08-07' AND ROW_EXP_DTE > DATE '2026-08-07'") + " = 2"),
            ("the orphan STILL was not touched",
             TGTQ("ROW_EFF_DTE = DATE '2026-08-01' AND AUDIT_BATCH_ID = 101\n"
                  "                      AND IS_DEL = 'N'") + " = 1")]},

  {"run_idx":4,"kind":"EDGE","title":"FULL recovery -- the original orphan self-heals",
   "what":"Zone1 restores everything. The 08-01 interval reappears and matches the orphan exactly.",
   "expect":"0 stage rows -- the orphan rejoins the timeline at ZERO cost. But the row written during partial recovery is now itself an orphan, so the overlap does NOT clear. Recorded honestly rather than smoothed over.",
   "changes": """
INSERT INTO Z1_BROKER_PARTY_HIST
SELECT 'K1','A1',NULL,DATE '2026-08-01',DATE '2026-08-10','U-001',TIMESTAMP '2026-09-22 12:00';

DELETE FROM Z1_BROKER_COMMISSION_HIST WHERE BROKER_ID = 'K1' AND ROW_EFF_DTE = DATE '2026-08-05';

INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT 'K1','B1',NULL,DATE '2026-08-01',DATE '9999-12-31','U-101',TIMESTAMP '2026-09-22 12:00';""",
   "conds":[("the original orphan self-heals with ZERO writes -- rule 3, not a repair",
             f"{STG}  = 0"),
            f"{TGT} = 4", f"{LIVE} = 4", f"{BATCH(105)} = 0",
            LIVEQ("ROW_EFF_DTE = DATE '2026-08-01' AND ROW_EXP_DTE = DATE '2026-08-10'") + " = 1",
            ("but the row written while degraded is an orphan now, so the overlap\n"
             "persists. Self-healing recovers the ORIGINAL row, not rows created\n"
             "during the outage.",
             LIVEQ("ROW_EFF_DTE <= DATE '2026-08-07' AND ROW_EXP_DTE > DATE '2026-08-07'") + " = 2")]},
 ]}

# ===========================================================================
SPECS["S13"] = {
 "title": "execution_type = RESTART",
 "blurb": ("-- A run that fails must process nothing, and the restart must then process it\n"
           "-- exactly once. The gate is JOB_STATUS -- the window CTE only accepts\n"
           "-- 'Completed' rows."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"initial load",
   "what":"K1 arrives.","expect":"1 stage row. Target 0 -> 1.",
   "changes": P_INS([("K1","A1","2026-08-10","9999-12-31","U-001")],0)
            + C_INS([("K1","B1","2026-08-10","9999-12-31","U-101")],0),
   "conds":[f"{STG}  = 1", f"{TGT} = 1", f"{LIVE} = 1"]},

  {"run_idx":1,"job_status":"Failed","kind":"NEGATIVE","title":"the run FAILS before it processes anything",
   "what":"Zone1 delivered a real change, but the run is recorded as Failed.",
   "expect":"NOTHING is processed. 0 stage rows, target untouched -- a failed run must not half-apply.",
   "changes": C_CLOSE("K1","2026-08-10","2026-08-20",1)
            + C_INS([("K1","B2","2026-08-20","9999-12-31","U-102")],1),
   "conds":[f"{STG}  = 0", f"{TGT} = 1", f"{LIVE} = 1", f"{BATCH(102)} = 0",
            ("the source change is sitting there, unprocessed",
             "(SELECT count(*) FROM Z1_BROKER_COMMISSION_HIST WHERE BROKER_ID='K1') = 2")]},

  {"run_idx":2,"rerun_of":1,"exec_type":"RESTART","kind":"POSITIVE","title":"the RESTART picks it up",
   "what":"A new run id over the SAME window, this time Completed.",
   "expect":"The change applies now: 2 stage rows, rule 5 + 17. Target 1 -> 2.",
   "changes":None,
   "conds":[f"{STG}  = 2", f"{RULE(5)} = 1", f"{RULE(17)} = 1", f"{TGT} = 2", f"{LIVE} = 2",
            LIVEQ("COMMISSION_TIER_CDE = 'B2' AND ROW_EFF_DTE = DATE '2026-08-20'") + " = 1",
            ("written by the restart, not the failed run",
             TGTQ("AUDIT_BATCH_ID = 103") + " = 1")]},

  {"run_idx":3,"rerun_of":1,"exec_type":"RESTART","kind":"IDEMPOTENT","title":"restarting twice applies it once",
   "what":"The same restart runs again over the same window.",
   "expect":"0 stage rows. A restart is safe to repeat.",
   "changes":None, "conds":IDEMPOTENT(2,2,104)},
 ]}

# ===========================================================================
SPECS["S12"] = {
 "title": "execution_type = Z1_RERUN",
 "blurb": ("-- On a rerun every MATCHED rule shifts by one -- rule 1 becomes 2, 3 becomes 4,\n"
           "-- and so on -- and the only extra effect is restamping the UUID. Rule 17 does\n"
           "-- NOT shift: an insert is an insert. TC03 is the case that proves it."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"initial load, one closed row and one open row",
   "what":"K1 arrives with two intervals, so both the 9999 branch and the real-date branch have something to match.",
   "expect":"2 stage rows, rule 17. Target 0 -> 2.",
   "changes": P_INS([("K1","A1","2026-08-10","2026-08-20","U-001"),
                     ("K1","A2","2026-08-20","9999-12-31","U-002")],0)
            + C_INS([("K1","B1","2026-08-10","9999-12-31","U-101")],0),
   "conds":[f"{STG}  = 2", f"{RULE(17)} = 2", f"{TGT} = 2", f"{LIVE} = 2"]},

  {"run_idx":1,"exec_type":"Z1_RERUN","kind":"POSITIVE","title":"rerun, nothing changed -- rules 2 AND 4",
   "what":"A NOTE_TEXT change makes K1 impacted so the diff runs, but the rebuilt timeline is identical.",
   "expect":"2 stage rows, both 'U': rule 2 for the row at the high end date, rule 4 for the closed one. No data moves -- only the UUID is restamped.",
   "changes": NOTE("Z1_BROKER_COMMISSION_HIST","K1","2026-08-10","rerun",1),
   "conds":[f"{STG}  = 2", f"{RULE(2)} = 1", f"{RULE(4)} = 1", f"{FLAG('U')} = 2",
            f"{TGT} = 2", f"{LIVE} = 2",
            ("nothing retired, nothing inserted",
             f"{FLAG('D')} = 0"), f"{FLAG('I')} = 0",
            ("every stage row carries a fresh UUID",
             "(SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE UUID IS NOT NULL) = 2")]},

  {"run_idx":2,"exec_type":"Z1_RERUN","kind":"EDGE","title":"rerun with a genuinely NEW interval -- rule 6 and rule 17",
   "what":"B1 closes at 08-25 and B2 takes over, during a rerun. Rule 17 must stay 17: if the rerun +1 were applied to it, it would become 18 and the insert would be DROPPED.",
   "expect":"3 stage rows: rule 4, rule 6 (expire in place), rule 17 (insert). Cover reaches the high end date. Target 2 -> 3.",
   "changes": C_CLOSE("K1","2026-08-10","2026-08-25",2)
            + C_INS([("K1","B2","2026-08-25","9999-12-31","U-102")],2),
   "conds":[f"{STG}  = 3", f"{RULE(4)} = 1", f"{RULE(6)} = 1", f"{RULE(17)} = 1",
            f"{TGT} = 3", f"{LIVE} = 3",
            ("THE REGRESSION GUARD: no stage row was classified 18",
             f"{RULE(18)} = 0"),
            ("and cover still reaches the high end date",
             LIVEQ("ROW_EXP_DTE = DATE '9999-12-31'") + " = 1")]},

  {"run_idx":3,"exec_type":"Z1_RERUN","kind":"POSITIVE","title":"rerun, dead record -- rule 10",
   "what":"B2 is restated as B7 over the same interval. Hash differs, expiry same, target at the high end date.",
   "expect":"4 stage rows: two 'U' no-ops plus rule 10's retire and insert. Target 3 -> 4.",
   "changes": C_SET("K1","2026-08-25","B7",3),
   "conds":[f"{STG}  = 4", f"{RULE(10)} = 2", f"{RULE(4)} = 2", f"{TGT} = 4", f"{LIVE} = 3",
            ("retired as a DEAD RECORD -- eff = exp, IS_DEL still 'N'",
             TGTQ("ROW_EFF_DTE = DATE '2026-08-25' AND ROW_EXP_DTE = DATE '2026-08-25'\n"
                  "                      AND IS_DEL = 'N'") + " = 1")]},

  {"run_idx":4,"exec_type":"Z1_RERUN","kind":"POSITIVE","title":"rerun, back-dated correction -- rule 12",
   "what":"A1 is restated as A9 on a CLOSED interval. Hash differs, expiry same, target expiry is a real date.",
   "expect":"4 stage rows including rule 12's retire and insert. Retired by DELETE INDICATOR, not dead record. Target 4 -> 5.",
   "changes": P_SET("K1","2026-08-10","A9",4),
   "conds":[f"{STG}  = 4", f"{RULE(12)} = 2", f"{TGT} = 5", f"{LIVE} = 3",
            ("DELETE INDICATOR, both dates intact",
             TGTQ("BROKER_STATUS_CDE = 'A1' AND IS_DEL = 'Y'\n"
                  "                      AND ROW_EFF_DTE = DATE '2026-08-10'\n"
                  "                      AND ROW_EXP_DTE = DATE '2026-08-20'") + " = 1")]},

  {"run_idx":5,"exec_type":"Z1_RERUN","kind":"POSITIVE","title":"rerun, expiry moves on a closed row -- rule 8",
   "what":"A9 is closed earlier, at 08-18. Hash unchanged, expiry differs, target expiry is a real date.",
   "expect":"5 stage rows: rule 8's retire and insert, rule 17 for the hole that opens, and 'U' no-ops. Target 5 -> 7.",
   "changes": P_CLOSE("K1","2026-08-10","2026-08-18",5),
   "conds":[f"{STG}  = 5", f"{RULE(8)} = 2", f"{RULE(17)} = 1", f"{TGT} = 7", f"{LIVE} = 4",
            LIVEQ("ROW_EFF_DTE = DATE '2026-08-18' AND BROKER_STATUS_CDE IS NULL") + " = 1"]},

  {"run_idx":6,"exec_type":"Z1_RERUN","kind":"POSITIVE","title":"rerun, hash AND expiry move at the high end date -- rule 14",
   "what":"B7 becomes B6 and closes at 2026-09-01, with B5 taking over.",
   "expect":"6 stage rows including rule 14's retire and insert, plus rule 17. Target 7 -> 9.",
   "changes": C_SET("K1","2026-08-25","B6",6)
            + C_CLOSE("K1","2026-08-25","2026-09-01",6)
            + C_INS([("K1","B5","2026-09-01","9999-12-31","U-103")],6),
   "conds":[f"{STG}  = 6", f"{RULE(14)} = 2", f"{RULE(17)} = 1", f"{TGT} = 9", f"{LIVE} = 5",
            ("retired as a DEAD RECORD -- its expiry was 9999",
             TGTQ("ROW_EFF_DTE = DATE '2026-08-25' AND ROW_EXP_DTE = DATE '2026-08-25'\n"
                  "                      AND COMMISSION_TIER_CDE = 'B7'") + " = 1")]},

  {"run_idx":7,"exec_type":"Z1_RERUN","kind":"POSITIVE","title":"rerun, hash AND expiry move on a closed row -- rule 16",
   "what":"A9 becomes A7 and its interval stretches from 08-18 back out to 08-20.",
   "expect":"5 stage rows including rule 16's retire and insert. The 08-18 row's effective date vanishes, so it becomes a rule 18 orphan and is LEFT LIVE -- which is why two live rows then cover 08-19. Target 9 -> 10.",
   "changes": P_SET("K1","2026-08-10","A7",7) + P_CLOSE("K1","2026-08-10","2026-08-20",7),
   "conds":[f"{STG}  = 5", f"{RULE(16)} = 2", f"{TGT} = 10", f"{LIVE} = 5",
            ("retired by DELETE INDICATOR. The dates matter: TC06 also retired an A9\n"
             "row, at 08-10 to 08-20. This is the OTHER one, 08-10 to 08-18.",
             TGTQ("BROKER_STATUS_CDE = 'A9' AND IS_DEL = 'Y'\n"
                  "                      AND ROW_EFF_DTE = DATE '2026-08-10'\n"
                  "                      AND ROW_EXP_DTE = DATE '2026-08-18'") + " = 1"),
            ("both A9 retirements are present and distinct",
             TGTQ("BROKER_STATUS_CDE = 'A9' AND IS_DEL = 'Y'") + " = 2"),
            ("the orphaned 08-18 row is left LIVE -- rule 18 -- so 08-19 is covered twice",
             LIVEQ("ROW_EFF_DTE <= DATE '2026-08-19' AND ROW_EXP_DTE > DATE '2026-08-19'") + " = 2")]},
 ]}

from mk_scenarios import step1_view
_HASH_V2 = "SHA2('v2|' || COALESCE(a.VAL,'~') || '|' || COALESCE(b.VAL,'~'), 256)"

# ===========================================================================
SPECS["S14"] = {
 "title": "The hash definition itself changes",
 "blurb": ("-- When the hash is redefined, EVERY hash moves without any data moving. The\n"
           "-- design says this is handled GRADUALLY -- keys re-derive as they become\n"
           "-- impacted, under rules 9-16 -- never by truncate and reload. See\n"
           "-- solution_design.md section 15.\n"
           "--\n"
           "-- This scenario really does redefine the hash, by replacing the Step 1 view\n"
           "-- with one whose hash expression is prefixed. Nothing else about it changes.\n"
           "-- TC04 puts the original definition back."),
 "tcs": [
  {"run_idx":0,"kind":"POSITIVE","title":"initial load of two independent keys",
   "what":"K1 and K2 each arrive with two intervals.",
   "expect":"4 stage rows, rule 17. Target 0 -> 4.",
   "changes": P_INS([("K1","A1","2026-08-10","2026-08-20","U-001"),
                     ("K1","A2","2026-08-20","9999-12-31","U-002"),
                     ("K2","C1","2026-08-10","2026-08-20","U-201"),
                     ("K2","C2","2026-08-20","9999-12-31","U-202")],0)
            + C_INS([("K1","B1","2026-08-10","9999-12-31","U-101"),
                     ("K2","D1","2026-08-10","9999-12-31","U-301")],0),
   "conds":[f"{STG}  = 4", f"{RULE(17)} = 4", f"{TGT} = 4", f"{LIVE} = 4",
            TGTQ("BROKER_ID = 'K1'") + " = 2", TGTQ("BROKER_ID = 'K2'") + " = 2"]},

  {"run_idx":1,"kind":"POSITIVE","title":"the hash definition changes -- and only K1 is impacted",
   "what":"The Step 1 view is replaced with one whose hash expression differs. NO DATA CHANGED. Only K1 is impacted this run.",
   "expect":"K1's two intervals both re-derive: rule 9 at the high end date, rule 11 on the closed one. 4 stage rows. K2 is NOT rewritten -- that is the gradual migration. Target 4 -> 6.",
   "changes": "\n-- ---- THE HASH DEFINITION CHANGES HERE -------------------------------------\n"
            + step1_view(_HASH_V2)
            + "\n"
            + NOTE("Z1_BROKER_COMMISSION_HIST","K1","2026-08-10","impacted, so it re-derives",1),
   "conds":[f"{STG}  = 4", f"{RULE(9)} = 2", f"{RULE(11)} = 2", f"{TGT} = 6", f"{LIVE} = 4",
            ("K1 re-derived: the closed row retired by DELETE INDICATOR",
             TGTQ("BROKER_ID = 'K1' AND IS_DEL = 'Y'") + " = 1"),
            ("and the open row by DEAD RECORD",
             TGTQ("BROKER_ID = 'K1' AND ROW_EFF_DTE = ROW_EXP_DTE") + " = 1"),
            ("K2 UNTOUCHED -- still exactly what run 101 wrote. No truncate, no reload.",
             TGTQ("BROKER_ID = 'K2' AND AUDIT_BATCH_ID = 101") + " = 2"),
            TGTQ("BROKER_ID = 'K2'") + " = 2",
            ("surrogate-key churn: 2 new keys for K1, none for K2",
             BATCH(102) + " = 2")]},

  {"run_idx":2,"rerun_of":1,"kind":"IDEMPOTENT","title":"re-run under the NEW definition",
   "what":"K1 is impacted again. Its target rows now carry the new hash, so nothing should move.",
   "expect":"0 stage rows. The migration is not repeated.",
   "changes":None, "conds":IDEMPOTENT(6,4,103)},

  {"run_idx":3,"kind":"POSITIVE","title":"K2 becomes impacted, and re-derives in its turn",
   "what":"K2 is touched for the first time since the hash changed. This is the gradual migration completing.",
   "expect":"4 stage rows, rules 9 and 11 again, for K2 this time. Target 6 -> 8. Every key now carries the new hash.",
   "changes": NOTE("Z1_BROKER_COMMISSION_HIST","K2","2026-08-10","impacted at last",3),
   "conds":[f"{STG}  = 4", f"{RULE(9)} = 2", f"{RULE(11)} = 2", f"{TGT} = 8", f"{LIVE} = 4",
            TGTQ("BROKER_ID = 'K2' AND IS_DEL = 'Y'") + " = 1",
            ("total churn across the migration: 4 rows retired, 4 written",
             TGTQ("IS_DEL = 'Y' OR ROW_EFF_DTE = ROW_EXP_DTE") + " = 4"),
            ("and the live timeline is unchanged in SHAPE -- same 4 intervals as day 1",
             f"{LIVE} = 4")]},

  {"run_idx":4,"kind":"POSITIVE","title":"restore the original hash definition",
   "what":"Housekeeping so this file leaves the objects as it found them. The keys re-derive once more, back to the original hash.",
   "expect":"K1 re-derives; K2 stays until it is impacted. The point is that the file is repeatable, not the rule.",
   "changes": "\n-- ---- PUT THE ORIGINAL DEFINITION BACK -------------------------------------\n"
            + step1_view()
            + "\n"
            + NOTE("Z1_BROKER_COMMISSION_HIST","K1","2026-08-10","back to v1",4),
   "conds":[f"{STG}  = 4", f"{TGT} = 10", f"{LIVE} = 4",
            ("the view is the original again -- later scenarios are unaffected",
             TGTQ("BROKER_ID = 'K1'") + " = 6")]},
 ]}

# ===========================================================================
SPECS["S15"] = {
 "title": "Many keys at once, and the invariants that must always hold",
 "blurb": ("-- A hand-written case proves the rule you were thinking about. This one checks\n"
           "-- the properties that must hold for EVERY key whatever the rules did:\n"
           "--\n"
           "--   * no two LIVE rows for one key may overlap\n"
           "--   * a corrupt source row must never reach the target\n"
           "--   * a duplicate (key, effective date) must never produce two live rows\n"
           "--\n"
           "-- Six keys with deliberately different shapes: single version, split on each\n"
           "-- side, a gap, staggered starts, and both sources versioned at once."),
 "tcs": [
  {"run_idx":0,"kind":"VOLUME","title":"six keys of different shapes, loaded at once",
   "what":"K01 one interval, K02 and K03 two, K04 three (one is a gap), K05 two, K06 four.",
   "expect":"14 stage rows, all rule 17. Target 0 -> 14, and no key overlaps itself.",
   "changes": P_INS([("K01","A1","2026-08-10","9999-12-31","U-011"),
                     ("K02","A1","2026-08-10","2026-08-20","U-021"),
                     ("K02","A2","2026-08-20","9999-12-31","U-022"),
                     ("K03","A1","2026-08-10","9999-12-31","U-031"),
                     ("K04","A1","2026-08-01","2026-08-10","U-041"),
                     ("K04","A2","2026-08-20","9999-12-31","U-042"),
                     ("K05","A1","2026-08-01","9999-12-31","U-051"),
                     ("K06","A1","2026-08-05","2026-08-15","U-061"),
                     ("K06","A2","2026-08-15","9999-12-31","U-062")],0)
            + C_INS([("K01","B1","2026-08-10","9999-12-31","U-111"),
                     ("K02","B1","2026-08-10","9999-12-31","U-121"),
                     ("K03","B1","2026-08-10","2026-08-15","U-131"),
                     ("K03","B2","2026-08-15","9999-12-31","U-132"),
                     ("K04","B1","2026-08-01","9999-12-31","U-141"),
                     ("K05","B1","2026-08-10","9999-12-31","U-151"),
                     ("K06","B1","2026-08-01","2026-08-10","U-161"),
                     ("K06","B2","2026-08-10","9999-12-31","U-162")],0),
   "conds":[f"{STG}  = 14", f"{RULE(17)} = 14", f"{TGT} = 14", f"{LIVE} = 14",
            ("INVARIANT: no key overlaps itself",  NO_OVERLAP),
            ("each key produced the shape its sources imply",
             LIVEQ("BROKER_ID = 'K01'") + " = 1"),
            LIVEQ("BROKER_ID = 'K04'") + " = 3",
            LIVEQ("BROKER_ID = 'K06'") + " = 4",
            ("K04's middle interval is the gap -- no status",
             LIVEQ("BROKER_ID = 'K04' AND BROKER_STATUS_CDE IS NULL") + " = 1")]},

  {"run_idx":1,"kind":"VOLUME","title":"several keys change at once, in different ways",
   "what":"K02's SRC_2 splits (rules 5 and 17). K03's SRC_2 is restated in place (rule 9). Four other keys are not impacted at all.",
   "expect":"4 stage rows across two keys. Target 14 -> 16, live 15. The four quiet keys are untouched.",
   "changes": C_CLOSE("K02","2026-08-10","2026-08-25",1)
            + C_INS([("K02","B2","2026-08-25","9999-12-31","U-122")],1)
            + C_SET("K03","2026-08-15","B9",1),
   "conds":[f"{STG}  = 4", f"{RULE(5)} = 1", f"{RULE(17)} = 1", f"{RULE(9)} = 2",
            f"{TGT} = 16", f"{LIVE} = 15",
            ("INVARIANT: still no key overlaps itself", NO_OVERLAP),
            ("the four quiet keys are byte-for-byte what run 101 wrote",
             TGTQ("BROKER_ID IN ('K01','K04','K05','K06') AND AUDIT_BATCH_ID = 101") + " = 10"),
            ("and nothing at all was written for them",
             "(SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM\n"
             "                  WHERE BROKER_ID IN ('K01','K04','K05','K06')) = 0")]},

  {"run_idx":2,"kind":"CORRUPT","title":"corrupt rows arrive alongside good ones",
   "what":"A NULL business key, and a duplicate (key, effective date) on K01 carrying the SAME timestamp as the row it duplicates, so there is no tie-break.",
   "expect":"Neither corrupts the target. The NULL key is dropped silently. The duplicate yields exactly ONE live row -- but WHICH value wins is arbitrary, so the target lands on 16 or 17. De-duplication belongs upstream.",
   "changes": C_INS([(None,"BX","2026-08-10","9999-12-31","U-999")],2)
            + """
-- make K01's existing row and the duplicate indistinguishable
UPDATE Z1_BROKER_COMMISSION_HIST
SET    GRS_REFINED_TIMESTAMP = TIMESTAMP '2026-09-21 16:00'
WHERE  BROKER_ID = 'K01' AND ROW_EFF_DTE = DATE '2026-08-10';

INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT 'K01','BZ',NULL,DATE '2026-08-10',DATE '9999-12-31','U-119',TIMESTAMP '2026-09-21 16:00';""",
   "conds":[("INVARIANT: no key overlaps itself, corrupt input or not", NO_OVERLAP),
            ("the NULL key NEVER reaches the target",
             TGTQ("BROKER_ID IS NULL") + " = 0"),
            ("exactly ONE live row for the duplicated (key, effective date)",
             LIVEQ("BROKER_ID = 'K01' AND ROW_EFF_DTE = DATE '2026-08-10'") + " = 1"),
            ("the winner is arbitrary -- accept either",
             LIVEQ("BROKER_ID = 'K01' AND COMMISSION_TIER_CDE IN ('B1','BZ')") + " = 1"),
            ("16 if the original won and nothing was written, 17 if the duplicate did",
             f"{TGT} IN (16, 17)"), f"{LIVE} = 15",
            ("and every other key is still untouched",
             TGTQ("BROKER_ID IN ('K04','K05','K06') AND AUDIT_BATCH_ID = 101") + " = 9")]},
 ]}
