"""POC07 — execute the scenario SQL and capture every result.

Runs the files in `Nikhil - 2/tests/` as they stand and records what came back.
The SQL is the artifact; this only executes it and writes down the answers.

    python run_poc07_tests.py --list
    python run_poc07_tests.py --file 00_setup --dry-run
    python run_poc07_tests.py --file 00_setup
    python run_poc07_tests.py --file s01_day1_first_publish
    python run_poc07_tests.py --all

WHY A SINGLE SESSION PER FILE. 00_setup.sql does `SET wh = '...'` and then uses
`IDENTIFIER($wh)`; a session variable does not survive a reconnect. The scenario
files switch role inline many times. Tooling that opens a connection per statement
would silently run everything as the connecting role — usually an account admin —
and the POC would appear to pass while proving nothing. One session, statements in
order, role switches honoured as written.

TWO STATEMENTS THIS RUNNER INJECTS, which are not in the files:

  USE SECONDARY ROLES NONE   after every USE ROLE
  USE WAREHOUSE <WAREHOUSE>  after every USE ROLE

The first is a guard rail: the operator account carries POC01's LM_PII_TAG_ADMIN and
LM_PII_POLICY_ADMIN as ACTIVE secondary roles, so without it a privilege check could
pass through a role other than the one under test — the flaw behind POC02's retracted
P2-F1. The files set it once at the top, but a USE ROLE re-enables the default.

The second is a necessity: no scenario file issues USE WAREHOUSE, so after switching
to a P7_* role the session would still point at the connection's default warehouse,
which no P7_* role can use. Every statement would fail on that rather than on
anything being tested.

Both are recorded as `injected_by_harness` on each capture and reported in the
evidence, so the deck never implies the file did something it did not.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path

import poc07_names as N

try:
    import poc07_expect as EXPECT_MOD
except ImportError:                                  # expectations not written yet
    EXPECT_MOD = None

PASS, FAIL, REVIEW, ERROR, INFO = "PASS", "FAIL", "REVIEW", "ERROR", "INFO"


# =================================================================================
# 1. Splitting the SQL
# =================================================================================
# Snowflake Scripting blocks contain their own semicolons, so a naive split on ';'
# would tear `BEGIN ... END;` into fragments. s09_atomicity.sql has two such blocks.
# The rule used here: a statement whose first keyword is BEGIN or DECLARE is only
# terminated by a ';' that directly follows the bare word END.

_LEADING_BLOCK = re.compile(r"^\s*(BEGIN|DECLARE)\b", re.IGNORECASE)
_ENDS_WITH_END = re.compile(r"\bEND\s*$", re.IGNORECASE)


class Chunk:
    """One statement, plus the comments around it and where it came from."""

    __slots__ = ("sql", "line", "comments_before", "comments_after")

    def __init__(self, sql: str, line: int, comments_before: list[str]):
        self.sql = sql
        self.line = line
        self.comments_before = comments_before
        self.comments_after: list[str] = []


def split_statements(text: str) -> list[Chunk]:
    """Split into executable statements, keeping the comments.

    Comments are preserved rather than stripped: the `/* EXPECT ... */` block that
    follows a verification query is the stated expectation, and it is wanted in the
    evidence beside the actual result. POC02's splitter strips comments, which is
    right for execution and wrong here.
    """
    chunks: list[Chunk] = []
    buf: list[str] = []                 # executable text of the current statement
    pending_comments: list[str] = []    # comments seen since the last statement
    i, n = 0, len(text)
    line = 1
    stmt_line = 1
    saw_code = False

    def flush_statement() -> None:
        nonlocal buf, pending_comments, saw_code
        sql = "".join(buf).strip()
        if sql:
            chunks.append(Chunk(sql, stmt_line, pending_comments))
            pending_comments = []
        buf = []
        saw_code = False

    while i < n:
        ch = text[i]

        # ---- line comment ------------------------------------------------------
        if ch == "-" and i + 1 < n and text[i + 1] == "-":
            j = text.find("\n", i)
            j = n if j < 0 else j
            comment = text[i:j].strip()
            if saw_code:
                # trailing comment on a code line: belongs to this statement
                pending_comments.append(comment) if False else None
                _attach_after(chunks, comment) if False else None
                pending_comments.append(comment)
            else:
                pending_comments.append(comment)
            i = j
            continue

        # ---- block comment -----------------------------------------------------
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            if j < 0:
                raise ValueError(f"unterminated /* comment opened at line {line}")
            comment = text[i:j + 2]
            line += comment.count("\n")
            if saw_code:
                # mid-statement comment: keep it with the statement's own context
                pending_comments.append(comment.strip())
            else:
                pending_comments.append(comment.strip())
            i = j + 2
            continue

        # ---- single-quoted string ---------------------------------------------
        if ch == "'":
            buf.append(ch)
            i += 1
            while i < n:
                if text[i] == "'":
                    if i + 1 < n and text[i + 1] == "'":   # '' escape
                        buf.append("''")
                        i += 2
                        continue
                    buf.append("'")
                    i += 1
                    break
                if text[i] == "\n":
                    line += 1
                buf.append(text[i])
                i += 1
            saw_code = True
            continue

        # ---- double-quoted identifier -----------------------------------------
        if ch == '"':
            buf.append(ch)
            i += 1
            while i < n:
                if text[i] == '"':
                    if i + 1 < n and text[i + 1] == '"':
                        buf.append('""')
                        i += 2
                        continue
                    buf.append('"')
                    i += 1
                    break
                if text[i] == "\n":
                    line += 1
                buf.append(text[i])
                i += 1
            saw_code = True
            continue

        # ---- dollar-quoted body ------------------------------------------------
        if ch == "$" and i + 1 < n and text[i + 1] == "$":
            j = text.find("$$", i + 2)
            if j < 0:
                raise ValueError(f"unterminated $$ block opened at line {line}")
            body = text[i:j + 2]
            line += body.count("\n")
            buf.append(body)
            i = j + 2
            saw_code = True
            continue

        # ---- statement terminator ---------------------------------------------
        if ch == ";":
            current = "".join(buf)
            if _LEADING_BLOCK.match(current) and not _ENDS_WITH_END.search(current.rstrip()):
                # inside a scripting block: this ';' is one of its internal ones
                buf.append(ch)
                i += 1
                continue
            flush_statement()
            i += 1
            continue

        if ch == "\n":
            line += 1
            if not saw_code:
                stmt_line = line
        buf.append(ch)
        if not ch.isspace():
            if not saw_code:
                stmt_line = line
            saw_code = True
        i += 1

    tail = "".join(buf).strip()
    if tail:
        if _LEADING_BLOCK.match(tail):
            raise ValueError(
                f"unterminated BEGIN/DECLARE block starting at line {stmt_line} — "
                "the file ends without a closing 'END;'")
        chunks.append(Chunk(tail, stmt_line, pending_comments))
    elif pending_comments and chunks:
        chunks[-1].comments_after.extend(pending_comments)

    return chunks


def _attach_after(chunks, comment):        # retained for clarity of intent; unused
    if chunks:
        chunks[-1].comments_after.append(comment)


def attach_trailing_comments(chunks: list[Chunk]) -> None:
    """Move each statement's leading comments to the previous statement's
    `comments_after` when they are EXPECT/RECORD notes.

    In these files the expectation follows its query:

        SELECT 'TC-03.3 ...' AS check_name, ... ;
        /* EXPECT  the renamed column carries NO tag. */

    so the comment is picked up as the NEXT statement's leading comment and has to be
    handed back to the one it describes.
    """
    for idx, ch in enumerate(chunks):
        keep: list[str] = []
        for c in ch.comments_before:
            body = c.strip("/*- \t\r\n")
            if re.match(r"^(EXPECT|RECORD|FIXED|NOTE|KEEP|IF\b)", body, re.IGNORECASE) and idx > 0:
                chunks[idx - 1].comments_after.append(c)
            else:
                keep.append(c)
        ch.comments_before = keep


# =================================================================================
# 2. Finding the test cases
# =================================================================================
# A banner is a line of three spaces + the id + the title, immediately followed by
# the '---' divider. Requiring the divider is what distinguishes a real banner from a
# wrapped prose line that happens to begin with an id — s07 had exactly that, and it
# inflated the case count by one before this was tightened.

_BANNER = re.compile(r"^ {3}(TC-\d\d\.\d[a-z]?)\s{2,}(\S.*?)\s*$")
_DIVIDER = re.compile(r"^ {3}-{10,}")
_CHECK_LABEL = re.compile(r"""^\s*SELECT\s+'([^']+)'\s+AS\s+check_name""", re.IGNORECASE)


