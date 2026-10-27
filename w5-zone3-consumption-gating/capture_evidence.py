"""POC07 — render the captured runs as one self-contained HTML evidence deck.

    python capture_evidence.py

Reads every `poc07_run_*.json` in ../evidence and writes, into the same folder,

    LM_Batch_Publishing_Evidence_POC07.html
    LM_Batch_Publishing_Evidence_POC07.md

A PURE RENDERER. Unlike POC02's generator, which re-queries Snowflake every time it
builds its pack, this reads only what the runner already captured. That is a
deliberate difference: every POC07 scenario opens with a RESET TO DAY 1 that
CREATE OR REPLACEs both swap schemas and TRUNCATEs the control tables, so a
re-querying generator would destroy the environment each time it ran — and would
also destroy the earlier scenarios' control-table evidence.

CHASSIS. The CSS, the capture-block anatomy, the sticky numbered tab bar and the
@media print rule that expands every panel are taken from POC02's
capture_evidence.py, so the three packs look like one family. The per-case status
pill (.st / .ok / .warn / .blocked) comes from POC01's deck, which POC02 does not
have. The counted scorecard is new: neither existing pack counts anything.
"""

from __future__ import annotations

import html
import json
from collections import Counter, OrderedDict
from datetime import datetime, timezone

import poc07_names as N

PASS, FAIL, REVIEW, ERROR, INFO = "PASS", "FAIL", "REVIEW", "ERROR", "INFO"

# Worst-first, so a test case's verdict is the worst of its captures. A case with
# nine passing checks and one failure is a failure.
SEVERITY = {FAIL: 0, ERROR: 1, REVIEW: 2, PASS: 3, INFO: 4}
PILL = {PASS: "ok", FAIL: "bad", REVIEW: "warn", ERROR: "bad", INFO: "blocked"}

# From POC07_TEST_DESIGN.md section 10. Shows which of the design's 42 tests this
# run touches, and by omission which it does not.
TC_TO_T = {
    "TC-01.1": "T1, T28", "TC-01.2": "T1, T3", "TC-01.3": "T37", "TC-01.4": "T1",
    "TC-01.5": "T37, T20", "TC-01.6": "T20",
    "TC-02.1": "T38", "TC-02.2": "T38", "TC-02.3": "T38", "TC-02.4": "T38",
    "TC-02.5": "T38",
    "TC-03.1": "T37", "TC-03.2": "T1, T3", "TC-03.3": "T2", "TC-03.4": "T16",
    "TC-04.1": "T15", "TC-04.2": "T41", "TC-04.3": "T41", "TC-04.4": "T41, T15",
    "TC-04.5": "T41", "TC-04.6": "T12", "TC-04.7": "T28",
    "TC-05.1": "T10, T24", "TC-05.2": "T10", "TC-05.3": "T10",
    "TC-05.3b": "T10", "TC-05.3c": "T10, T26", "TC-05.4": "T10",
    "TC-06.1": "T10", "TC-06.2": "T10", "TC-06.3": "T26", "TC-06.4": "T27",
    "TC-06.5": "T27",
    "TC-07.1": "T25", "TC-07.2": "T25", "TC-07.3": "T25, T31",
    "TC-07.4": "T30, T40", "TC-07.5": "T42",
    "TC-08.1": "T7", "TC-08.2": "T7", "TC-08.3": "T8", "TC-08.4": "T12",
    "TC-08.5": "T12",
    "TC-09.1": "T20", "TC-09.2": "T20", "TC-09.3": "T20, D7",
    "TC-10.1": "T39", "TC-10.2": "T39", "TC-10.3": "T39", "TC-10.4": "T39",
}

