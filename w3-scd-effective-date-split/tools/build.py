import sys
import openpyxl
from openpyxl.styles import Font
from lib import *

wb = openpyxl.Workbook(); wb.remove(wb.active)

SRC1 = ["PRIMARY_KEY", "NON_KEY_1", "HASH", "ROW_EFF_DATE", "ROW_EXP_DATE"]
SRC2 = ["PRIMARY_KEY", "NON_KEY_2", "HASH", "ROW_EFF_DATE", "ROW_EXP_DATE"]
TGT  = ["PRIMARY_KEY", "NON_KEY_1", "NON_KEY_2", "HASH", "ROW_EFF_DATE", "ROW_EXP_DATE", "DELETE_IND", "ACTION"]
WC   = ["WHAT CHANGED"]


def scenario(name, title, left, right, points, ques=None, tabcolor=None):
    """left/right are lists of (heading, cols, rows, fill). Target block is anchored
    clear of the widest left block, so the two never collide."""
    s = Sheet(wb, name, title, tabcolor)
    anchor = max(len(c) for _, c, _, _ in left) + 2
    rl = s.stack(1, left)
    rr = s.stack(anchor, right)
    r = max(rl, rr) + 1
    span = anchor + len(TGT) - 1
    r = s.bullets(r, points, span=span)
    if ques:
        s.questions(r + 1, ques, span=span)
    s.finish()
    return s


# ══════════════════════════════════ 00 Index ══════════════════════════════════
s = Sheet(wb, "00 Index", "Multi-source SCD2 effective-date split — scenarios")
r = s.block(3, 1, None, ["TAB", "SCENARIO", "GROUP", "WHAT IT TESTS / WHY IT MATTERS", "STATUS"], [
    ["S01", "One source changes, the other does not", "A. Timeline",
     "The core problem. The base example for the match-and-compare rule", "Proven — needs re-run under the HASH rule"],
    ["S02", "Both sources change in the same run", "A. Timeline",
     "Assumed to be the hard case; it is not", "Covered, not separately tested"],
    ["S03", "Change in a column the target never carries", "A. Timeline",
     "Must produce no target change at all — the HASH is what makes this work", "Proven"],
    ["S04", "A value comes back after a different one", "A. Timeline",
     "Two intervals share a HASH but must not merge", "Proven"],
    ["S05", "A gap in cover, same value either side", "A. Timeline",
     "The gap must survive; target carries a blank", "Proven"],
    ["S06", "A value corrected with no change to its dates", "A. Timeline",
     "Dates alone cannot tell old from new. This is why the HASH exists", "Proven — needs re-run under the HASH rule"],
    ["S07", "Several runs in one day, same key + eff date", "A. Timeline",
     "Restatements, or distinct versions? Changes the design", "OPEN — Q1, Q2"],
    ["S08", "A key no source touched this run", "A. Timeline",
     "Must not be read or written", "Proven"],
    ["S09", "A key appearing for the first time", "A. Timeline",
     "No special first-load path needed", "Proven"],
    ["S10", "execution_type = Z1 RERUN", "B. How applied",
     "Decided: no separate code path. The ordinary rule handles it", "DECIDED — Option 1. Q5 on UUID"],
    ["S11", "execution_type = RESTART", "B. How applied",
     "The only case where ABC writes to our target", "NOT TESTED — Q4"],
], GREEN) + 1

s.label(r, 1, "The rule every tab applies", TEAL); r += 1
c = s.ws.cell(row=r, column=1,
              value="Match each rebuilt interval to the existing target row on PRIMARY_KEY + ROW_EFF_DATE, then let the HASH decide:")
c.font = Font(size=10, color=INK)
s.ws.merge_cells(start_row=r, start_column=1, end_row=r, end_column=5); r += 1
r = s.block(r, 1, None, ["", "TARGET ROW AT THAT EFF DATE", "HASH", "ROW_EXP_DATE", "ACTION"], [
    ["", "exists", "same", "same", "untouched — nothing is written"],
    ["", "exists", "same", "different", "UPDATE ROW_EXP_DATE in place"],
    ["", "exists", "changed", "any", "RETIRE the old row + INSERT the new one"],
    ["", "none", "—", "—", "INSERT"],
    ["", "exists, but that eff date is gone from the rebuilt timeline", "—", "—", "RETIRE"],
], AMBER)
c = s.ws.cell(row=r, column=2,
              value="RETIRE means: DEAD RECORD (expiry pulled back to the row's own eff date) when the old expiry was 9999-12-31, "
                    "otherwise DELETE_IND = 'Y' with the dates left alone.")
c.font = Font(size=10, italic=True, color=INK); r += 1
c = s.ws.cell(row=r, column=2,
              value="HASH is taken over the columns that actually reach the target — not over every source column.")
c.font = Font(size=10, italic=True, color=INK); r += 2

