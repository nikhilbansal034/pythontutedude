"""Builds POC_v2_Evidence.xlsx — tab 1 the rules, tab 2 the test-case grid.
Tabs 3+ are left for the user to add as each scenario is run."""
import sys, openpyxl
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
  [("TC01","P","SRC_2 splits one version into three. SRC_1 untouched. The base case","1, 3, 7, 13, 17"),
   ("TC02","I","Re-run with the key STILL impacted but nothing changed. 0 stage rows","1, 3"),
   ("TC03","E","SRC_2 changes exactly on an existing boundary — no new interval appears","9"),
   ("TC04","C","SRC_2 carries a NULL business key — dropped SILENTLY, K1 unaffected","—")]),
 ("S02  Both sources change in the same run",
  [("TC01","P","Both split in the same run; the target row sat at the high end date","5, 17"),
   ("TC02","I","Re-run, zero writes","1"),
   ("TC03","E","Both sources close on the same date","5, 17")]),
 ("S03  Change in a column the target never carries",
  [("TC01","P","Only NOTE_TEXT changes — a column that never reaches the target","1"),
   ("TC02","N","0 rows written, stage is empty","—"),
   ("TC03","E","The non-target column changes on every version at once","1")]),
 ("S04  A value comes back after a different one",
  [("TC01","P","A1 → A2 → A1. The two A1 runs must stay separate","17"),
   ("TC02","E","Three alternations in one key","17")]),
 ("S05  A gap in cover, same value either side",
  [("TC01","P","Uncovered interval carries a blank; the gap survives","17"),
   ("TC02","E","Gap at the start, and a gap ending at the high end date","17")]),
 ("S06  A value corrected with no change to its dates",
  [("TC01","P","Value changes, both dates identical. Target at 9999","9, 17"),
   ("TC02","I","Re-run, zero writes","1"),
   ("TC03","E","Correction to a value that is NULL on one side","9")]),
 ("S07  Several runs in one day, same key and eff date",
  [("TC01","P","Two runs same day; run 2 sees what run 1 left","5, 17"),
   ("TC02","P","Both same-day rows inside ONE window — the Q1 case","5, 17"),
   ("TC03","E","Three runs in one day","5, 17"),
   ("TC04","C","Duplicate (key, eff date) with identical timestamps — no tie-break","—")]),
 ("S08  A key no source touched this run",
  [("TC01","P","K1 impacted, K8 outside the window","1, 3, 7, 13, 17"),
   ("TC02","N","K8 neither read nor written — prove by row count","—"),
   ("TC03","E","A key impacted but whose content is identical — read, zero writes","1, 3")]),
 ("S09  A key appearing for the first time",
  [("TC01","P","Empty target, everything inserts","17"),
   ("TC02","E","New key whose first version already sits at the high end date","17")]),
 ("S10  Back-dated correction",
  [("TC01","P","Hash changes on an already-closed row, expiry unchanged","11"),
   ("TC02","P","Hash AND expiry both change on an already-closed row","15"),
   ("TC03","I","Re-run, zero writes","1, 3"),
   ("TC04","E","Correction to the oldest row in a long history","11")]),
 ("S11  Stale / orphan row",
  [("TC01","P","Zone1 loses history; the orphan is left LIVE and untouched","18"),
   ("TC02","I","Re-run while degraded — orphan still untouched","18"),
   ("TC03","P","Zone1 recovers; the timeline self-heals and the orphan falls to rule 1","1, 5"),
   ("TC04","E","Two overlapping live rows — prove read-by-effective-date returns the right one","18")]),
 ("S12  execution_type = Z1 RERUN",
  [("TC01","P","Rerun, nothing changed, target at 9999","2"),
   ("TC02","P","Rerun, nothing changed, target at a real date","4"),
   ("TC03","P","Rerun, expire in place, target at 9999","6"),
   ("TC04","P","Rerun, retire, hash same, target at a real date","8"),
   ("TC05","P","Rerun, dead record, hash diff, expiry same, target at 9999","10"),
   ("TC06","P","Rerun, retire, hash diff, expiry same, target at a real date","12"),
   ("TC07","P","Rerun, dead record, hash and expiry diff, target at 9999","14"),
   ("TC08","P","Rerun, retire, hash and expiry diff, target at a real date","16"),
   ("TC09","I","Rerun twice — UUID restamped, nothing else moves","2, 4")]),
 ("S13  execution_type = RESTART",
  [("TC01","P","MERGE commits, run marked failed, restart re-applies","—"),
   ("TC02","I","Restart writes zero rows","1, 3"),
   ("TC03","E","Restart when the stage is half-built","—"),
   ("TC04","C","Restart with the target read MISSING its dead-record filter — must fail loudly","—")]),
 ("S14  Hash-definition change",
  [("TC01","P","Column added; an impacted key re-derives under rules 9–16","9, 11, 13, 15"),
   ("TC02","N","A quiet key is untouched and keeps the new column empty","—"),
   ("TC03","E","Surrogate-key churn measured and recorded","—")]),
 ("S15  Volume and differential",
  [("TC01","V","1,000 random keys, one run, compared against tools/verify.py","all"),
   ("TC02","V","10 consecutive runs with random mutations, compared after each","all"),
   ("TC03","V","Random data including corrupt rows","all")]),
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

# which test cases validate each rule. S15 says "all" — it is a differential test
# against verify.py, so it covers every rule but naming it against all 18 is noise.
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
r=5
for n,eff,h,exp,et,act,flag in RULES:
    hits=sorted(set(covers.get(n,[])))
    val=(", ".join(hits)+"  + S15 (all)") if hits else "— NOT COVERED —"
    put(ws,r,[n,eff,h,exp,et,act,flag,val],
        fill=RED if not hits else (GREY if et=="rerun" else None))
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
            ("V","random keys at scale, compared row for row against tools/verify.py")]:
    put(ws,r,["",k,TYPE_NAME[k],v,"",""],fill=TYPE_FILL[k]); r+=1
ws.freeze_panes="A5"

out=sys.argv[1] if len(sys.argv)>1 else "POC_v2_Evidence.xlsx"
wb.save(out)
print(f"wrote {out}")
print(f"  tabs: {wb.sheetnames}")
print(f"  {len(TCS)} scenarios, {total} test cases")
gaps=[n for n in range(1,19) if n not in covers]
print(f"  rules covered: {18-len(gaps)}/18" + (f"  GAPS: {gaps}" if gaps else "  — all 18"))
