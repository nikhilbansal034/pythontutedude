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

Section 2 code was drafted in `code.py`, with a summary
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
the top of section 2 in `code.py`) also carried into the
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

## Section 4 — Model development (reworked after review, verified)

First pass fit both models with default settings. That was the core mistake of
the first version: the notes correctly identified the 87.7/12.3 imbalance as the
central problem, then did nothing about it in the fit, so the headline "recall
0.068" was an artefact of the modelling, not a property of the data.

Current state:

- Remaining NaN handling unchanged: `battery_health_score` (72) and
  `total_trips_24h` (54) filled with column median right before modelling.
- `service_area` / `scooter_model` one-hot encoded; `scooter_id` dropped.
- Stratified 80/20 split, `random_state=42`. Train (1440, 11), test (360, 11).
- **`StandardScaler` added**, fit on the training split only. Two reasons:
  `battery_health_score` runs 50-100 against 0/1 dummies, and scaling makes the
  logistic regression coefficients comparable to each other — which is what
  resolves the ranking contradiction flagged in section 7 below.
- **`class_weight='balanced'` on both models.** Without it both learn that
  always answering "in service" is right 87.7% of the time.
- **Random forest capped** at `max_depth=5`, `min_samples_leaf=20`,
  `n_estimators=400`. The default forest was overfitting 1440 rows and was
  actually the *worse* model by cross-validated AUC (0.576).
- **`DummyClassifier(strategy='most_frequent')` added as a no-skill reference.**
  Not a third contender — a benchmark, so the "87.8% accuracy while catching
  nothing" argument is demonstrated rather than asserted.
- Problem type: binary classification. Baseline = logistic regression,
  comparison = random forest, reasons unchanged.

## Section 5 — Model evaluation (reworked, verified)

| Metric | No-skill | Baseline (LogReg) | Comparison (RF) |
|---|---|---|---|
| Accuracy | 0.878 | 0.589 | 0.617 |
| Precision | 0.000 | 0.149 | 0.144 |
| Recall | 0.000 | 0.500 | 0.432 |
| F1 | 0.000 | 0.229 | 0.216 |
| ROC-AUC | 0.500 | 0.620 | 0.601 |
| PR-AUC | 0.122 | 0.257 | 0.213 |
| True positives (of 44) | 0 | 22 | 19 |
| 5-fold CV ROC-AUC | — | 0.664 +/- 0.031 | 0.646 +/- 0.029 |

Confusion matrices: no-skill `[[316, 0], [44, 0]]`, baseline
`[[190, 126], [22, 22]]`, comparison `[[203, 113], [25, 19]]`.

**Corrections to the first version's conclusions:**

1. The claim that the ROC-AUC was depressed by class imbalance was wrong.
   ROC-AUC is invariant to the class prior — imbalance cannot affect it.
2. The claim that 0.62 is "close to random" was also wrong. A bootstrap 95% CI
   on that split is [0.532, 0.708], which excludes 0.5, and the out-of-fold AUC
   over all 1800 rows is 0.661. The signal is modest but real and significant.
3. PR-AUC and 5-fold CV added because the test split holds only 44 positives,
   which is far too few to report a single number from.

Honest read: cross-validated AUC ~0.65 supports **ranking scooters by risk**,
not predicting individual breakdowns.

## Section 6 — Business metric (reworked, verified)

First version proposed recall + precision. That is still a model metric, and
the workbook criterion asks to "define a way to compare your model performance
**to the business**". Reframed around the real operational constraint.

**Metric: pre-emptive catch rate at a fixed inspection budget.** Rank every
scooter by predicted risk, inspect the top 10% of the fleet, measure what share
of real breakdowns sat in that group. Reported with **hit rate** (share of
inspections that found a real problem — the labour/parts cost side) and **lift**
over random inspection.

**Business baseline: 0%** — maintenance is reactive today, nothing is inspected
before it fails.

