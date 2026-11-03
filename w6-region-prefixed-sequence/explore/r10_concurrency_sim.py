#!/usr/bin/env python3
"""
W6 / R10 - concurrency simulation.

Several "tables" draw surrogate keys from ONE shared sequence through ONE
shared key-building expression, from parallel threads, and the composed keys
are checked for collisions.

WHAT THIS CAN SHOW
  * whether the composed-key arithmetic stays collision-free when draws from
    different regions and tables interleave
  * that uniqueness depends on the sequence being the single source of the
    varying part - the region prefix contributes nothing to uniqueness
  * how gaps appear naturally, so nobody reads them as lost rows

WHAT THIS CANNOT SHOW - run poc/04_r10_concurrency.sql for these
  * Snowflake's own concurrency guarantee (already documented: "Concurrent
    queries never observe the same value")
  * whether a Snowflake UDF wrapper preserves it
  * IMMUTABLE / MEMOIZABLE folding - no DuckDB equivalent
  * per-row invocation counts

Run:  python3 r10_concurrency_sim.py
"""
import duckdb
from concurrent.futures import ThreadPoolExecutor

WIDTH = 15
SCALE = 10 ** WIDTH
ROWS_PER_WORKER = 2000

con = duckdb.connect()
con.execute("CREATE SEQUENCE shared_seq START 1 INCREMENT 1")
con.execute("""
CREATE TABLE region_map (REGION_NAME VARCHAR, REGION_CODE INTEGER);
INSERT INTO region_map VALUES ('North America', 1), ('EU', 2), ('APAC', 3);
CREATE TABLE issued_keys (K HUGEINT, REGION VARCHAR, TBL VARCHAR, WORKER INTEGER);
""")

WORKERS = [
    ("North America", "EMPLOYEE"), ("North America", "JOB"), ("North America", "OFFICE"),
    ("EU", "EMPLOYEE"),            ("EU", "JOB"),
    ("APAC", "EMPLOYEE"),          ("APAC", "JOB"),
]


def draw(spec):
    """One worker: its own cursor, drawing ROWS_PER_WORKER keys."""
    idx, (region, table) = spec
    cur = con.cursor()
    cur.execute(f"""
        INSERT INTO issued_keys (K, REGION, TBL, WORKER)
        SELECT CAST(m.REGION_CODE AS HUGEINT) * {SCALE} + nextval('shared_seq'),
               '{region}', '{table}', {idx}
        FROM region_map m, range({ROWS_PER_WORKER})
        WHERE m.REGION_NAME = '{region}'
    """)
    return idx


print("=" * 78)
print(f"W6 / R10 CONCURRENCY SIMULATION")
print(f"{len(WORKERS)} workers x {ROWS_PER_WORKER:,} rows = "
      f"{len(WORKERS) * ROWS_PER_WORKER:,} keys, one shared sequence, run in parallel")
print("=" * 78)

with ThreadPoolExecutor(max_workers=len(WORKERS)) as pool:
    list(pool.map(draw, enumerate(WORKERS)))

total, distinct, dups = con.execute("""
    SELECT COUNT(*), COUNT(DISTINCT K), COUNT(*) - COUNT(DISTINCT K) FROM issued_keys
""").fetchall()[0]

print(f"\n1. GLOBAL UNIQUENESS")
print(f"   keys issued      {total:,}")
print(f"   distinct keys    {distinct:,}")
print(f"   duplicates       {dups:,}   <- must be 0")
print(f"   verdict          {'PASS' if dups == 0 else 'FAIL'}")

print(f"\n2. PER REGION / TABLE - did every worker get its own keys?")
print(con.sql("""
    SELECT REGION, TBL, COUNT(*) AS KEYS, COUNT(DISTINCT K) AS DISTINCT_KEYS,
           CAST(MIN(K) AS VARCHAR) AS MIN_KEY, CAST(MAX(K) AS VARCHAR) AS MAX_KEY
    FROM issued_keys GROUP BY REGION, TBL ORDER BY REGION, TBL
""").df().to_string(index=False))

print(f"\n3. DOES EVERY KEY DECODE TO ITS ISSUING REGION? (R13)")
print(con.sql(f"""
    SELECT k.REGION,
           COUNT(*) AS KEYS,
           CAST(SUM(CASE WHEN K // {SCALE} = m.REGION_CODE THEN 1 ELSE 0 END) AS BIGINT) AS DECODE_OK,
           CASE WHEN COUNT(*) = SUM(CASE WHEN K // {SCALE} = m.REGION_CODE THEN 1 ELSE 0 END)
                THEN 'PASS' ELSE 'FAIL' END AS VERDICT
    FROM issued_keys k JOIN region_map m ON m.REGION_NAME = k.REGION
    GROUP BY k.REGION ORDER BY k.REGION
""").df().to_string(index=False))

print(f"\n4. CROSS-REGION COLLISIONS - the same key issued to two regions?")
cross = con.execute("""
    SELECT COUNT(*) FROM (
        SELECT K FROM issued_keys GROUP BY K HAVING COUNT(DISTINCT REGION) > 1
    )
""").fetchall()[0][0]
print(f"   keys shared by >1 region   {cross}   <- must be 0")

