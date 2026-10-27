"""POC07 — turn each `/* EXPECT ... */` note into a verdict.

The expectation is already written in the SQL, beside the query it describes. This
module reads that text and checks the actual result against it, so a verdict is
traceable to what the test author stated rather than to something invented here.

Three rules govern the design:

  1. REVIEW is the default. If nothing here can read an expectation, the capture is
     returned REVIEW with its output shown, for a person to judge. A verdict is never
     guessed, and never defaults to PASS.
  2. Masked-vs-real is an equality test against the policy's exact mask literal,
     never a guess at shape. A value that is neither masked nor one of the seeded
     real values is 'other', which forces REVIEW rather than passing.
  3. Where an expectation needs comparison across captures ("identical to TC-02.1",
     "unchanged from TC-07.2"), it is REVIEW. Those are real checks, but they belong
     to the renderer, which can see every capture at once.

The EXPECT notes mix the assertion with commentary and with conditional instructions
for the operator, e.g.

    EXPECT  2 rows - email=EMAIL and ssn=SSN
            ZERO ROWS  =  REFUSE THE PUBLISH

Only the first part is the expectation; the second is what to do if it fails. The
normaliser strips that trailing guidance before any rule runs, otherwise a passing
2-row result would also match the ZERO ROWS rule.
"""

from __future__ import annotations

import re

import poc07_names as N

PASS, FAIL, REVIEW, ERROR, INFO = "PASS", "FAIL", "REVIEW", "ERROR", "INFO"

# Columns the masking policy protects. Used to decide which cells a
# "***MASKED***" or "real values" expectation applies to.
PII_COLUMNS = {"EMAIL", "SSN", "EMAIL_ADDRESS"}

_WORD_NUM = {"no": 0, "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
             "five": 5, "six": 6, "seven": 7}

# Trailing operator guidance, cut before any rule runs. Each is the start of advice
# about what to do, not part of the expectation itself.
#
# Why this list matters more than it looks: the setup smoke test reads
#     EXPECT  ***MASKED*** / ***MASKED***
#             If this returns real values the masking policy is NOT attached
# and without the cut, the words "real values" in the GUIDANCE made the rule see
# both a masked expectation and a real one at once, so it declined to judge and the
# most important pre-flight check in the suite silently fell through to REVIEW.
_CUT_AT = (
    # general: an instructional or conditional clause, which is never the assertion
    r"\b(?:If this|If tags|If so|If B-|Any non-zero|Anything else|Do not|Stop and)\b",
    r"ZERO ROWS\s*=\s*REFUSE",
    r"Real values here mean",
    r"\bRECORD\b",
    r"A silent no-op",
    r"ZERO ROWS here would mean",
    r"A 2 in either row",
    r"FIXED \d+ \w+",
    r"\bNOTE\b",
    r"This query is the reason",
    r"The same bootstrap gap",
    r"IF \d+ ROWS APPEAR",
    r"so the work done under",
    r"Two refusals with a full rebuild",
    r"Keyed on batch_id",
    r"The block is unclearable",
    r"The rebuild copied the tags",
    r"which is exactly what",
    r"\bKEEP\b",
)