# What the substantive results MEAN. Keyed by case, rendered under the finding.
# Without this the deck reports "0 rows, expected 2" and leaves the reader to work
# out that it reproduces the design's central correctness finding.
FINDING_NOTES = {
    "TC-04.3": (
        "<b>This is the design's central correctness finding, reproduced from a "
        "different direction — not a defect in the run.</b> <code>TC-04.2</code> "
        "immediately before it does a <i>plain</i> <code>CREATE OR REPLACE</code>, "
        "which strips the tags. <code>TC-04.3</code> then rebuilds with "
        "<code>COPY TAGS</code> — and copies from the untagged table the previous case "
        "left behind, so the tags do not come back. The grants half of this case "
        "passes; the tags half cannot. That is exactly section 2.4 row 22 and test "
        "<code>T40</code> of the design: <b><code>COPY TAGS</code> takes its tags from "
        "the table it replaces, so once they are gone a rebuild cannot restore "
        "them</b> — only re-tagging can. The case's own expectation of 2 rows assumed "
        "otherwise."),
    "TC-04.5": (
        "<b>The case's premise is contradicted by its own evidence.</b> It asserts that "
        "on a first build there is nothing for <code>COPY GRANTS</code> to copy, so "
        "“grants must be deployed too”. But the <code>SELECT</code> is there — supplied "
        "by the <b>future grant</b> in the scenario's own reset block. So future grants "
        "<i>do</i> cover the day-1 bootstrap that <code>COPY GRANTS</code> alone cannot. "
        "That is direct evidence for the design's <code>D24</code> and <code>T41</code>, "
        "and it supports the design's choice of future grants over the "
        "<code>COPY GRANTS</code> route this suite relies on. Separately, OWNERSHIP is "
        "itself a grant, so “no <code>P7_</code> grants” can never be literally true."),
}

SCENARIO_TITLE = {
    "s01_day1_first_publish": "S01 — Day 1, the first publish",
    "s02_steady_state": "S02 — Steady state, four consecutive batches",
    "s03_tags": "S03 — Tags: seeding, table-level, rename, new column",
    "s04_grants": "S04 — Grants: swap, plain CTAS, COPY GRANTS, ownership",
    "s05_dependency_gating": "S05 — Dependency gating",
    "s06_exception_approval": "S06 — Exception approval and its expiry",
    "s07_restart": "S07 — Restart after failure",
    "s08_masking": "S08 — Masking, and what a writer stores",
    "s09_atomicity": "S09 — Atomicity at the swap",
    "s10_rollback": "S10 — Rollback to the previous batch",
}

# Statements worth showing as context even though they return nothing. These are the
# mechanism under test: the rebuild, the publish, and the tagging.
CONTEXT_SQL = ("CREATE OR REPLACE TABLE", "ALTER SCHEMA", "SET TAG", "UNSET TAG",
               "GRANT OWNERSHIP")


def esc(v) -> str:
    return html.escape("" if v is None else str(v))


# =================================================================================
# load
# =================================================================================
def load_runs() -> OrderedDict:
    runs = OrderedDict()
    for stem in (N.SETUP_FILE,) + N.SCENARIOS:
        path = N.RESULTS_DIR / f"poc07_run_{stem}.json"
        if path.exists():
            runs[stem] = json.loads(path.read_text(encoding="utf-8"))
    return runs


def build_cases(runs) -> OrderedDict:
    """tc_id -> {file, title, verdict, captures[]} in scenario order."""
    cases: OrderedDict = OrderedDict()
    for stem, run in runs.items():
        if stem == N.SETUP_FILE:
            continue
        for entry in run.get("case_list", []):
            cases[entry["tc_id"]] = {
                "file": stem, "title": entry["title"], "line": entry["line"],
                "captures": [], "verdict": None,
            }
        for cap in run["captures"]:
            tc = cap.get("tc_id")
            if tc and tc in cases:
                cases[tc]["captures"].append(cap)
    for tc, c in cases.items():
        graded = [x for x in c["captures"] if x["status"] != INFO]
        if not graded:
            c["verdict"] = INFO
        else:
            c["verdict"] = sorted((x["status"] for x in graded),
                                  key=lambda s: SEVERITY.get(s, 9))[0]
        c["graded"] = graded
    return cases


# =================================================================================
# pieces
# =================================================================================
def grid_html(cols, rows) -> str:
    """Verbatim from POC02's generator — generic, so reused unchanged."""
    if not cols:
        return "<p class='reading'>no result grid — statement returned no rows</p>"
    head = "".join(f"<th>{esc(c)}</th>" for c in cols)
    body = "".join("<tr>" + "".join(f"<td>{esc(v)}</td>" for v in r) + "</tr>"
                   for r in rows)
    return f"<table class='grid'><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"


def pill(status) -> str:
    return f"<span class='st {PILL.get(status, 'blocked')}'>{esc(status)}</span>"


