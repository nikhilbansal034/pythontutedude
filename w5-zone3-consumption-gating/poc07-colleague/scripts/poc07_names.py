"""POC07 — names, paths and connection helpers.

One place for every account-specific name, so the runner and the renderer never
hardcode one. Mirrors POC02's poc02_names.py, which is the proven pattern.

The object model here is the PARALLEL SUITE's (database P7_POC, seven P7_* roles),
not the design document's LM_P7_* model. That is deliberate: this harness runs the
SQL in `Nikhil - 2/tests/` as it stands, and that suite builds its own governance.
See `Nikhil - 2/CHANGES.md` and POC07_TEST_DESIGN.md section 10.

SECONDARY ROLES. Every connection opened here runs `USE SECONDARY ROLES NONE`, and
the runner re-asserts it after every `USE ROLE`. This is not belt-and-braces: the
operator account carries POC01's LM_PII_TAG_ADMIN and LM_PII_POLICY_ADMIN as ACTIVE
secondary roles, so a privilege check could otherwise pass via a role other than the
one under test. That is exactly the flaw that produced POC02's retracted P2-F1
finding, and it is the one mistake this suite cannot afford to repeat.
"""

from __future__ import annotations

from pathlib import Path

# ---------------------------------------------------------------------------------
# Account
# ---------------------------------------------------------------------------------
ACCOUNT = "pn56976-deloittena"
CONNECTION = "pn56976_psingh"          # ~/.snowflake/connections.toml, SNOWFLAKE_JWT

# The SHARED POC warehouse, reused from POC01 and POC02 by decision (27 Oct).
# X-Small, auto-resume, resource monitor RM_LM_PII_POC_WH at 100 credits monthly.
# 00_setup.sql sets $wh to this same value; keep the two in step.
WAREHOUSE = "LM_PII_POC_WH"

# ---------------------------------------------------------------------------------
# Objects the suite builds
# ---------------------------------------------------------------------------------
DB = "P7_POC"

SCHEMA_GOV = "GOV"                     # tags, masking policy, entitlement. Never swapped
SCHEMA_BASE = "BASE"                   # Zone 3 base tables, loaded per scenario
SCHEMA_SRC = "SRC_VIEWS"               # the existing complex views
SCHEMA_LIVE = "D_LIVE"                 # published tables      ) the swap pair:
SCHEMA_STAGE = "D_STAGE"               # next batch built here ) these two trade places
SCHEMA_VIEWS = "D_VIEWS"               # thin reader views. Never swapped
SCHEMA_CTRL = "CTRL"                   # control tables. Never swapped

TAG_PII = f"{DB}.{SCHEMA_GOV}.PII"
TAG_SCOPE = f"{DB}.{SCHEMA_GOV}.PII_SCOPE"
MASK_POLICY = f"{DB}.{SCHEMA_GOV}.MASK_PII"

PUBLISHED_TABLES = ("CUSTOMER_360", "POLICY_SUMMARY")

# ---------------------------------------------------------------------------------
# Roles, and who the masking policy lets through
# ---------------------------------------------------------------------------------
ROLE_BASE_OWNER = "P7_BASE_OWNER"
ROLE_PUBLISH = "P7_PUBLISH_ROLE"
ROLE_VIEW_OWNER = "P7_VIEW_OWNER"
ROLE_READER_OK = "P7_READER_OK"
ROLE_READER_NO = "P7_READER_NO"
ROLE_PROBE = "P7_PROBE_ROLE"
ROLE_BATCH_NOENT = "P7_BATCH_NOENT"

P7_ROLES = (ROLE_BASE_OWNER, ROLE_PUBLISH, ROLE_VIEW_OWNER, ROLE_READER_OK,
            ROLE_READER_NO, ROLE_PROBE, ROLE_BATCH_NOENT)

# From 00_setup.sql's GOV.ENTITLEMENT seed. The masking policy reads this table
# keyed on CURRENT_ROLE(), so these two sets decide who sees real values.
ENTITLED = frozenset({ROLE_READER_OK, ROLE_PUBLISH, ROLE_BASE_OWNER})
NOT_ENTITLED = frozenset({ROLE_READER_NO, ROLE_PROBE, ROLE_VIEW_OWNER, ROLE_BATCH_NOENT})

# Roles the suite uses that are not P7_* — needed so the runner can tell an
# expected administrative step from an accidental privilege escalation.
ADMIN_ROLES = ("SECURITYADMIN", "SYSADMIN", "ACCOUNTADMIN")

# ---------------------------------------------------------------------------------
# Masked vs real
# ---------------------------------------------------------------------------------
# 00_setup.sql's MASK_PII returns this exact literal in its ELSE branch, so the
# check is an equality test, not a guess at shape. POC02 had to use a known-plaintext
# allowlist because its masks were SHA2 hashes; here the mask is unambiguous.
MASK_LITERAL = "***MASKED***"