def normalise(expect_text: str) -> str:
    """The assertion only: EXPECT stripped, trailing guidance cut, whitespace flat."""
    if not expect_text:
        return ""
    t = expect_text
    t = re.sub(r"/\*|\*/", " ", t)
    t = re.sub(r"(?im)^\s*--\s*", " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    m = re.search(r"\bEXPECT\b", t, re.IGNORECASE)
    if m:
        t = t[m.end():]
    # "THIS STATEMENT IS EXPECTED TO FAIL" has no bare EXPECT, so keep the phrase
    # itself when that is all there is — _rule_expected_error matches on it.
    elif re.search(r"EXPECTED TO FAIL", t, re.IGNORECASE):
        t = "EXPECTED TO FAIL " + t
    for pat in _CUT_AT:
        cm = re.search(pat, t, re.IGNORECASE)
        if cm:
            t = t[:cm.start()]
    return t.strip(" -\u2014.,;:")


# =================================================================================
# helpers over the result grid
# =================================================================================
def _col_index(cols, name) -> int:
    up = [c.upper() for c in cols]
    try:
        return up.index(name.upper())
    except ValueError:
        return -1


def _data_rows(rows):
    """Rows excluding the runner's truncation marker."""
    return [r for r in rows
            if not (r and isinstance(r[0], str) and r[0].startswith("... more than"))]


def _pii_cells(cols, rows):
    idxs = [i for i, c in enumerate(cols) if c.upper() in PII_COLUMNS]
    return [(cols[i], r[i]) for r in _data_rows(rows) for i in idxs if i < len(r)]


# =================================================================================
# the rules
# =================================================================================
def _rule_expected_error(head, error):
    """Statements that are supposed to fail.

    Two forms in this suite: an explicit "EXPECTED TO FAIL" note before the
    statement, and an expectation that names the error — "object does not exist /
    not authorised". Either way the error is the PASS and success is the finding.
    """
    wants_failure = bool(re.search(
        r"EXPECTED TO FAIL|object does not exist|not authoris|not authoriz|"
        r"access.*denied|is REFUSED",
        head, re.IGNORECASE))
    if not wants_failure:
        return None
    if error:
        return (PASS, f"failed as required: {error[:140]}")
    return (FAIL, "the statement SUCCEEDED, but was expected to be refused")


def _rule_row_count(head, cols, rows):
    """Anchored row-count assertions. Anchoring matters: 'ZERO ROWS' appears inside
    trailing guidance too, and an unanchored match would fail a passing result."""
    data = _data_rows(rows)
    n = len(data)

    if re.match(r"^(STILL\s+)?ZERO ROWS\b", head, re.IGNORECASE):
        return (PASS, "0 rows, as expected") if n == 0 else \
               (FAIL, f"{n} rows, expected none")

    m = re.match(r"^(STILL\s+)?(\d+)\s+ROWS?\b", head, re.IGNORECASE)
    if m:
        want = int(m.group(2))
        return (PASS, f"{n} rows, as expected") if n == want else \
               (FAIL, f"{n} rows, expected {want}")

    m = re.match(r"^(no|zero|one|two|three|four|five)\s+(?:\w+\s+)?rows?\b", head, re.IGNORECASE)
    if m:
        want = _WORD_NUM[m.group(1).lower()]
        return (PASS, f"{n} rows, as expected") if n == want else \
               (FAIL, f"{n} rows, expected {want}")

    m = re.match(r"^(\d+)\s+or\s+more\b", head, re.IGNORECASE)
    if m:
        want = int(m.group(1))
        # a single numeric cell carries the count in these cases
        val = _single_number(cols, rows)
        got = val if val is not None else n
        return (PASS, f"{got} >= {want}") if got >= want else \
               (FAIL, f"{got}, expected {want} or more")

    m = re.match(r"^BOTH tables\b", head, re.IGNORECASE)
    if m:
        return (PASS, "2 rows, both tables") if n == 2 else \
               (FAIL, f"{n} rows, expected 2 (both tables)")
    return None


def _single_number(cols, rows):
    data = _data_rows(rows)
    if len(data) != 1:
        return None
    nums = []
    for v in data[0]:
        if isinstance(v, bool):
            continue
        if isinstance(v, int):
            nums.append(v)
        elif isinstance(v, str) and re.fullmatch(r"-?\d+", v.strip()):
            nums.append(int(v))
    return nums[0] if len(nums) == 1 else None


def _rule_bare_number(head, cols, rows):
    """'EXPECT 0.' — a single scalar result, e.g. approvals_for_next_batch."""
    m = re.match(r"^(-?\d+)\s*$", head)
    if not m:
        return None
    want = int(m.group(1))
    got = _single_number(cols, rows)
    if got is None:
        return None
    return (PASS, f"{got}, as expected") if got == want else \
           (FAIL, f"{got}, expected {want}")


def _rule_column_values(head, cols, rows):
    """Every `<column> = <value>` pair whose left side is a real column.

    Covers the compound forms in one rule — `distinct_batches = 1, batch_seen = B2`
    checks both — plus mixed_readings, rows_updated, remaining_stage_grants, owner
    and PII_SCOPE.
    """
    pairs = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*('?[A-Za-z0-9_*\-]+'?)", head)
    checks = []
    for raw_col, raw_val in pairs:
        ci = _col_index(cols, raw_col)
        if ci < 0:
            continue
        want = raw_val.strip("'")
        data = _data_rows(rows)
        if not data:
            checks.append((FAIL, f"{raw_col}: no rows returned, expected {want}"))
            continue
        got_vals = {("" if r[ci] is None else str(r[ci])) for r in data if ci < len(r)}
        if want.upper() == "NULL":
            ok = got_vals <= {""}
            shown = "NULL" if ok else ", ".join(sorted(v or "NULL" for v in got_vals))
        else:
            ok = got_vals == {want}
            shown = ", ".join(sorted(v or "NULL" for v in got_vals))
        checks.append((PASS if ok else FAIL, f"{raw_col}={shown}" if ok
                       else f"{raw_col}={shown}, expected {want}"))
    if not checks:
        return None
    if any(s == FAIL for s, _ in checks):
        return (FAIL, "; ".join(d for s, d in checks if s == FAIL))
    return (PASS, "; ".join(d for _, d in checks))


def _rule_masked_or_real(head, cols, rows):
    """`***MASKED***` or `real values`, over the tagged columns only.

    full_name is deliberately untagged, so an expectation that says
    "***MASKED*** in email and ssn. full_name is untagged, so real." is satisfied by
    checking the PII columns and leaving the rest alone.
    """
    wants_mask = "***MASKED***" in head or re.search(r"\bMASKED\b", head)
    wants_real = re.match(r"^REAL\b|^real\b", head) or re.search(
        r"\breal (e-mail and SSN )?values\b", head, re.IGNORECASE)
    if not (wants_mask or wants_real):
        return None

    cells = _pii_cells(cols, rows)
    if not cells:
        return None
    kinds = {}
    for name, val in cells:
        kinds.setdefault(N.classify(val), []).append(name)

    if wants_mask and not wants_real:
        if set(kinds) == {"masked"}:
            return (PASS, f"all {len(cells)} tagged cells masked")
        bad = {k: sorted(set(v)) for k, v in kinds.items() if k != "masked"}
        status = FAIL if "real" in kinds else REVIEW
        return (status, f"expected all masked; found {bad}")

    if wants_real and not wants_mask:
        if set(kinds) == {"real"}:
            return (PASS, f"all {len(cells)} tagged cells hold real values")
        bad = {k: sorted(set(v)) for k, v in kinds.items() if k != "real"}
        status = FAIL if "masked" in kinds else REVIEW
        return (status, f"expected real values; found {bad}")
    return None


def _rule_grant_presence(head, cols, rows):
    """`P7_PROBE_ROLE still holds SELECT`, `... is GONE`, `no P7_ grants`."""
    gi = _col_index(cols, "grantee_name")
    pi = _col_index(cols, "privilege")
    data = _data_rows(rows)

    if re.search(r"^no P7_ grants", head, re.IGNORECASE):
        if gi < 0:
            n = len(data)
            return (PASS, "no rows") if n == 0 else (FAIL, f"{n} rows, expected none")
        p7 = [r for r in data if r[gi] and str(r[gi]).startswith("P7_")]
        return (PASS, "no P7_ grants") if not p7 else \
               (FAIL, f"{len(p7)} P7_ grants present: "
                      f"{sorted({str(r[gi]) for r in p7})}")

    m = re.search(r"(P7_[A-Z_]+)\b[^.]*?\b(holds|is\s+GONE)", head, re.IGNORECASE)
    if not m or gi < 0 or pi < 0:
        return None
    role, verb = m.group(1).upper(), m.group(2).lower().replace(" ", "")
    held = {str(r[pi]).upper() for r in data
            if r[gi] and str(r[gi]).upper() == role}
    if verb == "holds":
        return (PASS, f"{role} holds {sorted(held)}") if "SELECT" in held else \
               (FAIL, f"{role} holds {sorted(held) or 'nothing'}, expected SELECT")
    return (PASS, f"{role} holds nothing") if "SELECT" not in held else \
           (FAIL, f"{role} still holds SELECT")


def _rule_tag_value(head, cols, rows):
    """`PII_SCOPE = P7_OVERRIDE` against a tag_name/tag_value grid.

    The column-values rule cannot do this one: the thing being asserted is a tag
    NAME, which appears as a value in the TAG_NAME column, not as a column itself.
    """
    ni, vi = _col_index(cols, "tag_name"), _col_index(cols, "tag_value")
    if ni < 0 or vi < 0:
        return None
    m = re.match(r"^(PII_SCOPE|PII)\s*=\s*'?([A-Za-z0-9_]+)'?", head, re.IGNORECASE)
    if not m:
        return None
    want_tag, want_val = m.group(1).upper(), m.group(2).upper()
    pairs = {(str(r[ni]).upper(), str(r[vi]).upper())
             for r in _data_rows(rows) if ni < len(r) and vi < len(r)}
    if (want_tag, want_val) in pairs:
        return (PASS, f"{want_tag} = {want_val}")
    got = sorted(v for t, v in pairs if t == want_tag)
    return (FAIL, f"{want_tag} = {got or 'not set'}, expected {want_val}")


def _rule_arrow_map(head, cols, rows):
    """`A, B, C -> OWNER` and `email -> PII = EMAIL, ssn -> PII = SSN`.

    Used by 00_setup.sql's pre-flight checks, which assert the whole environment in
    one grid: schema owners, and the base tags. Worth grading rather than leaving to
    a human, because a wrong environment invalidates every scenario after it.
    """
    if "->" not in head:
        return None

    # form 2: name -> TAG = VALUE
    trips = re.findall(r"([A-Za-z_]+)\s*->\s*([A-Z_]+)\s*=\s*([A-Za-z0-9_]+)", head)
    if trips:
        ci = _col_index(cols, "column_name")
        ni = _col_index(cols, "tag_name")
        vi = _col_index(cols, "tag_value")
        if min(ci, ni, vi) < 0:
            return None
        actual = {(str(r[ci]).upper(), str(r[ni]).upper(), str(r[vi]).upper())
                  for r in _data_rows(rows)}
        want = {(a.upper(), b.upper(), c.upper()) for a, b, c in trips}
        missing = want - actual
        return (PASS, f"all {len(want)} tag assignments as expected") if not missing else \
               (FAIL, f"missing {sorted(missing)}; found {sorted(actual)}")

    # form 1: A, B, C -> OWNER  (possibly several groups)
    groups = re.findall(r"([A-Za-z_][A-Za-z0-9_,\s]*?)\s*->\s*([A-Z][A-Z0-9_]+)", head)
    if not groups:
        return None
    ni = _col_index(cols, "name")
    oi = _col_index(cols, "owner")
    if ni < 0 or oi < 0:
        return None
    actual = {str(r[ni]).upper(): str(r[oi]).upper() for r in _data_rows(rows)}
    want = {}
    for names, owner in groups:
        for nm in re.split(r"[,\s]+", names.strip()):
            if nm:
                want[nm.upper()] = owner.upper()
    wrong = {k: (actual.get(k, "MISSING"), v) for k, v in want.items()
             if actual.get(k) != v}
    return (PASS, f"all {len(want)} owners as expected") if not wrong else \
           (FAIL, "; ".join(f"{k}: {got}, expected {exp}" for k, (got, exp) in wrong.items()))


def _rule_literal_values(head, cols, rows):
    """`setup@example.invalid / 000-00-0000` — two literal values, slash-separated.

    Used by the setup smoke test for the ENTITLED role, where the point is that the
    exact seeded values come back rather than masks.
    """
    parts = [p.strip() for p in head.split("/")]
    if len(parts) < 2:
        return None
    if not all(re.fullmatch(r"[\w.@*-]+", p) for p in parts):
        return None
    data = _data_rows(rows)
    if len(data) != 1:
        return None
    present = {("" if v is None else str(v)) for v in data[0]}
    missing = [p for p in parts if p not in present]
    return (PASS, f"{parts} all present") if not missing else \
           (FAIL, f"missing {missing}; row held {sorted(present)}")


def _rule_tag_absent(head, cols, rows):
    """`'phone' carries NO tag`, `the renamed column (email_address) carries NO tag`."""
    m = re.search(r"'?([a-z_]+)'?\s*(?:\([a-z_]+\))?\s*carries NO tag", head, re.IGNORECASE)
    if not m:
        m2 = re.search(r"renamed column \(([a-z_]+)\) carries NO tag", head, re.IGNORECASE)
        if not m2:
            return None
        col = m2.group(1)
    else:
        col = m.group(1)
        if col.lower() == "column":
            return None
    ci = _col_index(cols, "column_name")
    if ci < 0:
        return None
    tagged = {str(r[ci]).upper() for r in _data_rows(rows) if ci < len(r)}
    return (PASS, f"{col} not tagged; tagged columns: {sorted(tagged)}") \
        if col.upper() not in tagged else \
        (FAIL, f"{col} IS tagged, expected no tag")


# Expectations that genuinely need more than one capture, or a human. Returned REVIEW
# with a reason, so the deck shows what has to be checked and against what.
_NEEDS_REVIEW = (
    (r"^identical to (TC-[\d.]+[a-z]?)", "compare against {0}; cross-capture check"),
    (r"^unchanged", "compare against the preceding capture; cross-capture check"),
    (r"UNCHANGED from (TC-[\d.]+[a-z]?)", "compare status_at against {0}"),
    (r"^FEWER rows than before", "compare row count against the preceding capture"),
    (r"^B\d+ ", "multi-row sequence; read the grid"),
    (r"^CUSTOMER_360 ", "per-table status pattern; read the grid"),
    (r"^status FAILED", "multi-column pattern; read the grid"),
    (r"^distinct_batches = 1 in BOTH rows", "needs the second session's reading"),
    (r"^mixed_readings = 0 out of N", "needs the second session's reader loop"),
    (r"^one row\b.*only", "single named row; read the grid"),
    (r"^1 row\b.*with an approver", "single row plus free text; read the grid"),
)


def _rule_needs_review(head):
    for pat, why in _NEEDS_REVIEW:
        m = re.search(pat, head, re.IGNORECASE)
        if m:
            return (REVIEW, why.format(*m.groups()) if m.groups() else why)
    return None


# =================================================================================
def evaluate(tc, label, cols, rows, expect_text, error=None):
    """(status, detail) for one capture."""
    head = normalise(expect_text)

    if not head:
        if error:
            return (ERROR, error[:200])
        return (INFO, "no stated expectation — captured for the record")

    r = _rule_expected_error(head, error)
    if r:
        return r

    if error:
        return (ERROR, f"statement failed: {error[:160]}")

    r = _rule_needs_review(head)
    if r:
        return r

    for rule in (_rule_row_count, _rule_bare_number, _rule_arrow_map,
                 _rule_tag_value, _rule_column_values, _rule_masked_or_real,
                 _rule_grant_presence, _rule_tag_absent, _rule_literal_values):
        out = rule(head, cols, rows)
        if out:
            # A row-count assertion can be paired with column assertions
            # ("2 rows - email=EMAIL"), so confirm both when both are present.
            if rule is _rule_row_count:
                extra = _rule_column_values(head, cols, rows)
                if extra and extra[0] == FAIL:
                    return (FAIL, f"{out[1]}; {extra[1]}")
                if extra and out[0] == PASS:
                    return (PASS, f"{out[1]}; {extra[1]}")
            return out

    return (REVIEW, f"no rule for this expectation: {head[:120]}")