def find_cases(text: str) -> list[tuple[int, str, str]]:
    """[(line, tc_id, title)] in file order."""
    lines = text.split("\n")
    out = []
    for idx in range(len(lines) - 1):
        m = _BANNER.match(lines[idx])
        if m and _DIVIDER.match(lines[idx + 1]):
            out.append((idx + 1, m.group(1), m.group(2)))
    return out


def case_for_line(cases: list[tuple[int, str, str]], line: int) -> tuple[str | None, str | None]:
    """The case whose banner most recently preceded this line."""
    found = (None, None)
    for ln, tc, title in cases:
        if ln <= line:
            found = (tc, title)
        else:
            break
    return found


# =================================================================================
# 3. Running a file
# =================================================================================
_USE_ROLE = re.compile(r"^\s*USE\s+ROLE\s+([A-Za-z0-9_$\"]+)\s*$", re.IGNORECASE)
_RETURNS_ROWS = re.compile(r"^\s*(SELECT|WITH|SHOW|DESC|DESCRIBE|CALL|EXPLAIN|BEGIN|DECLARE)\b",
                           re.IGNORECASE)
_MAX_ROWS = 60           # a capture is evidence, not a data dump
_MAX_CELL = 400


def _cell(v):
    if v is None:
        return None
    s = v if isinstance(v, str) else str(v)
    return s if len(s) <= _MAX_CELL else s[:_MAX_CELL] + f" ... [{len(s)} chars]"


