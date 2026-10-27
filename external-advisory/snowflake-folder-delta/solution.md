# Solution analysis — listing CDC folders without reading the files inside them

Companion to `requirement.md`. Read that first; this assumes its §1 requirement statement and its §4
key layout.

**Bottom line**: the problem is **fully solvable**, but not with a SQL query. Snowflake SQL has no
folder-listing construct. S3's own listing API does, and reaching it costs a few lines of code.

---

## 1. Why no SQL query can do this

### S3 has no folders

S3 is a flat key-value store. The sample path is a single key, one unbroken string:

```
gwdryrun/cc/1758950910989/cc_activity/48b93605…/1787934690000/part-00008-….snappy.parquet
```

There is no `cc_activity` object and no `48b93605…` object in the bucket. Those names exist only as
characters inside each file's key. The S3 browser *draws* the folder tree by fetching keys and
splitting them on `/` — the hierarchy is rendered by the console, not stored by S3.

AWS states this directly:

- [Organizing objects in the S3 console by using folders](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-folders.html)
  — S3 has a flat structure, not a hierarchy; the console groups objects by shared key prefix. Also
  covers the 0-byte trailing-slash object the console writes when you "create a folder", which is
  what to show anyone who objects *"but I can see the folders"*.
- [Naming Amazon S3 objects](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-keys.html)
  — no nested sub-bucket or subfolder structure; hierarchy is inferred from key prefixes and the `/`
  delimiter.

### Therefore the team's complaint is unfixable as phrased

They report that Snowflake *"goes inside the folder and reads each file"*, which sounds like waste a
better query could avoid. **There is nothing to go inside.** A folder name can only be recovered by
examining a filename containing it — exactly what `split_part` does in both their queries. This is
not a SQL defect; it is the shape of the storage.

> **Analogy for the client call.** A library with no shelves — a million books in one pile, each
> labelled *"Fiction / Horror / King / It"*. Asked which genres exist, there is no genre sign to read.
> You must pick up books and read labels. Thirty books per genre means handling thirty books to learn
> one genre name.

This also explains why the workaround only went partway: it stopped *opening* the books, but still
had to pick up every one.

### Snowflake exposes three stage interfaces; none is folder-aware