s.label(r, 1, "Not covered by a scenario tab — no data needed", TEAL); r += 1
s.block(r, 1, None, ["", "CASE", "", "WHY NOT", ""], [
    ["", "SCD2 + SCD1 → SCD2   /   SCD2 + lookup → SCD2", "",
     "The SCD2 table sets the dates on its own. This is today's established pattern, no new logic", ""],
    ["", "SCD1 + SCD1 → SCD2", "", "Neither source carries history; target dates come from the load date", ""],
    ["", "SCD2 + SCD2 → SCD1", "", "No history to keep in the target — take the latest value", ""],
    ["", "execution_type = NEW", "", "The baseline. Identical to S01 — every tab from S01 to S09 is a NEW run", ""],
    ["", "Historical / catchup / first-time-incremental load", "", "ABC has not built these execution types yet", ""],
    ["", "Mixed clocks: one source load-timed, one business-timed", "",
     "Confirmed limitation. A decision to take, not a case to test", ""],
], GREY)
s.wneed = {1: 10, 2: 48, 3: 18, 4: 72, 5: 32}
s.finish()

# ══════════════════════════════════ S01 ══════════════════════════════════
scenario("S01 One source changes",
         "S01 — For same primary key: one source changes, the other does not",
    left=[
        ("DAY 1 — SRC_1", SRC1, [
            ["K1", "A1", H("A1"), "2026-09-10", "2026-09-21"],
            ["K1", "A2", H("A2"), "2026-09-21", HIGH]], None),
        ("DAY 1 — SRC_2", SRC2, [["K1", "B1", H("B1"), "2026-09-09", HIGH]], None),
        ("DAY 2 — SRC_1   ·   NOT TOUCHED, identical to Day 1", SRC1, [
            ["K1", "A1", H("A1"), "2026-09-10", "2026-09-21"],
            ["K1", "A2", H("A2"), "2026-09-21", HIGH]], GREY),
        ("DAY 2 — SRC_2   ·   changed", SRC2 + WC, [
            ["K1", "B1", H("B1"), "2026-09-09", "2026-09-15", "closed early — was 9999-12-31"],
            ["K1", "B2", H("B2"), "2026-09-15", "2026-09-22", "new version"],
            ["K1", "B3", H("B3"), "2026-09-22", HIGH,         "new version"]], RED),
    ],
    right=[
        ("DAY 1 — TGT   (3 rows)", TGT, [
            ["K1", "(blank)", "B1", H("", "B1"),   "2026-09-09", "2026-09-10", "N", "insert"],
            ["K1", "A1",      "B1", H("A1", "B1"), "2026-09-10", "2026-09-21", "N", "insert"],
            ["K1", "A2",      "B1", H("A2", "B1"), "2026-09-21", HIGH,         "N", "insert"]], GREEN),
        ("DAY 2 — TGT   (6 rows)", TGT, [
            ["K1", "(blank)", "B1", H("", "B1"), "2026-09-09", "2026-09-10", "N",
             "untouched — HASH same, expiry same. Nothing written"],
            ["K1", "A1", "B1", H("A1", "B1"), "2026-09-10", "2026-09-15", "N",
             "UPDATE EXP DATE — HASH same, expiry moved (was 2026-09-21)"],
            ["K1", "A2", "B1", H("A2", "B1"), "2026-09-21", "2026-09-21", "N",
             "DEAD RECORD — HASH changed (B1→B2) and expiry was 9999, so expiry pulled back to its own eff date"],
            ["K1", "A1", "B2", H("A1", "B2"), "2026-09-15", "2026-09-21", "N", "insert"],
            ["K1", "A2", "B2", H("A2", "B2"), "2026-09-21", "2026-09-22", "N", "insert"],
            ["K1", "A2", "B3", H("A2", "B3"), "2026-09-22", HIGH,         "N", "insert"]], GREEN),
    ],
    points=[
        "SRC_1 never changed on Day 2, yet two of its three target rows still had to move. Neither source on its own can decide the target's dates — this is the whole problem in one picture.",
        "How the target rows are derived: collect every date either source mentions (09, 10, 15, 21, 22, 9999), then every consecutive pair of dates becomes one target row, filled from whichever source version covers it.",
        "Each rebuilt interval is then matched to the existing target row on PRIMARY_KEY + ROW_EFF_DATE, and the HASH decides what happens to it. See the rule table on the Index tab.",
        "Row 2 is the point of the HASH. A1|B1 still covers 10-Sep, so the values are unchanged — only the expiry moved from 21-Sep to 15-Sep. That is an UPDATE in place, not a retire-and-reinsert.",
        "Row 3 is the only retirement. At 21-Sep the values genuinely changed (B1→B2), so the old row goes. Its expiry was the high end date, so it becomes a DEAD RECORD: expiry pulled back to its own eff date, spanning zero days.",
        "DELETE_IND = 'Y' does NOT fire anywhere in this scenario. It only fires when a HASH changes on a row whose expiry was a real date — which does not happen here.",
        "The dead record and the new A2|B2|21-Sep row share an effective date. That is fine — the dead one covers no time, so no as-of query can return it.",
        "The first target row carries a blank NON_KEY_1 because SRC_2 starts on 09-Sep but SRC_1 does not start until 10-Sep. We keep the row rather than dropping it.",
    ], tabcolor="FF0000")