| Estimate | Catch rate | Hit rate | Lift |
|---|---|---|---|
| Current process | 0% | — | — |
| Held-out test set | 0.205 | 0.250 | 2.05x |
| 5-fold over all 1800 rows | 0.234 | 0.289 | 2.34x |

Model used: logistic regression, since it leads on ROC-AUC, PR-AUC and true
positives. (First version picked the random forest because it was "the only one
catching any positives" — that was a thresholding artefact, and the RF was the
weaker model.)

## Section 7 — Final summary and driver ranking (reworked, verified)

The first version flagged that the two rankings disagreed because the features
were unscaled, then resolved the contradiction by trusting the weaker model.
Scaling is a two-line fix and makes the disagreement disappear.

- **Standardised logistic coefficients** (now mutually comparable):
  `battery_health_score` -0.532, `total_trips_24h` +0.184,
  `reported_issue_count_24h` +0.151, `service_area_downtown` +0.139, rest below
  0.11. Battery health odds ratio is 0.59 per +1 SD.
- **Random forest importances**: `battery_health_score` 0.511,
  `total_trips_24h` 0.212, `service_area_downtown` 0.069,
  `reported_issue_count_24h` 0.059, rest below 0.04.
- **Permutation importance added as a third, unbiased check** — impurity
  importance favours continuous/high-cardinality columns and raw coefficients
  favour large-scale ones, so neither ranking is trustworthy alone. Shuffling
  `battery_health_score` costs 0.057 ROC-AUC; every other column costs under
  0.008, and `reported_issue_count_24h` comes out slightly negative.

**Conclusion:** battery health dominates on all three rankings, trips second on
both models. `reported_issue_count_24h` is weak — removing it does not hurt the
score, so rider-reported issues are not a useful early warning on their own.
`service_area` and `scooter_model` add very little.

Underlying data check: lowest battery-health quintile goes out of service 24.1%
of the time against 5.2% for the highest. Trips quintiles run 7.6% to 20.9%.
Service area 5.9% (waterfront) to 17.1% (downtown).

## Files

| File | What it is |
|---|---|
| `code.py` | **The source of truth.** Exact copy of the single DataLab code cell. CRLF line endings — preserve them. |
| `report.txt` | **The source of truth** for the narrative. Exact copy of the DataLab text area, including the task-list preamble. CRLF. |
| `written_report_draft.md` | Markdown rendering of the same narrative, for readability and review |
| `FULL_SUBMISSION_REFERENCE.md` | Generated from `report.txt` + `code.py`. Do not hand-edit |
| `DS_capstone_scooter_snapshots.csv` | The dataset |
| `Deloitte+Practical+-+DS+-+Automotive.pdf` | The brief |
| `workbook_screenshot.png` | The DataLab workbook task list |

`datacamp_notebook_code.py` was deleted — it was a second copy of the same
analysis in a different style, and keeping two in sync was avoidable risk.

## Status

- **Code**: complete, all 7 sections, verified running end to end against the
  CSV (exit 0, no warnings, all three figures render).
- **Written report**: complete and consistent with the code. Every number in it
  comes from a verified run.
- **Presentation**: not started. 6-10 slides, <=10 minutes, recorded and
  submitted through the certification portal. Required to pass.

## Code style rules (agreed, apply to every section)

`code.py` has its own conventions — match them, do not import the style of any
other file:

1. All imports grouped at the top, one `from ... import X` per line.
2. Plain Title Case section headers (`# Model development`), no banner comments.
3. `print('\nLabel : ', value)` — leading newline, label and value in a single
   call.
4. Trailing inline comments for annotations (`# change 1`,
   `# checking for duplicates in scooter_id`).
5. Findings written as `# - ` comment bullets, matching
   `# observations from data profiling`.
6. Symmetric straight-line blocks, no helper functions.
7. No narrative `print()` walls — the file ends at the ranking output. The
   write-up belongs in the DataLab text area, not in print statements.
8. Beginner-level Python: simple lines over compact expert code.
9. CRLF line endings.
10. No AI attribution or watermarks anywhere in the submitted files.
