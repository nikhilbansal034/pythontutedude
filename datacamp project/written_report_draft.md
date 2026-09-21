# Written report — DataLab text area

This is the narrative that goes in the DataLab workbook's text area, above the
code cell. It is kept in markdown here for readability; the version actually
pasted into DataLab lives in `report.txt`, which is the exact notebook content.

Every number below comes from a verified run of `code.py` against
`DS_capstone_scooter_snapshots.csv`.

## Data Validation

The dataset has 1800 rows and 7 columns, one row per scooter snapshot. Checked
every column against the data dictionary and found four issues needing fixes.

| Column | Finding | Decision |
|---|---|---|
| `scooter_id` | 1800 unique, 0 duplicates | No action |
| `service_area` | 6 raw categories — `"downtwon"` is a misspelling of `"downtown"` (18 rows) | Merged into `downtown`, 496 → 514 |
| `scooter_model` | 3 clean categories (QX1010, QX2080, QX3000) | No action |
| `total_trips_24h` | Stored as text: 54 rows hold the literal string `'na'` | `pd.to_numeric(errors='coerce')` → 54 NaN |
| `battery_health_score` | Range 51.7–100, inside the documented 0–100. 72 rows missing | Left as NaN at cleaning, median-filled at the modelling step |
| `reported_issue_count_24h` | 18 rows negative (−1 to −5); a count cannot be negative | Treated as sign errors, corrected with `.abs()` |
| `taken_out_of_service` | Clean 0/1, but imbalanced — 87.7% / 12.3% | Not a cleaning issue; drove the modelling decisions |

## Exploratory Analysis

1. **Histogram of `battery_health_score`** (single variable) — skewed towards
   higher values, most scooters in the 80–90 range with a tail down to ~55.
2. **Bar chart of `service_area` counts** (single variable, different chart
   type) — downtown holds the most scooters (~514), waterfront the fewest (~185).
3. **Boxplot of `battery_health_score` split by `taken_out_of_service`** (two
   variables) — the out-of-service group has a lower median battery health
   (~77) than the in-service group (~82).

**Findings.** Battery health is the clearest signal in the data. Split into
five equal groups by battery health, the weakest fifth goes out of service
about 24% of the time against about 5% for the healthiest fifth — roughly a 5×
difference. Usage shows a weaker version of the same pattern (busiest fifth
~21% against quietest fifth ~8%). Service area varies too (downtown 17% against
waterfront 6%) but the groups overlap heavily, so no single chart separates the
two classes cleanly on its own.

## Model Development

**Binary classification** — predict whether each scooter is taken out of
service (1) or not (0) in the following 24 hours.

Preparation:

- Median-filled the remaining NaN in `battery_health_score` and
  `total_trips_24h`; scikit-learn cannot accept NaN input.
- One-hot encoded `service_area` and `scooter_model`. Mapping categories to
  1/2/3 would wrongly imply an ordering between them.
- Dropped `scooter_id` — an identifier with no predictive content.
- Stratified 80/20 train/test split, preserving the 87.7/12.3 ratio in both.
- **Standardised every column with `StandardScaler`, fit on the training split
  only.** `battery_health_score` runs 50–100 while the one-hot columns are 0/1;
  scaling also makes the logistic regression coefficients comparable to each
  other, which matters for the driver ranking.
- **`class_weight='balanced'` on both models.** Without it, both learn that
  always answering "in service" is right 87.7% of the time and never flag a
  single scooter.
- Fitted a **`DummyClassifier` no-skill reference** that always predicts the
  majority class. Not a third contender — a benchmark, because any accuracy
  figure has to be judged against what guessing already scores.

Models:

- **Baseline: Logistic Regression.** Simple, fast, interpretable; its
  coefficients double as a driver ranking once the features are scaled.
- **Comparison: Random Forest.** Captures non-linear relationships and
  interactions, and gives a second importance ranking. Capped at
  `max_depth=5` / `min_samples_leaf=20` / 400 trees, because a fully grown
  forest memorises 1440 training rows holding only 12% positives.

## Model Evaluation

| Metric | No-skill reference | Baseline (Logistic Regression) | Comparison (Random Forest) |
|---|---|---|---|
| Accuracy | 0.878 | 0.589 | 0.617 |
| Precision | 0.000 | 0.149 | 0.144 |
| Recall | 0.000 | **0.500** | 0.432 |
| F1 | 0.000 | 0.229 | 0.216 |
| ROC-AUC | 0.500 | **0.620** | 0.601 |
| PR-AUC | 0.122 | **0.257** | 0.213 |
| True positives (of 44) | 0 | **22** | 19 |
| 5-fold CV ROC-AUC | — | **0.664 ± 0.031** | 0.646 ± 0.029 |

