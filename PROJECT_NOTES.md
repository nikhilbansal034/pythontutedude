# DataCamp DS Professional Practical Exam — Project Notes

## Project understanding

**Scenario:** QuorWatt Urban Mobility (shared e-scooter operator). Fleet Reliability
Team wants to reduce scooter downtime while controlling maintenance/parts cost.

**Stakeholder asks (from Head of Strategy email):**
1. Identify most influential predictors of a scooter going out of service in the
   24h period after a snapshot.
2. Predict whether a scooter will go out of service in the next 24h, target ≥90%
   accuracy.
3. Recommend next steps regardless of results.

**Deliverables required:**
1. Written report in a DataLab workbook (code + output + text), covering:
   - Data validation/cleaning for every column
   - EDA: 2 single-variable graphics (different types) + 1+ multi-variable graphic
     + written findings
   - Model development: state problem type, fit a baseline model, fit a
     comparison model, justify model choices
   - Model evaluation: compare the two models on an appropriate metric
   - Business metric: define one the business can monitor + estimate its
     current value from the data
   - Final summary with recommendations
2. Presentation: 6–10 slides, ≤10 min, for Head of Data Science — project
   overview/goals, work summary, key findings (+ metric & current estimate),
   recommendations.
3. Must pass full grading rubric (rubric doc referenced but not directly
   fetched — only task list captured via workbook screenshot).

## Data

`DS_capstone_scooter_snapshots.csv` — 1800 rows, 7 columns, one row = one
scooter snapshot.

| Column | Doc says | Actual (scanned) |
|---|---|---|
| `scooter_id` | unique id | clean, 1800 unique, no dupes |
| `service_area` | categorical zone | 6 raw categories — `"downtwon"` (18 rows) is a typo dup of `"downtown"`; true count = 5 |
| `scooter_model` | categorical model family | clean — QX1010/QX2080/QX3000, no issue |
| `total_trips_24h` | discrete numeric | stored as **string**, contains literal `'na'` values mixed with numeric strings — needs coercion |
| `battery_health_score` | continuous 0–100 | in range (51.7–100), but **72 nulls (~4%)** |
| `reported_issue_count_24h` | discrete count | **18 rows negative** (-1 to -5) — impossible for a count, data-entry error |
| `taken_out_of_service` | binary target | clean 0/1, but **imbalanced: 87.7% / 12.3%** |

Key implication: stakeholder's ">=90% accuracy" ask is close to meaningless —
predicting "0 / in service" for every row already scores ~87.7% accuracy. Report
needs to flag this and push toward precision/recall/ROC-AUC/PR-AUC or a
cost-based metric instead of raw accuracy.

## Plan of action (code side)

1. **Data validation** — per column: fix `service_area` typo, coerce
   `total_trips_24h` to numeric (handle `'na'`), decide clip vs impute for
   negative `reported_issue_count_24h`, impute/flag nulls in
   `battery_health_score`, cast categoricals. Document every decision (rubric
   requires narrative for every column, not just the dirty ones).
2. **EDA** — histogram (battery_health_score) + bar chart (service_area or
   target counts) as the two single-variable graphics; boxplot of a numeric
   feature split by `taken_out_of_service` as the multi-variable graphic;
   write up findings (which features look separated by target).
3. **Model development** — state problem type (binary classification,
   imbalanced). Stratified train/test split. Baseline: Logistic Regression
   (interpretable, coefficients double as driver ranking). Comparison: Random
   Forest or Gradient Boosting (captures nonlinearity, feature_importances_ as
   second driver ranking). Justify both choices in text.
4. **Model evaluation** — confusion matrix, precision/recall/F1 for class 1,
   ROC-AUC (and note plain accuracy is misleading here) for both models,
   side-by-side comparison.
5. **Business metric** — define an operational metric business can track going
   forward (e.g. recall at a chosen threshold = % of true out-of-service
   events caught in advance, or a cost-weighted metric trading off missed
   failures vs wasted technician dispatches). Estimate its current value from
   the test set using the chosen model.
6. **Final summary** — restate top drivers, address whether 90% accuracy
   target is realistic/appropriate, give business recommendations (adjust
   monitoring metric, proactive maintenance threshold, fix upstream data
   quality issues found during validation).
