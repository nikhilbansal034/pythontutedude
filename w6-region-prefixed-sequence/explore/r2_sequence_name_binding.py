#!/usr/bin/env python3
"""
W6 / R2 - can a sequence be chosen by a NAME supplied at run time?

Tests Nikhil's proposal: hold the full sequence name in a second mapping table,
read it, and pass it to the function. If that worked, onboarding a new table
would be a row insert rather than a code change.

SCOPE WARNING - READ THIS BEFORE TRUSTING ANY OUTPUT BELOW.
DuckDB is NOT Snowflake, and on this particular question the two engines differ
in a way that makes a naive DuckDB test actively misleading:

  * DuckDB's nextval() takes a STRING argument      -> looks dynamic
  * Snowflake's syntax is seq_name.NEXTVAL          -> an identifier, not a string

So "a function wrapping nextval with a name parameter" SUCCEEDS in DuckDB and
proves nothing about Snowflake. What IS transferable is the deeper rule both
engines turn out to enforce, which section 2 isolates.

Run:  python3 r2_sequence_name_binding.py
"""
import duckdb

con = duckdb.connect()
con.execute("CREATE SEQUENCE employee_seq START 1")
con.execute("CREATE SEQUENCE job_seq START 100")
con.execute("CREATE MACRO regional_key(n) AS nextval(n)")      # stand-in for the UDF
con.execute("""
CREATE TABLE seq_map (LOGICAL_NAME VARCHAR, FULL_SEQUENCE_NAME VARCHAR);
INSERT INTO seq_map VALUES ('EMPLOYEE', 'employee_seq'), ('JOB', 'job_seq');
CREATE TABLE stg (LOGICAL_NAME VARCHAR);
INSERT INTO stg VALUES ('EMPLOYEE'), ('EMPLOYEE'), ('JOB');
""")


def attempt(label, sql):
    try:
        rows = con.execute(sql).fetchall()
        print(f"  WORKED   {label}\n           -> {rows}")
        return True
    except Exception as e:
        print(f"  FAILED   {label}\n           -> {str(e).splitlines()[0][:150]}")
        return False


print("=" * 78)
print("1. THE FALSE POSITIVE - why a naive DuckDB test must not be trusted here")
print("=" * 78)
attempt("function called with a LITERAL name",
        "SELECT regional_key('employee_seq') FROM range(3)")
print("""
  This passes in DuckDB and would pass nothing in Snowflake. DuckDB macros are
  inlined textually, so the literal reaches nextval as a constant. Snowflake has
  no equivalent - it needs the identifier written in the body.""")

print("\n" + "=" * 78)
print("2. THE TRANSFERABLE RESULT - the name must be fixed at COMPILE time")
print("=" * 78)
print("\n  Nikhil's proposal: read the full name from the mapping table, pass it in\n")
proposal = attempt("name taken from a mapping-table COLUMN",
                   """SELECT s.LOGICAL_NAME, regional_key(m.FULL_SEQUENCE_NAME) AS K
                      FROM stg s JOIN seq_map m ON m.LOGICAL_NAME = s.LOGICAL_NAME""")
print("""
  DuckDB's refusal is the whole point: "The sequence_name argument in function
  nextval must be a CONSTANT EXPRESSION." A value read from a table is, by
  definition, not a constant expression.

  Snowflake states the same invariant in different words - "Dynamic SQL is not
  supported when referring to database objects" - and its IDENTIFIER() syntax
  accepts only a string LITERAL, session variable, bind variable or Snowflake
  Scripting variable. A column value is none of those.

  Two unrelated engines enforcing the same rule is strong evidence that the rule
  is intrinsic, not a quirk: a sequence must be identifiable before the query
  runs. Storing the name in a table makes the NAME data, but it does not make
  the name USABLE as an object reference.""")

print("\n" + "=" * 78)
print("3. WHAT DOES WORK - the name as a branch selector, sequences named literally")
print("=" * 78)
# Reset so the counts below are read against a known start, not whatever
# section 1's probe calls happened to leave behind.
con.execute("CREATE OR REPLACE SEQUENCE employee_seq START 1")
con.execute("CREATE OR REPLACE SEQUENCE job_seq START 100")
attempt("CASE over literally-named sequences",
        """SELECT s.LOGICAL_NAME,
                  CASE s.LOGICAL_NAME
                      WHEN 'EMPLOYEE' THEN nextval('employee_seq')
                      WHEN 'JOB'      THEN nextval('job_seq')
                  END AS K
           FROM stg s""")
print("""
  Correct per-table keys: the two EMPLOYEE rows drew from employee_seq (1, 2),
  the JOB row drew from job_seq (100). The run-time value picks a branch; it
  never names an object.""")

print("\n" + "=" * 78)
print("4. DID UNTAKEN BRANCHES CONSUME VALUES? - DuckDB says no, Snowflake may differ")
print("=" * 78)
EMP_ROWS, JOB_ROWS = 2, 1          # what section 3 actually selected
EMP_START, JOB_START = 1, 100
e_next = con.execute("SELECT nextval('employee_seq')").fetchall()[0][0]
j_next = con.execute("SELECT nextval('job_seq')").fetchall()[0][0]
for nm, nxt, start, used in (("employee_seq", e_next, EMP_START, EMP_ROWS),
                             ("job_seq", j_next, JOB_START, JOB_ROWS)):
    want = start + used                 # if ONLY the taken branch consumed
    worst = start + used + JOB_ROWS + EMP_ROWS - used   # if every arm consumed per row
    verdict = "exactly the taken branch" if nxt == want else f"MORE than the taken branch (want {want})"
    print(f"  {nm:<13} next = {nxt:<5} -> {verdict}")
print(f"\n  ({EMP_ROWS} EMPLOYEE rows and {JOB_ROWS} JOB row were selected, from starts "
      f"{EMP_START} and {JOB_START}.)")
print("""
  DuckDB evaluated CASE lazily - untaken branches cost nothing.

  DO NOT CARRY THIS TO SNOWFLAKE. Snowflake's own documentation points the other
  way: "Each occurrence of a sequence generates a set of distinct values. This is
  different from what many other databases provide, where multiple references to
  NEXTVAL of a sequence return the same value for each row." That wording is
  about occurrences in the STATEMENT, not branches taken, so a Snowflake CASE
  may well burn a value from every arm. This is precisely a case where DuckDB
  gives a falsely reassuring answer - it must be measured in Snowflake.
  See poc/02_r2_sequence_name_binding.sql.""")

print("\n" + "=" * 78)
print("CONCLUSION FOR R2")
print("=" * 78)
print(f"""
  Mapping-table indirection inside the function:  {'NOT VIABLE' if not proposal else 'viable'}
  Branch selector with literal sequence names:    VIABLE

  The second mapping table is still worth building - as a REGISTRY, not as an
  indirection. See feasibility.md R2 for the two shapes that do deliver
  "new table = data change": generating the function from the registry, or a
  stored procedure, which can do dynamic SQL where a UDF cannot.
""")
