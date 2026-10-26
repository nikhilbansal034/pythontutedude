# Requirement — identify new CDC folders without reading the files inside them

**Separate engagement.** Not part of the GRS Zone1→Zone2 (Liberty Mutual) work in `w1`–`w5`.
Advisory ask raised with Nikhil on a call; source transcript and screenshots in `sources/`.

**Status**: requirement captured, four gating questions outstanding. No solution proposed yet.

---

## 1. The requirement in one sentence

> Given a prefix under an external stage, return the distinct **child folder names** — and ideally
> their arrival time — at a cost proportional to the **number of folders**, not to the number of
> files inside them, and not to the bytes inside those files.

Everything below is context for that sentence.

---

## 2. Who raised it

| Person | Role on the call |
|---|---|
| **Soumyajit Saha** | Owns the ask, sets context, drives escalation. Requires the stage change to be emailed to the platform side before anyone touches it |
| **Yaseswi Suda** | Hands-on developer. Demoed the S3 browser and both queries. Owns the current workaround |
| **Ravi Srivastava** | Joined ~9:42. Pushed back that the measured improvement came from a toy sample, not production |
| **Nikhil Bansal** | Advisory only. Committed to come back with options; said he would check with **Amit** |
| **Vijay** (absent) | Platform/stage owner. Any change to the stage definition must be raised with him in writing first |

This is an advisory ask from another account. They have something working; they want to know whether
a fundamentally better mechanism exists before they settle on it.

---

## 3. The pipeline

