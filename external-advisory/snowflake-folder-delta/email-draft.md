# Email draft — to Soumyajit / Yaseswi / Ravi

Written to survive a paste into Outlook: headings, bullets and indented code only, **no markdown
tables** (they render as raw pipes). Links are plain URLs so they stay clickable.

Backing detail is in `requirement.md` and `solution.md`. Two editorial calls are flagged at the
bottom — read those before sending.

---

**Subject:** Identifying new CDC folders on the external stage without reading file contents — analysis and options

Hi Soumyajit, Yaseswi, Ravi,

As promised on the call, I have gone through the queries Yaseswi shared along with the sample S3 path. Summarising my understanding, what I believe the actual constraint is, and the options available.

---

**1. My understanding of the requirement and the problem today**

The ingestion job needs to identify which CDC folders are new since the last run, so that only those folders are loaded into the raw layer. To do that it currently needs the list of folder names under an entity prefix, which it then compares against the watermark held in the Snowflake config table.

The sample path confirms the layout:

&nbsp;&nbsp;&nbsp;&nbsp;s3://&lt;bucket&gt;/gwdryrun/cc/1758950910989/cc_activity/48b93605…/1787934690000/part-00008-….snappy.parquet

Both current approaches obtain the folder name by taking a **file** path and splitting it on `/`:

- The `METADATA$FILENAME` query reads from the stage with a parquet file format. This opens the files and returns one row per **record** inside them — there is no `DISTINCT` on that query, so the volume returned is record-level, not file-level.
- The `DIRECTORY()` query reads stored file metadata rather than file contents, which is why it is considerably faster. However it still returns one row per **file**, and the folder name is still derived by splitting a file path.

So the cost of both scales with the number of files, not the number of folders. A folder holding 30 files costs 30 units of work to establish one folder name. This matches exactly what the team is observing.

One point worth noting on the measurement: the 200s → 10s comparison was taken across two different stages, two different entities and two different fingerprints, with `DISTINCT` applied on one query only. The improvement is real, but I would re-run it on like-for-like data before quoting the number to the client, which I believe is also the point Ravi was making.

---

**2. The limitation in Snowflake**

This is the key point, and I would ask that we align on it before discussing solutions.

**S3 does not have folders.** It is a flat key-value store. There is no `cc_activity` folder object and no `48b93605…` folder object anywhere in the bucket. Those names exist only as text inside each file's key. The S3 browser draws the folder tree by taking the keys and splitting them on `/` — the hierarchy is presented by the console, not stored by S3.

AWS states this directly:

- https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-folders.html
- https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-keys.html

The consequence is that there is nothing for Snowflake to "go inside". A folder name can only be recovered by examining a filename that contains it. The behaviour we are seeing is not an inefficiency in how the queries are written — it is the only thing available at the SQL layer.

Snowflake offers three ways to look at a stage, and none of them exposes a folder-level listing:

- `SELECT … FROM @stage` — returns rows from inside the files
&nbsp;&nbsp;&nbsp;&nbsp;https://docs.snowflake.com/en/user-guide/querying-metadata
- `DIRECTORY(@stage)` — returns one row per file (RELATIVE_PATH, SIZE, LAST_MODIFIED, MD5, ETAG, FILE_URL)
&nbsp;&nbsp;&nbsp;&nbsp;https://docs.snowflake.com/en/user-guide/data-load-dirtables-query
- `LIST @stage/path/` — lists files; accepts a path and an optional PATTERN regex, with no delimiter option
&nbsp;&nbsp;&nbsp;&nbsp;https://docs.snowflake.com/en/sql-reference/sql/list

All three are file-oriented. I would encourage the team to review these pages independently — the conclusion rests on no such option being documented, so it is worth confirming rather than taking on my word.

---

**3. What Snowflake can achieve on its own — and how**

Snowflake alone can solve a meaningful part of this, but not all of it.

**What it can fix:** the expensive part, which is opening the parquet files. The `METADATA$FILENAME` approach is reading file contents at record level. Moving fully to the directory table removes that entirely.

**What it cannot fix:** the per-file enumeration. Even on the directory table you will still process one row per file, so cost continues to grow with file count as the migration progresses.

Within Snowflake, I would recommend two changes:

*(a) Anchor the filter to the start of the path.* The current predicate opens with a wildcard:

&nbsp;&nbsp;&nbsp;&nbsp;`WHERE RELATIVE_PATH ILIKE '%activity/48b93605…%'`

A leading `%` prevents Snowflake from narrowing by prefix, so it reads every row of the directory table for the **entire stage** before filtering — all entities, all fingerprints. Anchoring it allows prefix matching:

&nbsp;&nbsp;&nbsp;&nbsp;`WHERE STARTSWITH(RELATIVE_PATH, '1758950910989/cc_activity/48b93605…/')`

This also closes a correctness gap: `'%activity/…'` matches mid-string and would match any entity name ending in `activity`. I would suggest making this change regardless of the wider direction.

*(b) Consider a stream on the directory table.* `CREATE STREAM … ON STAGE` returns only the files added since the stream was last consumed, which removes the need to list everything and compare against a watermark.

