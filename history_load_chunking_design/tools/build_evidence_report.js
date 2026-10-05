const fs = require('fs');
const path = require('path');
const {
  Document, Packer, Paragraph, TextRun, ImageRun, Table, TableRow, TableCell, WidthType,
  ShadingType, AlignmentType, HeadingLevel, PageOrientation, BorderStyle, LevelFormat,
  PageBreak, Footer, PageNumber,
} = require('docx');

// Screenshots: unzip POC_evidence.docx and point MEDIA at its word/media folder (image1..image8 in document order)
const MEDIA = process.env.MEDIA || path.join(__dirname, 'x/word/media');
const OUT = process.argv[2];

// Landscape US Letter, 0.6" margins → content width 15840 - 2*864 = 14112 DXA (9.8")
const CONTENT = 14112;
const SCALE = 940 / 1762;           // one scale for every screenshot so text size stays equal

const C = { ink: '1F2937', muted: '6B7280', line: 'D1D5DB', label: 'F3F4F6', head: '1E3A5F' };
const VERDICT = {
  PASS:   { fill: 'DCFCE7', ink: '166534' },
  FAIL:   { fill: 'FEE2E2', ink: '991B1B' },
  WARN:   { fill: 'FEF3C7', ink: '92400E' },
  NA:     { fill: 'E5E7EB', ink: '374151' },
};

const border = { style: BorderStyle.SINGLE, size: 4, color: C.line };
const borders = { top: border, bottom: border, left: border, right: border };
const cellMargins = { top: 70, bottom: 70, left: 120, right: 120 };

function runs(text, opts = {}) {
  // **bold** segments inside a string
  return text.split(/(\*\*[^*]+\*\*)/).filter(Boolean).map(seg =>
    seg.startsWith('**') ? new TextRun({ text: seg.slice(2, -2), bold: true, ...opts })
                         : new TextRun({ text: seg, ...opts }));
}
const P = (text, opts = {}) => new Paragraph({ children: runs(text, opts.run), spacing: { after: 100 }, ...opts.para });
const bullet = (text) => new Paragraph({ numbering: { reference: 'bul', level: 0 }, children: runs(text), spacing: { after: 60 } });
const num = (text) => new Paragraph({ numbering: { reference: 'num', level: 0 }, children: runs(text), spacing: { after: 80 } });
const H1 = (text, pageBreak = false) => new Paragraph({ heading: HeadingLevel.HEADING_1, pageBreakBefore: pageBreak, children: [new TextRun(text)] });
const H2 = (text, pageBreak = false) => new Paragraph({ heading: HeadingLevel.HEADING_2, pageBreakBefore: pageBreak, children: [new TextRun(text)] });

function cell(content, width, opts = {}) {
  const paras = (Array.isArray(content) ? content : [content]).map(t =>
    typeof t === 'string' ? new Paragraph({ children: runs(t, opts.run), spacing: { after: 40 } }) : t);
  return new TableCell({
    borders, width: { size: width, type: WidthType.DXA }, margins: cellMargins,
    shading: opts.fill ? { fill: opts.fill, type: ShadingType.CLEAR, color: 'auto' } : undefined,
    children: paras,
  });
}

function table(widths, rows) {
  return new Table({
    width: { size: widths.reduce((a, b) => a + b, 0), type: WidthType.DXA },
    columnWidths: widths,
    rows: rows.map(r => new TableRow({ children: r })),
  });
}

