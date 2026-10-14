"""Reproduces every executed claim in dataassist_department_findings.md.

D2 hash divergence, D3 tautological checks and the hidden source duplicate,
D4 double-insert, and the dedup discarding a second source system.
Needs duckdb only.
"""
import duckdb, hashlib

c = duckdb.connect()
HI = "TIMESTAMP '9999-12-31 00:00:00'"

# HR_DEPT_T seeded with a CORRUPT SCD-2 chain: dept 00123 has TWO rows on the same
# effective date, and a third that overlaps a later one. Exactly what the checks exist to find.
c.execute("""CREATE TABLE HR_DEPT_T(DEPT_NUM VARCHAR, DEPT_NME VARCHAR, SRC_SYS_NME VARCHAR,
             ROW_EFF_DTE TIMESTAMP, ROW_EXP_DTE TIMESTAMP)""")
c.executemany("INSERT INTO HR_DEPT_T VALUES (?,?,?,?,?)", [
  ('00123','Claims'   ,'PAYROLL' ,'2024-01-01','2024-06-01'),
  ('00123','Claims DUP','BENEFITS','2024-01-01','9999-12-31'),   # duplicate (key, eff date)
  ('00123','Claims v2','PAYROLL' ,'2024-03-01','9999-12-31'),    # overlaps the first
])
print("HR_DEPT_T holds 3 rows for dept 00123, two sharing an effective date, one overlapping:")
for r in c.execute("SELECT * FROM HR_DEPT_T").fetchall(): print("   ", r)

# Q1 exactly as generated
c.execute(f"""CREATE TABLE DEPARTMENT_STG AS
WITH department_hr_dept_t_records AS (
  SELECT CAST(hd.DEPT_NUM AS VARCHAR(5)) AS DEPARTMENT_NUMBER,
         CAST(hd.DEPT_NME AS VARCHAR(70)) AS DEPARTMENT_NAME,
         CAST('EMPLOYEE' AS VARCHAR(30)) AS SOURCE_SYSTEM_NAME,
         CAST(hd.ROW_EFF_DTE AS TIMESTAMP) AS ROW_EFFECTIVE_DATETIME,
         CAST(hd.ROW_EXP_DTE AS TIMESTAMP) AS ROW_EXPIRATION_DATETIME,
         CAST(NULL AS VARCHAR(1)) AS DELETE_INDICATOR,
         1 AS TABLE_PRIORITY
  FROM HR_DEPT_T hd),
all_records AS (SELECT * FROM department_hr_dept_t_records),
cross_table_deduped AS (
  SELECT *, CAST(CASE WHEN ROW_EXPIRATION_DATETIME >= {HI} THEN 'Y' ELSE 'N' END AS VARCHAR(1))
              AS CURRENT_RECORD_INDICATOR,
         ROW_NUMBER() OVER (PARTITION BY DEPARTMENT_NUMBER, ROW_EFFECTIVE_DATETIME
                            ORDER BY TABLE_PRIORITY ASC, ROW_EXPIRATION_DATETIME DESC) AS final_dedup_rn
  FROM all_records),
final_deduped AS (SELECT * FROM cross_table_deduped WHERE final_dedup_rn = 1)
SELECT DEPARTMENT_NUMBER, DEPARTMENT_NAME, SOURCE_SYSTEM_NAME,
       ROW_EFFECTIVE_DATETIME, ROW_EXPIRATION_DATETIME,
       CURRENT_RECORD_INDICATOR, DELETE_INDICATOR, 0 AS CHANGE_FLAG
FROM final_deduped""")
print("\nstaging after Q1 — the duplicate was silently dropped before any check could see it:")
for r in c.execute("SELECT DEPARTMENT_NUMBER,DEPARTMENT_NAME,ROW_EFFECTIVE_DATETIME,ROW_EXPIRATION_DATETIME FROM DEPARTMENT_STG ORDER BY 3").fetchall(): print("   ", r)

