#!/usr/bin/env python3
"""Every copy of the apply MERGE must be identical.

00_objects.sql carries the canonical statement; each scenario script repeats it
so its test cases stay self-contained and independently runnable. That is five
copies today and more as S02-S15 land, which is exactly how 00_objects.sql and
01_ddl_and_merge.sql came to disagree about MERGE_KEY without anything failing.
This makes that drift a build error instead of a silent one."""
import re, sys, glob, os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "poc_v2")

def merges(path):
    src = open(path).read()
    out = []
    for m in re.finditer(r"^MERGE INTO Z2_BROKER_PARTY_DIM T$", src, flags=re.M):
        end = src.index("CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());", m.start())
        body = src[m.start():end + len("CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());")]
        out.append((src[:m.start()].count("\n") + 1, body))
    return out

found = []
for path in [os.path.join(ROOT, "00_objects.sql")] + sorted(glob.glob(os.path.join(ROOT, "scenarios", "*.sql"))):
    for line, body in merges(path):
        found.append((os.path.relpath(path, ROOT), line, body))

if not found:
    print("no MERGE found — has the statement been renamed?"); sys.exit(1)

canon_src, canon_line, canon = found[0]
bad = [(f, l, b) for f, l, b in found[1:] if b != canon]
print(f"  {len(found)} copies of the apply MERGE")
print(f"  canonical: {canon_src}:{canon_line}")
for f, l, _ in found[1:]:
    print(f"    {'DRIFTED' if any(x[0]==f and x[1]==l for x in bad) else 'matches'}  {f}:{l}")
if bad:
    import difflib
    f, l, b = bad[0]
    print(f"\n  first difference, {f}:{l} vs {canon_src}:{canon_line}:")
    for d in list(difflib.unified_diff(canon.split("\n"), b.split("\n"), lineterm=""))[2:12]:
        print("   ", d)
sys.exit(1 if bad else 0)
