#!/usr/bin/env python3
"""Annotate POC_Evidence.xlsx: a one-line caption above every screenshot, and a
RESULT column on the 'Test Cases' tab.

This works by direct OOXML surgery rather than openpyxl, because openpyxl drops
every embedded image on load/save -- verified by round-trip test. The workbook is
12.7 MB of screenshots and they are the whole point of the file, so nothing here
goes through a library that would rewrite the drawing parts.

Each screenshot's test case is taken from the workbook ITSELF: the sheets carry a
SCENARIO / TEST CASE / WHAT IT DOES / RULES VALIDATED header block above each test
case's shots, so an image belongs to the last such block above its anchor row. That
is authoritative -- it does not assume a fixed number of shots per test case, and it
is what catches the two captures that are not 5-per-case (see SHOT_LAYOUT).

Usage:
  python3 tools/annotate_evidence.py --xlsx <in.xlsx> --expected <expected_results.txt>
                                     --verdicts <verdicts.json> --out <out.xlsx>
"""
import argparse, json, os, re, shutil, sys, zipfile
from xml.sax.saxutils import escape

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from scenario_specs import SPECS

NS_MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

# ---------------------------------------------------------------- shot layouts
SHOTS = ["SRC_1", "SRC_2", "stage", "MERGE", "target AFTER"]

# Captures that are NOT the standard five shots. Both were established by reading
# the label baked into each screenshot, and both are corroborated independently by
# the image counts the sheets' own test-case header blocks imply.
SHOT_LAYOUT = {
    ("S01", 3): ["SRC_1", "SRC_2", "stage", "target AFTER"],  # MERGE pane not captured
    ("S14", 2): ["DDL"] + SHOTS,   # the Step 1 view is redefined before this run
    ("S14", 5): ["DDL"] + SHOTS,   # and again before this one
}

RULE_SHORT = {
    1:"no action", 2:"rerun no-op", 3:"no action on a closed interval",
    4:"rerun no-op on a closed interval", 5:"EXPIRE IN PLACE", 6:"rerun expire-in-place",
    7:"RETIRE by delete indicator", 8:"rerun retire by delete indicator",
    9:"DEAD RECORD", 10:"rerun dead record",
    11:"RETIRE by delete indicator, back-dated", 12:"rerun back-dated correction",
    13:"DEAD RECORD, hash and expiry both moved", 14:"rerun dead record, hash and expiry both moved",
    15:"RETIRE, hash and expiry both moved", 16:"rerun retire, hash and expiry both moved",
    17:"INSERT", 18:"NO ACTION, orphan left live",
}

# ------------------------------------------------------- what each source did
SRC_TABLE = {"Z1_BROKER_PARTY_HIST": "SRC_1", "Z1_BROKER_COMMISSION_HIST": "SRC_2"}

def source_ops(sql):
    """Classify a test case's source changes into per-source English phrases."""
    res = {"SRC_1": [], "SRC_2": []}
    for stmt in (s.strip() for s in (sql or "").split(";") if s.strip()):
        up = stmt.upper()
        tbl = next((v for k, v in SRC_TABLE.items() if k in up), None)
        if not tbl:
            continue
        if up.startswith("INSERT"):
            n = 1 + up.count("UNION ALL")
            res[tbl].append(("insert", n))
        elif up.startswith("UPDATE"):
            setc = re.search(r"SET\s+(.*?)\s+WHERE", stmt, re.S | re.I)
            cols = [c for c in re.findall(r"(\w+)\s*=", setc.group(1) if setc else "")
                    if c.upper() not in ("DATE", "TIMESTAMP")]
            data = [c for c in cols if c.upper() != "GRS_REFINED_TIMESTAMP"]
            if not data:
                res[tbl].append(("touch", None))
            elif any(c.upper() == "ROW_EXP_DTE" for c in data):
                res[tbl].append(("close", None))
            else:
                res[tbl].append(("fix", data[0]))
        elif up.startswith("DELETE"):
            res[tbl].append(("delete", None))
    return {k: _phrase(v) for k, v in res.items()}

def _phrase(items):
    """Collapse repeats and render as one phrase, e.g. '1 version closed early, 2 rows added'."""
    ins   = sum(n for kind, n in items if kind == "insert")
    close = sum(1 for kind, _ in items if kind == "close")
    dele  = sum(1 for kind, _ in items if kind == "delete")
    fixes, touch = [], any(kind == "touch" for kind, _ in items)
    for kind, col in items:
        if kind == "fix" and col not in fixes:
            fixes.append(col)
    bits = []
    if close: bits.append(f"{close} existing version{'s' if close > 1 else ''} closed early")
    if ins:   bits.append(f"{ins} new version row{'s' if ins > 1 else ''} arrive{'' if ins > 1 else 's'}")
    if fixes: bits.append(f"{' and '.join(fixes)} corrected in place")
    if dele:  bits.append(f"{dele} row{'s' if dele > 1 else ''} deleted outright")
    if touch: bits.append("a GRS_REFINED_TIMESTAMP moves with no data change")
    return ", ".join(bits)