checks = [
 ("1 DUPLICATE_KEY_EFF",    "SELECT COUNT(*) FROM (SELECT DEPARTMENT_NUMBER, ROW_EFFECTIVE_DATETIME FROM DEPARTMENT_STG GROUP BY 1,2 HAVING COUNT(*)>1)"),
 ("2 CURRENT_IND_MISMATCH", f"SELECT COUNT(*) FROM DEPARTMENT_STG WHERE CURRENT_RECORD_INDICATOR <> CASE WHEN ROW_EXPIRATION_DATETIME >= {HI} THEN 'Y' ELSE 'N' END"),
 ("3 OVERLAPPING_INTERVALS","SELECT COUNT(*) FROM DEPARTMENT_STG a JOIN DEPARTMENT_STG b ON a.DEPARTMENT_NUMBER=b.DEPARTMENT_NUMBER AND a.ROW_EFFECTIVE_DATETIME<b.ROW_EFFECTIVE_DATETIME AND b.ROW_EFFECTIVE_DATETIME<a.ROW_EXPIRATION_DATETIME"),
 ("4 BAD_INTERVAL",         "SELECT COUNT(*) FROM DEPARTMENT_STG WHERE ROW_EXPIRATION_DATETIME <= ROW_EFFECTIVE_DATETIME"),
 ("5 NULL_BUSINESS_KEY",    "SELECT COUNT(*) FROM DEPARTMENT_STG WHERE DEPARTMENT_NUMBER IS NULL"),
 ("6 OPEN_ENDED_COUNT",     f"SELECT COUNT(*) FROM (SELECT DEPARTMENT_NUMBER FROM DEPARTMENT_STG WHERE ROW_EXPIRATION_DATETIME >= {HI} GROUP BY 1 HAVING COUNT(*)<>1)"),
 ("8 NON_INSERT_FLAG",      "SELECT COUNT(*) FROM DEPARTMENT_STG WHERE CHANGE_FLAG <> 0"),
 ("9 DEGENERATE_KEY",       "SELECT CASE WHEN COUNT(DISTINCT DEPARTMENT_NUMBER) <= 1 THEN 1 ELSE 0 END FROM DEPARTMENT_STG"),
]
print("\ngenerated checks against this deliberately corrupt source:")
for n,q in checks:
    v=c.execute(q).fetchone()[0]
    print(f"   {'reports 0' if v==0 else 'FIRES  '}  {n} = {v}")
print("\n   -> check 1 reports 0 on a source that genuinely has a duplicate (key, eff date).")
print("      check 3 is the only one that catches the corrupt chain at all.")

print("\nchecks 1, 2 and 8 re-state what the same query just computed. Proof they cannot fail:")
print("   check 1: final_deduped is ROW_NUMBER()=1 over exactly (DEPARTMENT_NUMBER, ROW_EFFECTIVE_DATETIME)")
print("   check 2: compares CURRENT_RECORD_INDICATOR against the expression that produced it")
print("   check 8: CHANGE_FLAG is the literal 0 in the SELECT list")
print("\n   the duplicate the source really had, visible only BEFORE the dedup:")
n = c.execute("SELECT COUNT(*) FROM (SELECT DEPT_NUM, ROW_EFF_DTE FROM HR_DEPT_T GROUP BY 1,2 HAVING COUNT(*)>1)").fetchone()[0]
print(f"   same check run against HR_DEPT_T instead of DEPARTMENT_STG: {n}  <- this is where it belongs")

print("\n" + "=" * 70 + "\n")

c = duckdb.connect()

print("=== 1. DELETE_INDICATOR = NULL, and it is inside AUDIT_CHANGE_HASH ===")
def h(*vals):  # the generated hash expression: COALESCE(CAST(x AS VARCHAR),'') joined by '|'
    return hashlib.md5("|".join("" if v is None else str(v) for v in vals).encode()).hexdigest()
hist = h('00123','Claims','CLM','LM01','Y','EMPLOYEE','2024-01-01','9999-12-31', None)
incr = h('00123','Claims','CLM','LM01','Y','EMPLOYEE','2024-01-01','9999-12-31', 'N')
print(f"   historical row, DELETE_INDICATOR NULL -> {hist}")
print(f"   same row next run,  DELETE_INDICATOR 'N' -> {incr}")
print(f"   {'DIFFER' if hist!=incr else 'match'}  -> the first incremental run sees every historical row as changed\n")