// ---------- the evidence ----------
const LABEL_W = 2300, TEXT_W = CONTENT - LABEL_W;
const ev = [
  {
    id: 'E1', title: 'Test data setup', file: '02_test_setup.sql', img: 'image1.png',
    tried: 'Build the 11 synthetic test objects in LM_POC_DB.POC_SCHEMA: 9 Snowflake-managed Iceberg tables, 1 standard table and 1 view. Then count the rows in each.',
    expected: '11 objects, each with the row count in its NOTE column. For example: T01 9,000 rows; T05 1,750 rows, of which 150 have a NULL partition value; T11 empty.',
    got: 'All 11 objects were created, and every ROW_COUNT matches its expected value.',
    verdict: ['PASS', 'PASS'],
    caption: 'Test data setup: all 11 objects created with the expected row counts.',
  },
  {
    id: 'E2', title: 'Planner: full schema run', file: '04_chunk_planner.sql', img: 'image2.png',
    tried: 'Plan every object in LM_POC_DB.POC_SCHEMA (p_tables = \'\').',
    expected: 'With max_chunk_rows = 1000 (the test setting): T01, T02, T03, T05, T06 and T08 cut into several chunks (DAY_RANGES, DAY_RANGES_WITH_SPLITS, HASH_BUCKETS). T04 and T11 as SINGLE. T07 FAILED. T09 and T10 SKIPPED.',
    got: 'The run completed in 1m 33s: 29 objects in scope, 9 planned, 0 failed, 20 skipped. **Every Iceberg table was planned as SINGLE with 1 chunk**, and T07 was PLANNED instead of FAILED. The 18 extra objects in the schema (V_*, Z1_* and Z2_* from other work) were correctly skipped as non-Iceberg.',
    why: 'A 9,000-row table gets one chunk only if the row cap is at least 9,000. So max_chunk_rows was left at its production default of 250 million, not 1000. At that cap every test table fits in one chunk, so SINGLE is the correct answer.',
    verdict: ['WARN', 'Ran correctly, but not with the test setting'],
    caption: 'Full-schema planner run: completed, but at the production row cap, so every table fits in one chunk.',
  },
  {
    id: 'E3', title: 'A1: table outcome vs expected', file: '05_validate.sql, A1', img: 'image3.png',
    tried: 'Compare each test table\'s active plan with its expected status, chunk axis, method, chunk count and row count.',
    expected: '11 of 11 PASS (expected values assume max_chunk_rows = 1000).',
    got: '**Chunk axis correct for all 11 tables; status correct for 10 of 11.** The planner found the right layer (CURRENT/HISTORY) and chunk column every time. It also read the partition spec from Iceberg metadata: PARTITION_VERIFIED = TRUE for all 6 partitioned tables. Method and chunk count differ for 7 tables (T01, T02, T03, T05, T06, T07, T08), because every table came out SINGLE. T04, T09, T10 and T11 match fully. The RESULT column is off-screen to the right; by these values it shows FAIL for those 7 rows.',
    verdict: ['FAIL', 'FAIL vs expected (7 of 11), caused by the run setting'],
    caption: 'A1: every table got the right chunk column; chunk counts differ because the test row cap was not applied.',
  },
  {
    id: 'E4', title: 'A2: every chunk boundary vs expected', file: '05_validate.sql, A2', img: 'image4.png',
    tried: 'Compare every planned chunk (type, day range, sub-range, hash bucket, rows) with the 32 expected chunk rows.',
    expected: '32 expected chunks, each matched by an actual chunk with the same boundaries.',
    got: 'The actual columns (CHUNK_TYPE, DAY_START, DAY_END, SUB_START_TS, SUB_END_TS) are empty for the expected range chunks, because each plan holds a single ALL chunk. For example, T02 chunk 1 should be a day range up to 2026-03-10, but the plan has one ALL chunk.',
    verdict: ['FAIL', 'FAIL vs expected, caused by the run setting'],
    caption: 'A2: the expected day ranges and split pieces are absent; each plan holds one whole-table chunk.',
  },
  {
    id: 'E5', title: 'A3: chunk rows add up to the table', file: '05_validate.sql, A3', img: 'image5.png',
    tried: 'For every active plan, check that the chunks\' estimated rows add up to the table\'s total rows.',
    expected: 'PASS for every planned table.',
    got: '9 of 9 PASS, including T11_EMPTY (0 = 0). With one chunk per table this check is trivially true, so it says little about chunk cutting yet.',
    verdict: ['PASS', 'PASS (trivial with one chunk per table)'],
    caption: 'A3: chunk row estimates add up to the table row count for all 9 planned tables.',
  },
  {
    id: 'E6', title: 'A4: day chunks tile without gaps or overlaps', file: '05_validate.sql, A4', img: 'image6.png',
    tried: 'Check that consecutive day chunks start where the previous one ended, and that split-day pieces continue end-to-start.',
    expected: 'One PASS row for every DAY_RANGE, DAY_SUBRANGE and DAY_HASH chunk.',
    got: 'No rows. A4 lists only range chunks, and this run produced none (every chunk is ALL). So there was nothing to check: this is not a pass.',
    verdict: ['NA', 'NOT TESTED in this run'],
    caption: 'A4: no range chunks existed, so tiling was not exercised in this run.',
  },
  {
    id: 'E7', title: 'A5: plan history', file: '05_validate.sql, A5', img: 'image7.png',
    tried: 'List the plan history for T01, T07, T09 and T10.',
    expected: 'After a first run: one active row per table from the same run; T07 FAILED; T09 and T10 SKIPPED with a reason.',
    got: 'Four active rows from one run (RUN_ID f4602129…). T09 and T10 are SKIPPED with "Not an Iceberg table" reasons. T07 is PLANNED with 1 chunk, for the same reason as E2. There are no SUPERSEDED rows yet, which is expected: the re-run tests (R7, R8) have not been run.',
    verdict: ['WARN', 'As expected for a first run, except T07'],
    caption: 'A5: plan history after the first run; one active row per table, non-Iceberg objects recorded as SKIPPED.',
  },
  {
    id: 'E8', title: 'Part B: exactly-once coverage against the source data', file: '05_validate.sql, Part B', img: 'image8.png',
    tried: 'Against the source rows themselves: count rows that fall in no chunk or in two or more chunks, and compare each chunk\'s actual row count with its estimate.',
    expected: 'PASS for every planned table: 0 rows missed, 0 rows double-counted, every estimate exact.',
    got: '8 tables PASS. **T11_EMPTY FAILS**: ROWS_IN_NO_CHUNK and ROWS_IN_2PLUS_CHUNKS are null, and RANGE_CHUNKS_EXACT is "0 of 1".',
    why: 'This is a defect in the validation script, not in the plan. The script counts with COUNT_IF, which returned NULL instead of 0 on the empty table. A NULL count never equals 0, so the check fails. Fixed in 05_validate.sql with COALESCE(COUNT_IF(…), 0).',
    verdict: ['FAIL', '8 PASS, 1 FAIL: validator defect, now fixed'],
    caption: 'Part B coverage proof: 8 tables pass; the empty table fails because of a defect in the validation script.',
  },
];