def who(cap) -> str:
    ident = cap.get("identity") or {}
    role = ident.get("role") or cap.get("role") or "?"
    user = ident.get("user") or "PSINGH"
    sec = ident.get("secondary_roles")
    secnote = "secondary roles NONE" if (sec in (None, "", '{"roles":"","value":""}')
                                         or (isinstance(sec, str) and '"roles":""' in sec)) \
        else f"secondary roles: {sec}"
    wh = ident.get("warehouse") or "—"
    return f"executed as: {esc(user)} using {esc(role)} ({secnote}) · warehouse {esc(wh)}"


def capture_block(cap) -> str:
    bits = [f"<div class='cap'><div class='lbl'>{pill(cap['status'])} "
            f"{esc(cap.get('label') or cap.get('tc_id') or 'statement')}</div>",
            f"<div class='who'>{who(cap)} · line {cap['line']} · {cap['elapsed_ms']} ms</div>",
            f"<pre>{esc(cap['sql'])}</pre>"]
    if cap.get("error"):
        bits.append("<table class='grid'><thead><tr><th>error, verbatim</th></tr>"
                    f"</thead><tbody><tr><td>{esc(cap['error'])}</td></tr></tbody></table>")
    else:
        bits.append(grid_html(cap["cols"], cap["rows"]))
    if cap.get("expect_text"):
        flat = " ".join(cap["expect_text"].split())
        bits.append(f"<div class='reading'><b>stated expectation:</b> {esc(flat)}</div>")
    bits.append(f"<div class='reading'><b>verdict:</b> {esc(cap['status'])} — "
                f"{esc(cap['detail'])}</div></div>")
    return "".join(bits)


def context_row(cap) -> str:
    return (f"<div class='cap' style='background:#fff;border-style:dashed'>"
            f"<div class='who'>context · line {cap['line']} · "
            f"{esc((cap.get('identity') or {}).get('role') or cap.get('role'))}</div>"
            f"<pre>{esc(cap['sql'])}</pre></div>")


# =================================================================================
# tabs
# =================================================================================
def tab_brief(runs, cases) -> list[str]:
    counts = Counter(c["verdict"] for c in cases.values())
    total = len(cases)
    setup = runs.get(N.SETUP_FILE)
    setup_counts = Counter(c["status"] for c in setup["captures"]) if setup else Counter()

    p = ["<h2>What was run, and what it showed</h2>"]
    p.append(
        "<div class='rec'>"
        f"<b>{counts.get(PASS, 0)} of {total} test cases passed.</b> "
        f"{counts.get(FAIL, 0)} failed · {counts.get(ERROR, 0)} errored · "
        f"{counts.get(REVIEW, 0)} need a human reading · {counts.get(INFO, 0)} not graded. "
        "Every verdict below is checked against the expectation written in the SQL "
        "beside the query, not against a separate list — so a verdict can always be "
        "traced to what the test author asked for."
        "</div>")

    p.append("<table class='score'><thead><tr><th>#</th><th>Scenario</th>"
             "<th>Cases</th><th>Pass</th><th>Fail</th><th>Error</th><th>Review</th>"
             "<th>Statements</th></tr></thead><tbody>")
    for i, stem in enumerate(N.SCENARIOS, 1):
        if stem not in runs:
            continue
        mine = [c for c in cases.values() if c["file"] == stem]
        cc = Counter(c["verdict"] for c in mine)
        p.append(f"<tr><td>{i}</td><td>{esc(SCENARIO_TITLE.get(stem, stem))}</td>"
                 f"<td>{len(mine)}</td><td>{cc.get(PASS, 0)}</td><td>{cc.get(FAIL, 0)}</td>"
                 f"<td>{cc.get(ERROR, 0)}</td><td>{cc.get(REVIEW, 0)}</td>"
                 f"<td>{runs[stem]['statements']}</td></tr>")
    p.append("</tbody></table>")

    if setup:
        p.append("<h2>The environment it ran against</h2>")
        p.append(
            "<p><code>00_setup.sql</code> built the whole environment and verified it "
            f"before any scenario ran: {runs[N.SETUP_FILE]['statements']} statements, "
            f"{setup_counts.get(PASS, 0)} checks passed, {setup_counts.get(FAIL, 0)} failed, "
            f"{setup_counts.get(ERROR, 0)} errored. Its own pre-flight checks confirm the "
            "schema owners, the base tags, and — the one that matters most — that an "
            "unentitled role reads <code>***MASKED***</code> while an entitled one reads "
            "real values. If that last check had failed, nothing after it would mean "
            "anything.</p>")

    p.append("<h2>Every case</h2>")
    p.append("<table class='score'><thead><tr><th>#</th><th>Case</th><th>What it proves</th>"
             "<th>Verdict</th><th>Design test</th></tr></thead><tbody>")
    for i, (tc, c) in enumerate(cases.items(), 1):
        p.append(f"<tr><td>{i}</td><td><b>{esc(tc)}</b></td>"
                 f"<td>{esc(c['title'])}</td>"
                 f"<td class='st'>{pill(c['verdict'])}</td>"
                 f"<td>{esc(TC_TO_T.get(tc, '—'))}</td></tr>")
    p.append("</tbody></table>")
    return p