# ------------------------------------------------------------------- captions
SRC_LONG = {"SRC_1": "SRC_1 (Zone1 party history)", "SRC_2": "SRC_2 (Zone1 commission history)"}

def caption(scen, tc, shot, e, prev, ops):
    if shot == "DDL":
        return ("The Step 1 view is REDEFINED here, changing the hash formula mid-pipeline. The change "
                "alone re-derives nothing: only keys whose source timestamp moves are rebuilt, which is "
                "what makes the migration gradual.")
    if shot in ("SRC_1", "SRC_2"):
        did = ops.get(shot, "")
        other = "SRC_2" if shot == "SRC_1" else "SRC_1"
        if did:
            return f"{SRC_LONG[shot]} after this run's delivery: {did}."
        if ops.get(other):
            return (f"{SRC_LONG[shot]} is UNTOUCHED this run -- same rows, same GRS_REFINED_TIMESTAMP as "
                    f"before -- yet its target rows still have to move, because only {other} moved. "
                    f"This is the problem the POC exists to solve.")
        return (f"{SRC_LONG[shot]} is unchanged, and so is {other}: this run re-reads identical inputs, "
                f"which is what makes it a true idempotency check.")
    if e is None:
        return f"{scen} TC{tc:02d} -- {shot}."
    if shot == "stage":
        if e["stage"] == 0:
            return ("Step 1 produced ZERO stage rows: the rebuilt timeline already matches the target, so "
                    "this run has nothing to write.")
        bits = ", ".join(f"rule {r} ({RULE_SHORT[r]})" for r in e["rules"])
        return (f"Step 1 output -- {e['stage']} stage rows: {bits}. "
                f"{e['D']} retire, {e['U']} expire in place, {e['I']} insert.")
    if shot == "MERGE":
        if e["ins"] == 0 and e["upd"] == 0:
            return ("The MERGE writes NOTHING: 0 inserted, 0 updated. Re-running costs nothing and changes "
                    "nothing.")
        return (f"One atomic MERGE applies the whole stage: {e['ins']} inserted, {e['upd']} updated -- "
                f"retire and insert land in a single statement, not two.")
    if shot == "target AFTER":
        if e["stage"] == 0:
            return (f"Target unchanged at {e['tgt']} rows: every row still carries the batch id of the run "
                    f"that created it, so nothing was silently restamped.")
        grew = f"{prev['tgt']} -> {e['tgt']}" if prev else f"0 -> {e['tgt']}"
        extra = ""
        if any(r in e["rules"] for r in (9, 10, 13, 14)):
            extra = " The superseded row is a DEAD RECORD: effective date equals expiry, IS_DEL stays 'N'."
        elif any(r in e["rules"] for r in (7, 8, 11, 12, 15, 16)):
            extra = " The superseded row is retired by DELETE INDICATOR: IS_DEL 'Y', both dates untouched."
        elif any(r in e["rules"] for r in (5, 6)):
            extra = " Nothing was retired: the expired row keeps its surrogate key and its batch id."
        return f"Target {grew} rows, {e['live']} live.{extra}"
    return f"{scen} TC{tc:02d} -- {shot}."

# ----------------------------------------------------------- expected results
def parse_expected(path):
    txt = open(path).read(); out = {}
    for m in re.finditer(r"={78}\n(S\d\d)\n={78}\n(.*?)(?=\n={78}\nS\d\d\n|\Z)", txt, flags=re.S):
        scen, body, tcs = m.group(1), m.group(2), {}
        for t in re.finditer(r"TC(\d\d)\s+MERGE: (\d+) inserted, (\d+) updated\s+"
                             r"target (\d+) rows, live (\d+)\n\s+stage \((\d+) rows\).*?\n(.*?)"
                             r"(?=\n\s+target AFTER)", body, flags=re.S):
            flags = re.findall(r"^\s+\d+ \| (\w)", t.group(7), flags=re.M)
            tcs[int(t.group(1))] = {
                "ins": int(t.group(2)), "upd": int(t.group(3)), "tgt": int(t.group(4)),
                "live": int(t.group(5)), "stage": int(t.group(6)),
                "rules": sorted({int(x) for x in re.findall(r"^\s+(\d+) \|", t.group(7), flags=re.M)}),
                "I": flags.count("I"), "U": flags.count("U"), "D": flags.count("D")}
        out[scen] = tcs
    return out