# ══════════════════════════════════ S02 ══════════════════════════════════
scenario("S02 Both sources change", "S02 — Both sources change in the same run",
    left=[
        ("DAY 1 — SRC_1", SRC1, [["K2", "A1", H("A1"), "2026-06-01", HIGH]], None),
        ("DAY 1 — SRC_2", SRC2, [["K2", "B1", H("B1"), "2026-06-01", HIGH]], None),
        ("DAY 2 — SRC_1   ·   changed", SRC1 + WC, [
            ["K2", "A1", H("A1"), "2026-06-01", "2026-06-10", "closed early"],
            ["K2", "A2", H("A2"), "2026-06-10", HIGH,         "new version"]], RED),
        ("DAY 2 — SRC_2   ·   changed too", SRC2 + WC, [
            ["K2", "B1", H("B1"), "2026-06-01", "2026-06-05", "closed early"],
            ["K2", "B2", H("B2"), "2026-06-05", HIGH,         "new version"]], RED),
    ],
    right=[
        ("DAY 1 — TGT", TGT, [
            ["K2", "A1", "B1", H("A1", "B1"), "2026-06-01", HIGH, "N", "insert"]], GREEN),
        ("DAY 2 — TGT   (3 rows)", TGT, [
            ["K2", "A1", "B1", H("A1", "B1"), "2026-06-01", "2026-06-05", "N",
             "UPDATE EXP DATE — HASH same, expiry moved (was 9999-12-31)"],
            ["K2", "A1", "B2", H("A1", "B2"), "2026-06-05", "2026-06-10", "N", "insert"],
            ["K2", "A2", "B2", H("A2", "B2"), "2026-06-10", HIGH,         "N", "insert"]], GREEN),
    ],
    points=[
        "No different in kind from S01. Dates from both sides go into the same pot before the intervals are cut, so it does not matter whether one source moved or both.",
        "Listed separately only because this is the case people assume is the hardest, and it is not.",
        "The first target row keeps its surrogate key and its effective date. A1|B1 still covers 01-Jun, so the HASH is unchanged and only the expiry moves — an UPDATE, not a new row.",
        "Nothing is retired in this scenario at all: no interval's values changed at an effective date the target already held.",
    ])

# ══════════════════════════════════ S03 ══════════════════════════════════
S1N = ["PRIMARY_KEY", "NON_KEY_1", "NOTE_TEXT", "HASH", "ROW_EFF_DATE", "ROW_EXP_DATE"]
S2N = ["PRIMARY_KEY", "NON_KEY_2", "NOTE_TEXT", "HASH", "ROW_EFF_DATE", "ROW_EXP_DATE"]
scenario("S03 Non-target col changes", "S03 — A change in a column the target never carries",
    left=[
        ("DAY 1 — SRC_1   ·   NOTE_TEXT is NOT carried to the target", S1N,
         [["K3", "A1", "original", H("A1"), "2026-07-01", HIGH]], None),
        ("DAY 1 — SRC_2   ·   NOTE_TEXT is NOT carried to the target", S2N,
         [["K3", "B1", "original", H("B1"), "2026-07-01", HIGH]], None),
        ("DAY 2 — SRC_1   ·   unchanged", S1N,
         [["K3", "A1", "original", H("A1"), "2026-07-01", HIGH]], GREY),
        ("DAY 2 — SRC_2   ·   splits, but only NOTE_TEXT differs", S2N + WC, [
            ["K3", "B1", "original", H("B1"), "2026-07-01", "2026-07-12", "closed early"],
            ["K3", "B1", "reworded", H("B1"), "2026-07-12", HIGH, "new version — NON_KEY_2 is still B1"]], RED),
    ],
    right=[
        ("DAY 1 — TGT", TGT, [
            ["K3", "A1", "B1", H("A1", "B1"), "2026-07-01", HIGH, "N", "insert"]], GREEN),
        ("DAY 2 — TGT", TGT, [
            ["K3", "A1", "B1", H("A1", "B1"), "2026-07-01", HIGH, "N",
             "NO CHANGE — 0 rows written. HASH same, expiry same"]], GREEN),
    ],
    points=[
        "The HASH is taken over the columns that reach the target only. NOTE_TEXT is not one of them, so both Day 2 SRC_2 rows carry the same HASH — H(B1).",
        "Because the two versions hash identically AND are consecutive, they merge back into one before any dates are collected. The 12-Jul boundary disappears before it can split anything.",
        "Without this step the target would gain a split into two IDENTICAL rows — a change that means nothing to any consumer, and one that would then have to be undone.",
    ])