def tab_findings(runs, cases) -> list[str]:
    p = ["<h2>What needs attention</h2>"]
    bad = [(tc, c) for tc, c in cases.items() if c["verdict"] in (FAIL, ERROR)]
    rev = [(tc, c) for tc, c in cases.items() if c["verdict"] == REVIEW]

    if not bad:
        p.append("<div class='rec'><b>No test case failed or errored.</b> Read this "
                 "with the Scope tab: a clean run proves the cases that exist, not the "
                 "ones that do not.</div>")
    for tc, c in bad:
        p.append(f"<div class='finding'><b>{esc(tc)} — {esc(c['title'])}</b> "
                 f"{pill(c['verdict'])}<br><span style='font-size:12px;color:#666'>"
                 f"{esc(SCENARIO_TITLE.get(c['file'], c['file']))} · design test "
                 f"{esc(TC_TO_T.get(tc, '—'))}</span><ul class='opt'>")
        for cap in c["graded"]:
            if cap["status"] in (FAIL, ERROR):
                p.append(f"<li><b>{esc(cap.get('label') or 'line ' + str(cap['line']))}:</b> "
                         f"{esc(cap['detail'])}</li>")
        p.append("</ul>")
        if tc in FINDING_NOTES:
            p.append(f"<div class='reading' style='font-style:normal'>"
                     f"{FINDING_NOTES[tc]}</div>")
        p.append("</div>")

    if rev:
        p.append("<h2>Cases a person still has to read</h2>")
        p.append("<p>These are not failures. Each one states an expectation that cannot "
                 "be checked mechanically from a single result — a comparison against an "
                 "earlier capture, or a pattern across rows. The grids are in the Evidence "
                 "tab. Nothing here was marked passed on the harness's say-so.</p>")
        p.append("<table class='matrix'><thead><tr><th>Case</th><th>What it proves</th>"
                 "<th>Why it needs reading</th></tr></thead><tbody>")
        for tc, c in rev:
            why = "; ".join(sorted({cap["detail"] for cap in c["graded"]
                                    if cap["status"] == REVIEW}))
            p.append(f"<tr><td><b>{esc(tc)}</b></td><td>{esc(c['title'])}</td>"
                     f"<td>{esc(why)}</td></tr>")
        p.append("</tbody></table>")

    inj = sum(r.get("harness_injected_statements", 0) for r in runs.values())
    p.append("<h2>What the harness did that the SQL does not say</h2>")
    p.append(
        "<p>Stated so the deck never implies the files did something they do not. "
        f"The runner injected <b>{inj} statements</b> across all runs, two kinds only, "
        "both after every <code>USE ROLE</code>:</p>"
        "<ul class='opt'>"
        "<li><b><code>USE SECONDARY ROLES NONE</code></b> — the files set this once at the "
        "top, but a <code>USE ROLE</code> re-enables the account default. This operator's "
        "account carries POC01's <code>LM_PII_TAG_ADMIN</code> and "
        "<code>LM_PII_POLICY_ADMIN</code> as <i>active</i> secondary roles, so without it a "
        "privilege check could pass through a role other than the one under test. That is "
        "the flaw that produced POC02's retracted <code>P2-F1</code> finding.</li>"
        "<li><b><code>USE WAREHOUSE " + esc(N.WAREHOUSE) + "</code></b> — no scenario file "
        "issues this, so after switching to a <code>P7_*</code> role the session would still "
        "point at the connection's default warehouse, which no <code>P7_*</code> role can "
        "use. Every query would fail on that rather than on anything being tested. It is "
        "best-effort: <code>SECURITYADMIN</code> and <code>SYSADMIN</code> hold no grant on "
        "the warehouse and need none for DDL, so a failure there is recorded and ignored.</li>"
        "</ul>")
    wp = [(r["file"], w) for r in runs.values() for w in r.get("warehouse_problems", [])]
    if wp:
        p.append("<div class='finding'><b>Warehouse problems recorded:</b><ul class='opt'>")
        for f, w in wp:
            p.append(f"<li>{esc(f)}: {esc(w['role'])} — {esc(w['error'])}</li>")
        p.append("</ul></div>")
    return p