print(f"\n5. GAPS WITHIN A REGION - expected, and not data loss")
print(con.sql(f"""
    WITH per_region AS (
        SELECT REGION, K % {SCALE} AS SEQ_PART FROM issued_keys
    )
    SELECT REGION, COUNT(*) AS KEYS,
           MIN(SEQ_PART) AS MIN_SEQ, MAX(SEQ_PART) AS MAX_SEQ,
           MAX(SEQ_PART) - MIN(SEQ_PART) + 1 AS SPAN,
           MAX(SEQ_PART) - MIN(SEQ_PART) + 1 - COUNT(*) AS GAP_COUNT
    FROM per_region GROUP BY REGION ORDER BY REGION
""").df().to_string(index=False))
print("""
   Each region's keys are spread across the shared sequence's range rather than
   contiguous, because all regions draw from one sequence. GAP_COUNT is large
   and that is CORRECT. Snowflake says the same of its own sequences: "There is
   no guarantee that values from a sequence are contiguous (gap-free)."
   Anything downstream that treats a missing key as a missing row is wrong
   independently of this change.""")

print(f"\n6. WHAT THE REGION PREFIX DOES AND DOES NOT DO")
seq_dups = con.execute(f"""
    SELECT COUNT(*) - COUNT(DISTINCT K % {SCALE}) FROM issued_keys
""").fetchall()[0][0]
print(f"   duplicate SEQUENCE parts, ignoring the region prefix:  {seq_dups}")
print("""   Zero, because one shared sequence already separates every row. So the
   prefix is carrying TRACEABILITY (R13), not uniqueness - uniqueness comes
   from the sequence.

   That matters for the design: if each region ever gets its OWN sequence
   instead of sharing one, the prefix becomes load-bearing for uniqueness
   too, and the C3 scheme choice stops being cosmetic. Worth settling which
   topology is intended - see feasibility.md R12.""")

print("\n" + "=" * 78)
print("PASS" if dups == 0 and cross == 0 else "FAIL",
      "- composed-key uniqueness holds under interleaved parallel draws.")
print("Snowflake-specific behaviour still needs poc/04_r10_concurrency.sql.")
print("=" * 78)

# ---------------------------------------------------------------------------
# 7. THE TOPOLOGY THAT SECTION 3 OF THE TRANSCRIPT ACTUALLY IMPLIES
# ---------------------------------------------------------------------------
print("\n" + "=" * 78)
print("7. PER-REGION SEQUENCES - the topology the requirement implies")
print("=" * 78)
print("""
   Sections 1-6 shared ONE sequence across all regions. That is probably the
   wrong model. Section 3 of the transcript describes regions being consolidated
   into a GLOBAL database later, which means each region runs its own Zone 2
   with its OWN sequence - and every one of them starts at 1.

   If that is right, the prefix is not decoration: it is the ONLY thing keeping
   North America's employee 1 apart from EU's employee 1. Re-run with per-region
   sequences and the picture changes.""")

con.execute("CREATE SEQUENCE na_seq START 1")
con.execute("CREATE SEQUENCE eu_seq START 1")
con.execute("CREATE SEQUENCE ap_seq START 1")
con.execute("""
CREATE TABLE per_region_keys (REGION VARCHAR, REGION_CODE INTEGER, SEQ_PART BIGINT);
INSERT INTO per_region_keys
    SELECT 'North America', 1, nextval('na_seq') FROM range(3000)
    UNION ALL SELECT 'EU', 2, nextval('eu_seq') FROM range(3000)
    UNION ALL SELECT 'APAC', 3, nextval('ap_seq') FROM range(3000);
""")

print(con.sql("""
    SELECT REGION, COUNT(*) AS KEYS, MIN(SEQ_PART) AS MIN_SEQ, MAX(SEQ_PART) AS MAX_SEQ
    FROM per_region_keys GROUP BY REGION ORDER BY REGION
""").df().to_string(index=False))
print("\n   Every region issued 1..3000 independently. Without a prefix these")
print("   collide completely:")

raw_dups = con.execute("""
    SELECT COUNT(*) - COUNT(DISTINCT SEQ_PART) FROM per_region_keys
""").fetchall()[0][0]
print(f"   duplicate keys with NO prefix at all:                 {raw_dups:,}")

off_dups = con.execute(f"""
    SELECT COUNT(*) - COUNT(DISTINCT CAST(REGION_CODE AS HUGEINT) * {SCALE} + SEQ_PART)
    FROM per_region_keys
""").fetchall()[0][0]
cat_dups = con.execute("""
    SELECT COUNT(*) - COUNT(DISTINCT CAST(CAST(REGION_CODE AS VARCHAR)
                                       || CAST(SEQ_PART AS VARCHAR) AS HUGEINT))
    FROM per_region_keys
""").fetchall()[0][0]
print(f"   duplicate keys with FIXED-WIDTH OFFSET prefix:        {off_dups:,}")
print(f"   duplicate keys with DIGIT CONCATENATION prefix:       {cat_dups:,}")
print(f"""
   So under the topology the requirement implies, the prefix is LOAD-BEARING:
   {raw_dups:,} of {3000 * 3:,} keys collide without it. Both schemes fix that at three
   single-digit regions - but it changes what is at stake in the C3 decision.
   Concatenation's failure at a two-digit region code stops being a tidiness
   argument and becomes the loss of the only thing separating two regions'
   primary keys.

   ACTION: confirm the topology (feasibility.md C8). One shared sequence or one
   per region is not a detail - it decides whether the prefix is traceability
   or integrity.""")
print("=" * 78)
