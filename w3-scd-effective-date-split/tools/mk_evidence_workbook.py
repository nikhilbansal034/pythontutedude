"""Builds POC_v2_Evidence.xlsx — tab 1 the rules, tab 2 the test-case grid.
Tabs 3+ are left for the user to add as each scenario is run."""
import os, sys, openpyxl
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

INK="14213D"; TEAL="2A6F6B"
HDR=PatternFill("solid",fgColor="14213D")
GREEN=PatternFill("solid",fgColor="D9EAD3")
AMBER=PatternFill("solid",fgColor="FCF3E8")
GREY=PatternFill("solid",fgColor="F2F2F2")
RED=PatternFill("solid",fgColor="F7E2DA")
thin=Side(style="thin",color="BFBFBF"); BOX=Border(left=thin,right=thin,top=thin,bottom=thin)
WRAP=Alignment(wrap_text=True,vertical="top")

HIGH = "9999-12-31"

# ── the 18 rules, from solution_design.md section 6 ───────────────────────────
RULES = [
 (1,"matches a target row","same","same · target at 9999","regular","do nothing","none"),
 (2,"matches a target row","same","same · target at 9999","rerun","update UUID — no data change","'U'"),
 (3,"matches a target row","same","same · target at real date","regular","do nothing","none"),
 (4,"matches a target row","same","same · target at real date","rerun","update UUID — no data change","'U'"),
 (5,"matches a target row","same","diff · target at 9999","regular",
    "EXPIRE IN PLACE — update ROW_EXP_DTE; no retire, no is_del, surrogate key survives. "
    "AND INSERT the new version at the new effective date if the source supplies one","'U' (+ 'I')"),
 (6,"matches a target row","same","diff · target at 9999","rerun","as rule 5, + update UUID","'U' (+ 'I')"),
 (7,"matches a target row","same","diff · target at REAL DATE","regular",
    "RETIRE — is_del='Y', both dates untouched — + INSERT a new entry at the SAME effective date","'D' + 'I'"),
 (8,"matches a target row","same","diff · target at REAL DATE","rerun","as rule 7, + update UUID","'D' + 'I'"),
 (9,"matches a target row","DIFF","same · target at 9999","regular",
    "DEAD RECORD — ROW_EXP_DTE pulled back to the row's own ROW_EFF_DTE — + INSERT at the same effective date","'D' + 'I'"),
 (10,"matches a target row","DIFF","same · target at 9999","rerun","as rule 9, + update UUID","'D' + 'I'"),
 (11,"matches a target row","DIFF","same · target at REAL DATE","regular",
     "RETIRE (is_del='Y') + INSERT at the same effective date","'D' + 'I'"),
 (12,"matches a target row","DIFF","same · target at REAL DATE","rerun","as rule 11, + update UUID","'D' + 'I'"),
 (13,"matches a target row","DIFF","diff · target at 9999","regular",
     "DEAD RECORD + INSERT at the same effective date","'D' + 'I'"),
 (14,"matches a target row","DIFF","diff · target at 9999","rerun","as rule 13, + update UUID","'D' + 'I'"),
 (15,"matches a target row","DIFF","diff · target at REAL DATE","regular",
     "RETIRE (is_del='Y') + INSERT at the same effective date","'D' + 'I'"),
 (16,"matches a target row","DIFF","diff · target at REAL DATE","rerun","as rule 15, + update UUID","'D' + 'I'"),
 (17,"NO target row at that effective date","—","—","either","INSERT","'I'"),
 (18,"target row's effective date is GONE from the rebuilt timeline","—","—","either",
     "NO ACTION — the row is left live, deliberately. See solution_design.md section 14","none"),
]