# --------------------------------------------------------------- xlsx reading
def sheet_index(parts):
    """-> [(sheet name, 'xl/worksheets/sheetN.xml', 'drawingN.xml' or None)] in tab order."""
    wb   = parts["xl/workbook.xml"].decode("utf-8")
    rels = parts["xl/_rels/workbook.xml.rels"].decode("utf-8")
    rid  = dict(re.findall(r'Id="(rId\d+)"[^>]*?Target="([^"]+)"', rels))
    out = []
    for m in re.finditer(r'<sheet name="([^"]+)"[^>]*?r:id="(rId\d+)"', wb):
        tgt = rid[m.group(2)].lstrip("/")
        path = tgt if tgt.startswith("xl/") else "xl/" + tgt
        relp = f"xl/worksheets/_rels/{os.path.basename(path)}.rels"
        dr = None
        if relp in parts:
            d = re.search(r'Target="[^"]*?(drawing\d+\.xml)"', parts[relp].decode("utf-8"))
            dr = d.group(1) if d else None
        out.append((m.group(1), path, dr))
    return out

def shared_strings(parts):
    if "xl/sharedStrings.xml" not in parts:
        return []
    ss = parts["xl/sharedStrings.xml"].decode("utf-8")
    return [re.sub(r"<[^>]+>", "", m.group(1)) for m in re.finditer(r"<si>(.*?)</si>", ss, re.S)]

def read_cells(xml, strs):
    """-> {(row, col): (style, text)}"""
    out = {}
    for r in re.finditer(r'<row r="(\d+)"[^>]*>(.*?)</row>', xml, re.S):
        rn = int(r.group(1))
        for c in re.finditer(r'<c r="([A-Z]+)\d+"\s*(?:s="(\d+)")?\s*(?:t="(\w+)")?\s*(?:/>|>(.*?)</c>)',
                             r.group(2), re.S):
            col, st, t, body = c.groups()
            val = ""
            if body:
                v = re.search(r"<v>([^<]*)</v>", body)
                if v:
                    val = strs[int(v.group(1))] if t == "s" else v.group(1)
                else:
                    it = re.search(r"<t[^>]*>([^<]*)</t>", body)
                    val = it.group(1) if it else ""
            out[(rn, col)] = (st, val)
    return out

def read_anchors(parts, drawing):
    """-> [{'row': 1-based top row, 'media': 'imageN.png'}] in document order."""
    d = parts[f"xl/drawings/{drawing}"].decode("utf-8")
    rid = dict(re.findall(r'Id="(rId\d+)"[^>]*?Target="[^"]*?(image\d+\.\w+)"',
                          parts[f"xl/drawings/_rels/{drawing}.rels"].decode("utf-8")))
    out = []
    for a in re.finditer(r"<xdr:(?:two|one)CellAnchor.*?</xdr:(?:two|one)CellAnchor>", d, re.S):
        blk = a.group(0)
        row = int(re.search(r"<xdr:from>.*?<xdr:row>(\d+)</xdr:row>", blk, re.S).group(1)) + 1
        to  = re.search(r"<xdr:to>.*?<xdr:row>(\d+)</xdr:row><xdr:rowOff>(\d+)</xdr:rowOff>", blk, re.S)
        emb = re.search(r'r:embed="(rId\d+)"', blk)
        out.append({"row": row, "media": rid.get(emb.group(1)) if emb else None,
                    "to_row": int(to.group(1)) + 1 if to else row,
                    "to_off": int(to.group(2)) if to else 0})
    return out