def _error_text(exc) -> str:
    """The whole Snowflake error, flattened.

    Keeping only the first line loses the part that says what to do: the two future
    grants in 00_setup.sql reported just
        "003001 (42501): SQL access control error:"
    while the actionable sentence — "Your primary role P7_BASE_OWNER must have
    MANAGE GRANTS granted on ACCOUNT DELOITTENA" — was on the next line and thrown
    away. Diagnosing that cost a round trip it should not have.
    """
    return " ".join(str(exc).split())[:600]


def _expect_text(ch: Chunk) -> str:
    """The stated expectation for this statement.

    Normally the `/* EXPECT ... */` note FOLLOWS its query, which is why
    attach_trailing_comments hands those back to the statement above. But the suite
    also uses a PRECEDING note for statements that are meant to fail:

        /* THIS STATEMENT IS EXPECTED TO FAIL — object does not exist.
           Run it, copy the error into the evidence tab, then continue. */
        CREATE OR REPLACE TABLE D_STAGE.POLICY_SUMMARY ... ;

        /* BOTH of these are EXPECTED TO FAIL. Run them, copy the errors in. */
        SELECT * FROM D_LIVE.CUSTOMER_360 LIMIT 1;
        SELECT * FROM D_STAGE.CUSTOMER_360 LIMIT 1;

    Those are real expectations, and without reading them the harness grades a
    deliberately-broken rebuild as an ERROR when it is the test working. Only
    "EXPECTED TO FAIL" is taken from the preceding comments, so a mis-attributed
    ordinary EXPECT cannot leak backwards onto the wrong statement.
    """
    parts = []
    for c in ch.comments_after:
        if re.search(r"\bEXPECT\b", c, re.IGNORECASE):
            parts.append(c.strip())
    for c in ch.comments_before:
        if re.search(r"\bEXPECTED TO FAIL\b", c, re.IGNORECASE):
            parts.append(c.strip())
    return "\n".join(parts)


