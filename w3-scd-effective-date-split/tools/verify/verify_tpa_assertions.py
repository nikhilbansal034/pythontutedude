import duckdb
HI = "DATE '9999-12-31'"
c = duckdb.connect()

# Two business keys. drv = CONTRACT_T (driver). con2 = CONTRACT_NUMBER_ELEMENT_T (contributor).
c.execute("CREATE TABLE drv(agr_id VARCHAR, eff DATE, exp DATE, bgi VARCHAR, divn VARCHAR, srl VARCHAR)")
c.executemany("INSERT INTO drv VALUES (?,?,?,?,?,?)", [
  ('A1','2024-01-01','2024-06-01','0005','D1','S-DRV'),
  ('A1','2024-06-01','9999-12-31','0005','D2','S-DRV'),
  ('A2','2024-01-01','9999-12-31','0005','D9','S-DRV')])
c.execute("CREATE TABLE con2(agr_id VARCHAR, eff DATE, exp DATE, pol_sym VARCHAR, srl VARCHAR)")
c.executemany("INSERT INTO con2 VALUES (?,?,?,?,?)", [
  ('A1','2024-01-01','2024-03-15','P','S-C2'),
  ('A1','2024-03-15','9999-12-31','Q','S-C2'),
  ('A2','2024-01-01','9999-12-31','Z','S-C2')])

# --- the GENERATED Q1 shape, transcribed ---
c.execute(f"""
CREATE TABLE THIRD_PARTY_AGREEMENT_STG AS
WITH boundaries AS (
  SELECT DISTINCT agr_id, 'CCO' AS SOURCE_SYSTEM_CODE, boundary_date FROM (
      SELECT agr_id, eff AS boundary_date FROM drv
      UNION ALL SELECT agr_id, exp FROM drv
      UNION ALL SELECT d.agr_id, c.eff FROM drv d JOIN con2 c ON d.agr_id=c.agr_id
      UNION ALL SELECT d.agr_id, c.exp FROM drv d JOIN con2 c ON d.agr_id=c.agr_id)
  WHERE boundary_date IS NOT NULL),
intervals AS (
  SELECT agr_id, boundary_date AS interval_start,
         LEAD(boundary_date) OVER (PARTITION BY agr_id ORDER BY boundary_date) AS interval_end
  FROM boundaries),
resolved AS (
  SELECT i.agr_id, 'CCO' AS SOURCE_SYSTEM_CODE, i.interval_start, i.interval_end,
         drv.divn AS DIVISION_CODE, con2.pol_sym AS POLICY_SYMBOL_CODE,
         con2.srl AS SERIAL_NUMBER              -- generated: con2 only (STTM: coalesce(drv.srl, con2.srl))
  FROM intervals i
  JOIN drv ON i.agr_id=drv.agr_id AND drv.eff<=i.interval_start AND drv.exp>=i.interval_end
  LEFT JOIN con2 ON drv.agr_id=con2.agr_id AND con2.eff<=i.interval_start AND con2.exp>=i.interval_end
  WHERE i.interval_end IS NOT NULL),
change_flags AS (
  SELECT r.*, CASE WHEN ((r.DIVISION_CODE IS DISTINCT FROM LAG(r.DIVISION_CODE) OVER (PARTITION BY agr_id ORDER BY r.interval_start))
                      OR (r.POLICY_SYMBOL_CODE IS DISTINCT FROM LAG(r.POLICY_SYMBOL_CODE) OVER (PARTITION BY agr_id ORDER BY r.interval_start))
                      OR (r.SERIAL_NUMBER IS DISTINCT FROM LAG(r.SERIAL_NUMBER) OVER (PARTITION BY agr_id ORDER BY r.interval_start)))
                   OR ((r.interval_start <> LAG(r.interval_end) OVER (PARTITION BY agr_id ORDER BY r.interval_start)))
              THEN 1 ELSE 0 END AS new_grp
  FROM resolved r),
collapsed AS (
  SELECT MAX(agr_id) AS agr_id, 'CCO' AS SOURCE_SYSTEM_CODE,
         MIN(interval_start) AS ROW_EFFECTIVE_DATETIME, MAX(interval_end) AS ROW_EXPIRATION_DATETIME,
         MAX(DIVISION_CODE) AS DIVISION_CODE, MAX(POLICY_SYMBOL_CODE) AS POLICY_SYMBOL_CODE,
         MAX(SERIAL_NUMBER) AS SERIAL_NUMBER
  FROM (SELECT *, SUM(new_grp) OVER (PARTITION BY agr_id ORDER BY interval_start ROWS UNBOUNDED PRECEDING) AS grp
        FROM change_flags)
  GROUP BY agr_id, grp)
SELECT agr_id AS SOURCE_TPA_IDENTIFIER, SOURCE_SYSTEM_CODE,
       ROW_EFFECTIVE_DATETIME, ROW_EXPIRATION_DATETIME, DIVISION_CODE, POLICY_SYMBOL_CODE, SERIAL_NUMBER,
       CASE WHEN ROW_EXPIRATION_DATETIME >= {HI} THEN 'Y' ELSE 'N' END AS CURRENT_RECORD_INDICATOR,
       0 AS CHANGE_FLAG
FROM collapsed""")