# The scenarios generate their base data by a fixed rule, so real values are derivable
# rather than typed out:
#     'cust'||(seq4()+1)||'@example.invalid'
#     LPAD(TO_VARCHAR(seq4()+1),3,'0')||'-00-0000'
# ROWCOUNT is 20 for CUSTOMER in every scenario; the margin is deliberate slack.
_MAX_SEEDED_ROWS = 64

REAL_EMAILS = frozenset(f"cust{n}@example.invalid" for n in range(1, _MAX_SEEDED_ROWS + 1))
REAL_SSNS = frozenset(f"{n:03d}-00-0000" for n in range(1, _MAX_SEEDED_ROWS + 1))
REAL_NAMES = frozenset(f"Customer {n}" for n in range(1, _MAX_SEEDED_ROWS + 1))


def is_masked(value) -> bool:
    """True only for the policy's exact mask literal."""
    return isinstance(value, str) and value == MASK_LITERAL


def is_real_email(value) -> bool:
    return isinstance(value, str) and value in REAL_EMAILS


def is_real_ssn(value) -> bool:
    return isinstance(value, str) and value in REAL_SSNS


def classify(value) -> str:
    """'masked' | 'real' | 'other' — so a verdict can never silently treat an
    unexpected third thing as a pass. A NULL, a truncated value or a hash all
    land in 'other' and force a REVIEW rather than a PASS."""
    if value is None:
        return "other"
    if is_masked(value):
        return "masked"
    if is_real_email(value) or is_real_ssn(value) or value in REAL_NAMES:
        return "real"
    return "other"


# ---------------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------------
# Everything for this deliverable lives under `Nikhil - 2/`, beside the SQL it runs:
#
#   Nikhil - 2/
#     tests/      the SQL under test        <- read
#     scripts/    this harness              <- you are here
#     evidence/   results, deck, run JSONs  <- written
#
# Resolved from __file__ rather than the working directory, so the scripts can be
# run from anywhere. parents[1] is `Nikhil - 2`.
_HERE = Path(__file__).resolve()
DELIVERABLE_DIR = _HERE.parents[1]

TESTS_DIR = DELIVERABLE_DIR / "tests"
RESULTS_DIR = DELIVERABLE_DIR / "evidence"
SCRIPTS_DIR = DELIVERABLE_DIR / "scripts"

PACK_STEM = "LM_Batch_Publishing_Evidence_POC07"

# Scenario order matters: each file resets the swap pair and the control tables to
# day 1, so they are independent, but 00_setup must precede them all and the capture
# for one must be written before the next one truncates CTRL.
SETUP_FILE = "00_setup"
TEARDOWN_FILE = "99_teardown"
SCENARIOS = ("s01_day1_first_publish", "s02_steady_state", "s03_tags", "s04_grants",
             "s05_dependency_gating", "s06_exception_approval", "s07_restart",
             "s08_masking", "s09_atomicity", "s10_rollback")

# Settled 27 Oct by counting banner lines followed by the '---' divider. The original
# suite had 48; TC-05.3b and TC-05.3c were added when fixing the unclearable
# missing-row block. Any drift from this means the inventory changed and the deck's
# counts need re-checking.
EXPECTED_CASE_COUNT = 50
EXPECTED_CASES_PER_FILE = {
    "s01_day1_first_publish": 6, "s02_steady_state": 5, "s03_tags": 4,
    "s04_grants": 7, "s05_dependency_gating": 6, "s06_exception_approval": 5,
    "s07_restart": 5, "s08_masking": 5, "s09_atomicity": 3, "s10_rollback": 4,
}


# ---------------------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------------------
def connect(connection_name: str = CONNECTION, role: str | None = None):
    """Open a session on the named connection.

    Secondary roles are DISABLED immediately and must be re-disabled by the caller
    after any USE ROLE — see the module docstring for why that matters here.

    The warehouse is NOT set: 00_setup.sql grants usage to the P7_* roles and the
    SQL files issue their own USE WAREHOUSE where needed. Setting it here would mask
    a missing grant, which is one of the things worth catching.
    """
    import snowflake.connector

    conn = snowflake.connector.connect(connection_name=connection_name)
    with conn.cursor() as cur:
        cur.execute("USE SECONDARY ROLES NONE")
        if role:
            cur.execute(f"USE ROLE {role}")
            cur.execute("USE SECONDARY ROLES NONE")
    return conn


def session_identity(cur) -> dict:
    """What the session actually is, read back rather than asserted.

    POC02's deck printed a hardcoded 'executed as:' label. Reading it back costs one
    round trip and makes the evidence self-proving: if a USE ROLE silently failed, the
    capture says so instead of claiming a role it never held.
    """
    row = cur.execute(
        "SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_SECONDARY_ROLES(), "
        "CURRENT_WAREHOUSE(), CURRENT_DATABASE(), CURRENT_SCHEMA()").fetchone()
    return {"user": row[0], "role": row[1], "secondary_roles": row[2],
            "warehouse": row[3], "database": row[4], "schema": row[5]}
