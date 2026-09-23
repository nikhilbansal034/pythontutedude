"""Independently re-derives every target table in the workbook from its own source
tables, applying the rule, and compares against what the sheet actually says.
Parses the built file - it does not import build.py - so a typo in the data shows up."""
import re, sys, openpyxl
from collections import defaultdict

HIGH = "9999-12-31"


def parse_blocks(ws):
    """Returns [(heading, anchor_col, header_row, cols, rows)]."""
    out = []
    for r in range(1, ws.max_row + 1):
        for c in range(1, ws.max_column + 1):
            if ws.cell(r, c).value != "PRIMARY_KEY":
                continue
            cols = []
            cc = c
            while cc <= ws.max_column and ws.cell(r, cc).value:
                cols.append(str(ws.cell(r, cc).value)); cc += 1
            heading = ws.cell(r - 1, c).value or ""
            rows, rr = [], r + 1
            while rr <= ws.max_row and ws.cell(rr, c).value:
                rows.append([ws.cell(rr, c + i).value for i in range(len(cols))]); rr += 1
            out.append((str(heading), c, r, cols, rows))
    return out


def as_dicts(cols, rows):
    return [dict(zip(cols, r)) for r in rows]


def norm(v):
    return "" if v in (None, "(blank)", "") else str(v)


def rebuild(src1, src2):
    """Cut both sources into a common interval grid, per key, then collapse
    adjacent intervals whose value combination is identical."""
    keys = {r["PRIMARY_KEY"] for r in src1} | {r["PRIMARY_KEY"] for r in src2}
    out = []
    for k in sorted(keys):
        s1 = [r for r in src1 if r["PRIMARY_KEY"] == k]
        s2 = [r for r in src2 if r["PRIMARY_KEY"] == k]
        # latest refined timestamp wins per (key, eff date) - the S07 read (a) rule
        for s in (s1, s2):
            best = {}
            for r in s:
                e = r["ROW_EFF_DATE"]
                if e not in best or str(r.get("REFINED_TIMESTAMP", "")) >= str(best[e].get("REFINED_TIMESTAMP", "")):
                    best[e] = r
            s[:] = sorted(best.values(), key=lambda r: str(r["ROW_EFF_DATE"]))
        dates = sorted({str(r[c]) for r in s1 + s2 for c in ("ROW_EFF_DATE", "ROW_EXP_DATE")})
        ivs = []
        for a, b in zip(dates, dates[1:]):
            def cover(s, col):
                for r in s:
                    if str(r["ROW_EFF_DATE"]) <= a and b <= str(r["ROW_EXP_DATE"]):
                        return norm(r[col])
                return ""
            nk1 = cover(s1, "NON_KEY_1") if s1 else ""
            nk2 = cover(s2, "NON_KEY_2") if s2 else ""
            ivs.append([k, nk1, nk2, a, b])
        merged = []
        for iv in ivs:
            if merged and merged[-1][1] == iv[1] and merged[-1][2] == iv[2] and merged[-1][4] == iv[3]:
                merged[-1][4] = iv[4]
            else:
                merged.append(iv)
        out += merged
    return out


def diff(rebuilt, existing):
    """Applies the rule table. The EXISTING row's expiry decides first; the hash
    only decides inside the high-end-date branch. Returns {(key, eff): (action, nk1, nk2, exp)}."""
    have = {(r["PRIMARY_KEY"], str(r["ROW_EFF_DATE"])[:10]): r for r in existing}
    acts = {}
    for k, nk1, nk2, eff, exp in rebuilt:
        old = have.get((k, eff[:10]))
        if old is None:
            acts[(k, eff)] = ("insert", nk1, nk2, exp)
            continue
        same_hash = (norm(old["NON_KEY_1"]), norm(old["NON_KEY_2"])) == (nk1, nk2)
        if same_hash and str(old["ROW_EXP_DATE"])[:10] == exp[:10]:
            acts[(k, eff)] = ("untouched", nk1, nk2, exp)
        elif str(old["ROW_EXP_DATE"])[:10] != HIGH:
            # already closed with a real date - changing it is a CORRECTION, keep the trail
            acts[(k, eff)] = ("retire+insert", nk1, nk2, exp)
        elif not same_hash:
            acts[(k, eff)] = ("dead+insert", nk1, nk2, exp)
        else:
            acts[(k, eff)] = ("update", nk1, nk2, exp)
    return acts


def classify(action_text):
    a = (action_text or "").lower()
    if "not read" in a or "untouched" in a or "no change" in a:
        return "untouched"
    if "update exp" in a or "no-op" in a or "expiry updated" in a or a == "update":
        return "update"
    if "dead record" in a or "retired" in a or "delete_ind" in a or "already dead" in a:
        return "retire"
    if "insert" in a:
        return "insert"
    return "?"