print("STAGING produced by the generated Q1 shape:")
for r in c.execute("SELECT * FROM THIRD_PARTY_AGREEMENT_STG ORDER BY 1,3").fetchall(): print("  ", r)

print("\nGENERATED assertions, run verbatim (every one must return 0):")
gen = [
 ("1 DUPLICATE_KEY_EFF", "SELECT COUNT(*) FROM (SELECT SOURCE_SYSTEM_CODE, ROW_EFFECTIVE_DATETIME FROM THIRD_PARTY_AGREEMENT_STG GROUP BY 1,2 HAVING COUNT(*)>1)"),
 ("2 CURRENT_IND_MISMATCH", f"SELECT COUNT(*) FROM THIRD_PARTY_AGREEMENT_STG WHERE CURRENT_RECORD_INDICATOR <> CASE WHEN ROW_EXPIRATION_DATETIME >= {HI} THEN 'Y' ELSE 'N' END"),
 ("3 OVERLAPPING_INTERVALS", "SELECT COUNT(*) FROM THIRD_PARTY_AGREEMENT_STG a JOIN THIRD_PARTY_AGREEMENT_STG b ON a.SOURCE_SYSTEM_CODE=b.SOURCE_SYSTEM_CODE AND a.ROW_EFFECTIVE_DATETIME<b.ROW_EFFECTIVE_DATETIME AND b.ROW_EFFECTIVE_DATETIME<a.ROW_EXPIRATION_DATETIME"),
 ("4 BAD_INTERVAL", "SELECT COUNT(*) FROM THIRD_PARTY_AGREEMENT_STG WHERE ROW_EXPIRATION_DATETIME <= ROW_EFFECTIVE_DATETIME"),
 ("5 NULL_BUSINESS_KEY", "SELECT COUNT(*) FROM THIRD_PARTY_AGREEMENT_STG WHERE SOURCE_SYSTEM_CODE IS NULL"),
 ("6 OPEN_ENDED_COUNT", f"SELECT COUNT(*) FROM (SELECT SOURCE_SYSTEM_CODE FROM THIRD_PARTY_AGREEMENT_STG WHERE ROW_EXPIRATION_DATETIME >= {HI} GROUP BY 1 HAVING COUNT(*)<>1)"),
 ("8 NON_INSERT_FLAG", "SELECT COUNT(*) FROM THIRD_PARTY_AGREEMENT_STG WHERE CHANGE_FLAG <> 0"),
]
for n,q in gen:
    v=c.execute(q).fetchone()[0]
    print(f"   {'pass' if v==0 else 'FAIL'}  {n} = {v}")

print("\nSame checks keyed on the REAL business key (SOURCE_TPA_IDENTIFIER, SOURCE_SYSTEM_CODE):")
fixed = [
 ("1 DUPLICATE_KEY_EFF", "SELECT COUNT(*) FROM (SELECT SOURCE_TPA_IDENTIFIER, SOURCE_SYSTEM_CODE, ROW_EFFECTIVE_DATETIME FROM THIRD_PARTY_AGREEMENT_STG GROUP BY 1,2,3 HAVING COUNT(*)>1)"),
 ("3 OVERLAPPING_INTERVALS", "SELECT COUNT(*) FROM THIRD_PARTY_AGREEMENT_STG a JOIN THIRD_PARTY_AGREEMENT_STG b ON a.SOURCE_TPA_IDENTIFIER=b.SOURCE_TPA_IDENTIFIER AND a.SOURCE_SYSTEM_CODE=b.SOURCE_SYSTEM_CODE AND a.ROW_EFFECTIVE_DATETIME<b.ROW_EFFECTIVE_DATETIME AND b.ROW_EFFECTIVE_DATETIME<a.ROW_EXPIRATION_DATETIME"),
 ("5 NULL_BUSINESS_KEY", "SELECT COUNT(*) FROM THIRD_PARTY_AGREEMENT_STG WHERE SOURCE_TPA_IDENTIFIER IS NULL"),
 ("6 OPEN_ENDED_COUNT", f"SELECT COUNT(*) FROM (SELECT SOURCE_TPA_IDENTIFIER FROM THIRD_PARTY_AGREEMENT_STG WHERE ROW_EXPIRATION_DATETIME >= {HI} GROUP BY 1 HAVING COUNT(*)<>1)"),
]
for n,q in fixed:
    v=c.execute(q).fetchone()[0]
    print(f"   {'pass' if v==0 else 'FAIL'}  {n} = {v}")