print("=== 2. dedup partition is (DEPARTMENT_NUMBER, ROW_EFFECTIVE_DATETIME) only ===")
c.execute("""CREATE TABLE all_records(DEPARTMENT_NUMBER VARCHAR, SOURCE_SYSTEM_NAME VARCHAR,
             DEPARTMENT_NAME VARCHAR, ROW_EFFECTIVE_DATETIME DATE, ROW_EXPIRATION_DATETIME DATE,
             TABLE_PRIORITY INT)""")
c.executemany("INSERT INTO all_records VALUES (?,?,?,?,?,?)", [
  ('00123','PAYROLL','Claims Dept'  ,'2024-01-01','9999-12-31',1),
  ('00123','BENEFITS','Claims Dept B','2024-01-01','9999-12-31',1)])
print("   two source systems supply department 00123 on the same effective date:")
for r in c.execute("SELECT * FROM all_records").fetchall(): print("     ", r)
kept = c.execute("""SELECT DEPARTMENT_NUMBER, SOURCE_SYSTEM_NAME, DEPARTMENT_NAME FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY DEPARTMENT_NUMBER, ROW_EFFECTIVE_DATETIME
                                 ORDER BY TABLE_PRIORITY ASC, ROW_EXPIRATION_DATETIME DESC) AS rn
    FROM all_records) WHERE rn = 1""").fetchall()
print(f"   rows surviving dedup: {len(kept)} -> {kept}")
print("   -> one source system's department is silently discarded.\n")

print("=== 3. Q2 is a bare INSERT with no TRUNCATE ===")
c.execute("CREATE TABLE TGT(DEPARTMENT_ID INT, DEPARTMENT_NUMBER VARCHAR)")
c.execute("CREATE SEQUENCE DEPARTMENT_SEQ START 1")
for run in (1,2):
    c.execute("INSERT INTO TGT SELECT nextval('DEPARTMENT_SEQ'), '00123'")
    n = c.execute("SELECT COUNT(*) FROM TGT").fetchone()[0]
    print(f"   after run {run}: {n} row(s) in target")
print("   -> a re-run duplicates every row. A1 of the instruction file says truncate-and-reload;")
print("      the generated Q2 contains no TRUNCATE.")

print("\n" + "=" * 70 + "\n")
print("J1 / J4 — JOB: a whole job lost while every check reports zero\n")

c = duckdb.connect()
HI = "TIMESTAMP '9999-12-31 00:00:00'"

print("=== A. JOB_CODE scoped to HR business group? dedup partitions on JOB_CODE alone ===")
c.execute("""CREATE TABLE HR_JOB_T(JOB_CDE VARCHAR, HR_BUSN_GRP_CDE VARCHAR, JOB_TITL_NME VARCHAR,
             SRC_SYS_NME VARCHAR, ROW_EFF_DTE TIMESTAMP, ROW_EXP_DTE TIMESTAMP)""")
c.executemany("INSERT INTO HR_JOB_T VALUES (?,?,?,?,?,?)", [
  ('A100','CORP-US  ','Claims Adjuster'    ,'EMPLOYEE','2024-01-01','9999-12-31'),
  ('A100','SPECIALTY','Underwriting Analyst','EMPLOYEE','2024-01-01','9999-12-31'),
  ('B200','CORP-US  ','Actuary'            ,'EMPLOYEE','2024-01-01','2024-07-01'),
  ('B200','CORP-US  ','Senior Actuary'     ,'EMPLOYEE','2024-07-01','9999-12-31')])
print("   source holds job A100 in TWO business groups, and a clean 2-version chain for B200:")
for r in c.execute("SELECT JOB_CDE,HR_BUSN_GRP_CDE,JOB_TITL_NME,ROW_EFF_DTE FROM HR_JOB_T").fetchall(): print("     ", r)