function evidenceBlock(e) {
  const v = VERDICT[e.verdict[0]];
  const rows = [
    [cell('What we tried', LABEL_W, { fill: C.label, run: { bold: true } }), cell(e.tried, TEXT_W)],
    [cell('What we expected', LABEL_W, { fill: C.label, run: { bold: true } }), cell(e.expected, TEXT_W)],
    [cell('What we got', LABEL_W, { fill: C.label, run: { bold: true } }), cell(e.got, TEXT_W)],
  ];
  if (e.why) rows.push([cell('Why', LABEL_W, { fill: C.label, run: { bold: true } }), cell(e.why, TEXT_W)]);
  rows.push([cell('Verdict', LABEL_W, { fill: C.label, run: { bold: true } }),
             cell(e.verdict[1], TEXT_W, { fill: v.fill, run: { bold: true, color: v.ink } })]);

  const buf = fs.readFileSync(path.join(MEDIA, e.img));
  const w = buf.readUInt32BE(16), h = buf.readUInt32BE(20);
  return [
    H2(`${e.id}  ${e.title}`, true),
    P(`Script: ${e.file}`, { run: { color: C.muted, size: 18 } }),
    table([LABEL_W, TEXT_W], rows),
    new Paragraph({ spacing: { before: 160, after: 60 }, alignment: AlignmentType.CENTER,
      children: [new ImageRun({ type: 'png', data: buf,
        transformation: { width: Math.round(w * SCALE), height: Math.round(h * SCALE) } })] }),
    new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 120 },
      children: [new TextRun({ text: `${e.id}. ${e.caption}`, italics: true, color: C.muted, size: 19 })] }),
  ];
}

// ---------- summary table ----------
const SW = [900, 4200, 3300, CONTENT - 900 - 4200 - 3300];
const summaryRows = [
  [cell('#', SW[0], { fill: C.head, run: { bold: true, color: 'FFFFFF' } }),
   cell('Check', SW[1], { fill: C.head, run: { bold: true, color: 'FFFFFF' } }),
   cell('Verdict', SW[2], { fill: C.head, run: { bold: true, color: 'FFFFFF' } }),
   cell('In one line', SW[3], { fill: C.head, run: { bold: true, color: 'FFFFFF' } })],
  ...ev.map(e => {
    const v = VERDICT[e.verdict[0]];
    return [cell(e.id, SW[0]), cell(`${e.title} (${e.file})`, SW[1]),
            cell(e.verdict[1], SW[2], { fill: v.fill, run: { bold: true, color: v.ink } }), cell(e.caption, SW[3])];
  }),
];