# ══════════════════════════════════ S04 ══════════════════════════════════
scenario("S04 Value returns later", "S04 — A value comes back after a different one (A1 → A2 → A1)",
    left=[
        ("SRC_1", SRC1, [
            ["K4", "A1", H("A1"), "2026-03-01", "2026-03-10"],
            ["K4", "A2", H("A2"), "2026-03-10", "2026-03-20"],
            ["K4", "A1", H("A1"), "2026-03-20", HIGH]], None),
        ("SRC_2", SRC2, [["K4", "B1", H("B1"), "2026-03-01", HIGH]], None),
    ],
    right=[
        ("TGT — correct result   (3 rows)", TGT, [
            ["K4", "A1", "B1", H("A1", "B1"), "2026-03-01", "2026-03-10", "N", "insert"],
            ["K4", "A2", "B1", H("A2", "B1"), "2026-03-10", "2026-03-20", "N", "insert"],
            ["K4", "A1", "B1", H("A1", "B1"), "2026-03-20", HIGH,         "N", "insert"]], GREEN),
    ],
    points=[
        "Rows 1 and 3 of SRC_1 carry the SAME hash, H(A1), and so do target rows 1 and 3. They must still stay SEPARATE.",
        "If they were merged because the hash matches, you get one A1 version spanning 01-Mar to 9999 which overlaps the A2 version. The middle interval then matches TWO source versions instead of one, and the join produces duplicate target rows.",
        "Rule: only CONSECUTIVE identical versions merge — never any two that happen to hash the same. A matching hash licenses a merge only when the rows are adjacent in time.",
    ])

# ══════════════════════════════════ S05 ══════════════════════════════════
scenario("S05 Gap in cover", "S05 — A gap in cover, with the same value either side",
    left=[
        ("SRC_1 — nothing covers 10-Apr to 20-Apr", SRC1, [
            ["K5", "A1", H("A1"), "2026-04-01", "2026-04-10"],
            ["K5", "A1", H("A1"), "2026-04-20", HIGH]], None),
        ("SRC_2", SRC2, [["K5", "B1", H("B1"), "2026-04-01", HIGH]], None),
    ],
    right=[
        ("TGT — correct result   (3 rows)", TGT, [
            ["K5", "A1",      "B1", H("A1", "B1"), "2026-04-01", "2026-04-10", "N", "insert"],
            ["K5", "(blank)", "B1", H("", "B1"),   "2026-04-10", "2026-04-20", "N",
             "insert — the gap. NON_KEY_1 is blank, so this row's HASH differs from its neighbours"],
            ["K5", "A1",      "B1", H("A1", "B1"), "2026-04-20", HIGH,         "N", "insert"]], GREEN),
    ],
    points=[
        "The source says nothing at all about 10-Apr to 20-Apr, so the target must say nothing either — the middle row carries a blank rather than being filled in or dropped.",
        "The two A1 versions must NOT merge across the gap even though they hash identically. A gap is not a match.",
        "This is why the date collection uses expiry dates as well as effective dates. Using only effective dates would lose both boundaries.",
    ])

# ══════════════════════════════════ S06 ══════════════════════════════════
scenario("S06 Value fixed same dates", "S06 — A value corrected with no change to its dates",
    left=[
        ("DAY 1 — SRC_1", SRC1, [["K6", "A1", H("A1"), "2026-05-01", HIGH]], None),
        ("DAY 1 — SRC_2", SRC2, [["K6", "B1", H("B1"), "2026-05-01", HIGH]], None),
        ("DAY 2 — SRC_1   ·   same row restated with a different value. BOTH DATES UNCHANGED", SRC1 + WC,
         [["K6", "A9", H("A9"), "2026-05-01", HIGH, "value A1 → A9. Dates identical."]], RED),
        ("DAY 2 — SRC_2   ·   unchanged", SRC2, [["K6", "B1", H("B1"), "2026-05-01", HIGH]], GREY),
    ],
    right=[
        ("DAY 1 — TGT holds", TGT, [
            ["K6", "A1", "B1", H("A1", "B1"), "2026-05-01", HIGH, "N", "insert"]], GREEN),
        ("DAY 2 — TGT", TGT, [
            ["K6", "A1", "B1", H("A1", "B1"), "2026-05-01", "2026-05-01", "N",
             "DEAD RECORD — HASH changed (A1→A9) and expiry was 9999"],
            ["K6", "A9", "B1", H("A9", "B1"), "2026-05-01", HIGH, "N", "insert"]], GREEN),
    ],
    points=[
        "This is the scenario the HASH exists for. Both dates are identical on Day 1 and Day 2 — the dates alone cannot tell the old row from the new one.",
        "The match finds the existing target row at effective date 01-May. Its HASH is H(A1|B1); the rebuilt interval hashes to H(A9|B1). Different, so the old row is retired and the new one inserted.",
        "Its expiry was the high end date, so it retires as a DEAD RECORD rather than by delete indicator.",
        "If the comparison used dates only: old matches new, nothing is written, the stale A1 stays in the target permanently, and the job reports success. A silent failure.",
    ])

# ══════════════════════════════════ S07 ══════════════════════════════════
S2R = ["PRIMARY_KEY", "NON_KEY_2", "HASH", "ROW_EFF_DATE", "ROW_EXP_DATE", "REFINED_TIMESTAMP"]
S1R7 = ["PRIMARY_KEY", "NON_KEY_1", "HASH", "ROW_EFF_DATE", "ROW_EXP_DATE", "REFINED_TIMESTAMP"]
TWO_ROWS = [["K7", "B1", H("B1"), "2026-09-05", HIGH,         "2026-09-22 08:00"],
            ["K7", "B1", H("B1"), "2026-09-05", "2026-09-07", "2026-09-22 14:00"]]