# Q1 as generated
c.execute(f"""CREATE TABLE JOB_STG AS
WITH job_hr_job_t_records AS (
  SELECT CAST(hj.JOB_CDE AS VARCHAR(4)) AS JOB_CODE,
         CAST(hj.HR_BUSN_GRP_CDE AS VARCHAR(10)) AS HR_BUSINESS_GROUP_CODE,
         CAST(hj.JOB_TITL_NME AS VARCHAR(80)) AS JOB_TITLE_NAME,
         CAST('EMPLOYEE' AS VARCHAR(30)) AS SOURCE_SYSTEM_NAME,
         CAST(hj.ROW_EFF_DTE AS TIMESTAMP) AS ROW_EFFECTIVE_DATETIME,
         CAST(hj.ROW_EXP_DTE AS TIMESTAMP) AS ROW_EXPIRATION_DATETIME,
         CAST(NULL AS VARCHAR(1)) AS DELETE_INDICATOR, 1 AS TABLE_PRIORITY
  FROM HR_JOB_T hj),
all_records AS (SELECT * FROM job_hr_job_t_records),
cross_table_deduped AS (
  SELECT *, CAST(CASE WHEN ROW_EXPIRATION_DATETIME >= {HI} THEN 'Y' ELSE 'N' END AS VARCHAR(1))
              AS CURRENT_RECORD_INDICATOR,
         ROW_NUMBER() OVER (PARTITION BY JOB_CODE, ROW_EFFECTIVE_DATETIME
                            ORDER BY TABLE_PRIORITY ASC, ROW_EXPIRATION_DATETIME DESC) AS final_dedup_rn
  FROM all_records),
final_deduped AS (SELECT * FROM cross_table_deduped WHERE final_dedup_rn = 1)
SELECT JOB_CODE, HR_BUSINESS_GROUP_CODE, JOB_TITLE_NAME, SOURCE_SYSTEM_NAME,
       ROW_EFFECTIVE_DATETIME, ROW_EXPIRATION_DATETIME, CURRENT_RECORD_INDICATOR,
       DELETE_INDICATOR, 0 AS CHANGE_FLAG
FROM final_deduped""")
src_n = c.execute("SELECT COUNT(*) FROM HR_JOB_T").fetchone()[0]
stg_n = c.execute("SELECT COUNT(*) FROM JOB_STG").fetchone()[0]
print(f"\n   source rows {src_n} -> staging rows {stg_n}")
for r in c.execute("SELECT JOB_CODE,HR_BUSINESS_GROUP_CODE,JOB_TITLE_NAME FROM JOB_STG ORDER BY 1,2").fetchall(): print("     ", r)
print("   -> the SPECIALTY 'Underwriting Analyst' job is gone. One business group's job silently dropped.\n")

print("=== B. the generated checks against that same loss ===")
checks = [
 ("1 DUPLICATE_KEY_EFF",    "SELECT COUNT(*) FROM (SELECT JOB_CODE, ROW_EFFECTIVE_DATETIME FROM JOB_STG GROUP BY 1,2 HAVING COUNT(*)>1)"),
 ("2 CURRENT_IND_MISMATCH", f"SELECT COUNT(*) FROM JOB_STG WHERE CURRENT_RECORD_INDICATOR <> CASE WHEN ROW_EXPIRATION_DATETIME >= {HI} THEN 'Y' ELSE 'N' END"),
 ("3 OVERLAPPING_INTERVALS","SELECT COUNT(*) FROM JOB_STG a JOIN JOB_STG b ON a.JOB_CODE=b.JOB_CODE AND a.ROW_EFFECTIVE_DATETIME<b.ROW_EFFECTIVE_DATETIME AND b.ROW_EFFECTIVE_DATETIME<a.ROW_EXPIRATION_DATETIME"),
 ("4 BAD_INTERVAL",         "SELECT COUNT(*) FROM JOB_STG WHERE ROW_EXPIRATION_DATETIME <= ROW_EFFECTIVE_DATETIME"),
 ("5 NULL_BUSINESS_KEY",    "SELECT COUNT(*) FROM JOB_STG WHERE JOB_CODE IS NULL"),
 ("6 OPEN_ENDED_COUNT",     f"SELECT COUNT(*) FROM (SELECT JOB_CODE FROM JOB_STG WHERE ROW_EXPIRATION_DATETIME >= {HI} GROUP BY 1 HAVING COUNT(*)<>1)"),
 ("8 NON_INSERT_FLAG",      "SELECT COUNT(*) FROM JOB_STG WHERE CHANGE_FLAG <> 0"),
 ("9 DEGENERATE_KEY",       "SELECT CASE WHEN COUNT(DISTINCT JOB_CODE) <= 1 THEN 1 ELSE 0 END FROM JOB_STG"),
]
for n,q in checks:
    v=c.execute(q).fetchone()[0]
    print(f"   {'reports 0' if v==0 else 'FIRES  '}  {n} = {v}")