def run_file(conn, stem: str, cases_expected: int | None, dry_run: bool = False) -> dict:
    path = N.TESTS_DIR / f"{stem}.sql"
    text = path.read_bytes().decode("utf-8")
    chunks = split_statements(text)
    attach_trailing_comments(chunks)
    cases = find_cases(text)

    print(f"\n{'=' * 78}\n{stem}  —  {len(chunks)} statements, {len(cases)} test cases\n{'=' * 78}")
    if cases_expected is not None and len(cases) != cases_expected:
        print(f"  !! case count {len(cases)} but expected {cases_expected} — inventory drift")

    if dry_run:
        for k, ch in enumerate(chunks, 1):
            tc, _ = case_for_line(cases, ch.line)
            head = " ".join(ch.sql.split())[:110]
            print(f"  {k:3}  L{ch.line:<5} {tc or '-':<10} {head}")
        return {"file": stem, "dry_run": True, "statements": len(chunks), "cases": len(cases)}

    started = datetime.now(timezone.utc)
    captures: list[dict] = []
    role = None
    identity: dict = {}
    injected = 0
    warehouse_problems: list[tuple[str, str]] = []
    aborted = None
    cur = conn.cursor()

    try:
        for k, ch in enumerate(chunks, 1):
            sql = ch.sql
            tc, title = case_for_line(cases, ch.line)
            t0 = time.time()

            try:
                cur.execute(sql)
            except Exception as exc:
                msg = _error_text(exc)
                # Grade the failure rather than just recording it. Several cases
                # EXPECT a refusal ("object does not exist / not authorised"), so
                # for those an error is the PASS and success would be the finding.
                status, detail = _evaluate(tc, None, [], [], _expect_text(ch), error=msg)
                flag = {PASS: "ok  ", FAIL: "FAIL", REVIEW: "rev "}.get(status, "ERR ")
                print(f"  {k:3}  L{ch.line:<5} {tc or '-':<10} {flag} {msg[:64]}")
                captures.append({
                    "seq": k, "line": ch.line, "tc_id": tc, "tc_title": title,
                    "label": None, "role": role, "identity": identity,
                    "sql": sql, "cols": [], "rows": [],
                    "expect_text": _expect_text(ch),
                    "status": status, "detail": detail, "error": msg,
                    "elapsed_ms": int((time.time() - t0) * 1000),
                    "injected_by_harness": False,
                })
                # Keep going. A refusal is often the point of the test, and stopping
                # here would discard every later case in the file.
                continue

            rows, cols = [], []
            if cur.description:
                cols = [d[0] for d in cur.description]
                try:
                    fetched = cur.fetchmany(_MAX_ROWS + 1)
                except Exception:
                    fetched = []
                truncated = len(fetched) > _MAX_ROWS
                rows = [[_cell(v) for v in r] for r in fetched[:_MAX_ROWS]]
                if truncated:
                    rows.append([f"... more than {_MAX_ROWS} rows; truncated"] + [None] * (len(cols) - 1))

            elapsed = int((time.time() - t0) * 1000)

            # role switch: re-assert the guards the file does not
            m = _USE_ROLE.match(sql)
            if m:
                role = m.group(1).strip('"')
                # Secondary roles MUST be off — this is the guard rail, so a failure
                # here is fatal and should stop the file rather than run on with a
                # privilege that could come from the wrong role.
                cur.execute("USE SECONDARY ROLES NONE")
                injected += 1
                # The warehouse is best-effort. SECURITYADMIN and SYSADMIN run DDL
                # and hold no grant on LM_PII_POC_WH, which is correct and not a
                # problem — DDL needs no warehouse. Only the P7_* roles run queries,
                # and 00_setup.sql grants them usage. So a failure here is recorded,
                # not fatal: making it fatal would abort the file on the first
                # administrative role switch.
                try:
                    cur.execute(f"USE WAREHOUSE {N.WAREHOUSE}")
                    injected += 1
                    wh_ok = True
                except Exception as exc:
                    wh_ok = False
                    wh_note = str(exc).strip().splitlines()[0][:120]
                    if role not in N.ADMIN_ROLES:
                        # a P7_* role that cannot reach the warehouse WILL fail every
                        # query that follows, so say so loudly rather than let the
                        # scenario fail later with a confusing error
                        print(f"       !! {role} cannot USE WAREHOUSE {N.WAREHOUSE}: "
                              f"{wh_note}")
                        warehouse_problems.append((role, wh_note))
                try:
                    identity = N.session_identity(cur)
                except Exception:
                    # no warehouse, so CURRENT_* cannot be read; keep the declared
                    # role rather than claiming an identity we could not confirm
                    identity = {"role": role, "warehouse": None,
                                "note": "identity not read back (no warehouse on this role)"}

            label = None
            lm = _CHECK_LABEL.match(sql)
            if lm:
                label = lm.group(1)

            if cols:
                status, detail = _evaluate(tc, label, cols, rows, _expect_text(ch))
                captures.append({
                    "seq": k, "line": ch.line, "tc_id": tc, "tc_title": title,
                    "label": label, "role": role, "identity": identity,
                    "sql": sql, "cols": cols, "rows": rows,
                    "expect_text": _expect_text(ch),
                    "status": status, "detail": detail, "error": None,
                    "elapsed_ms": elapsed, "injected_by_harness": False,
                })
                flag = {PASS: "ok  ", FAIL: "FAIL", REVIEW: "rev ", INFO: "info"}.get(status, "    ")
                print(f"  {k:3}  L{ch.line:<5} {tc or '-':<10} {flag} "
                      f"{(label or ' '.join(sql.split())[:60])[:70]}")
            else:
                print(f"  {k:3}  L{ch.line:<5} {tc or '-':<10}      "
                      f"{' '.join(sql.split())[:70]}")
    except KeyboardInterrupt:
        aborted = "interrupted by operator"
    except Exception:
        aborted = traceback.format_exc(limit=3)
    finally:
        cur.close()

    result = {
        "file": stem,
        "started": started.isoformat(),
        "finished": datetime.now(timezone.utc).isoformat(),
        "account": N.ACCOUNT,
        "warehouse": N.WAREHOUSE,
        "statements": len(chunks),
        "cases_found": len(cases),
        "cases_expected": cases_expected,
        "case_list": [{"tc_id": t, "title": ti, "line": l} for l, t, ti in cases],
        "harness_injected_statements": injected,
        "warehouse_problems": [{"role": r, "error": e} for r, e in warehouse_problems],
        "aborted": aborted,
        "captures": captures,
    }

    N.RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    out = N.RESULTS_DIR / f"poc07_run_{stem}.json"
    out.write_text(json.dumps(result, indent=2, default=str), encoding="utf-8")
    print(f"  -> {out.name}  ({len(captures)} captures)")
    return result