scenario("S07 Multiple runs same day",
         "S07 — Several runs in one day: same key and effective date more than once",
    left=[
        ("DAY 1 — SRC_1   ·   one plain version, nothing unusual", S1R7,
         [["K7", "A1", H("A1"), "2026-09-05", HIGH, "2026-09-22 08:00"]], None),
        ("DAY 1 — SRC_2 — two rows, SAME key and SAME eff date, inside one sourcing window",
         S2R, TWO_ROWS, AMBER),
        ("DAY 2 — SRC_1   ·   unchanged", S1R7,
         [["K7", "A1", H("A1"), "2026-09-05", HIGH, "2026-09-22 08:00"]], GREY),
        ("DAY 2 — SRC_2 — the same two rows, read the other way", S2R, TWO_ROWS, AMBER),
    ],
    right=[
        ("DAY 1 — TGT   ·   under read (a), latest wins", TGT, [
            ["K7", "A1", "B1",      H("A1", "B1"), "2026-09-05", "2026-09-07", "N", "insert"],
            ["K7", "A1", "(blank)", H("A1", ""),   "2026-09-07", HIGH,         "N",
             "insert — SRC_2 says nothing after 07-Sep, so NON_KEY_2 is blank"]], GREEN),
        ("DAY 2 — READ (a): they are RESTATEMENTS, latest wins", TGT, [
            ["K7", "A1", "B1",      H("A1", "B1"), "2026-09-05", "2026-09-07", "N",
             "untouched — the 14:00 row wins, the 08:00 row is discarded"],
            ["K7", "A1", "(blank)", H("A1", ""),   "2026-09-07", HIGH,         "N",
             "untouched — still uncovered after 07-Sep"]], GREEN),
        ("DAY 2 — READ (b): they are DISTINCT versions, both must land", TGT, [
            ["K7", "A1", "B1", H("A1", "B1"), "2026-09-05", HIGH,         "N", "?"],
            ["K7", "A1", "B1", H("A1", "B1"), "2026-09-05", "2026-09-07", "N",
             "? — two LIVE rows share a key, an eff date AND a hash. The timeline is now ambiguous."]], AMBER),
    ],
    points=[
        "Our current logic keeps only the LATEST refined timestamp per (key, effective date). That is correct if the second row is a restatement of the first.",
        "You said these 'need to get loaded in zone2 target'. If ALL of them must land, our logic is dropping data you want.",
        "Note that the HASH does not separate these two rows — both are H(B1). Only REFINED_TIMESTAMP and the expiry differ, which is exactly why this case cannot be settled by the ordinary rule.",
        "Under read (b) the target ends up with two live rows sharing a key and effective date, which breaks the timeline — UNLESS ROW_EFF_DATE carries a time component, in which case they never collide and nothing special is needed.",
        "Read (a) has a consequence worth seeing: discarding the 08:00 row also discards the cover it provided. The 14:00 row closes B1 at 07-Sep, so from 07-Sep onwards SRC_2 says nothing and the target carries a blank NON_KEY_2 — the same handling as the gap in S05.",
    ],
    ques=[
        "Q1 — are two rows with the same key and eff date in one window RESTATEMENTS (latest wins) or DISTINCT versions (both land)? This is the only open question that could still change the design.",
        "Q2 — is ROW_EFF_DATE a DATE or a TIMESTAMP? If it carries a time, read (b) costs nothing and Q1 goes away.",
    ], tabcolor="FF0000")