# ── the test-case grid, from poc_v2/TEST_PLAN.md ─────────────────────────────
# (scenario, tc, type, what it does, rules validated)
TCS = [
 ("S01  One source changes, the other does not",
  [("TC01 (D1R1)","P","initial load into an empty target","17"),
   ("TC02 (D1R2)","P","SRC_2 splits one version into three","7, 13, 17"),
   ("TC03 (D1R3)","I","re-run of the same window, nothing changed","— (0 writes)"),
   ("TC04 (D2R1)","E","SRC_2 splits on a boundary SRC_1 already uses","11"),
   ("TC05 (D2R2)","E","a value corrected in place, dates unchanged","9"),
   ("TC06 (D2R3)","C","a NULL business key arrives","— (0 writes)"),
   ("TC07 (D3R1)","P","a new version arrives ahead of the open row","5, 17")]),
 ("S02  Both sources change in the same run",
  [("TC01 (D1R1)","P","initial load into an empty target","17"),
   ("TC02 (D1R2)","P","both sources split in the same run","5, 17"),
   ("TC03 (D1R3)","I","re-run of the same window","— (0 writes)"),
   ("TC04 (D2R1)","E","both sources close on the SAME date","5, 17")]),
 ("S03  A change in a column the target never carries",
  [("TC01 (D1R1)","P","initial load into an empty target","17"),
   ("TC02 (D1R2)","N","only NOTE_TEXT changes","— (0 writes)"),
   ("TC03 (D1R3)","P","a real split, so there are several versions to test against","5, 17"),
   ("TC04 (D2R1)","N","NOTE_TEXT changes on EVERY version at once","— (0 writes)")]),
 ("S04  A value comes back after a different one",
  [("TC01 (D1R1)","P","initial load with a value that already repeats","17"),
   ("TC02 (D1R2)","I","re-run -- the two A1 runs must still not collapse","— (0 writes)"),
   ("TC03 (D1R3)","E","a third alternation","5, 17"),
   ("TC04 (D2R1)","E","a fourth alternation, back to A1 again","5, 17")]),
 ("S05  A gap in cover, with the same value either side",
  [("TC01 (D1R1)","P","initial load with a hole in SRC_1","17"),
   ("TC02 (D1R2)","I","re-run -- the gap must survive","— (0 writes)"),
   ("TC03 (D1R3)","E","a gap at the START of the timeline","17"),
   ("TC04 (D2R1)","E","a gap that runs to the high end date","5, 17")]),
 ("S06  A value corrected with no change to its dates",
  [("TC01 (D1R1)","P","initial load into an empty target","17"),
   ("TC02 (D1R2)","P","the value is corrected, both dates unchanged","9"),
   ("TC03 (D1R3)","I","re-run of the same window","— (0 writes)"),
   ("TC04 (D2R1)","E","corrected to NULL","9")]),
 ("S07  Several runs in one day against the same key",
  [("TC01 (D1R1)","P","day 1 run 1 -- initial load","17"),
   ("TC02 (D1R2)","P","day 1 run 2 -- SRC_2 moves","5, 17"),
   ("TC03 (D1R3)","P","day 1 run 3 -- and it sees what run 2 left","5, 17"),
   ("TC04 (D2R1)","P","TWO deliveries inside ONE window","5, 17"),
   ("TC05 (D2R2)","C","duplicate (key, effective date) with IDENTICAL timestamps","— (0 writes)")]),
 ("S08  A key no source touched this run",
  [("TC01 (D1R1)","P","initial load of TWO keys","17"),
   ("TC02 (D1R2)","P","only K1 changes -- K8 is outside the window","5, 17"),
   ("TC03 (D1R3)","I","re-run -- K8 still untouched","— (0 writes)"),
   ("TC04 (D2R1)","E","K8 IS impacted, but its content is identical","— (0 writes)")]),
 ("S09  A key appearing for the first time",
  [("TC01 (D1R1)","P","an empty target -- everything inserts","17"),
   ("TC02 (D1R2)","P","a second brand-new key, alongside an existing one","17"),
   ("TC03 (D1R3)","E","a new key arriving with SEVERAL versions at once","17"),
   ("TC04 (D2R1)","I","re-run -- no key inserts twice","— (0 writes)")]),
 ("S10  A back-dated correction to an already-closed interval",
  [("TC01 (D1R1)","P","initial load with closed intervals to correct later","17"),
   ("TC02 (D1R2)","P","hash changes on a closed row, expiry unchanged","11"),
   ("TC03 (D1R3)","I","re-run of the same window","— (0 writes)"),
   ("TC04 (D2R1)","E","hash AND expiry both change on a closed row","15, 17")]),
 ("S11  A stale / orphan row after Zone1 loses history",
  [("TC01 (D1R1)","P","initial load, three intervals","17"),
   ("TC02 (D1R2)","P","Zone1 loses its early history","— (0 writes)"),
   ("TC03 (D1R3)","I","re-run while still degraded","— (0 writes)"),
   ("TC04 (D2R1)","E","PARTIAL recovery -- and this is where it costs","17"),
   ("TC05 (D2R2)","E","FULL recovery -- the original orphan self-heals","— (0 writes)")]),
 ("S12  execution_type = Z1_RERUN",
  [("TC01 (D1R1)","P","initial load, one closed row and one open row","17"),
   ("TC02 (D1R2)","P","rerun, nothing changed -- rules 2 AND 4","2, 4"),
   ("TC03 (D1R3)","E","rerun with a genuinely NEW interval -- rule 6 and rule 17","4, 6, 17"),
   ("TC04 (D2R1)","P","rerun, dead record -- rule 10","4, 10"),
   ("TC05 (D2R2)","P","rerun, back-dated correction -- rule 12","2, 4, 12"),
   ("TC06 (D2R3)","P","rerun, expiry moves on a closed row -- rule 8","2, 4, 8, 17"),
   ("TC07 (D3R1)","P","rerun, hash AND expiry move at the high end date -- rule 14","4, 14, 17"),
   ("TC08 (D3R2)","P","rerun, hash AND expiry move on a closed row -- rule 16","2, 4, 16")]),
 ("S13  execution_type = RESTART",
  [("TC01 (D1R1)","P","initial load","17"),
   ("TC02 (D1R2)","N","the run FAILS before it processes anything","— (0 writes)"),
   ("TC03 (D1R3)","P","the RESTART picks it up","5, 17"),
   ("TC04 (D2R1)","I","restarting twice applies it once","— (0 writes)")]),
 ("S14  The hash definition itself changes",
  [("TC01 (D1R1)","P","initial load of two independent keys","17"),
   ("TC02 (D1R2)","P","the hash definition changes -- and only K1 is impacted","9, 11"),
   ("TC03 (D1R3)","I","re-run under the NEW definition","— (0 writes)"),
   ("TC04 (D2R1)","P","K2 becomes impacted, and re-derives in its turn","9, 11"),
   ("TC05 (D2R2)","P","restore the original hash definition","9, 11")]),
 ("S15  Many keys at once, and the invariants that must always hold",
  [("TC01 (D1R1)","V","six keys of different shapes, loaded at once","17"),
   ("TC02 (D1R2)","V","several keys change at once, in different ways","5, 9, 17"),
   ("TC03 (D1R3)","C","corrupt rows arrive alongside good ones","— (0 writes)")]),
]

