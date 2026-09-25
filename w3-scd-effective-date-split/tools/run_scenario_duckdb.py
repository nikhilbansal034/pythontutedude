"""Executes 00_objects.sql then a scenario against DuckDB, statement by
statement, so the files on disk are what gets validated -- not a paraphrase.
DuckDB has no multi-clause MERGE, so each MERGE is applied as its three
branches; that validates the DATA. Snowflake still has to validate the
STATEMENT."""
import re, sys, duckdb

import os
BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "poc_v2") + "/"

def translate(st):
    st = re.sub(r"SHA2\(([^;]*?),\s*256\)", r"md5(\1)", st, flags=re.S)
    st = st.replace("UUID_STRING()", "'uuid'")
    st = st.replace("CURRENT_TIMESTAMP()", "CURRENT_TIMESTAMP")
    st = st.replace("TIMESTAMP_NTZ", "TIMESTAMP")
    st = re.sub(r"NUMBER\(\d+,\s*\d+\)", "BIGINT", st)
    # a REAL sequence, so keys keep climbing across runs and truncates -- the
    # production behaviour we are deliberately replicating (no RESTART)
    st = st.replace("SEQ_BROKER_PARTY_DIM_SK.NEXTVAL", "nextval('SEQ_BROKER_PARTY_DIM_SK')")
    st = re.sub(r"CREATE SEQUENCE IF NOT EXISTS (\w+) START = (\d+) INCREMENT = (\d+)",
                r"CREATE SEQUENCE IF NOT EXISTS \1 START \2 INCREMENT \3", st)
    st = re.sub(r"TRUNCATE TABLE (\w+)", r"DELETE FROM \1", st)
    return st

MERGE_AS_THREE = [
 """UPDATE Z2_BROKER_PARTY_DIM t SET ROW_EXP_DTE=s.ROW_EXP_DTE, UUID=COALESCE(s.UUID,t.UUID),
    AUDIT_UPDATE_DATETIME=CURRENT_TIMESTAMP FROM STG_Z2_BROKER_PARTY_DIM s
    WHERE s.ACTION_FLAG='U' AND t.BROKER_PARTY_DIM_SK=s.BROKER_PARTY_DIM_SK""",
 """UPDATE Z2_BROKER_PARTY_DIM t SET
    IS_DEL      = CASE WHEN t.ROW_EXP_DTE=DATE '9999-12-31' THEN t.IS_DEL ELSE 'Y' END,
    ROW_EXP_DTE = CASE WHEN t.ROW_EXP_DTE=DATE '9999-12-31' THEN t.ROW_EFF_DTE ELSE t.ROW_EXP_DTE END,
    UUID        = COALESCE(s.UUID,t.UUID), AUDIT_UPDATE_DATETIME=CURRENT_TIMESTAMP
    FROM STG_Z2_BROKER_PARTY_DIM s
    WHERE s.ACTION_FLAG='D' AND t.BROKER_PARTY_DIM_SK=s.BROKER_PARTY_DIM_SK""",
 """INSERT INTO Z2_BROKER_PARTY_DIM SELECT BROKER_PARTY_DIM_SK,BROKER_ID,ROW_EFF_DTE,ROW_EXP_DTE,
    BROKER_STATUS_CDE,COMMISSION_TIER_CDE,'N',ROW_HASH,UUID,AUDIT_BATCH_ID,AUDIT_JOB_ID,
    CURRENT_TIMESTAMP,CURRENT_TIMESTAMP FROM STG_Z2_BROKER_PARTY_DIM WHERE ACTION_FLAG='I'"""]

def strip_comments(src):
    """Remove -- comments to end of line, but not inside single-quoted strings.
    Trailing comments can contain semicolons, which would split a statement."""
    out = []
    for line in src.split("\n"):
        q = False; cut = None
        for i, ch in enumerate(line):
            if ch == "'": q = not q
            elif ch == "-" and not q and line[i:i+2] == "--": cut = i; break
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)

def statements(path):
    src = strip_comments(open(BASE+path).read())
    for raw in src.split(";"):
        st = raw.strip()
        if st: yield st

def run(con, path, verbose_selects=False):
    fails = passes = 0
    for st in statements(path):
        head = st.split()[0].upper()
        if head == "USE": continue
        if head == "MERGE":
            for m in MERGE_AS_THREE: con.execute(m)
            continue
        st = translate(st)
        try:
            cur = con.execute(st)
        except Exception as e:
            print(f"  !! {head} failed: {str(e)[:200]}\n     {st[:160]}"); fails += 1; continue
        if head == "SELECT":
            rows = cur.fetchall(); cols = [d[0] for d in cur.description]
            if "RESULT" in cols:
                i = cols.index("RESULT")
                for r in rows:
                    ok = str(r[i]).upper().startswith("PASS")
                    passes += ok; fails += (not ok)
                    print(f"  {'PASS' if ok else 'FAIL'}  {r[0]}")
            elif verbose_selects:
                print(f"  -- {rows[0][0] if rows else '(empty)'}: {len(rows)} row(s)")
                for r in rows[:12]: print("      ", r)
    return passes, fails

if __name__ == "__main__":
    con = duckdb.connect()
    p0,f0 = run(con, "00_objects.sql")
    print(f"00_objects.sql  -> {f0} error(s)")
    scen = next((a for a in sys.argv[1:] if a.endswith(".sql")), "S01.sql")
    p1,f1 = run(con, "scenarios/" + scen, verbose_selects="-v" in sys.argv)
    print(f"\n{scen}: {p1} PASS, {f1} FAIL")
    sys.exit(1 if (f0+f1) else 0)
