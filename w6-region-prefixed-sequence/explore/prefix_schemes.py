#!/usr/bin/env python3
"""
W6 - compare the two candidate region-prefix schemes.

Simulated in DuckDB using DECIMAL(38,0), which mirrors Snowflake's
NUMBER(38,0) exactly, so the arithmetic, the datatype behaviour, the
decodability and the overflow limits all carry across.

It CANNOT answer the Snowflake-specific questions - whether a UDF may
reference a sequence, and how many times a scalar UDF is invoked per row.
Those need a real Snowflake account.

Run:  python3 prefix_schemes.py
"""
import duckdb

con = duckdb.connect()

WIDTH = 18                      # digits reserved for the sequence value
SCALE = 10 ** WIDTH             # the multiplier, as an exact integer literal
NUM = "DECIMAL(38,0)"           # DuckDB's equivalent of Snowflake NUMBER(38,0)

# Expression templates, so the two schemes are defined in exactly one place.
CONCAT = "CAST(CAST({r} AS VARCHAR) || CAST({s} AS VARCHAR) AS " + NUM + ")"
OFFSET = "CAST({r} AS " + NUM + ") * " + str(SCALE) + " + CAST({s} AS " + NUM + ")"


def concat(r="REGION_CODE", s="SEQ_VALUE"):
    return CONCAT.format(r=r, s=s)


def offset(r="REGION_CODE", s="SEQ_VALUE"):
    return OFFSET.format(r=r, s=s)


# The mapping table from the requirement (R6). Codes 1-3 are allocated today.
con.execute("""
CREATE TABLE REGION_MAP (REGION_NAME VARCHAR, REGION_CODE INTEGER);
INSERT INTO REGION_MAP VALUES ('North America', 1), ('EU', 2), ('APAC', 3);
""")

# Stand-in for <TABLE>_SEQ.NEXTVAL: ascending surrogate keys, per region.
con.execute("""
CREATE TABLE RAW_KEYS AS
SELECT r.REGION_NAME, r.REGION_CODE, s.SEQ_VALUE
FROM REGION_MAP r
CROSS JOIN (SELECT UNNEST([1, 2, 11, 12, 123, 999999]) AS SEQ_VALUE) s;
""")

print("=" * 78)
print(f"W6 PREFIX SCHEMES  -  simulated on {NUM}, sequence field {WIDTH} digits")
print("=" * 78)

print("\n1. THE DATATYPE CONCERN FROM THE TRANSCRIPT (section 4)")
print("-" * 78)
print("Raw concatenation returns TEXT, not a number - this is the cast Nidwika hit:\n")
print(con.sql(f"""
    SELECT REGION_CODE, SEQ_VALUE,
           CAST(REGION_CODE AS VARCHAR) || CAST(SEQ_VALUE AS VARCHAR)         AS RAW_CONCAT,
           typeof(CAST(REGION_CODE AS VARCHAR) || CAST(SEQ_VALUE AS VARCHAR)) AS RAW_CONCAT_TYPE,
           CAST({offset()} AS VARCHAR)                                        AS OFFSET_KEY,
           typeof({offset()})                                                 AS OFFSET_TYPE
    FROM RAW_KEYS WHERE SEQ_VALUE IN (1, 123) ORDER BY REGION_CODE, SEQ_VALUE
""").df().to_string(index=False))
print("\n-> Concatenation leaves VARCHAR and needs an explicit cast back to the key's")
print("   type. Offset arithmetic is numeric start to finish - nothing to cast back,")
print("   which removes the very problem that motivated centralising this (section 4).")

print("\n\n2. BOTH SCHEMES SIDE BY SIDE")
print("-" * 78)
print(con.sql(f"""
    SELECT REGION_NAME, REGION_CODE, SEQ_VALUE,
           CAST({concat()} AS VARCHAR) AS CONCAT_KEY,
           CAST({offset()} AS VARCHAR)  AS OFFSET_KEY
    FROM RAW_KEYS ORDER BY REGION_CODE, SEQ_VALUE
""").df().to_string(index=False))
print("\n-> CONCAT_KEY magnitude tracks the NUMBER OF DIGITS in the sequence value:")
print("   region 1 yields 11, 12, 111, 112, 1123, 1999999 - key length is unstable,")
print("   and a region's keys interleave with other regions' as they grow.")
print("   OFFSET_KEY is always the region code followed by a fixed-width field.")