# ══════════════════════════════════ S08 ══════════════════════════════════
S1R = ["PRIMARY_KEY", "NON_KEY_1", "HASH", "ROW_EFF_DATE", "ROW_EXP_DATE", "REFINED_TIMESTAMP"]
scenario("S08 Key not touched", "S08 — A key that no source touched this run",
    left=[
        ("DAY 1 — SRC_1", S1R, [
            ["K1", "A1", H("A1"), "2026-09-10", "2026-09-21", "2026-09-21 08:00"],
            ["K1", "A2", H("A2"), "2026-09-21", HIGH,         "2026-09-21 08:00"],
            ["K8", "A1", H("A1"), "2026-01-01", HIGH,         "2026-09-21 08:00"]], None),
        ("DAY 1 — SRC_2", S2R, [
            ["K1", "B1", H("B1"), "2026-09-09", HIGH, "2026-09-21 08:00"],
            ["K8", "B1", H("B1"), "2026-01-01", HIGH, "2026-09-21 08:00"]], None),
        ("DAY 2 — SRC_1   ·   unchanged", S1R, [
            ["K1", "A1", H("A1"), "2026-09-10", "2026-09-21", "2026-09-21 08:00"],
            ["K1", "A2", H("A2"), "2026-09-21", HIGH,         "2026-09-21 08:00"],
            ["K8", "A1", H("A1"), "2026-01-01", HIGH,         "2026-09-21 08:00"]], GREY),
        ("DAY 2 — SRC_2   ·   K1 changes, K8 does not", S2R + WC, [
            ["K1", "B1", H("B1"), "2026-09-09", "2026-09-15", "2026-09-22 08:00", "closed early"],
            ["K1", "B2", H("B2"), "2026-09-15", "2026-09-22", "2026-09-22 08:00", "new version"],
            ["K1", "B3", H("B3"), "2026-09-22", HIGH,         "2026-09-22 08:00", "new version"],
            ["K8", "B1", H("B1"), "2026-01-01", HIGH,         "2026-09-21 08:00",
             "untouched — timestamp still 21-Sep, outside the 22-Sep window"]], RED),
    ],
    right=[
        ("DAY 1 — TGT", TGT, [
            ["K1", "(blank)", "B1", H("", "B1"),   "2026-09-09", "2026-09-10", "N", "insert"],
            ["K1", "A1",      "B1", H("A1", "B1"), "2026-09-10", "2026-09-21", "N", "insert"],
            ["K1", "A2",      "B1", H("A2", "B1"), "2026-09-21", HIGH,         "N", "insert"],
            ["K8", "A1",      "B1", H("A1", "B1"), "2026-01-01", HIGH,         "N", "insert"]], GREEN),
        ("DAY 2 — TGT   ·   impacted keys = { K1 }", TGT, [
            ["K1", "(blank)", "B1", H("", "B1"), "2026-09-09", "2026-09-10", "N",
             "untouched — HASH same, expiry same"],
            ["K1", "A1", "B1", H("A1", "B1"), "2026-09-10", "2026-09-15", "N",
             "UPDATE EXP DATE — HASH same, expiry moved (was 2026-09-21)"],
            ["K1", "A2", "B1", H("A2", "B1"), "2026-09-21", "2026-09-21", "N",
             "DEAD RECORD — HASH changed (B1→B2), expiry was 9999"],
            ["K1", "A1", "B2", H("A1", "B2"), "2026-09-15", "2026-09-21", "N", "insert"],
            ["K1", "A2", "B2", H("A2", "B2"), "2026-09-21", "2026-09-22", "N", "insert"],
            ["K1", "A2", "B3", H("A2", "B3"), "2026-09-22", HIGH,         "N", "insert"],
            ["K8", "A1", "B1", H("A1", "B1"), "2026-01-01", HIGH,         "N",
             "NOT READ, NOT WRITTEN — K8 never enters the impacted-key list"]], GREEN),
    ],
    points=[
        "K8's REFINED_TIMESTAMP is still 21-Sep, outside the 22-Sep sourcing window, so it never appears in the list of impacted keys. It is not read and not written — no work is done for it at all.",
        "This is what keeps the run proportional to what actually changed rather than to the size of the table.",
        "K1's rows follow the ordinary rule exactly as in S01 — one untouched, one expiry update, one dead record, three inserts.",
    ],
    ques=[
        "Q10 — a key with the high end date sits in the target indefinitely with no re-validation. If a source ever deletes its own versions without touching REFINED_TIMESTAMP, the target keeps a row the source no longer holds.",
    ], tabcolor="FF0000")

# ══════════════════════════════════ S09 ══════════════════════════════════
scenario("S09 Brand new key", "S09 — A key appearing for the first time",
    left=[
        ("SRC_1", SRC1, [["K9", "A1", H("A1"), "2026-08-01", HIGH]], None),
        ("SRC_2", SRC2, [["K9", "B1", H("B1"), "2026-08-01", HIGH]], None),
    ],
    right=[
        ("TGT", TGT, [["K9", "A1", "B1", H("A1", "B1"), "2026-08-01", HIGH, "N", "insert"]], GREEN),
    ],
    points=[
        "There is nothing in the target to compare against, so every interval falls to the fourth line of the rule table — no matching row, therefore INSERT. Nothing is updated and nothing is retired.",
        "No special first-load path is needed — it is the ordinary logic with an empty target.",
    ])