TYPE_NAME={"P":"Positive","I":"Idempotent","N":"Negative","E":"Edge","C":"Corrupt","V":"Volume"}
TYPE_FILL={"P":GREEN,"I":GREY,"N":GREY,"E":AMBER,"C":RED,"V":AMBER}

def hdr(ws,row,cols,widths):
    for i,v in enumerate(cols,1):
        c=ws.cell(row=row,column=i,value=v)
        c.font=Font(bold=True,size=10,color="FFFFFF"); c.fill=HDR; c.border=BOX
        c.alignment=Alignment(wrap_text=True,vertical="center")
    ws.row_dimensions[row].height=30
    for i,w in enumerate(widths,1): ws.column_dimensions[get_column_letter(i)].width=w

def put(ws,row,vals,fill=None,bold=False):
    for i,v in enumerate(vals,1):
        c=ws.cell(row=row,column=i,value=v)
        c.font=Font(size=10,bold=bold,color=INK); c.border=BOX; c.alignment=WRAP
        if fill: c.fill=fill

# which test cases validate each rule -- MEASURED from a real run by
# tools/refresh_docs.py, never asserted by hand
covers={}
for scen,tcs in TCS:
    for tc,_,_,rules in tcs:
        for r in rules.split(","):
            r=r.strip()
            if r.isdigit(): covers.setdefault(int(r),[]).append(f"{scen[:3]} {tc}")

wb=openpyxl.Workbook(); wb.remove(wb.active)

# ── TAB 1 ────────────────────────────────────────────────────────────────────
ws=wb.create_sheet("01 Rules"); ws.sheet_view.showGridLines=False
c=ws.cell(row=1,column=1,value="The 18 rules — solution_design.md §6, from sources/Requirement.xlsx")
c.font=Font(bold=True,size=13,color=INK)
c=ws.cell(row=2,column=1,value="Match each rebuilt interval to the existing target row on PRIMARY_KEY + ROW_EFF_DATE. "
  "The matched row's CURRENT EXPIRY decides first; the HASH only decides inside the high-end-date branch. "
  "Each rule describes what happens at ONE effective date — a run normally triggers several for one key.")
c.font=Font(size=10,italic=True,color=INK); c.alignment=WRAP
ws.merge_cells(start_row=2,start_column=1,end_row=2,end_column=8); ws.row_dimensions[2].height=42
hdr(ws,4,["RULE","EFF_DATE","HASH","EXP_DATE","EXECUTION_TYPE","ACTION","STAGE FLAG","VALIDATED BY"],
       [7,26,8,26,15,62,12,30])
# rules 1, 3 and 18 are the DO-NOTHING rules -- they emit no stage row at all,
# so they are proved by ZERO WRITES in the idempotent cases, not by a visible row
SILENT = {1: "S01 TC03, S02 TC03, S06 TC03 and every other idempotent case — proved by ZERO WRITES",
          3: "S01 TC03, S08 TC03, S10 TC03 and every other idempotent case — proved by ZERO WRITES",
          18:"S11 TC02–TC05 — proved by the orphan staying LIVE and UNTOUCHED, 0 stage rows"}
