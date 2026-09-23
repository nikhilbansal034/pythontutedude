"""Injects known-wrong data and confirms verify.py catches each one.
Keeps the checks honest: a verifier that passes everything proves nothing."""
import subprocess, shutil, sys, openpyxl

SRC = sys.argv[1] if len(sys.argv) > 1 else "../Final_Scenarios_v2.xlsx"


def find(ws, pred, min_col=1):
    for r in range(1, ws.max_row + 1):
        for c in range(min_col, ws.max_column + 1):
            if pred(ws.cell(r, c).value):
                return r, c
    return None, None


# Each: (tab, predicate, min_col, replacement, why it must be caught)
MUTS = [
    ("M1 revert S01 to update-in-place - the exact error the transcript corrected",
     "S01 One source changes", lambda v: isinstance(v, str) and v.strip() == "Retired", 9,
     "UPDATE EXP DATE - hash same"),
    ("M2 wrong expiry on the corrected row S01 inserts",
     "S01 One source changes", lambda v: v == "2026-09-15", 9, "2026-09-16"),
    ("M3 wrong HASH on an S06 target row",
     "S06 Value fixed same dates", lambda v: v == "H(A9|B1)", 1, "H(A1|B1)"),
    ("M4 drop the dead record from S06",
     "S06 Value fixed same dates", lambda v: isinstance(v, str) and v.startswith("DEAD RECORD"), 1,
     "insert"),
    ("M5 retire a row that should be expired in place (S02 sat at 9999)",
     "S02 Both sources change", lambda v: isinstance(v, str) and v.startswith("UPDATE EXP DATE"), 1,
     "Retired"),
    ("M6 S07 run 102 loses its dead record",
     "S07 Multiple runs same day", lambda v: isinstance(v, str) and v.lower().startswith("dead record"), 1,
     "insert"),
]

caught = 0
for name, tab, pred, min_col, new in MUTS:
    shutil.copy(SRC, "_mut.xlsx")
    wb = openpyxl.load_workbook("_mut.xlsx"); ws = wb[tab]
    r, c = find(ws, pred, min_col)
    if r is None:
        print(f"  {name}: COULD NOT APPLY - target cell not found"); continue
    ws.cell(r, c).value = new
    wb.save("_mut.xlsx")
    rc = subprocess.run([sys.executable, "verify.py", "_mut.xlsx"], capture_output=True, text=True)
    ok = rc.returncode != 0
    caught += ok
    print(f"  {name}: {'CAUGHT' if ok else 'MISSED  <-- verifier is blind to this'}")

print(f"\n{caught}/{len(MUTS)} mutations caught")
sys.exit(0 if caught == len(MUTS) else 1)
