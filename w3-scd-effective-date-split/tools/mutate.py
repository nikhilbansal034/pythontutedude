"""Injects known-wrong data and confirms verify.py catches each one."""
import subprocess, shutil, openpyxl, sys

def find_cell(ws, pred):
    for r in range(1, ws.max_row+1):
        for c in range(1, ws.max_column+1):
            if pred(ws.cell(r,c).value): return r, c
    return None, None

MUTS = {
 "M1 revert S01 to the OLD retire-and-reinsert behaviour":
   ("S01 One source changes", lambda v: isinstance(v,str) and v.startswith("UPDATE EXP DATE"),
    "RETIRED — exp was a real date, so delete indicator"),
 "M2 wrong expiry on an S01 insert":
   ("S01 One source changes", lambda v: v=="2026-09-22", "2026-09-23"),
 "M3 wrong HASH on an S06 target row":
   ("S06 Value fixed same dates", lambda v: v=="H(A9|B1)", "H(A1|B1)"),
 "M4 drop the dead record from S06":
   ("S06 Value fixed same dates", lambda v: isinstance(v,str) and v.startswith("DEAD RECORD"),
    "insert"),
}

caught = 0
for name,(tab,pred,new) in MUTS.items():
    shutil.copy("Final_Scenarios_v2.xlsx","_mut.xlsx")
    wb = openpyxl.load_workbook("_mut.xlsx"); ws = wb[tab]
    r,c = find_cell(ws, pred)
    if r is None:
        print(f"  {name}: COULD NOT APPLY"); continue
    ws.cell(r,c).value = new; wb.save("_mut.xlsx")
    rc = subprocess.run([sys.executable,"verify.py","_mut.xlsx"],capture_output=True,text=True)
    ok = rc.returncode != 0
    caught += ok
    print(f"  {name}: {'CAUGHT' if ok else 'MISSED  <-- verifier is blind to this'}")
print(f"\n{caught}/{len(MUTS)} mutations caught")
sys.exit(0 if caught==len(MUTS) else 1)