def tab_evidence(runs, cases) -> list[str]:
    p = ["<h2>Every graded check, with its SQL and its result</h2>",
         "<p>Grouped by scenario and test case. Each block shows the verbatim SQL, who ran "
         "it, what came back, the expectation stated in the file, and the verdict. "
         "Statements that return nothing are shown as dashed <i>context</i> blocks where "
         "they are the mechanism under test — the rebuild, the swap, the tagging — and "
         "omitted otherwise.</p>"]
    for stem in N.SCENARIOS:
        if stem not in runs:
            continue
        p.append(f"<h2>{esc(SCENARIO_TITLE.get(stem, stem))}</h2>")
        for tc, c in cases.items():
            if c["file"] != stem:
                continue
            p.append(f"<h3>{esc(tc)} &nbsp; {esc(c['title'])} &nbsp; {pill(c['verdict'])}"
                     f"</h3>")
            shown = 0
            for cap in c["captures"]:
                if cap["status"] != INFO:
                    p.append(capture_block(cap))
                    shown += 1
                elif any(k in cap["sql"].upper() for k in CONTEXT_SQL):
                    p.append(context_row(cap))
            if not shown:
                p.append("<p class='reading'>no graded check in this case — it sets up "
                         "state that a later case verifies.</p>")
    return p


def tab_trace(runs, cases) -> list[str]:
    covered = set()
    for tc in cases:
        for t in TC_TO_T.get(tc, "").replace(" ", "").split(","):
            if t.startswith("T"):
                covered.add(t)
    all_t = {f"T{i}" for i in range(1, 43)}
    missing = sorted(all_t - covered, key=lambda s: int(s[1:]))

    p = ["<h2>What this run covers of the design</h2>",
         "<p>The design document defines 42 tests (<code>T1</code>–<code>T42</code>). "
         "This suite was written independently and uses its own ids, so the map matters: "
         "it is what stops a clean run reading as a proven POC.</p>"]
    p.append("<table class='matrix'><thead><tr><th>Case</th><th>What it proves</th>"
             "<th>Verdict</th><th>Design test</th></tr></thead><tbody>")
    for tc, c in cases.items():
        p.append(f"<tr><td><b>{esc(tc)}</b></td><td>{esc(c['title'])}</td>"
                 f"<td>{pill(c['verdict'])}</td><td>{esc(TC_TO_T.get(tc, '—'))}</td></tr>")
    p.append("</tbody></table>")

    p.append(f"<h2>The {len(missing)} design tests this run does not touch</h2>")
    p.append("<div class='finding'><b>Two of these are the must-pass findings of the "
             "design's own validation.</b> <code>T31</code> (the restart clone guard) "
             "cannot arise here — this suite has no clone at all, which is itself evidence "
             "for dropping it. <code>T32</code> (tags follow the column <i>name</i>, so a "
             "name-preserving data move leaves sensitive values untagged while the "
             "name-based check still passes) has no counterpart: <code>TC-03.3</code> "
             "renames a column, which is a different case. <code>T32</code> describes a way "
             "to publish unmasked data with every check green, and this run does not "
             "address it.</div>")
    p.append("<p><code>" + "</code>, <code>".join(missing) + "</code></p>")
    return p