# ══════════════════════════════════ S10 — Z1 RERUN ══════════════════════════════════
S1U = ["PRIMARY_KEY", "NON_KEY_1", "HASH", "ROW_EFF_DATE", "ROW_EXP_DATE", "UNIQUE_ID", "REFINED_TIMESTAMP"]
S2U = ["PRIMARY_KEY", "NON_KEY_2", "HASH", "ROW_EFF_DATE", "ROW_EXP_DATE", "UNIQUE_ID", "REFINED_TIMESTAMP"]
TGU = TGT + ["UUID"]
scenario("S10 Exec type Z1 RERUN", "S10 — execution_type = Z1 RERUN   ·   DECIDED: Option 1, no separate code path",
    left=[
        ("DAY 1 — SRC_1", S1U, [
            ["K1", "A1", H("A1"), "2026-09-10", "2026-09-21", "U-001", "2026-09-21 08:00"],
            ["K1", "A2", H("A2"), "2026-09-21", HIGH,         "U-002", "2026-09-21 08:00"]], None),
        ("DAY 1 — SRC_2", S2U, [
            ["K1", "B1", H("B1"), "2026-09-09", HIGH, "U-101", "2026-09-21 08:00"]], None),
        ("CASE 1 · DAY 2 — SRC_1   ·   new UNIQUE_IDs and timestamps, SAME values", S1U, [
            ["K1", "A1", H("A1"), "2026-09-10", "2026-09-21", "U-201", "2026-09-22 08:00"],
            ["K1", "A2", H("A2"), "2026-09-21", HIGH,         "U-202", "2026-09-22 08:00"]], GREY),
        ("CASE 1 · DAY 2 — SRC_2   ·   new UNIQUE_ID and timestamp, SAME value", S2U, [
            ["K1", "B1", H("B1"), "2026-09-09", HIGH, "U-301", "2026-09-22 08:00"]], GREY),
        ("CASE 2 · DAY 2 — SRC_1   ·   unchanged values, new UNIQUE_IDs", S1U, [
            ["K1", "A1", H("A1"), "2026-09-10", "2026-09-21", "U-201", "2026-09-22 08:00"],
            ["K1", "A2", H("A2"), "2026-09-21", HIGH,         "U-202", "2026-09-22 08:00"]], GREY),
        ("CASE 2 · DAY 2 — SRC_2   ·   changed", S2U, [
            ["K1", "B1", H("B1"), "2026-09-09", "2026-09-15", "U-301", "2026-09-22 08:00"],
            ["K1", "B2", H("B2"), "2026-09-15", "2026-09-22", "U-302", "2026-09-22 08:00"],
            ["K1", "B3", H("B3"), "2026-09-22", HIGH,         "U-303", "2026-09-22 08:00"]], RED),
    ],
    right=[
        ("DAY 1 — TGT", TGU, [
            ["K1", "(blank)", "B1", H("", "B1"),   "2026-09-09", "2026-09-10", "N", "insert", "T-001"],
            ["K1", "A1",      "B1", H("A1", "B1"), "2026-09-10", "2026-09-21", "N", "insert", "T-002"],
            ["K1", "A2",      "B1", H("A2", "B1"), "2026-09-21", HIGH,         "N", "insert", "T-003"]], GREEN),
        ("CASE 1 — a rerun where nothing actually changed   ·   DAY 2 TGT", TGU, [
            ["K1", "(blank)", "B1", H("", "B1"), "2026-09-09", "2026-09-10", "N",
             "no change — HASH same, expiry same. UUID restamped", "T-001"],
            ["K1", "A1", "B1", H("A1", "B1"), "2026-09-10", "2026-09-21", "N",
             "no change — HASH same, expiry same. UUID restamped", "T-002"],
            ["K1", "A2", "B1", H("A2", "B1"), "2026-09-21", HIGH, "N",
             "no change — HASH same, expiry same. UUID restamped", "T-003"]], GREEN),
        ("CASE 2 — a rerun where the content did change   ·   DAY 2 TGT, identical to S01", TGU, [
            ["K1", "(blank)", "B1", H("", "B1"), "2026-09-09", "2026-09-10", "N",
             "no change — UUID restamped", "T-001"],
            ["K1", "A1", "B1", H("A1", "B1"), "2026-09-10", "2026-09-15", "N",
             "UPDATE EXP DATE — HASH same, expiry moved", "T-002"],
            ["K1", "A2", "B1", H("A2", "B1"), "2026-09-21", "2026-09-21", "N",
             "DEAD RECORD — HASH changed, expiry was 9999", "T-003"],
            ["K1", "A1", "B2", H("A1", "B2"), "2026-09-15", "2026-09-21", "N", "insert", "T-004"],
            ["K1", "A2", "B2", H("A2", "B2"), "2026-09-21", "2026-09-22", "N", "insert", "T-005"],
            ["K1", "A2", "B3", H("A2", "B3"), "2026-09-22", HIGH,         "N", "insert", "T-006"]], GREEN),
    ],
    points=[
        "DECIDED — Option 1. A Z1 rerun needs no separate code path. The ordinary rule already produces the right answer in both cases.",
        "Case 1: every rebuilt interval matches an existing target row on effective date, every HASH is unchanged and every expiry is unchanged, so every row falls to 'untouched'. No surrogate key is churned, no row is retired, nothing is re-inserted.",
        "Case 2: the result is identical to S01, row for row. A rerun that genuinely changed something is just a run that changed something.",
        "The only rerun-specific act is restamping the UUID so the row records which run last confirmed it. That is a column update, not a branch in the logic.",
        "The rejected alternative (Option 2) deleted all rows for the key and re-inserted them. Ruled out because it churns every surrogate key even when nothing changed, which breaks anything downstream that joins on them.",
    ],
    ques=[
        "Q5 — what exactly is UUID on the target? A row identifier we generate per target row and restamp each run, or the source UNIQUE_ID carried through? If it is carried through, which source supplies it — a target row is built from both, and the 09-Sep row here comes only from SRC_2. The T-nnn values above assume a target-generated id.",
    ], tabcolor="FF0000")