print("   -> all eight report 0. A whole job was lost and nothing says so.\n")

print("=== C. the same checks with the key as (JOB_CODE, HR_BUSINESS_GROUP_CODE) ===")
c.execute("""CREATE TABLE JOB_STG_FIXED AS
  SELECT * FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY JOB_CDE, HR_BUSN_GRP_CDE, ROW_EFF_DTE
                              ORDER BY ROW_EXP_DTE DESC) AS rn FROM HR_JOB_T) WHERE rn=1""")
print(f"   staging rows: {c.execute('SELECT COUNT(*) FROM JOB_STG_FIXED').fetchone()[0]}  (all four source rows kept)")
lost = c.execute("""SELECT COUNT(*) FROM (SELECT JOB_CDE, ROW_EFF_DTE FROM HR_JOB_T GROUP BY 1,2 HAVING COUNT(*)>1)""").fetchone()[0]
print(f"   source-side duplicate check on (JOB_CDE, ROW_EFF_DTE): {lost}  <- the signal, available only before the dedup\n")

print("=== D. DELETE_INDICATOR NULL inside the 13-term hash ===")
def h(*v): return hashlib.md5("|".join("" if x is None else str(x) for x in v).encode()).hexdigest()
cols = ['A100','CORP-US','Claims Adjuster','Claims Adj','Claims','Ops','Professional','Y','N','EMPLOYEE','2024-01-01','9999-12-31']
print(f"   DELETE_INDICATOR NULL -> {h(*cols, None)}")
print(f"   DELETE_INDICATOR 'N'  -> {h(*cols, 'N')}")
print(f"   {'DIFFER -> every unchanged row re-versions on the first incremental run' if h(*cols,None)!=h(*cols,'N') else 'match'}")

print("\n" + "=" * 70 + "\n")
print("OD1 / OD2 / OD3 — OFFICE_DEPARTMENT: the foreign-key boundary split\n")

c = duckdb.connect()

c.execute("""CREATE TABLE OFFICE(OFFICE_ID INT, OFFICE_NUMBER VARCHAR,
             ROW_EFFECTIVE_DATETIME DATE, ROW_EXPIRATION_DATETIME DATE, ROW_UPDATE_DATETIME DATE)""")
c.execute("""CREATE TABLE DEPARTMENT(DEPARTMENT_ID INT, DEPARTMENT_NUMBER VARCHAR,
             ROW_EFFECTIVE_DATETIME DATE, ROW_EXPIRATION_DATETIME DATE, ROW_UPDATE_DATETIME DATE)""")
c.execute("""CREATE TABLE OFFICE_DEPARTMENT_STG(OFFICE_NUMBER VARCHAR, DEPARTMENT_NUMBER VARCHAR,
             PHONE_NUMBER VARCHAR, ROW_EFFECTIVE_DATETIME DATE, ROW_EXPIRATION_DATETIME DATE)""")