| Interface | Returns | Reference |
|---|---|---|
| `SELECT … FROM @stage` | One row per **record inside the files** — opens them | [Querying metadata for staged files](https://docs.snowflake.com/en/user-guide/querying-metadata) |
| `DIRECTORY(@stage)` | One row per **file**, stored metadata only | [Query directory tables](https://docs.snowflake.com/en/user-guide/data-load-dirtables-query) |
| `LIST @stage/path/` | One row per **file**; takes a path and optional `PATTERN` regex, **no delimiter option** | [LIST](https://docs.snowflake.com/en/sql-reference/sql/list) |

The argument here is **negative** — no page documents a folder-listing option. It rests on none of
the three offering one, not on a quotable line. When presenting, invite the team to check those pages
themselves rather than asserting it flatly; it is easier to defend and lands better.

---

## 2. The mechanism that does solve it

S3's listing API accepts a **`Delimiter`** parameter. Set to `/`, it instructs S3 to roll up
everything past the next slash and return only the distinct prefixes — the folder names — in a field
called **`CommonPrefixes`**. S3 performs that grouping internally against its own index; the nested
files are never enumerated or returned.

[ListObjectsV2 — S3 API reference](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html)
· [boto3/botocore paginator](https://docs.aws.amazon.com/botocore/latest/reference/services/s3/paginator/ListObjectsV2.html)

The line worth quoting to the client: all keys rolling up into a single common prefix count as **one**
returned item. That is the cost argument in their own vendor's words.

```python
response = s3.list_objects_v2(
    Bucket = 'epsilon-3-us-east-1-arch-archpre-cda-0aece',
    Prefix = 'gwdryrun/cc/1758950910989/cc_activity/',
    Delimiter = '/')

for p in response['CommonPrefixes']:
    print(p['Prefix'])
# gwdryrun/cc/1758950910989/cc_activity/48b93605f5894d69830b1ee611d60316/
# gwdryrun/cc/1758950910989/cc_activity/a759f0b7a93d4b16bc59d8e7b3dce93b/
# … one line per fingerprint folder, nothing else
```

### What it does to the numbers

Illustrative: one entity, 500 fingerprint folders, 30 files each — 15 000 files.

| Approach | Work done |
|---|---|
| Query 5a (`METADATA$FILENAME`) | Opens all 15 000 parquet files, emits a row **per record** inside them |
| Query 5b (`DIRECTORY()`) | Reads metadata for all 15 000 files, then dedupes |
| `Delimiter='/'` | **One API call, 500 folder names returned** |

One call, since a listing returns up to 1 000 items; 5 000 folders would be 5 calls, following
`NextContinuationToken` while `IsTruncated` is true. Cost tracks **folder count** — the requirement,
word for word.

---

## 3. The two viable designs

These are **alternatives**, not two halves of one design. Each solves the delta problem on its own.

### Design 1 — S3 listing API + a registry table

No directory table, no stream.

1. Call `ListObjectsV2` with `Delimiter='/'` → distinct folder names
2. Load that list into a transient table in Snowflake
3. Anti-join against a registry table of already-loaded folders
4. Non-matching folders are the delta → `COPY INTO`
5. Insert those folder names into the registry

Two placements for step 1:

- **1A — orchestration layer.** Anywhere the job can run a script. **No Snowflake change at all**, so
  the stage-definition sign-off (C3) and the directory-table cost question (C4) do not arise.
- **1B — inside Snowflake.** A Python stored procedure with `boto3`. Outbound network is blocked by
  default, so it needs a network rule naming the S3 endpoint on port 443 plus an external access
  integration wrapping it. Both are narrow and auditable.
  [External network access examples](https://docs.snowflake.com/en/developer-guide/external-network-access/external-network-access-examples)
  · [Snowflake-authored boto3/S3 gist](https://gist.github.com/sfc-gh-mharris/945f7d5067e88cfcfb9b0f9eaa655046)
  (a gist, not supported documentation — treat as a code sample)

Either placement needs `s3:ListBucket` on the prefix. **Check first whether the IAM role behind the
existing stage already holds it** — it reads the same bucket, so it very likely does, in which case
no AWS request is needed.

### Design 2 — stream on the directory table

No S3 API, no watermark.

1. `DIRECTORY = (ENABLE = TRUE)` on the stage, kept refreshed
2. `CREATE STREAM … ON STAGE`
   ([CREATE STREAM](https://docs.snowflake.com/en/sql-reference/sql/create-stream) ·
   [directory table pipeline](https://docs.snowflake.com/en/user-guide/data-load-dirtables-pipeline))
3. Read the stream — it already holds only new files
4. `SELECT DISTINCT SPLIT_PART(…)` over those rows for folder names
5. Consume the stream inside a DML statement, which advances the offset automatically

A stream holds an internal offset and **replaces** the watermark table; it is not a process that
writes to one. It tracks changes to the stage's **directory table**, not "DML on a folder" — there is
no DML on S3 — and for directory tables it is insert-only, so an overwritten file reappears as an
insert with no diff.

Step 3–4 still yields one row per file, but only for *new* files, so volume is small. That is
acceptable in practice, but it is not the "proportional to folders" property; only Design 1 has that.

---

## 4. Design 2 only works with event-based refresh

**This is the decisive detail.** The stream sees nothing until the directory table is updated, and
there are two ways to update it.

**Manual `ALTER STAGE … REFRESH` — does not solve the problem.** Snowflake's own documentation:
manual refreshes *"perform a list operation on a stage, and can be slow or expensive for large or
fast-growing stages. Instead, use event-based automated refreshes."*
[Manage directory tables](https://docs.snowflake.com/en/user-guide/data-load-dirtables-manage)

The full scan has simply moved out of the query and into the refresh. **This is the trap**: the team
runs the fast new stream query, measures 2 seconds, and concludes it is fixed — while the cost sits
in the refresh step that must run first. The symptom disappears from the place they are measuring.
`REFRESH` accepts a `SUBPATH` to narrow the listing, which helps but does not change the shape.

**Event-based auto-refresh — does solve it.** S3 event notifications → SNS → Snowflake. New objects
push themselves into the directory table; nothing re-lists anything.
[Refresh directory tables automatically for Amazon S3](https://docs.snowflake.com/en/user-guide/data-load-dirtables-auto-s3)

### The irony to flag

Design 2's appeal was "stay inside Snowflake, no AWS involvement". To actually work it needs **S3
bucket event notifications and an SNS topic** — a change to the bucket, owned by whoever administers
that AWS account, *on top of* the stage change needing Vijay. Design 1 needs one IAM read permission
that probably already exists. **The option that looked like less organisational change needs more.**

---

## 5. Verdict

| | Fully solves? | Requires |
|---|---|---|
| **Design 1** | Yes | `s3:ListBucket` (likely already granted) |
| **Design 2 + event auto-refresh** | Yes | Stage change (C3, Vijay) + S3 event notifications + SNS |
| **Design 2 + manual refresh** | **No** — relocates the scan | Stage change (C3, Vijay) |

Two further points keep Design 2 behind even in its working form:

- A stale directory table returns no new folders **with no error** — a missed load is silent (C6).
- Its cost tracks new *files*, not folders.

**Recommendation: Design 1, placement 1A.** Present Design 2 as the pure-Snowflake alternative with
the event-notification requirement stated **up front** — otherwise the team will adopt it with manual
refresh, measure the query, and believe it is solved.

Operational note if Design 2 is pursued: for stages approaching a million files Snowflake recommends
`REFRESH_ON_CREATE = FALSE`, then populating incrementally by subpath. Enabling a directory table
naively on a large stage is itself an expensive one-off.

---

## 6. Worth doing regardless — two SQL fixes

Independent of which design wins.

**Anchor the directory-table filter.** The current predicate opens with a wildcard, which prevents
prefix narrowing, so it reads every row for the **entire stage** — all entities, all fingerprints —
before filtering:

```sql
-- current
WHERE RELATIVE_PATH ILIKE '%activity/48b93605…%'

-- anchored
WHERE STARTSWITH(RELATIVE_PATH, '1758950910989/cc_activity/48b93605…/')
```

This also closes a correctness gap: `'%activity/…'` matches mid-string and would match any entity
name merely *ending* in `activity`.

**Prefer a registry over a timestamp watermark.** One row per folder already ingested, with new
folders found by set difference rather than a `>` comparison. This matters here specifically: the
sample path has an epoch folder dating to **2026-08-28** sitting inside a run folder dating to
**2025-09-27** (`requirement.md` §4). If that ordering is unreliable anywhere in the tree, a
timestamp watermark silently skips folders; a set difference cannot. It also makes reprocessing one
folder trivial — delete one row.

---

## 7. Still open

The recommendation holds whichever way `requirement.md` §8 question 1 resolves — if the delta unit is
the epoch folder or the run id rather than the fingerprint, the same call applies with `Prefix` one
level deeper or shallower. Only the prefix string changes.

Question 3 (what the job is permitted to run) decides **1A vs 1B**, and question 4 (volume) decides
how many pages a listing takes. Neither changes the mechanism.

---

## 8. Verification note

Both documentation hosts are blocked by the network policy of the session this was written in, so
every page above was confirmed through search results quoting its content rather than by direct
fetch. Open each link once before presenting externally.