# --------------------------------------------------------------- xlsx writing
def add_styles(xml):
    """Append the caption font/style and the PASS variants. -> (xml, ids)."""
    fonts = re.search(r'<fonts count="(\d+)"([^>]*)>', xml)
    nf = int(fonts.group(1))
    cap_font, pass_font = nf, nf + 1
    xml = xml.replace(fonts.group(0), f'<fonts count="{nf + 2}"{fonts.group(2)}>')
    xml = xml.replace("</fonts>",
        '<font><i/><sz val="9"/><color rgb="FF5A6B7B"/><name val="Calibri"/></font>'
        '<font><b/><sz val="10"/><color rgb="FF1B7A3D"/><name val="Calibri"/></font></fonts>')

    xfs = re.search(r'<cellXfs count="(\d+)">(.*?)</cellXfs>', xml, re.S)
    n = int(xfs.group(1))
    existing = re.findall(r"<xf\b.*?(?:/>|</xf>)", xfs.group(2), re.S)
    new, ids = [], {}
    # caption cell: italic grey, bottom-aligned so the odd tight row stays legible
    new.append(f'<xf numFmtId="0" fontId="{cap_font}" fillId="0" borderId="0" xfId="0" '
               f'applyFont="1" applyAlignment="1"><alignment vertical="bottom"/></xf>')
    ids["caption"] = n + len(new) - 1
    # one PASS variant per fill the Test Cases tab already uses, so the banding survives
    for src in sorted({4, 7, 8, 9}):
        fill = re.search(r'fillId="(\d+)"', existing[src]).group(1)
        new.append(f'<xf numFmtId="0" fontId="{pass_font}" fillId="{fill}" borderId="1" xfId="0" '
                   f'applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">'
                   f'<alignment horizontal="center" vertical="top"/></xf>')
        ids[f"pass{src}"] = n + len(new) - 1
    xml = xml.replace(xfs.group(0),
                      f'<cellXfs count="{n + len(new)}">{xfs.group(2)}{"".join(new)}</cellXfs>')
    return xml, ids

def insert_rows(xml, new_rows):
    """Merge {row: '<row .../>'} into sheetData, keeping ascending row order."""
    sd = re.search(r"<sheetData\s*/>|<sheetData>(.*?)</sheetData>", xml, re.S)
    body = sd.group(1) or "" if sd.group(0) != "<sheetData/>" else ""
    rows = {int(m.group(1)): m.group(0) for m in re.finditer(r'<row r="(\d+)"[^>]*?(?:/>|>.*?</row>)',
                                                            body, re.S)}
    clash = set(rows) & set(new_rows)
    if clash:
        raise SystemExit(f"refusing to overwrite existing rows: {sorted(clash)[:10]}")
    rows.update(new_rows)
    return xml.replace(sd.group(0), "<sheetData>" + "".join(rows[k] for k in sorted(rows)) + "</sheetData>")

def set_dimension(xml, last_col, last_row):
    m = re.search(r'<dimension ref="[^"]*"/>', xml)
    return xml.replace(m.group(0), f'<dimension ref="A1:{last_col}{last_row}"/>') if m else xml

EMU_PER_PT = 12700

def cap_row_xml(row, style, text, spill_emu=0):
    """A caption row is 21pt, bottom-aligned. Where the image above spills into this
    row (three of the 346 anchors end a few pixels into it), grow the row by the spill
    so the bottom-aligned text still clears it instead of sitting behind the image."""
    ht = 21 + (round(spill_emu / EMU_PER_PT, 1) + 2 if spill_emu else 0)
    return (f'<row r="{row}" ht="{ht}" customHeight="1" spans="1:1">'
            f'<c r="A{row}" s="{style}" t="inlineStr"><is><t xml:space="preserve">'
            f'{escape(text)}</t></is></c></row>')