// what this run proves / does not prove
const PW = [CONTENT / 2, CONTENT / 2];
const proves = [
  'Snowflake-managed Iceberg test data builds and loads correctly (E1)',
  'Every object in the schema is discovered; all 20 non-Iceberg objects are SKIPPED with a reason and recorded (E2, E7)',
  'Layer (CURRENT / HISTORY) and chunk axis are identified correctly for all 9 Iceberg tables, including the fallbacks REFINED_TS_DAY, UNIQUE_ID_HASH and NONE (E3)',
  'The Iceberg partition spec is read from metadata: PARTITION_VERIFIED = TRUE on all 6 partitioned tables (E3)',
  'Row and byte profiling, the SINGLE path, and plan rows written to both metadata tables (E3, E5, E8)',
  'The metadata-location settings work with plan tables and test data in the same schema',
];
const notProved = [
  'Cutting into day ranges, and splitting a heavy day by minute or by hash buckets (T01, T02, T03)',
  'The NULL_VALUES chunk for NULL partition values (T05)',
  'Hash buckets over a table with no date column (T08)',
  'The FAILED path for a table that has no usable column and needs more than one chunk (T07)',
  'Input validation exits for a bad table name and a bad schema (R3, R4)',
  'Safe re-runs and forced re-plans with SUPERSEDED history (R7, R8, R9)',
];
const provesTable = table(PW, [
  [cell('Proven by this run', PW[0], { fill: VERDICT.PASS.fill, run: { bold: true, color: VERDICT.PASS.ink } }),
   cell('Not yet exercised: needs the re-run at max_chunk_rows = 1000', PW[1], { fill: VERDICT.WARN.fill, run: { bold: true, color: VERDICT.WARN.ink } })],
  [cell(proves.map(t => new Paragraph({ numbering: { reference: 'bul', level: 0 }, children: runs(t), spacing: { after: 40 } })), PW[0]),
   cell(notProved.map(t => new Paragraph({ numbering: { reference: 'bul', level: 0 }, children: runs(t), spacing: { after: 40 } })), PW[1])],
]);