def check(path):
    wb = openpyxl.load_workbook(path)
    fails = []
    for name in wb.sheetnames:
        if not name.startswith("S"):
            continue
        ws = wb[name]
        blocks = parse_blocks(ws)
        def find(pred):
            return [(h, as_dicts(c, r)) for h, _, _, c, r in blocks if pred(h.upper())]
        def tag(h):
            u = h.upper()
            m = re.search(r"(?:EXECUTION[ _]RUN(?:_ID)?[ \-]*)(\d+)", u)
            if m: return "R" + m.group(1)
            if "CASE 1" in u: return "C1"
            if "CASE 2" in u: return "C2"
            if "DAY 2" in u:  return "D2"
            return "D1"
        s1 = {tag(h): d for h, d in find(lambda h: "SRC_1" in h)}
        s2 = {tag(h): d for h, d in find(lambda h: "SRC_2" in h)}
        tgs = defaultdict(list)
        for h, d in find(lambda h: "TGT" in h or "READ (" in h):
            u = h.upper()
            # Blocks that deliberately show a REJECTED alternative are not the rule.
            if "READ (B)" in u or "OPTION 2" in u:
                continue
            tgs[tag(h)].append(d)
        tg = {k: v[-1] for k, v in tgs.items()}   # last block for a tag = the final state
        runs = sorted(t for t in tg if t.startswith("R"))
        base = runs[0] if runs else "D1"
        if not (base in s1 and base in s2 and base in tg):
            print(f"  {name}: skipped (needs a baseline SRC_1, SRC_2 and TGT)"); continue

        # The baseline target must be a pure rebuild of the baseline sources.
        d1 = rebuild(s1[base], s2[base])
        got1 = [(r["PRIMARY_KEY"], norm(r["NON_KEY_1"]), norm(r["NON_KEY_2"]),
                 str(r["ROW_EFF_DATE"]), str(r["ROW_EXP_DATE"])) for r in tg[base]]
        exp1 = [tuple([k, a, b, e, x]) for k, a, b, e, x in d1]
        if got1 != exp1:
            fails.append(f"{name}: Day 1 target does not match a rebuild of its sources\n"
                         f"      expected {exp1}\n      got      {got1}")

        # Later stages. A numbered run diffs against what the PREVIOUS run left;
        # named branches (CASE 1 / CASE 2) are alternatives, each from the baseline.
        later = runs[1:] if runs else [x for x in ("D2", "C1", "C2") if x in tg]
        for i, t in enumerate([x for x in later if x in s1 and x in s2 and x in tg]):
            prev = runs[runs.index(t) - 1] if runs else base
            d2 = rebuild(s1[t], s2[t])
            acts = diff(d2, tg[prev])
            live = {(r["PRIMARY_KEY"], str(r["ROW_EFF_DATE"])) for r in tg[prev]}
            sheet_rows = tg[t]
            seen = defaultdict(list)
            for r in sheet_rows:
                seen[(r["PRIMARY_KEY"], str(r["ROW_EFF_DATE"]))].append(r)
            for (k, eff), (act, nk1, nk2, exp) in sorted(acts.items()):
                rows = seen.get((k, eff), [])
                if not rows:
                    fails.append(f"{name} [{t}]: rule says {act} for {k}@{eff}, but no such row in the Day 2 target")
                    continue
                kinds = {classify(r.get("ACTION")) for r in rows}
                want = {"insert"} if act == "insert" else \
                       {"update"} if act == "update" else \
                       {"untouched"} if act == "untouched" else {"retire", "insert"}
                # retire+insert and dead+insert both need a retired row and an inserted row
                if not want <= kinds:
                    fails.append(f"{name} [{t}]: {k}@{eff} rule says {act} (needs {sorted(want)}), "
                                 f"sheet shows {sorted(kinds)}")
                # Whichever row carries the NEW state must match the rebuild exactly.
                # For retire+insert that is the inserted half, not the retired one.
                carries_new = {"insert": ("insert",), "update": ("update",),
                               "untouched": ("untouched",), "retire+insert": ("insert",),
                               "dead+insert": ("insert",)}[act]
                for r in [x for x in rows if classify(x.get("ACTION")) in carries_new]:
                    if str(r["ROW_EXP_DATE"]) != exp:
                        fails.append(f"{name} [{t}]: {k}@{eff} ({act}) expiry should be {exp}, "
                                     f"sheet has {r['ROW_EXP_DATE']}")
                    if (norm(r["NON_KEY_1"]), norm(r["NON_KEY_2"])) != (nk1, nk2):
                        fails.append(f"{name} [{t}]: {k}@{eff} ({act}) values should be ({nk1},{nk2}), "
                                     f"sheet has ({norm(r['NON_KEY_1'])},{norm(r['NON_KEY_2'])})")
            # rows in the sheet the rule never produced
            for (k, eff), rows in sorted(seen.items()):
                if (k, eff) not in acts and (k, eff) in live:
                    if not all(classify(r.get("ACTION")) in ("untouched", "retire") for r in rows):
                        fails.append(f"{name} [{t}]: {k}@{eff} is not in the rebuilt timeline, so it must be "
                                     f"untouched or retired; sheet says {[r.get('ACTION') for r in rows]}")
        print(f"  {name}: checked  stages={sorted(set(s1) & set(s2) & set(tg))}")
    return fails


def hash_check(path):
    """Every HASH cell must equal H(...) of the value columns on its own row."""
    wb = openpyxl.load_workbook(path); bad = []
    for name in wb.sheetnames:
        ws = wb[name]
        for heading, c, hr, cols, rows in parse_blocks(ws):
            if "HASH" not in cols:
                continue
            hi = cols.index("HASH")
            vi = [i for i, cn in enumerate(cols) if cn in ("NON_KEY_1", "NON_KEY_2")]
            for r in rows:
                want = "H(" + "|".join(norm(r[i]) for i in vi) + ")"
                if str(r[hi]) != want:
                    bad.append(f"{name} / {heading[:34]}: row {r[:3]} has {r[hi]}, expected {want}")
    return bad


if __name__ == "__main__":
    path = sys.argv[1]
    print("Rule check:")
    fails = check(path)
    print("\nHash check:")
    bad = hash_check(path)
    print(f"  {len(bad)} mismatched HASH cell(s)")
    for b in bad: print("   ", b)
    print()
    if fails:
        print(f"FAIL — {len(fails)} finding(s):")
        for f in fails: print("  -", f)
    else:
        print("PASS — every target matches the rule applied to its own sources.")
    sys.exit(1 if (fails or bad) else 0)