The no-skill reference is the most important row: 87.8% accuracy while catching
zero real cases. It proves accuracy is the wrong metric here — a model below
87.8% is not necessarily worse, and one above it is not necessarily useful. The
requested ≥90% accuracy target was not met, and should not be chased.

Both real models score lower accuracy than the no-skill reference. That is
expected and is the trade we want: they give up accuracy in order to flag
scooters at risk at all.

The test set holds only 44 positives, too few to judge on one split, so both
models were also cross-validated over all 1800 rows. Logistic regression is
slightly ahead on ROC-AUC, PR-AUC and true positives, so it is the better of
the two. A cross-validated ROC-AUC of ~0.65 is clearly above the 0.5 of a coin
flip, with a small spread across folds, so **the signal is real but modest** —
enough to rank scooters by risk, not enough to call any individual scooter a
certain breakdown. PR-AUC 0.257 against a 0.122 positive rate says the same:
about twice as good as random, not more.

## Business Metrics

Accuracy cannot be the metric — the no-skill reference already scores 87.8%
while catching nothing. Rather than swap it for another model metric, the
metric is built around the decision the business actually makes: how many
scooters technicians can inspect each day.

**Metric — pre-emptive catch rate at a fixed inspection budget.** Rank every
scooter by predicted risk, inspect the top 10% of the fleet, and measure what
share of the scooters that really did go out of service sat in that inspected
group. Reported alongside it: **hit rate** (share of inspections that found a
real problem — the labour and parts cost side) and **lift** over inspecting the
same number of scooters at random.

**Business baseline: 0%.** Maintenance is reactive today, no scooter is
inspected before it fails, so every breakdown is found after the fact. Anything
above 0% improves on how the business runs right now.

| Estimate | Catch rate | Hit rate | Lift |
|---|---|---|---|
| Current process (reactive) | **0%** | — | — |
| Held-out test set | 20.5% | 25.0% | 2.05× |
| 5-fold across all 1800 rows | **23.4%** | **28.9%** | **2.34×** |

In plain terms: if technicians inspect the 180 highest-risk scooters out of
1800 each day, they find roughly a quarter of the scooters about to break down,
and about 1 in every 3–4 inspections is justified. A little over twice as good
as inspecting at random.

## Final Summary and Recommendations

- **The 90% accuracy target was not met and should not be chased.** Only 12.3%
  of scooters go out of service, so a model can exceed 90% accuracy while being
  useless — the no-skill reference proved it at 87.8% with zero catches.
- **`battery_health_score` is by far the strongest predictor.** All three
  rankings agree: standardised logistic coefficient −0.532 (largest of any
  feature), random forest importance 0.511 (more than twice the next), and a
  shuffle test where scrambling that column costs more ROC-AUC than any other.
  `total_trips_24h` is second on both models. Because the features were
  standardised before fitting, the coefficient magnitudes are directly
  comparable.
- **`reported_issue_count_24h` is weaker than expected.** Both models rank it
  low and the shuffle test shows removing it does not hurt the score, so
  rider-reported issues are not a useful early warning on their own.
  `service_area` and `scooter_model` add very little, and the three hardware
  families are effectively indistinguishable.
- **The signal is real but modest** — cross-validated ROC-AUC ~0.65. This data
  supports ranking scooters by risk, not predicting them one by one.

**Recommendations:**

1. **Replace the accuracy target** with catch rate and hit rate at whatever
   inspection budget the team can staff, reviewed monthly. Chasing a single
   accuracy number actively pushes towards a model that does nothing.
2. **Start proactive inspections from the bottom of the battery health
   ranking.** That one column carries most of the signal and needs no model to
   act on, so this can begin immediately.
3. **Use the model to prioritise the daily inspection queue, but do not size
   the technician team or the parts order from it yet.** At 2.3× lift it is
   worth acting on; it is not precise enough to plan headcount around.
4. **Fix the upstream data collection issues** found during validation — the
   `service_area` spelling error, text mixed into `total_trips_24h`, and
   impossible negative counts in `reported_issue_count_24h`.
5. **Collect additional features.** Five columns are not enough to predict an
   individual breakdown. Scooter age, battery charge cycles, telemetry fault
   codes and weather are all worth adding — and battery health being the
   dominant driver suggests richer battery telemetry is the highest-value place
   to start.