def q2(label):
    """The generated Q2 CTE chain, transcribed."""
    return c.execute(f"""
    WITH fk_bounds AS (
      SELECT DISTINCT OFFICE_NUMBER, DEPARTMENT_NUMBER, b FROM (
        SELECT s.OFFICE_NUMBER, s.DEPARTMENT_NUMBER, s.ROW_EFFECTIVE_DATETIME AS b FROM OFFICE_DEPARTMENT_STG s
        UNION ALL
        SELECT s.OFFICE_NUMBER, s.DEPARTMENT_NUMBER, s.ROW_EXPIRATION_DATETIME AS b FROM OFFICE_DEPARTMENT_STG s
        UNION ALL
        SELECT s.OFFICE_NUMBER, s.DEPARTMENT_NUMBER, pa.ROW_EFFECTIVE_DATETIME AS b
        FROM OFFICE_DEPARTMENT_STG s JOIN OFFICE pa ON TRIM(s.OFFICE_NUMBER)=TRIM(pa.OFFICE_NUMBER)
        WHERE pa.ROW_EFFECTIVE_DATETIME > s.ROW_EFFECTIVE_DATETIME
          AND pa.ROW_EFFECTIVE_DATETIME < s.ROW_EXPIRATION_DATETIME
        UNION ALL
        SELECT s.OFFICE_NUMBER, s.DEPARTMENT_NUMBER, pa.ROW_EFFECTIVE_DATETIME AS b
        FROM OFFICE_DEPARTMENT_STG s JOIN DEPARTMENT pa ON TRIM(s.DEPARTMENT_NUMBER)=TRIM(pa.DEPARTMENT_NUMBER)
        WHERE pa.ROW_EFFECTIVE_DATETIME > s.ROW_EFFECTIVE_DATETIME
          AND pa.ROW_EFFECTIVE_DATETIME < s.ROW_EXPIRATION_DATETIME)
      WHERE b IS NOT NULL),
    fk_intervals AS (
      SELECT OFFICE_NUMBER, DEPARTMENT_NUMBER, b AS ROW_EFFECTIVE_DATETIME,
             LEAD(b) OVER (PARTITION BY OFFICE_NUMBER, DEPARTMENT_NUMBER ORDER BY b) AS ROW_EXPIRATION_DATETIME
      FROM fk_bounds),
    fk_split_stg AS (
      SELECT fi.ROW_EFFECTIVE_DATETIME, fi.ROW_EXPIRATION_DATETIME,
             s.OFFICE_NUMBER, s.DEPARTMENT_NUMBER, s.PHONE_NUMBER
      FROM fk_intervals fi
      JOIN OFFICE_DEPARTMENT_STG s ON fi.OFFICE_NUMBER=s.OFFICE_NUMBER AND fi.DEPARTMENT_NUMBER=s.DEPARTMENT_NUMBER
       AND s.ROW_EFFECTIVE_DATETIME <= fi.ROW_EFFECTIVE_DATETIME
       AND s.ROW_EXPIRATION_DATETIME >= fi.ROW_EXPIRATION_DATETIME
      WHERE fi.ROW_EXPIRATION_DATETIME IS NOT NULL)
    SELECT stg.OFFICE_NUMBER, stg.ROW_EFFECTIVE_DATETIME, stg.ROW_EXPIRATION_DATETIME,
           p_office_id.OFFICE_ID, p_department_id.DEPARTMENT_ID
    FROM fk_split_stg stg
    LEFT JOIN (SELECT OFFICE_ID, OFFICE_NUMBER, ROW_EFFECTIVE_DATETIME, ROW_EXPIRATION_DATETIME FROM OFFICE
               QUALIFY ROW_NUMBER() OVER (PARTITION BY OFFICE_NUMBER, ROW_EFFECTIVE_DATETIME ORDER BY ROW_UPDATE_DATETIME DESC)=1
              ) p_office_id
      ON stg.OFFICE_NUMBER = p_office_id.OFFICE_NUMBER
     AND stg.ROW_EFFECTIVE_DATETIME >= p_office_id.ROW_EFFECTIVE_DATETIME
     AND stg.ROW_EFFECTIVE_DATETIME <  p_office_id.ROW_EXPIRATION_DATETIME
    LEFT JOIN (SELECT DEPARTMENT_ID, DEPARTMENT_NUMBER, ROW_EFFECTIVE_DATETIME, ROW_EXPIRATION_DATETIME FROM DEPARTMENT
               QUALIFY ROW_NUMBER() OVER (PARTITION BY DEPARTMENT_NUMBER, ROW_EFFECTIVE_DATETIME ORDER BY ROW_UPDATE_DATETIME DESC)=1
              ) p_department_id
      ON stg.DEPARTMENT_NUMBER = p_department_id.DEPARTMENT_NUMBER
     AND stg.ROW_EFFECTIVE_DATETIME >= p_department_id.ROW_EFFECTIVE_DATETIME
     AND stg.ROW_EFFECTIVE_DATETIME <  p_department_id.ROW_EXPIRATION_DATETIME
    ORDER BY 2""").fetchall()