&nbsp;&nbsp;&nbsp;&nbsp;https://docs.snowflake.com/en/sql-reference/sql/create-stream
&nbsp;&nbsp;&nbsp;&nbsp;https://docs.snowflake.com/en/user-guide/data-load-dirtables-pipeline

Two caveats before adopting this. First, the stream only sees files once the directory table has been updated, and **how** it is updated decides whether this helps at all. A manual `ALTER STAGE … REFRESH` performs a list operation over the stage — Snowflake's own guidance is that this "can be slow or expensive for large or fast-growing stages. Instead, use event-based automated refreshes." In other words, with manual refresh the full scan simply moves out of the query and into the refresh step. Event-based refresh (S3 event notifications into an SNS topic) avoids that, but it is a change to the bucket as well as to the stage.

&nbsp;&nbsp;&nbsp;&nbsp;https://docs.snowflake.com/en/user-guide/data-load-dirtables-manage
&nbsp;&nbsp;&nbsp;&nbsp;https://docs.snowflake.com/en/user-guide/data-load-dirtables-auto-s3

Second, if the directory table is stale, the query returns no new folders and the load is silently skipped with no error — so this becomes a correctness consideration and not only a cost one.

As Soumyajit noted, enabling `DIRECTORY` changes the stage definition and should go to Vijay's team in writing first, along with the cost impact Yaseswi raised.

---

**4. Alternatives that solve the problem fully**

S3 itself does support exactly what we want. Its listing API accepts a `Delimiter` parameter which, set to `/`, instructs S3 to roll up everything beyond the next slash and return only the distinct prefixes — the folder names — in a field called `CommonPrefixes`. S3 performs that grouping internally against its own index; the nested files are never enumerated or returned.

&nbsp;&nbsp;&nbsp;&nbsp;https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html

Worth noting from that page: all keys rolling up into a single common prefix count as **one** returned item. So the cost becomes proportional to the number of folders, which is precisely the requirement.

For our path, retrieving the fingerprint folders under one entity is a single call:

&nbsp;&nbsp;&nbsp;&nbsp;Prefix = 'gwdryrun/cc/1758950910989/cc_activity/'
&nbsp;&nbsp;&nbsp;&nbsp;Delimiter = '/'

returning only the folder names, with no file enumeration at all. One call covers up to 1,000 folders; beyond that it pages.

There are two places this can run:

**Option A — in the orchestration layer (my recommendation).** If the job is driven by anything that can execute a script, the call goes there. Fetch the folder list, compare against the config table, pass only the new folders into the existing `COPY INTO`. **No change to the Snowflake stage is required**, so this avoids the stage-definition approval and the directory-table cost question entirely.

**Option B — inside Snowflake.** Snowflake can run Python with `boto3` in a stored procedure. Outbound network access is blocked by default, so it requires a network rule naming the S3 endpoint and an external access integration wrapping it. Both are narrow and auditable.

&nbsp;&nbsp;&nbsp;&nbsp;https://docs.snowflake.com/en/developer-guide/external-network-access/external-network-access-examples

Either option needs `s3:ListBucket` permission on the prefix. Please could someone check whether the IAM role behind the existing stage already holds it — given it reads from the same bucket, it very likely does, in which case there is no AWS request to raise.

One further suggestion on the comparison step itself. Rather than a high-water timestamp, a small registry table holding one row per folder already ingested would be more robust: new folders become a set difference rather than a greater-than comparison. It also makes reprocessing a single folder trivial.

---

**5. To finalise the recommendation**

Three things would help me firm this up:

1. Which folder level actually signals "new data to load" — the run id (1758950910989), the fingerprint (48b93605…), or the epoch folder (1787934690000)? Both queries pin the fingerprint as a hardcoded literal, so something upstream already determines it. Could you share that step?
2. Is there any constraint requiring this to remain a single SQL statement, or is a script step acceptable within the job? This determines whether we aim for the full fix or the partial one.
3. Roughly how many folders exist per entity, and how many files per folder?

One observation while reviewing the sample path: the epoch folder decodes to 28-Aug-2026, while the run folder containing it decodes to 27-Sep-2025. If the delta comparison sorts on the epoch folder value, it would be worth confirming what that number represents, as it does not appear to be the time the run executed.

Separately, the `@GWCC_S3_STG` stage appears to be defined one level deeper than `@GWCC_S3_STG_DEV2` — its root includes the run id. If each migration run creates a new run-id folder, that stage definition would need updating each time. Flagging in case it is already known.

Happy to walk through any of this on a call.

Best regards,
Nikhil

---

## Editorial calls before sending

**The measurement paragraph in §1.** Included because Ravi already raised it on the call, and framed
as supporting him rather than correcting Yaseswi. It costs nothing to drop and the email stands
without it.

**Option A recommended over Option B.** That is a judgement on organisational friction, not technical
merit — both use the identical S3 call, but Option A touches nothing Vijay owns. If the job turns out
to be pure Snowflake with no orchestration layer able to run a script, Option B becomes the answer
and the recommendation flips.
