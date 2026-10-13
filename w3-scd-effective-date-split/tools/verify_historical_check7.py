import duckdb
c = duckdb.connect()
c.execute("CREATE TABLE acct_ref_t(k VARCHAR, eff DATE, exp DATE, typ VARCHAR)")
c.executemany("INSERT INTO acct_ref_t VALUES (?,?,?,?)", [
    ('1001','2024-01-01','2024-06-01','L'), ('1001','2024-06-01','9999-12-31','M')])
c.execute("CREATE TABLE elem_t(k VARCHAR, eff DATE, exp DATE, ind VARCHAR)")
c.executemany("INSERT INTO elem_t VALUES (?,?,?,?)", [
    ('1001','2024-01-01','2024-03-15','Y'), ('1001','2024-03-15','9999-12-31','N')])

# THE FAULT: class C table generated with the class B template -- driving source's own
# intervals, contributor joined with no date predicate, deduped to one row per (key, eff).
c.execute("""CREATE TABLE stg AS
  SELECT business_key, row_effective_datetime, row_expiration_datetime, typ, ind FROM (
    SELECT a.k AS business_key, a.eff AS row_effective_datetime, a.exp AS row_expiration_datetime,
           a.typ, x.ind,
           ROW_NUMBER() OVER (PARTITION BY a.k, a.eff ORDER BY x.exp DESC) AS rn
    FROM acct_ref_t a JOIN elem_t x ON a.k = x.k) WHERE rn = 1""")
print("staging produced by the WRONG template:")
for r in c.execute("SELECT * FROM stg ORDER BY 2").fetchall(): print("  ", r)

q = """SELECT COUNT(*) FROM (
  SELECT s.business_key, s.row_effective_datetime FROM stg s
  JOIN elem_t c ON s.business_key = c.k
  WHERE c.eff < s.row_expiration_datetime AND s.row_effective_datetime < c.exp
  GROUP BY 1,2
  HAVING COUNT(DISTINCT CONCAT_WS('~', COALESCE(c.ind,'~NULL~'))) > 1)"""
n = c.execute(q).fetchone()[0]
print(f"  {'OK ' if n>0 else 'FAIL'} CONTAINMENT_VIOLATION = {n} (must be > 0)")

d = c.execute("SELECT COUNT(*) FROM (SELECT business_key,row_effective_datetime FROM stg GROUP BY 1,2 HAVING COUNT(*)>1)").fetchone()[0]
print(f"  note: DUPLICATE_KEY_EFF = {d} -- the dedup hides the fanout, so check 1 alone would pass")