def _evaluate(tc, label, cols, rows, expect_text, error=None):
    """Verdict for one capture, from the expectation table if it has an entry."""
    if EXPECT_MOD is None:
        return (REVIEW, "no expectation table loaded")
    return EXPECT_MOD.evaluate(tc, label, cols, rows, expect_text, error=error)


# =================================================================================
# 4. Inventory
# =================================================================================
def do_list() -> int:
    print(f"tests dir : {N.TESTS_DIR}")
    print(f"warehouse : {N.WAREHOUSE}")
    print(f"expecting : {N.EXPECTED_CASE_COUNT} cases\n")
    print(f"{'file':<30}{'stmts':>7}{'cases':>7}{'want':>7}  state")
    total_cases = total_stmts = 0
    problems = 0
    for stem in (N.SETUP_FILE,) + N.SCENARIOS + (N.TEARDOWN_FILE,):
        path = N.TESTS_DIR / f"{stem}.sql"
        if not path.exists():
            print(f"{stem:<30}{'-':>7}{'-':>7}{'-':>7}  MISSING")
            problems += 1
            continue
        text = path.read_bytes().decode("utf-8")
        try:
            chunks = split_statements(text)
        except ValueError as exc:
            print(f"{stem:<30}{'-':>7}{'-':>7}{'-':>7}  SPLIT ERROR: {exc}")
            problems += 1
            continue
        cases = find_cases(text)
        want = N.EXPECTED_CASES_PER_FILE.get(stem)
        state = "ok" if want is None or len(cases) == want else "COUNT DRIFT"
        if state != "ok":
            problems += 1
        print(f"{stem:<30}{len(chunks):>7}{len(cases):>7}{(want if want is not None else '-'):>7}  {state}")
        total_cases += len(cases)
        total_stmts += len(chunks)
    print(f"{'TOTAL':<30}{total_stmts:>7}{total_cases:>7}{N.EXPECTED_CASE_COUNT:>7}")
    ids = []
    for stem in N.SCENARIOS:
        p = N.TESTS_DIR / f"{stem}.sql"
        if p.exists():
            ids += [t for _, t, _ in find_cases(p.read_bytes().decode("utf-8"))]
    dupes = {i for i in ids if ids.count(i) > 1}
    print(f"\nduplicate ids: {sorted(dupes) if dupes else 'none'}")
    if total_cases != N.EXPECTED_CASE_COUNT:
        print(f"!! total {total_cases} != expected {N.EXPECTED_CASE_COUNT}")
        problems += 1
    return 1 if problems else 0


# =================================================================================
def main() -> int:
    ap = argparse.ArgumentParser(description="Run the POC07 scenario SQL and capture results.")
    ap.add_argument("--connection", default=N.CONNECTION)
    ap.add_argument("--file", help="one file stem, e.g. s01_day1_first_publish or 00_setup")
    ap.add_argument("--all", action="store_true", help="run the ten scenarios in order")
    ap.add_argument("--list", action="store_true", help="inventory only, no connection")
    ap.add_argument("--dry-run", action="store_true", help="print statements without executing")
    args = ap.parse_args()

    if args.list:
        return do_list()
    if not args.file and not args.all:
        ap.error("need --file, --all or --list")

    stems = list(N.SCENARIOS) if args.all else [args.file]
    for s in stems:
        if not (N.TESTS_DIR / f"{s}.sql").exists():
            print(f"no such file: {N.TESTS_DIR / (s + '.sql')}")
            return 2

    conn = None if args.dry_run else N.connect(args.connection)
    try:
        if conn:
            with conn.cursor() as c:
                print(f"session: {N.session_identity(c)}")
        for s in stems:
            run_file(conn, s, N.EXPECTED_CASES_PER_FILE.get(s), dry_run=args.dry_run)
    finally:
        if conn:
            conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