1. Data migration generates CDC files — snappy parquet. (The transcript's "CDF files" and "Parikh
   files" are transcription artefacts for *CDC* and *parquet*.)
2. Files land in an **S3 bucket**.
3. Snowflake ingests them into a **raw layer** through an external stage.
4. Entities are Guidewire ClaimCenter tables — `cc_activity`, `cc_claim`, `cc_inboundrecord`.
5. **Delta detection**: the job obtains the list of folder names under an entity prefix, compares it
   against a last-loaded watermark held in a Snowflake config table, and loads only the folders newer
   than that watermark.

Files in folders that were already loaded are never needed again. Soumyajit, 4:57 — *"we just have to
read the file content of the latest folder, which was not there previously."*

---

## 4. Key layout

Derived from the `split_part` positions in the two queries, cross-checked against their `FROM`
clauses. **Needs confirming against one real S3 key** — see question 1 in §8.

```
s3://<bucket>/<a>/<b>/<c>/cc_inboundrecord/<fingerprint>/<epoch>/<file>.snappy.parquet
                 1   2   3        4              5          6        7     ← METADATA$FILENAME
```

`METADATA$FILENAME` is bucket-relative and carries the stage URL's own prefix. In query 1 the entity
folder sits directly under the `@GWCC_S3_STG` root (it is appended straight after the stage name in
the `FROM`), yet reads at position 4 — so that stage's URL contributes three leading segments.

`RELATIVE_PATH` is stage-root-relative, and in `@GWCC_S3_STG_DEV2` the entity reads at position 2:

```
<seg1>/cc_activity/<fingerprint>/<epoch>/<file>.snappy.parquet
   1         2           3           4        5                ← RELATIVE_PATH in DEV2
```

**The two stages therefore have roots at different depths**, and the `split_part` indices are not
comparable between the queries.

---

## 5. What they run today

### 5a. Current production approach — `METADATA$FILENAME`

```sql
select  split_part(METADATA$FILENAME,'/',4) as gw_table_name,
        split_part(METADATA$FILENAME,'/',6) as epoch_folder,
        '48c0cf2c75514f6ca8756ae5727cbcc6' as latest_fingerprint_folder
        from
        @GWCC_S3_STG/cc_inboundrecord/48c0cf2c75514f6ca8756ae5727cbcc6/
        (FILE_FORMAT => PARQUET_FILE_FORMAT,PATTERN =>'.*snappy.*[.]parquet');
```

Selecting from a stage with `FILE_FORMAT => PARQUET` yields **one row per data record**, and there is
no `DISTINCT`. This opens every parquet file under the fingerprint folder and emits a row for every
record in them, purely to recover folder names from the path.

### 5b. Workaround — directory table

```sql
SELECT distinct  SPLIT_PART(RELATIVE_PATH, '/', 2) AS gw_table_name,
    SPLIT_PART(RELATIVE_PATH, '/', 4) AS epoch_folder,
        '48b93605f5894d69830b1ee611d60316'  AS latest_fingerprint_folder

FROM DIRECTORY(@GWCC_S3_STG_DEV2)
-- WHERE RELATIVE_PATH ilike '%cc_claim/a759f0b7a93d4b16bc59d8e7b3dce93b%'
WHERE RELATIVE_PATH ILIKE '%activity/48b93605f5894d69830b1ee611d60316%'
AND RELATIVE_PATH LIKE '%.snappy.parquet';
```

Requires `DIRECTORY` enabled on the external stage. Returns one deduplicated row set from stored file
metadata.

---

## 6. Why both fail the requirement

S3 has no folders — only keys. Both queries derive a folder name by projecting a path off a **file**
row, so both pay per file by construction. That is a property of the approach, not a tuning problem,
which is why faster SQL does not resolve it. A folder of 30 files costs 30 units of work to learn one
folder name (Soumyajit, 0:42).

Query 5a pays per *record* on top of that, because it has no `DISTINCT` and actually reads parquet
content.

**The team's diagnosis is half right.** Yaseswi's reason for calling the directory approach
file-level is *"this relative path is nothing but the entire file name"* (7:39) — that is evidence of
row **granularity**, not of content reads. `DIRECTORY()` returns stored metadata (`RELATIVE_PATH`,
`SIZE`, `LAST_MODIFIED`, `MD5`, `ETAG`, `FILE_URL`); reading a staged file's contents is a separate
step requiring `GET_PRESIGNED_URL` or `BUILD_SCOPED_FILE_URL`. So 5b is very likely **not** reading
parquet content, while 5a definitely is. Worth one confirming test on their side — Snowflake's docs
do not state the negative outright, so this is inferred from the column contract.

### Observations that do not change the requirement, but are on record

- **Neither query enumerates folders.** Both are scoped to a single, already-known fingerprint
  supplied as a literal. What they return is the set of **epoch folders inside one fingerprint** —
  not "all the folder list for that particular table entity" as described at 6:14.
- **The 200 s → 10 s measurement is not a controlled comparison.** Different stage, entity,
  fingerprint and data volume, plus `DISTINCT` on one side only. Four variables at once. This backs
  Ravi's pushback at 12:15, for a reason not raised on the call.
- **5b scans the whole stage.** No path scoping on `DIRECTORY()`, and a leading-wildcard `ILIKE`
  rules out prefix pruning. Its cost tracks total object count in the stage, not the folder being
  inspected.
- `'%activity/…%'` matches mid-string and would also match any entity name *ending* in `activity`;
  the commented-out line used the safer `'%cc_claim/…%'`.
- `PATTERN => '.*snappy.*[.]parquet'` (regex, matches anywhere) and `LIKE '%.snappy.parquet'` (must
  end exactly) are not equivalent filters.

---

## 7. Constraints

| # | Constraint | Source |
|---|---|---|
| C1 | Cost must scale with folder count, not file count or bytes | The requirement itself |
| C2 | Must still support delta detection against the stored watermark | Yaseswi, 4:17 |
| C3 | Any change to the stage definition goes to Vijay's team **in email** first — *"they should not come back and say, you guys didn't inform"* | Soumyajit, 10:41 |
| C4 | Cost and maintenance impact of enabling a directory table must be answered explicitly | Yaseswi, 10:03 |
| C5 | Timings must be re-measured at production volume, not on the 1 000-record sample | Ravi, 12:15 |
| C6 | A directory table on an external stage is not self-maintaining — a stale one silently misses new folders, which is a **correctness** risk for delta detection, not only a cost one | Snowflake behaviour |

---

## 8. Open questions — gating

Four. Everything else can wait.

1. **Which level is the CDC folder?** One complete real S3 key, bucket through filename. In that
   path, which segment's *appearance* means "new data to load" — the fingerprint folder, or the epoch
   folder inside it?
2. **Is that level already known before the query runs?** Both queries receive the fingerprint as a
   literal, so something upstream identifies it. If it is already known by other means, is the list
   actually needed only at *epoch* level — and is fingerprint-level listing not required at all?
3. **What is allowed to do the listing?** Must it be a single SQL statement inside the existing
   ingestion job, or may it use a directory table, a stored procedure / task, Snowpark, an external
   function, or S3 event notifications? Separately — **can the producer side be changed at all**, for
   example to write a manifest or marker file when it finishes a folder?
4. **Volume.** Folders per entity, files per folder, total object count under the stage, and job
   frequency.

Question 3 decides whether this is a SQL problem or an architecture problem, and carries the C3
governance step. Question 4 decides whether any candidate mechanism survives production scale.

Deliberately **not** blocking on: watermark datatype, the `COPY INTO` statement, the benchmark
numbers. None affects whether a folder-level listing mechanism exists.

---

## 9. Sources

| File | What it is |
|---|---|
| `sources/requirement.vtt` | Transcript of the requirement call, 594 lines, 4 speakers |
| `sources/query1.png` | Screenshot of the `METADATA$FILENAME` query (mid-edit; §5a is the full version supplied later) |
| `sources/query2.png` | Screenshot of the directory-table query (mid-edit; §5b is the full version supplied later) |

Both screenshots were taken mid-edit and disagree with the supplied text in places — §5a and §5b are
authoritative.