def tab_scope(runs, cases) -> list[str]:
    p = ["<h2>What this run does not prove</h2>",
         "<table class='matrix'><thead><tr><th>#</th><th>Limitation</th>"
         "<th>Why it matters</th></tr></thead><tbody>",
         "<tr><td>1</td><td><b>No gate is enforced.</b> This suite has no stored "
         "procedure by design — every gate is a <code>SELECT</code> a human reads before "
         "running the next statement by hand.</td><td>Nothing stops an operator reading "
         "\"2 rows returned\" and swapping anyway. The design's owner's-rights questions "
         "(<code>T11</code>, <code>T12</code>) cannot be answered without a procedure, and "
         "<code>T12</code> is graded the most important test in the design.</td></tr>",
         "<tr><td>2</td><td><b>Identity is a role switch, not a service principal.</b> "
         "<code>00_setup.sql</code> creates no users, so every step runs as this operator "
         "switching role.</td><td>Weaker evidence than POC01/POC02, which used a key-pair "
         "per user. A role switch by someone who could reach the privilege another way "
         "proves less than a login that holds only that role — mitigated, not removed, by "
         "<code>USE SECONDARY ROLES NONE</code> after every switch.</td></tr>",
         "<tr><td>3</td><td><b>Masking is one <code>STRING</code> policy keyed on "
         "<code>CURRENT_ROLE()</code>.</b></td><td>POC01's proven model is three typed "
         "policies keyed on <code>CURRENT_USER()</code>, attribute and scope. The masking "
         "here exercises the mechanism, not the model that is actually in production.</td>"
         "</tr>",
         "<tr><td>4</td><td><b>No tag configuration table, so no mapping check.</b></td>"
         "<td>The design's config-against-base and source-mapping checks "
         "(section 3 row 2) have no counterpart. Those are what would catch "
         "<code>T32</code>.</td></tr>",
         "<tr><td>5</td><td><b>Seven setup grants run as <code>ACCOUNTADMIN</code>.</b></td>"
         "<td>The suite's header claims no <code>ACCOUNTADMIN</code> anywhere, and that "
         "holds for every test statement. It does not hold for the seven "
         "<code>GRANT USAGE ON WAREHOUSE</code> statements: the warehouse is owned by "
         "<code>ACCOUNTADMIN</code> and <code>SYSADMIN</code> holds no grant on it. Stated "
         "rather than quietly done.</td></tr>",
         "<tr><td>6</td><td><b>Volume is trivial.</b> 20 customers, 50 policies.</td>"
         "<td>Nothing here says anything about the batch window at real volume — the "
         "design's <code>Q5</code> timing question is untouched.</td></tr>",
         "<tr><td>7</td><td><b>The suite publishes unprotected PII on purpose.</b> "
         "<code>s03 TC-03.1</code> publishes four times with no security check at all.</td>"
         "<td>Intentional, on synthetic generated data in an isolated database. Worth "
         "knowing before anyone reads the publish log as a real exposure.</td></tr>",
         "</tbody></table>"]

    p.append("<h2>Where the SQL had to be corrected before it would run</h2>")
    p.append("<p>The suite had not been run before. Seven defects prevented it; each is "
             "recorded with its evidence in <code>Nikhil - 2/CHANGES.md</code>. The "
             "substantive ones: a warehouse that does not exist on this account; seven "
             "warehouse grants run as a role that cannot make them; two future grants run "
             "as a schema owner, which Snowflake requires <code>MANAGE GRANTS</code> for; "
             "58 unqualified grants that fail because <code>USE ROLE SECURITYADMIN</code> "
             "drops the database context; and 44 tag checks that never filtered to the "
             "<code>PII</code> attribute tag, so an inherited schema-level "
             "<code>PII_SCOPE</code> made every one of them return the wrong row count. "
             "None of these changed what is being tested.</p>")
    return p