7. **Presentation** — condense report into 6–10 slides per the four required
   sections (overview/goals, work summary, key findings + metric, recommendations).

## Code style rules (agreed, apply to every section)

1. Comment before every block, but keep comments short (one line) — heavy
   detailed comments look AI-written, not human. See
   `~/.claude/.../memory/feedback_datacamp_code_style.md`.
2. Beginner-style Python only — no one-liner consolidation, no advanced
   syntax, multiple simple lines over compact expert code. User is learning
   Python and this is their own submitted work.
3. No watermarks/AI-attribution anywhere in code or docs for this project.
4. Nothing gets dropped from the data initially — validate first via code,
   decide fixes only after seeing full picture.
5. All fixes/decisions happen via code (with a comment explaining what and
   why), not silently — this project runs in a single DataLab notebook cell,
   so `datacamp_notebook_code.py` in this folder is the running source of
   truth, built up section by section, that the user copies into that cell.

## Section 1 — Data validation (done, verified in user's actual DataLab cell)

Checked, no fixes applied yet, per column:
- shape (1800, 7), dtypes, null counts
- `scooter_id`: 0 duplicates
- `service_area`: 6 raw categories incl. `"downtwon"` typo (18 rows)
- `scooter_model`: 3 clean categories
- `total_trips_24h`: dtype object, unique values include literal `'na'` string
- `battery_health_score`: min 51.7, max 100.0 (in bounds), 72 nulls
- `reported_issue_count_24h`: value counts show negatives -5..-1 (18 rows total)
- `taken_out_of_service`: unique [0, 1], split 87.7% / 12.3%

User ran this in their real DataCamp DataLab cell and confirmed output matches
exactly what we found in the standalone scan.

## Section 2 — Data cleaning decisions (agreed, code drafted and VERIFIED in DataLab)

Decisions discussed and confirmed with user:

1. **`service_area` typo** — `"downtwon"` merged into `"downtown"` via
   `.replace()`. Straightforward, no disagreement.
2. **`total_trips_24h` `'na'` string** — user asked why conversion to NaN is
   necessary at all: because the column is stored as text (object dtype) due
   to the `'na'` string mixed in with numeric strings, so no math/model can
   use it until converted. Fix: `pd.to_numeric(..., errors='coerce')`, which
   turns `'na'` (and any other non-numeric entry) into a real NaN, restoring
   proper numeric dtype for the rest of the values.
3. **`reported_issue_count_24h` negative values (18 rows, -5 to -1)** — user's
   own instinct was these could be a typo/incorrect data entry. Agreed
   explanation: a count can't be negative in reality; magnitudes are small and
   fall within the same range as valid positive values (1–5), so most likely
   a sign error rather than sensor garbage. **Decision: take absolute value**
   (`.abs()`) to recover the likely true count, rather than treating as
   missing/imputing.
4. **`battery_health_score` nulls (72 rows, ~4%)** — walked through options
   (drop / mean / median / leave as NaN / missing-flag + impute / advanced
   imputation). User decided: **leave as NaN for now**, do not impute at the
   cleaning stage. Missing values here are already proper NaN (pandas
   auto-converts blank cells in a numeric column on read), so no conversion
   code is needed for this column at all right now. Handling (impute, or
   pipeline-level imputer, or drop) will be decided later at the model-fitting
   step, since sklearn models generally can't take raw NaN as input.

Section 2 code was drafted in `datacamp_notebook_code.py`, with a summary
comment block added at the top listing all section 1 findings/decisions
(typo, `'na'` conversion, negative-value fix, battery_health_score left as
NaN), per user's ask to carry those assumptions forward as comments into
section 2.

**Run and verified in user's real DataLab cell — output cross-checked:**
- `service_area`: downtown count went 496 -> 514 (496 + 18 typo rows) — typo
  merge confirmed correct
- `total_trips_24h`: converted to float64, 54 missing values after
  conversion — cross-checked separately against raw data, which had exactly
  54 `'na'` string rows, exact match