print("\n\n3. DECODABILITY - can the region be recovered from the key?")
print("-" * 78)
print(con.sql(f"""
    SELECT REGION_CODE AS TRUE_REGION, SEQ_VALUE AS TRUE_SEQ,
           CAST(LEFT(CAST({concat()} AS VARCHAR), 1) AS INTEGER)       AS CONCAT_REGION,
           CAST(CAST({offset()} AS HUGEINT) // {SCALE} AS INTEGER)     AS OFFSET_REGION,
           CAST(CAST({offset()} AS HUGEINT) %  {SCALE} AS BIGINT)      AS OFFSET_SEQ
    FROM RAW_KEYS WHERE SEQ_VALUE IN (1, 123) ORDER BY REGION_CODE, SEQ_VALUE
""").df().to_string(index=False))
print("\n-> Both decode correctly TODAY. Concatenation only works because it reads the")
print("   first character and every region code happens to be exactly one digit.")
print("   Offset decodes by division and modulo, with no digit-counting assumption,")
print("   and recovers the original sequence value too - concatenation cannot.")

print("\n\n4. WHERE CONCATENATION BREAKS: a region code reaching two digits")
print("-" * 78)
con.execute("""
CREATE TABLE GROWN_MAP (REGION_NAME VARCHAR, REGION_CODE INTEGER);
INSERT INTO GROWN_MAP VALUES
    ('North America', 1), ('EU', 2), ('APAC', 3), ('LATAM', 4), ('UK', 5),
    ('MEA', 6), ('ANZ', 7), ('Japan', 8), ('India', 9),
    ('Nordics', 10), ('Benelux', 12);
""")
con.execute(f"""
CREATE TABLE GROWN_KEYS AS
SELECT g.REGION_NAME, g.REGION_CODE, s.SEQ_VALUE,
       {concat('g.REGION_CODE', 's.SEQ_VALUE')} AS CONCAT_KEY,
       {offset('g.REGION_CODE', 's.SEQ_VALUE')} AS OFFSET_KEY
FROM GROWN_MAP g CROSS JOIN (SELECT UNNEST(range(1, 400)) AS SEQ_VALUE) s;
""")
print("Eleven regions, so codes now reach 10 and 12. Collisions under CONCAT:\n")
print(con.sql("""
    SELECT CAST(CONCAT_KEY AS VARCHAR) AS CONCAT_KEY, COUNT(*) AS ROWS_SHARING_KEY,
           STRING_AGG(REGION_NAME || ' seq=' || SEQ_VALUE, '  |  ' ORDER BY REGION_CODE) AS COLLIDING
    FROM GROWN_KEYS GROUP BY CONCAT_KEY HAVING COUNT(*) > 1
    ORDER BY MIN(CONCAT_KEY) LIMIT 6
""").df().to_string(index=False))

tot, dc, do = con.execute("""
    SELECT COUNT(*),
           COUNT(*) - COUNT(DISTINCT CONCAT_KEY),
           COUNT(*) - COUNT(DISTINCT OFFSET_KEY)
    FROM GROWN_KEYS
""").fetchall()[0]
print(f"\n   population tested                  {tot:,} keys (11 regions x 399 values)")
print(f"-> CONCAT duplicate keys             {dc:,}")
print(f"-> OFFSET duplicate keys             {do:,}")
print("\n   concat(1, 23) and concat(12, 3) are both '123'. That is a DUPLICATE")
print("   PRIMARY KEY in the global database - two different employees in two")
print("   different regions sharing one identifier. Not a cosmetic problem, and it")
print("   appears silently the day an eleventh region is onboarded.")

print("\n\n5. HEADROOM AND THE FIELD-WIDTH CONSTRAINT")
print("-" * 78)
for rc_digits in (1, 2, 3):
    max_rc = 10 ** rc_digits - 1
    biggest = max_rc * SCALE + (SCALE - 1)
    fits = "fits" if biggest < 10 ** 38 else "OVERFLOWS"
    print(f"   region code up to {max_rc:>3}  ->  largest key {len(str(biggest)):>2} digits   {fits} NUMBER(38,0)")
print(f"\n   sequence values available per region: {SCALE - 1:,}")
print(f"   NUMBER(38,0) ceiling:                 {10**38 - 1:,}")
print("\n-> The constraint is max_region_code * 10^WIDTH < 10^38. At WIDTH=18 there is")
print("   room for a 19-digit region code, so the scheme has ample headroom - but")
print("   WIDTH must be FIXED ONCE AND NEVER CHANGED. Changing it later renumbers")
print("   every key ever issued, so pin it in the requirement, not in code.")
print("\n   (An earlier draft of this script used BIGINT and overflowed at region")
print("   code 10, since 10 * 10^18 exceeds 9.22e18. Snowflake NUMBER(38,0) is")
print("   fine, but any downstream BIGINT/long column would not be - worth checking")
print("   what consumes EMPLOYEE_ID before fixing WIDTH.)")
print()