# ------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--xlsx", required=True)
    ap.add_argument("--expected", required=True)
    ap.add_argument("--verdicts", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    zin = zipfile.ZipFile(a.xlsx)
    order = [i.filename for i in zin.infolist()]
    parts = {n: zin.read(n) for n in order}
    zin.close()

    exp      = parse_expected(a.expected)
    verdicts = json.load(open(a.verdicts))
    strs     = shared_strings(parts)
    sheets   = sheet_index(parts)
    ops_by   = {f"{s}|{i}": source_ops(tc.get("changes"))
                for s, sp in SPECS.items() for i, tc in enumerate(sp["tcs"], 1)}

    parts["xl/styles.xml"], SID = add_styles(parts["xl/styles.xml"].decode("utf-8"))
    parts["xl/styles.xml"] = parts["xl/styles.xml"].encode("utf-8")

    # ---- 1. captions on every scenario tab -------------------------------
    n_caps, ledger = 0, {}
    for name, path, drawing in sheets:
        if not re.fullmatch(r"S\d\d", name) or not drawing:
            continue
        xml   = parts[path].decode("utf-8")
        cells = read_cells(xml, strs)
        # test-case header blocks: a row whose column B holds a 'TCnn' label
        hdrs = sorted((rn, v) for (rn, col), (st, v) in
                      ((k, v) for k, v in cells.items()) if col == "B" and v.startswith("TC"))
        imgs = read_anchors(parts, drawing)

        groups = {}
        for im in imgs:
            lbl = None
            for rn, l in hdrs:
                if rn < im["row"]:
                    lbl = l
            groups.setdefault(lbl, []).append(im)

        new_rows, recs = {}, []
        for lbl, group in groups.items():
            tc     = int(re.match(r"TC(\d+)", lbl).group(1))
            layout = SHOT_LAYOUT.get((name, tc), SHOTS)
            if len(group) != len(layout):
                raise SystemExit(f"{name} {lbl}: {len(group)} images, layout expects {len(layout)}. "
                                 f"Add an entry to SHOT_LAYOUT rather than guessing.")
            e, prev = exp[name].get(tc), exp[name].get(tc - 1)
            ops = ops_by.get(f"{name}|{tc}", {})
            for im, shot in zip(group, layout):
                txt = caption(name, tc, shot, e, prev, ops)
                cap_row = im["row"] - 1
                before  = [x for x in imgs if x["to_row"] <= cap_row or x["row"] < im["row"]]
                spill   = next((x["to_off"] for x in reversed(before) if x["to_row"] == cap_row), 0)
                new_rows[cap_row] = cap_row_xml(cap_row, SID["caption"], txt, spill)
                recs.append({"media": im["media"], "row": im["row"] - 1, "tc": tc,
                             "shot": shot, "caption": txt})
                n_caps += 1
        xml = insert_rows(xml, new_rows)
        xml = set_dimension(xml, "K", max(max(new_rows), max(r for r, _ in cells)) + 1)
        parts[path] = xml.encode("utf-8")
        ledger[name] = recs

    # ---- 2. RESULT column on the Test Cases tab --------------------------
    tc_path = next(p for n, p, _ in sheets if n.startswith("02"))
    xml   = parts[tc_path].decode("utf-8")
    cells = read_cells(xml, strs)
    maxrow = max(r for r, _ in cells)

    scen_of, cur = {}, None
    for rn in range(1, maxrow + 1):
        a_st, a_val = cells.get((rn, "A"), (None, ""))
        b_st, b_val = cells.get((rn, "B"), (None, ""))
        if b_val.startswith("TC"):
            scen_of[rn] = (cur, int(re.match(r"TC(\d+)", b_val).group(1)), b_st)
        elif a_val:
            m = re.match(r"(S\d\d)", a_val)
            if m:
                cur = m.group(1)

    written = 0
    for rn in range(1, maxrow + 1):
        row_m = re.search(rf'<row r="{rn}"[^>]*>(.*?)</row>', xml, re.S)
        if not row_m:
            continue
        if rn in scen_of:
            scen, tc, st = scen_of[rn]
            res = verdicts[scen][str(tc)]
            if res != "PASS":
                raise SystemExit(f"{scen} TC{tc:02d} verdict is {res!r}; this tool only styles PASS. "
                                 f"Add a FAIL style before shipping a failing result.")
            style = SID.get(f"pass{st}", SID[f"pass7"])
            cell  = f'<c r="F{rn}" s="{style}" t="inlineStr"><is><t>{res}</t></is></c>'
            written += 1
        elif rn == 3:   # header band
            cell = f'<c r="F{rn}" s="2" t="inlineStr"><is><t>RESULT</t></is></c>'
        else:           # keep the scenario banding running across the new column
            st = cells.get((rn, "A"), (None, ""))[0] or cells.get((rn, "E"), (None, ""))[0]
            cell = f'<c r="F{rn}" s="{st}"/>' if st else ""
        if cell:
            new = row_m.group(0).replace("</row>", cell + "</row>")
            new = re.sub(r'(<row r="%d")([^>]*?)spans="[^"]*"' % rn, r'\1\2spans="1:6"', new)
            xml = xml.replace(row_m.group(0), new)

    xml = xml.replace('<col min="5" max="5" width="16" customWidth="1"/>',
                      '<col min="5" max="5" width="16" customWidth="1"/>'
                      '<col min="6" max="6" width="12" customWidth="1"/>')
    xml = set_dimension(xml, "F", maxrow)
    parts[tc_path] = xml.encode("utf-8")

    # ---- 3. write, preserving every part and its order -------------------
    tmp = a.out + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        for n in order:
            z.writestr(n, parts[n])
    shutil.move(tmp, a.out)
    json.dump(ledger, open(os.path.join(os.path.dirname(a.out), "caption_ledger.json"), "w"), indent=1)
    print(f"  {n_caps} captions written across {len(ledger)} scenario tabs")
    print(f"  {written} RESULT cells written on '{next(n for n,p,_ in sheets if p == tc_path)}'")
    print(f"  -> {a.out}")

if __name__ == "__main__":
    main()