- `reported_issue_count_24h`: after `.abs()`, value counts cross-checked
  value-by-value against the pre-fix counts (e.g. count of 1 went
  236 -> 237, absorbing the 1 row that was -1; count of 4 went 48 -> 55,
  absorbing the 7 rows that were -4; etc), total still sums to 1800 rows,
  nothing lost
- `battery_health_score`: left untouched as planned, 72 NaN carried forward
  to be handled at model-fitting step

Section 2 fully verified, no issues found in output.

## Section 3 — EDA (done, verified in user's real DataLab cell)

Two single-variable graphics (different types) + one multi-variable graphic,
per rubric:
1. Histogram of `battery_health_score`
2. Bar chart of `service_area` counts
3. Boxplot of `battery_health_score` split by `taken_out_of_service` (the
   multi-variable graphic — user asked why a boxplot specifically: it
   compares the distribution of one numeric column across two groups side by
   side, which directly answers the stakeholder's "what predicts going out of
   service" question)

Findings confirmed against actual chart output and corrected once real charts
were seen:
- `battery_health_score` is skewed towards higher values, most scooters sit
  around 80-90 with a tail going down towards 55 (not "uniformly spread" as
  first guessed before seeing the chart)
- `service_area`: downtown has the most scooters (~514), waterfront the
  least (~185)
- Boxplot: out-of-service group has a lower median battery health (~77) than
  the in-service group (~82), some overlap between groups but battery health
  looks like a real candidate predictor

Section 3 fully verified. Findings comment in the code corrected to match
actual chart output.

## Presentation requirement (noted for later, not built yet)

User wants section 1 assumptions/decisions (the same summary now placed at
the top of section 2 in `datacamp_notebook_code.py`) also carried into the
final presentation slides — likely as part of the "data validation" /
"summary of work" slide, so the reviewer sees what was found and how it was
handled, not just the modeling results.

## Total sections planned (7, mapped to rubric)

1. Data validation
2. Data cleaning
3. EDA
4. Model development
5. Model evaluation
6. Business metric definition
7. Final summary + recommendations

(Presentation slides are a separate deliverable built after the report, not
an 8th code section.)

## Section 4 — Model development (done, verified in user's real DataLab cell)

- Remaining NaN handling decided: `battery_health_score` (72) and
  `total_trips_24h` (54) filled with column median via `.fillna()`, right
  before modeling — sklearn models can't accept raw NaN input.
- `service_area` and `scooter_model` one-hot encoded via `pd.get_dummies`
  (user asked why text columns need conversion: models only do numeric math,
  text has no inherent order/magnitude, and naively mapping categories to
  1/2/3 would wrongly imply an order between them — one-hot avoids that).
- `scooter_id` dropped from features (identifier, not predictive).
- Stratified 80/20 train/test split (`stratify=target_column`) to preserve
  the 87.7/12.3 class ratio in both sets, `random_state=42`.
- Problem type stated: binary classification.
- Baseline model: Logistic Regression (simple, interpretable coefficients
  double as a driver ranking).
- Comparison model: Random Forest (captures non-linear patterns, gives a
  second feature-importance-based driver ranking).

Verified output: train shape (1440, 11), test shape (360, 11), both models
trained with no errors, matches expected split sizes (80% of 1800 = 1440).

## Section 5 — Model evaluation (done, verified in user's real DataLab cell)

Compared both models on accuracy, precision, recall, F1, ROC-AUC and
confusion matrix, not just accuracy, given the class imbalance.

**Baseline (Logistic Regression):** accuracy 0.878, precision 0.0, recall
0.0, F1 0.0, ROC-AUC 0.620. Confusion matrix `[[316, 0], [44, 0]]` — it
predicts "in service" for every single test row, never once flags a real
out-of-service case. High accuracy, zero practical use.

**Comparison (Random Forest):** accuracy 0.856 (lower than baseline),
precision 0.214, recall 0.068, F1 0.103, ROC-AUC 0.588. Confusion matrix
`[[305, 11], [41, 3]]` — catches only 3 of 44 true out-of-service cases, but
at least catches some, unlike the baseline.

**This is the concrete evidence for the report's key message:** the
stakeholder's ">=90% accuracy" ask is a trap given the 87.7%/12.3% class
imbalance — a model can clear 90% accuracy while being functionally useless
(as the baseline demonstrates at 87.8%). ROC-AUC (0.62 / 0.59, close to 0.5
random-guess baseline) is the more honest read: with only 3 features and this
much class imbalance, neither model meaningfully separates the two classes
yet. Report should recommend against raw accuracy as the target metric and
propose something imbalance-aware instead (feeds into section 6, business
metric).

## Section 6 — Business metric (done, verified in user's real DataLab cell)

**Chosen metric: recall ("catch rate")**, with precision reported alongside
as a secondary check.

Rationale: business asked for accuracy, but section 5 already proved plain
accuracy is misleading (baseline hits 87.8% accuracy while catching zero real
cases). Recall directly answers what the business actually needs — of all
scooters that truly go out of service, what percent get flagged ahead of
time. Precision reported alongside because a low precision means wasted
technician dispatches on false alarms (labor/parts cost).

Model used for the estimate: Random Forest (the comparison model), since it's
the only one of the two that catches any real positives at all.

**Current estimate (verified):** recall = 0.068 (catches ~3 of 44 true
out-of-service cases in the test set), precision = 0.214. Plain-english
takeaway printed in the code: catch rate is very low today, not yet reliable
enough to base staffing/purchasing decisions on — clear room-for-improvement
message carried into section 7.

## Section 7 — Final summary and recommendations (done, verified in user's real DataLab cell)

Pulled feature rankings from both models and wrote up the closing summary:

- **Logistic regression coefficients** (sorted): `service_area_downtown`
  0.383, `service_area_university` 0.136, `reported_issue_count_24h` 0.112,
  ... down to `service_area_waterfront` -0.311 — dominated by the
  `service_area` dummy variables.
- **Random forest feature importances** (sorted): `battery_health_score`
  0.546 (dominant), `total_trips_24h` 0.218, `reported_issue_count_24h`
  0.111, all `service_area`/`scooter_model` dummies under 0.02 each.
- **Important caveat caught and written into the summary**: these two
  rankings disagree because the numeric features were never scaled before
  fitting logistic regression, so its coefficient magnitudes aren't
  comparable across differently-scaled columns (0/1 dummies vs. a 50-100
  range score) — flagged explicitly rather than silently picking one
  ranking. Random forest importances treated as the more reliable ranking
  for "most influential predictors" since they don't have this issue.
- Final summary + recommendations printed: problem type, data quality issues
  found, why 90% accuracy is not a meaningful target given the imbalance,
  the scaling caveat, true feature ranking, low recall on both models, and
  recommendations (track recall/precision monthly instead of accuracy, fix
  upstream data collection issues, collect more features, don't rely on
  current models yet for staffing/purchasing decisions).

Verified against actual DataLab output — matches exactly.

## Written report text (drafted, not yet pasted into DataLab / finalized by user)

DataLab workbook template has a separate markdown/text area above the single
code cell ("Start writing report here..") distinct from code comments/print
output — rubric requires actual written text summaries there, not just code
output. Drafted full narrative covering all 6 rubric bullets (data
validation, EDA, model development, model evaluation, business metrics,
final summary/recommendations), using the exact verified numbers from all 7
code sections. Saved to `written_report_draft.md` in this folder. User to
copy into the DataLab text area, may adjust wording to sound like their own
voice.

Also created `FULL_SUBMISSION_REFERENCE.md` — combined copy of the report
text followed by the full verified code, all in one file, for convenience of
having both together in one place (not a new/different submission artifact,
same content as `written_report_draft.md` + `datacamp_notebook_code.py`).

## Status

All 7 planned code sections (data validation, data cleaning, EDA, model
development, model evaluation, business metric, final summary/
recommendations) are complete and verified against user's real DataLab
workbook output, each cross-checked and confirmed correct. Section 1
findings/decisions are carried as a comment summary at the top of section 2
in the code; still to be carried into the final presentation slides too (see
requirement above). Written report narrative drafted (`written_report_draft.md`)
but not yet confirmed as pasted/finalized by user. Not yet started: the
presentation slides (6-10 slides, <=10 min).
