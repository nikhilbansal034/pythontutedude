# Snowflake external-stage folder delta listing

**Separate engagement.** This folder is not part of the GRS Zone1→Zone2 (Liberty Mutual) work that
the `w1`–`w5` folders cover. It is an advisory ask raised directly with Nikhil on a call.

## The problem

Data migration writes parquet files to S3 under an external stage (`@GWCC_S3_STG_DEV2`), one folder
per load fingerprint, e.g. `cc_activity/48b93605f5894d69830b1ee611d60316/…snappy.parquet`. The
ingestion job detects new (delta) folders by listing all folder names and comparing against the
last-loaded timestamp held in a Snowflake config table.

Both known ways of getting that folder list make Snowflake descend to **file** level and read file
content, which is slow and expensive — a folder with 30 files costs 30 reads just to learn the
folder's name.

| Input | Approach |
|-------|----------|
| `sources/query1.png` | `split_part(METADATA$FILENAME, '/', n)` over the stage — the original approach |
| `sources/query2.png` | `DIRECTORY()`-enabled stage, `split_part(RELATIVE_PATH, '/', n)` — the workaround |

The workaround is far faster (≈200 s → ≈10 s on a 1 000-record test) but still file-level, and it
has only been measured on that small sample, not on production volumes.

## What is wanted

A way to enumerate **only the folder prefixes** under a stage path, without reading file content.

## Open questions raised on the call

- Cost and maintenance impact of enabling `DIRECTORY` on the external stage (storage, refresh) —
  to be checked with the platform team before the stage definition is changed.
- Re-run the timing comparison at production volume.

## Sources

| File | What it is |
|------|-----------|
| `sources/requirement.vtt` | Transcript of the requirement call (Soumyajit Saha, Yaseswi Suda, Ravi Srivastava, Nikhil Bansal) |
| `sources/query1.png` | Screenshot of the `METADATA$FILENAME` query |
| `sources/query2.png` | Screenshot of the `DIRECTORY()` / `RELATIVE_PATH` query |