# =================================================================================
# page
# =================================================================================
CSS = """
    :root{--navy:#16213e;--blue:#0f3460;--teal:#0097a9;--ink:#1a1a2e;}
    *{box-sizing:border-box;}
    body{font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;margin:0;color:var(--ink);background:#fff}
    .wrap{max-width:1040px;margin:0 auto;padding:1.5rem}
    h1{border-bottom:3px solid var(--navy);margin:0 0 .4rem}
    h2{margin-top:1.4rem;color:var(--navy);border-bottom:1px solid #ccc}
    h3{margin:1.2rem 0 .3rem;color:var(--blue);font-size:15px}
    .panel > h2:first-child{margin-top:.4rem}
    .cap{border:1px solid #ddd;border-radius:8px;margin:1rem 0;padding:1rem;background:#fafafa}
    .lbl{font-weight:600;color:var(--blue)}.who{font-size:12px;color:#666;margin:.2rem 0}
    pre{background:var(--navy);color:#e8e8e8;padding:.7rem;border-radius:6px;overflow-x:auto;font-size:12px;
      white-space:pre-wrap}
    table.grid{border-collapse:collapse;margin:.6rem 0;font-size:12px}
    table.grid th,table.grid td{border:1px solid #ccc;padding:3px 8px;text-align:left;vertical-align:top}
    table.grid th{background:var(--blue);color:#fff}
    table.matrix,table.score{border-collapse:collapse;margin:1rem 0;font-size:13px;width:100%}
    table.matrix th,table.matrix td,table.score th,table.score td{border:1px solid #bbb;padding:5px 9px;
      text-align:left;vertical-align:top}
    table.matrix th,table.score th{background:var(--navy);color:#fff}
    table.matrix tr:nth-child(even),table.score tr:nth-child(even){background:#f4f6fa}
    table.score td:first-child{text-align:center;color:#666;font-weight:700}
    .opt{margin:.1rem 0;padding-left:1.05rem}
    .opt li{margin:.15rem 0}
    .opt b{color:var(--blue)}
    .st{display:inline-block;padding:2px 9px;border-radius:10px;font-size:11px;font-weight:700;
      letter-spacing:.3px}
    .ok{background:#d7f5dd;color:#0d5c25}
    .bad{background:#fdecea;color:#8a1710}
    .warn{background:#ffe6cc;color:#8a4b00}
    .blocked{background:#dfe7ee;color:#2b3a42}
    .reading{font-style:italic;color:#333;margin-top:.5rem}
    .finding{background:#fff3f0;border-left:4px solid #c0392b;padding:.6rem 1rem;margin:.6rem 0}
    .intro{color:#444}.stamp{color:#888;font-size:12px;margin:.2rem 0 0}
    .rec{background:#eaf5ea;border-left:5px solid #2e7d32;padding:.8rem 1rem;margin:1rem 0;font-size:15px}
    .rec b{color:#1b5e20}
    .tabbar{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:2px;background:#fff;
      border-bottom:3px solid var(--teal);margin:1rem 0 .4rem;padding-top:.3rem}
    .tabbar button{appearance:none;border:0;background:transparent;cursor:pointer;font:inherit;
      font-weight:600;color:#555;padding:.55rem .9rem;border-bottom:3px solid transparent;margin-bottom:-3px}
    .tabbar button:hover{color:var(--navy);background:#f4f6fa}
    .tabbar button[aria-selected=true]{color:var(--navy);border-bottom-color:var(--teal)}
    .tabbar .tnum{color:var(--teal);font-weight:700;margin-right:.35rem}
    .panel{display:none;animation:fade .15s ease-in}
    .panel.active{display:block}
    @keyframes fade{from{opacity:.35}to{opacity:1}}
    @media print{
      .tabbar{display:none}
      .panel{display:block !important}
      .panel::before{content:attr(data-title);display:block;font-size:19px;font-weight:700;
        color:var(--navy);border-bottom:2px solid var(--navy);margin:1.2rem 0 .5rem;page-break-before:always}
      .panel:first-of-type::before{page-break-before:avoid}
    }
"""

NAV_JS = (
    "(function(){var tabs=[].slice.call(document.querySelectorAll('.tabbar button'));"
    "var panels=[].slice.call(document.querySelectorAll('.panel'));"
    "function show(id){tabs.forEach(function(t){"
    "t.setAttribute('aria-selected',t.dataset.target===id);});"
    "panels.forEach(function(pn){pn.classList.toggle('active',pn.id===id);});"
    "if(history.replaceState)history.replaceState(null,'','#'+id);}"
    "tabs.forEach(function(t){t.addEventListener('click',function(){show(t.dataset.target);});});"
    "var h=(location.hash||'').replace('#','');"
    "if(h&&document.getElementById(h)&&document.getElementById(h).classList.contains('panel'))"
    "show(h);})();")


