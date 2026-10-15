import duckdb
HI = "DATE '9999-12-31'"

def build(elem_rows):
    c = duckdb.connect()
    c.execute("CREATE TABLE acct_ref_t(k VARCHAR, eff DATE, exp DATE, typ VARCHAR)")
    c.executemany("INSERT INTO acct_ref_t VALUES (?,?,?,?)", [
        ('1001','2024-01-01','2024-06-01','L'),
        ('1001','2024-06-01','9999-12-31','M')])
    c.execute("CREATE TABLE elem_t(k VARCHAR, eff DATE, exp DATE, ind VARCHAR)")
    c.executemany("INSERT INTO elem_t VALUES (?,?,?,?)", elem_rows)
    # section 8 algorithm
    c.execute(f"""
    CREATE TABLE stg AS
    WITH b AS (
        SELECT k, eff AS d FROM acct_ref_t UNION
        SELECT k, exp AS d FROM acct_ref_t UNION
        SELECT k, eff AS d FROM elem_t      UNION
        SELECT k, exp AS d FROM elem_t),
    iv AS (
        SELECT k, d AS s, LEAD(d) OVER (PARTITION BY k ORDER BY d) AS e FROM b),
    cand AS (SELECT * FROM iv WHERE e IS NOT NULL),
    res AS (
        SELECT c.k, c.s, c.e,
               (SELECT a.typ FROM acct_ref_t a
                 WHERE a.k=c.k AND a.eff<=c.s AND a.exp>=c.e) AS typ,
               (SELECT x.ind FROM elem_t x
                 WHERE x.k=c.k AND x.eff<=c.s AND x.exp>=c.e) AS ind
        FROM cand c),
    -- driving source bounds the target
    bounded AS (SELECT * FROM res WHERE typ IS NOT NULL),
    -- step 4: collapse adjacent identical touching intervals
    grp AS (
        SELECT *, SUM(brk) OVER (PARTITION BY k ORDER BY s) AS g FROM (
          SELECT *, CASE WHEN LAG(e) OVER (PARTITION BY k ORDER BY s) = s
                          AND LAG(typ) OVER (PARTITION BY k ORDER BY s) IS NOT DISTINCT FROM typ
                          AND LAG(ind) OVER (PARTITION BY k ORDER BY s) IS NOT DISTINCT FROM ind
                         THEN 0 ELSE 1 END AS brk
          FROM bounded))
    SELECT k AS business_key, MIN(s) AS row_effective_datetime, MAX(e) AS row_expiration_datetime,
           ANY_VALUE(typ) AS typ, ANY_VALUE(ind) AS ind,
           CASE WHEN MAX(e) >= {HI} THEN 'Y' ELSE 'N' END AS current_record_indicator,
           0 AS change_flag
    FROM grp GROUP BY k, g ORDER BY 2""")
    return c

ASSERTS = [
 ("DUPLICATE_KEY_EFF", "SELECT COUNT(*) FROM (SELECT business_key,row_effective_datetime FROM stg GROUP BY 1,2 HAVING COUNT(*)>1)"),
 ("CURRENT_IND_MISMATCH", f"SELECT COUNT(*) FROM stg WHERE current_record_indicator <> CASE WHEN row_expiration_datetime >= {HI} THEN 'Y' ELSE 'N' END"),
 ("OVERLAPPING_INTERVALS", "SELECT COUNT(*) FROM stg a JOIN stg b ON a.business_key=b.business_key AND a.row_effective_datetime<b.row_effective_datetime AND b.row_effective_datetime<a.row_expiration_datetime"),
 ("BAD_INTERVAL", "SELECT COUNT(*) FROM stg WHERE row_expiration_datetime <= row_effective_datetime"),
 ("NULL_BUSINESS_KEY", "SELECT COUNT(*) FROM stg WHERE business_key IS NULL"),
 ("OPEN_ENDED_COUNT", f"SELECT COUNT(*) FROM (SELECT business_key FROM stg WHERE row_expiration_datetime >= {HI} GROUP BY 1 HAVING COUNT(*)<>1)"),
 ("CONTAINMENT_VIOLATION", "SELECT COUNT(*) FROM (SELECT s.business_key, s.row_effective_datetime FROM stg s JOIN elem_t c ON s.business_key=c.k WHERE c.eff < s.row_expiration_datetime AND s.row_effective_datetime < c.exp GROUP BY 1,2 HAVING COUNT(DISTINCT CONCAT_WS('~', COALESCE(c.ind,'~NULL~')))>1)"),
 ("NON_INSERT_FLAG", "SELECT COUNT(*) FROM stg WHERE change_flag <> 0"),
]

for label, elem in [
  ("worked example (Y then N)", [('1001','2024-01-01','2024-03-15','Y'),('1001','2024-03-15','9999-12-31','N')]),
  ("collapse variant (Y then Y)", [('1001','2024-01-01','2024-03-15','Y'),('1001','2024-03-15','9999-12-31','Y')]),
]:
    c = build(elem)
    print("==", label)
    for r in c.execute("SELECT * FROM stg").fetchall(): print("  ", r)
    for name, q in ASSERTS:
        n = c.execute(q).fetchone()[0]
        print(f"   {'OK ' if n==0 else 'FAIL'} {name} = {n}")

# negative control: no-split (naive join) must trip assertion 1
c = build([('1001','2024-01-01','2024-03-15','Y'),('1001','2024-03-15','9999-12-31','N')])
c.execute("""CREATE TABLE naive AS
  SELECT a.k AS business_key, a.eff AS row_effective_datetime, a.exp AS row_expiration_datetime, x.ind
  FROM acct_ref_t a JOIN elem_t x ON a.k=x.k""")
print("== negative control: naive join, no date predicate")
print("   rows:", c.execute("SELECT COUNT(*) FROM naive").fetchone()[0], "(design says 4)")
dup = c.execute("SELECT COUNT(*) FROM (SELECT business_key,row_effective_datetime FROM naive GROUP BY 1,2 HAVING COUNT(*)>1)").fetchone()[0]
print(f"   {'OK ' if dup>0 else 'FAIL'} DUPLICATE_KEY_EFF trips = {dup} (must be > 0)")
