#!/usr/bin/env python3
"""Two Snowflake-specific checks the DuckDB harness cannot make.

1. NO FUNCTION CALL INSIDE A VALUES CLAUSE.
   Snowflake's INSERT .. VALUES takes constants only:
     SQL compilation error: Invalid expression [SHA2('~|B1', 256)] in VALUES clause
   DuckDB accepts it happily, so the harness ran green while Snowflake refused
   the file. Use INSERT .. SELECT .. UNION ALL instead. A MERGE's own VALUES
   clause is exempt -- expressions are legal there.

2. NO CURRENT_TIMESTAMP()/CURRENT_DATE IN SEED DATA.
   Seeds replay a fixed history. Stamping a "day 1" row with CURRENT_TIMESTAMP()
   dates it later than the day 2 window that is supposed to follow it, which
   cannot happen. Use explicit literals. The MERGE is exempt -- stamping the
   audit columns with CURRENT_TIMESTAMP() is what production does."""
import re, sys, glob, os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "poc_v2")

def strip_comments(src):
    out = []
    for line in src.split("\n"):
        q = False; cut = None
        for i, ch in enumerate(line):
            if ch == "'": q = not q
            elif ch == "-" and not q and line[i:i+2] == "--": cut = i; break
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)

def statements(src):
    """Yield (line number, statement). strip_comments removes comment TEXT but
    keeps every newline, so offsets into the stripped source give correct line
    numbers -- as long as we index the stripped source, not the original."""
    stripped = strip_comments(src)
    pos = 0
    for raw in stripped.split(";"):
        if raw.strip():
            lead = len(raw) - len(raw.lstrip())
            yield stripped[:pos + lead].count("\n") + 1, raw.strip()
        pos += len(raw) + 1

bad = []
for path in sorted(glob.glob(os.path.join(ROOT, "**", "*.sql"), recursive=True)):
    rel = os.path.relpath(path, ROOT)
    for line, st in statements(open(path).read()):
        head = st.split()[0].upper()
        if head == "MERGE": continue                       # both rules exempt
        if head != "INSERT": continue
        m = re.search(r"\bVALUES\b", st, flags=re.I)
        if m:
            for f in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(", st[m.end():]):
                bad.append((rel, line, f"function {f.group(1)}() inside a VALUES clause"))
        for f in re.finditer(r"\b(CURRENT_TIMESTAMP|CURRENT_DATE|SYSDATE|LOCALTIMESTAMP)\b", st, flags=re.I):
            bad.append((rel, line, f"{f.group(1)} in seed data — use an explicit literal"))

seen = set()
for rel, line, msg in bad:
    if (rel, line, msg) in seen: continue
    seen.add((rel, line, msg)); print(f"  {rel}:{line}  {msg}")
print(f"  {len(seen)} problem(s)" if seen else "  clean")
sys.exit(1 if seen else 0)