def reset():
    for t in ("OFFICE","DEPARTMENT","OFFICE_DEPARTMENT_STG"): c.execute(f"DELETE FROM {t}")

print("=== A. the normal case: OFFICE gains a new version mid-interval ===")
reset()
c.executemany("INSERT INTO OFFICE VALUES (?,?,?,?,?)", [
  (501,'O001','2024-01-01','2024-05-01','2024-01-01'),
  (502,'O001','2024-05-01','9999-12-31','2024-05-01')])
c.execute("INSERT INTO DEPARTMENT VALUES (701,'D001',DATE '2024-01-01',DATE '9999-12-31',DATE '2024-01-01')")
c.execute("INSERT INTO OFFICE_DEPARTMENT_STG VALUES ('O001','D001','555-0100',DATE '2024-01-01',DATE '9999-12-31')")
for r in q2("A"): print("   ", r)
print("   -> interval correctly CUT at 2024-05-01; each half carries the office version in force. CORRECT.\n")

print("=== B. OFFICE is RETIRED mid-interval (its expiry is a boundary, its effective date is not) ===")
reset()
c.execute("INSERT INTO OFFICE VALUES (501,'O001',DATE '2024-01-01',DATE '2024-05-01',DATE '2024-01-01')")  # no successor
c.execute("INSERT INTO DEPARTMENT VALUES (701,'D001',DATE '2024-01-01',DATE '9999-12-31',DATE '2024-01-01')")
c.execute("INSERT INTO OFFICE_DEPARTMENT_STG VALUES ('O001','D001','555-0100',DATE '2024-01-01',DATE '9999-12-31')")
for r in q2("B"): print("   ", r)
print("   -> ONE row 2024-01-01 -> 9999-12-31 carrying OFFICE_ID 501, which EXPIRED on 2024-05-01.")
print("      fk_bounds collects only the FK tables' EFFECTIVE dates, never their EXPIRATION dates,")
print("      so a retirement or a gap in the FK chain is not a cut point. STALE FK.\n")

print("=== C. the office_number does not exist in OFFICE at all ===")
reset()
c.execute("INSERT INTO DEPARTMENT VALUES (701,'D001',DATE '2024-01-01',DATE '9999-12-31',DATE '2024-01-01')")
c.execute("INSERT INTO OFFICE_DEPARTMENT_STG VALUES ('O999','D001','555-0100',DATE '2024-01-01',DATE '9999-12-31')")
for r in q2("C"): print("   ", r)
print("   -> OFFICE_ID is NULL. The association row points at no office, and NO CHECK counts it.\n")

print("=== D. the Q1 self-checks run on OFFICE_DEPARTMENT_STG, BEFORE Q2 re-splits ===")
reset()
c.executemany("INSERT INTO OFFICE VALUES (?,?,?,?,?)", [
  (501,'O001','2024-01-01','2024-05-01','2024-01-01'),
  (502,'O001','2024-05-01','9999-12-31','2024-05-01')])
c.execute("INSERT INTO DEPARTMENT VALUES (701,'D001',DATE '2024-01-01',DATE '9999-12-31',DATE '2024-01-01')")
c.execute("INSERT INTO OFFICE_DEPARTMENT_STG VALUES ('O001','D001','555-0100',DATE '2024-01-01',DATE '9999-12-31')")
stg_n = c.execute("SELECT COUNT(*) FROM OFFICE_DEPARTMENT_STG").fetchone()[0]
out_n = len(q2("D"))
print(f"   rows checked by Q1's nine assertions : {stg_n}")
print(f"   rows actually inserted by Q2         : {out_n}")
print("   -> Q2 changes the row set. Nothing asserts the post-split output: no duplicate check,")
print("      no overlap check, no interval-width check, no open-ended check, no FK-resolution check.")