const children = [
  new Paragraph({ children: [new TextRun({ text: 'Iceberg Historical Load Chunk Planner', bold: true, size: 40, color: C.head })], spacing: { after: 60 } }),
  new Paragraph({ children: [new TextRun({ text: 'POC test evidence: run 1, annotated', size: 28, color: C.muted })], spacing: { after: 200 } }),
  table([3000, CONTENT - 3000], [
    [cell('Run date', 3000, { fill: C.label, run: { bold: true } }), cell('2026-10-05 (planner RUN_ID f4602129-eafa-47bb-84ba-40f0d5dcc476)', CONTENT - 3000)],
    [cell('Source and metadata location', 3000, { fill: C.label, run: { bold: true } }), cell('LM_POC_DB.POC_SCHEMA (plan tables in the same schema)', CONTENT - 3000)],
    [cell('Scripts run', 3000, { fill: C.label, run: { bold: true } }), cell('02_test_setup.sql → 04_chunk_planner.sql (full schema) → 05_validate.sql A1–A5 and Part B', CONTENT - 3000)],
    [cell('Overall', 3000, { fill: C.label, run: { bold: true } }),
     cell('**The planner ran without errors, but at the production row cap (250 million), not the test cap (1000).** Every test table therefore fit in one chunk, so the chunk-cutting logic was not exercised. The one hard failure (T11_EMPTY in Part B) is a defect in the validation script, now fixed. Next: reset and re-run with max_chunk_rows = 1000.', CONTENT - 3000, { fill: VERDICT.WARN.fill })],
  ]),
  H1('Results at a glance'),
  table(SW, summaryRows),

  ...ev.flatMap(evidenceBlock),

  H1('Analysis', true),
  H2('1. The failed test: T11_EMPTY in Part B'),
  P('**It is the validation script that fails, not the plan.** The plan for T11 is correct: one ALL chunk with 0 rows, and T11 passes A1 and A3. Part B counts rows with COUNT_IF. On an empty table Snowflake returned NULL instead of 0, and its documentation says COUNT_IF returns NULL when no record satisfies the condition. A NULL count never equals 0, so the result became FAIL, and the per-chunk comparison read "0 of 1".'),
  P('**Fix:** 05_validate.sql now wraps both counts in COALESCE(…, 0). The planner (04) is unchanged.'),
  H2('2. The bigger finding: the run did not use the test chunk size'),
  P('The expected results in TEST_PLAN.md assume max_chunk_rows = 1000, which forces the small test tables to be cut. This run planned a 9,000-row table as one chunk, which happens only if the cap is at least 9,000. So the default of 250 million was in effect. At that cap the planner was right to plan every test table as SINGLE. But it means:'),
  bullet('A1 shows 7 of 11 mismatches and A2 shows no matching chunk boundaries. Both are expected consequences, not defects.'),
  bullet('A4 returned no rows because there were no range chunks to check. That is "not tested", not "passed".'),
  bullet('Part B passed for 8 tables, but one ALL chunk covers every row by construction, so it proves little yet.'),
  H2('3. T07 PLANNED instead of FAILED is by design'),
  P('The design marks a table with no usable chunk column as FAILED **only when it needs more than one chunk**. A table that fits in one chunk is loaded whole and needs no column. At the 250 million cap, T07 (2,000 rows) fits in one chunk, so PLANNED / SINGLE is correct. At 1000 it needs two chunks and should FAIL, which is what the test expects.'),
  H2('4. Shared schema'),
  P('POC_SCHEMA holds 18 objects from other work besides T01–T11, so 29 objects were in scope instead of 11. All 18 are non-Iceberg and were skipped and recorded with a reason. This is correct behaviour. The validation checks are unaffected: A1, A2 and A5 list only the test tables, and the other objects have no plans.'),

  H2('5. What this run proves, and what it does not', true),
  provesTable,
  H1('Next steps'),
  num('**Get the updated 05_validate.sql** (Part B fix) from the repository.'),
  num('**Clear this run\'s plan rows: run 06_reset_test_metadata.sql** with SET meta_location = \'LM_POC_DB.POC_SCHEMA\', src_database = \'LM_POC_DB\', src_schema = \'POC_SCHEMA\'. Without this, every table is now "already planned" and the next run would skip it. Using p_force_replan = TRUE instead would leave SUPERSEDED rows from this run, which would muddle the R7/R8 evidence.'),
  num('**In 04_chunk_planner.sql, set max_chunk_rows = 1000.** After each run, check that the SUMMARY row says "1000 rows max per chunk".'),
  num('**Run R3, R4 and R5 from TEST_PLAN.md** (bad table name, bad schema, full schema). Expected R5 summary in this schema: **in scope 29, planned 8, failed 1 (T07), skipped 20.**'),
  num('**Run 05 A1–A4 and Part B.** Expected: A1 11 of 11 PASS, A2 32 of 32, A3 all PASS, A4 one PASS row per range chunk, Part B all PASS including T11_EMPTY.'),
  num('**Run R7, R8 and R9** (re-run safety, forced re-plan, coverage after re-plan), then A5.'),
  num('**For the screenshots:** widen the REASON column on the summary row so the whole line shows, and scroll A1 and A2 to include the RESULT column.'),
];

const doc = new Document({
  creator: 'Chunk Planner POC',
  title: 'Chunk Planner POC test evidence: run 1',
  styles: {
    default: { document: { run: { font: 'Arial', size: 20, color: C.ink } } },
    paragraphStyles: [
      { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 30, bold: true, color: C.head }, paragraph: { spacing: { before: 280, after: 140 }, outlineLevel: 0 } },
      { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 25, bold: true, color: C.head }, paragraph: { spacing: { before: 200, after: 80 }, outlineLevel: 1 } },
    ],
  },
  numbering: { config: [
    { reference: 'bul', levels: [{ level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 400, hanging: 260 } } } }] },
    { reference: 'num', levels: [{ level: 0, format: LevelFormat.DECIMAL, text: '%1.', alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 440, hanging: 300 } } } }] },
  ] },
  sections: [{
    properties: { page: { size: { width: 12240, height: 15840, orientation: PageOrientation.LANDSCAPE },
                          margin: { top: 864, bottom: 864, left: 864, right: 864 } } },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.RIGHT,
      children: [new TextRun({ text: 'Chunk Planner POC: test evidence, run 1   |   page ', color: C.muted, size: 16 }),
                 new TextRun({ children: [PageNumber.CURRENT], color: C.muted, size: 16 })] })] }) },
    children,
  }],
});

Packer.toBuffer(doc).then(b => { fs.writeFileSync(OUT, b); console.log('wrote', OUT); });
