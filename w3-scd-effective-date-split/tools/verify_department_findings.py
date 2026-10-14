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