# ══════════════════════════════════ S11 — RESTART ══════════════════════════════════
TGA = ["PRIMARY_KEY", "NON_KEY_1", "NON_KEY_2", "HASH", "ROW_EFF_DATE", "ROW_EXP_DATE",
       "DELETE_IND", "AUDIT_BATCH_ID", "ACTION"]
scenario("S11 Exec type RESTART", "S11 — execution_type = RESTART",
    left=[
        ("DAY 1 — SRC_1", S1R, [
            ["K1", "A1", H("A1"), "2026-09-10", "2026-09-21", "2026-09-21 08:00"],
            ["K1", "A2", H("A2"), "2026-09-21", HIGH,         "2026-09-21 08:00"]], None),
        ("DAY 1 — SRC_2", S2R, [
            ["K1", "B1", H("B1"), "2026-09-09", HIGH, "2026-09-21 08:00"]], None),
        ("DAY 2 — SRC_1   ·   unchanged", S1R, [
            ["K1", "A1", H("A1"), "2026-09-10", "2026-09-21", "2026-09-21 08:00"],
            ["K1", "A2", H("A2"), "2026-09-21", HIGH,         "2026-09-21 08:00"]], GREY),
        ("DAY 2 — SRC_2   ·   changed", S2R, [
            ["K1", "B1", H("B1"), "2026-09-09", "2026-09-15", "2026-09-22 08:00"],
            ["K1", "B2", H("B2"), "2026-09-15", "2026-09-22", "2026-09-22 08:00"],
            ["K1", "B3", H("B3"), "2026-09-22", HIGH,         "2026-09-22 08:00"]], RED),
    ],
    right=[
        ("DAY 1 — TGT   ·   run 101, execution_type = NEW   ·   succeeded", TGA, [
            ["K1", "(blank)", "B1", H("", "B1"),   "2026-09-09", "2026-09-10", "N", "101", "insert"],
            ["K1", "A1",      "B1", H("A1", "B1"), "2026-09-10", "2026-09-21", "N", "101", "insert"],
            ["K1", "A2",      "B1", H("A2", "B1"), "2026-09-21", HIGH,         "N", "101", "insert"]], GREEN),
        ("DAY 2 — TGT   ·   run 102, execution_type = NEW   ·   FAILED part-way", TGA, [
            ["K1", "(blank)", "B1", H("", "B1"), "2026-09-09", "2026-09-10", "N", "101", "untouched"],
            ["K1", "A1", "B1", H("A1", "B1"), "2026-09-10", "2026-09-15", "N", "101",
             "expiry updated by run 102 before it died"],
            ["K1", "A2", "B1", H("A2", "B1"), "2026-09-21", "2026-09-21", "N", "101",
             "dead record written by run 102 before it died"],
        ], AMBER),
        ("DAY 2 — TGT   ·   run 102 re-run, execution_type = RESTART   ·   final", TGA, [
            ["K1", "(blank)", "B1", H("", "B1"), "2026-09-09", "2026-09-10", "N", "101",
             "untouched — HASH same, expiry same"],
            ["K1", "A1", "B1", H("A1", "B1"), "2026-09-10", "2026-09-15", "N", "101",
             "re-derived to the same value — the update is a no-op"],
            ["K1", "A2", "B1", H("A2", "B1"), "2026-09-21", "2026-09-21", "N", "101",
             "already dead, stays dead — retiring it again changes nothing"],
            ["K1", "A1", "B2", H("A1", "B2"), "2026-09-15", "2026-09-21", "N", "102",
             "insert — the work run 102 never got to"],
            ["K1", "A2", "B2", H("A2", "B2"), "2026-09-21", "2026-09-22", "N", "102",
             "insert — the work run 102 never got to"],
            ["K1", "A2", "B3", H("A2", "B3"), "2026-09-22", HIGH, "N", "102",
             "insert — the work run 102 never got to"]], GREEN),
    ],
    points=[
        "A restart keeps the SAME sourcing window, so Step 1 rebuilds exactly the same timeline. The diff then runs against whatever the target happens to hold at that moment — half-finished or not.",
        "Every action in the rule table is idempotent. Re-applying an expiry update writes the value that is already there; re-retiring a dead record leaves it dead; an interval already inserted now matches an existing row with the same HASH and expiry, so it falls to 'untouched'.",
        "That is why the design self-heals without ABC's automatic cleanup. It does not depend on that cleanup finding anything — the rows written by the failed run carry the INSERTING run's batch id, not run 102's.",
        "The update-in-place rule makes this stronger than it was. Under the old retire-and-reinsert handling a restart could retire a row the failed run had already replaced; now there is nothing to double-apply.",
    ],
    ques=[
        "Q4 — does ABC's automatic SCD2 cleanup (§3.4, keyed on execution_run_id + job_run_id) run against this target? We do not depend on it, but if it does run it must not fight our own idempotent re-derivation.",
    ], tabcolor="FF0000")

out = sys.argv[1] if len(sys.argv) > 1 else "Final_Scenarios_v2.xlsx"
wb.save(out)
print("wrote", out, "·", len(wb.sheetnames), "tabs")