def render_html(runs, cases) -> str:
    counts = Counter(c["verdict"] for c in cases.values())
    ran = [s for s in N.SCENARIOS if s in runs]
    tabs = [("brief", "In brief", tab_brief(runs, cases)),
            ("findings", "Findings", tab_findings(runs, cases)),
            ("evidence", "Evidence", tab_evidence(runs, cases)),
            ("trace", "Traceability", tab_trace(runs, cases)),
            ("scope", "Scope &amp; limits", tab_scope(runs, cases))]

    p = ["<!doctype html><html><head><meta charset='utf-8'>",
         f"<title>{N.PACK_STEM}</title><style>{CSS}</style></head><body>",
         "<div class='wrap'>",
         "<h1>Liberty Mutual — POC07 evidence</h1>",
         "<p class='intro'>Publishing a whole domain only when its batch is complete, by "
         "rebuilding into a staging schema and swapping it with live. Ten scenarios, "
         f"{len(cases)} test cases, run end to end against the account. Every session runs "
         "with a single primary role and secondary roles disabled, so privilege claims are "
         "genuine. The SQL is shown verbatim and the results are exactly what came back.</p>",
         f"<p class='stamp'>Generated {datetime.now(timezone.utc):%Y-%m-%d %H:%M UTC} · "
         f"account {esc(N.ACCOUNT)} · warehouse {esc(N.WAREHOUSE)} · "
         f"{len(ran)} of {len(N.SCENARIOS)} scenarios · "
         f"{counts.get(PASS, 0)} pass / {counts.get(FAIL, 0)} fail / "
         f"{counts.get(ERROR, 0)} error / {counts.get(REVIEW, 0)} review</p>",
         "<div class='tabbar' role='tablist'>"]
    for i, (tid, label, _) in enumerate(tabs):
        sel = "true" if i == 0 else "false"
        p.append(f"<button role='tab' aria-selected='{sel}' aria-controls='p_{tid}' "
                 f"data-target='p_{tid}'><span class='tnum'>{i + 1}</span>{label}</button>")
    p.append("</div>")
    for i, (tid, label, body) in enumerate(tabs):
        cls = "panel active" if i == 0 else "panel"
        p.append(f"<section class='{cls}' id='p_{tid}' role='tabpanel' "
                 f"data-title='{label.replace('&amp;', '&')}'>")
        p.extend(body)
        p.append("</section>")
    p.append(f"<script>{NAV_JS}</script>")
    p.append("</div></body></html>")
    return "\n".join(p)


def render_md(runs, cases) -> str:
    counts = Counter(c["verdict"] for c in cases.values())
    out = [f"# POC07 evidence — batch-consistent publishing via CTAS + Swap", "",
           f"**{counts.get(PASS, 0)} of {len(cases)} test cases passed** · "
           f"{counts.get(FAIL, 0)} failed · {counts.get(ERROR, 0)} errored · "
           f"{counts.get(REVIEW, 0)} need a human reading.", "",
           f"Generated {datetime.now(timezone.utc):%Y-%m-%d %H:%M UTC} · "
           f"account {N.ACCOUNT} · warehouse {N.WAREHOUSE}.", "",
           "| # | Case | What it proves | Verdict | Design test |",
           "|---|------|----------------|---------|-------------|"]
    for i, (tc, c) in enumerate(cases.items(), 1):
        out.append(f"| {i} | `{tc}` | {c['title']} | **{c['verdict']}** | "
                   f"{TC_TO_T.get(tc, '—')} |")
    out += ["", "## Failures and errors", ""]
    bad = [(tc, c) for tc, c in cases.items() if c["verdict"] in (FAIL, ERROR)]
    if not bad:
        out.append("None.")
    for tc, c in bad:
        out.append(f"### {tc} — {c['title']} ({c['verdict']})")
        for cap in c["graded"]:
            if cap["status"] in (FAIL, ERROR):
                out += [f"- **{cap.get('label') or 'line ' + str(cap['line'])}** — "
                        f"{cap['detail']}", "", "```sql", cap["sql"], "```", ""]
    out += ["", "## Cases needing a human reading", ""]
    rev = [(tc, c) for tc, c in cases.items() if c["verdict"] == REVIEW]
    if not rev:
        out.append("None.")
    for tc, c in rev:
        why = "; ".join(sorted({cap["detail"] for cap in c["graded"]
                                if cap["status"] == REVIEW}))
        out.append(f"- `{tc}` {c['title']} — {why}")
    out += ["", "Full SQL and result grids are in the HTML deck.", ""]
    return "\n".join(out)


def main() -> int:
    runs = load_runs()
    if not runs:
        print(f"no runs found in {N.RESULTS_DIR}")
        return 2
    cases = build_cases(runs)
    counts = Counter(c["verdict"] for c in cases.values())

    hpath = N.RESULTS_DIR / f"{N.PACK_STEM}.html"
    mpath = N.RESULTS_DIR / f"{N.PACK_STEM}.md"
    hpath.write_text(render_html(runs, cases), encoding="utf-8")
    mpath.write_text(render_md(runs, cases), encoding="utf-8")

    print(f"runs loaded : {len(runs)}  ({', '.join(runs)})")
    print(f"cases       : {len(cases)}  {dict(counts)}")
    print(f"captures    : {sum(len(r['captures']) for r in runs.values())}")
    print(f"-> {hpath.name}  ({hpath.stat().st_size // 1024} KB)")
    print(f"-> {mpath.name}  ({mpath.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