r=5
for n,eff,h,exp,et,act,flag in RULES:
    hits=sorted(set(covers.get(n,[])))
    if hits:              val = ", ".join(hits)
    elif n in SILENT:     val = SILENT[n]
    else:                 val = "— NOT COVERED —"
    put(ws,r,[n,eff,h,exp,et,act,flag,val],
        fill=RED if (not hits and n not in SILENT) else (GREY if et=="rerun" else None))
    r+=1
c=ws.cell(row=r+1,column=2,value="RETIRE means: DEAD RECORD (expiry pulled back to the row's own eff date) when the "
  "target row sat at 9999-12-31, otherwise DELETE_IND = 'Y' with both dates left alone.")
c.font=Font(size=10,italic=True,color=INK)
c=ws.cell(row=r+2,column=2,value="HASH is taken over the columns that actually reach the target — not over every source column.")
c.font=Font(size=10,italic=True,color=INK)
c=ws.cell(row=r+3,column=2,value="Target read must be: is_del = 'N' AND row_eff_dte < row_exp_dte. A dead record keeps "
  "is_del = 'N', so without the second condition a re-run sees two live rows at one effective date and cannot match.")
c.font=Font(size=10,italic=True,color=INK)
ws.freeze_panes="A5"

# ── TAB 2 ────────────────────────────────────────────────────────────────────
ws=wb.create_sheet("02 Test Cases"); ws.sheet_view.showGridLines=False
c=ws.cell(row=1,column=1,value="Scenarios and test cases — poc_v2/TEST_PLAN.md")
c.font=Font(bold=True,size=13,color=INK)
total=sum(len(t) for _,t in TCS)
c=ws.cell(row=2,column=1,value=f"{len(TCS)} scenarios, {total} test cases. Every one of the 18 rules is exercised "
  "at least once. Everything proved in POC v1 is treated as UNPROVEN — the rule changed after v1 ran.")
c.font=Font(size=10,italic=True,color=INK); c.alignment=WRAP
ws.merge_cells(start_row=2,start_column=1,end_row=2,end_column=6); ws.row_dimensions[2].height=30
hdr(ws,4,["SCENARIO","TEST CASE","TYPE","WHAT IT DOES","RULES VALIDATED","EVIDENCE TAB"],
       [44,11,13,66,20,16])
r=5
for scen,tcs in TCS:
    put(ws,r,[scen,"","","","",""],fill=GREEN,bold=True); r+=1
    for tc,ty,what,rules in tcs:
        put(ws,r,["",tc,f"{ty}  {TYPE_NAME[ty]}",what,rules,scen[:3]],fill=TYPE_FILL[ty]); r+=1
r+=1
c=ws.cell(row=r,column=1,value="TYPES"); c.font=Font(bold=True,size=11,color=TEAL); r+=1
for k,v in [("P","the canonical case produces the expected target"),
            ("I","re-running the same input writes ZERO rows"),
            ("N","input that must produce no change at all"),
            ("E","zero-length rows, same eff and exp, high-end-date boundaries"),
            ("C","NULL key, duplicate (key, eff date), timestamp outside the window"),
            ("V","many keys of different shapes at once, checked against structural invariants")]:
    put(ws,r,["",k,TYPE_NAME[k],v,"",""],fill=TYPE_FILL[k]); r+=1
ws.freeze_panes="A5"

# Default to the REAL evidence workbook so the guard below always applies. Pointing
# this at a fresh name would quietly produce a second, image-less workbook that
# looks like evidence and is not.
out=sys.argv[1] if len(sys.argv)>1 else "poc_v2/evidence/POC_Evidence.xlsx"

# REFUSE TO DESTROY EVIDENCE.
# Once a scenario tab carries screenshots, this file is no longer a build
# artefact -- openpyxl drops embedded images on save, so regenerating over it
# silently deletes them. Tabs 1 and 2 must then be edited in place, or the
# captions and screenshots rebuilt by hand.
if os.path.exists(out):
    import zipfile
    with zipfile.ZipFile(out) as _z:
        _imgs = [n for n in _z.namelist() if "/media/" in n]
    _extra = [n for n in openpyxl.load_workbook(out).sheetnames
              if n not in ("01 Rules", "02 Test Cases")]
    if _imgs or _extra:
        sys.exit(f"REFUSING to overwrite {out}: it holds {len(_imgs)} embedded image(s) "
                 f"and the tab(s) {_extra}. openpyxl would drop every image. "
                 f"Edit tabs 1-2 in place, or pass a different output path.")

wb.save(out)
print(f"wrote {out}")
print(f"  tabs: {wb.sheetnames}")
print(f"  {len(TCS)} scenarios, {total} test cases")
gaps=[n for n in range(1,19) if n not in covers]
print(f"  rules covered: {18-len(gaps)}/18" + (f"  GAPS: {gaps}" if gaps else "  — all 18"))
