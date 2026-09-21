## Data Validation

The dataset has 1800 rows and 7 columns, one row per scooter snapshot. I checked every column against the data dictionary provided and found a few issues that needed fixing before analysis.

- **scooter_id**: unique identifier for each scooter. No duplicates found, so no cleaning needed here.
- **service_area**: categorical zone. Found 6 raw category values instead of the expected 5 — "downtwon" was a spelling mistake for "downtown" (18 rows). Fixed by merging it into "downtown".
- **scooter_model**: categorical model family (QX1010, QX2080, QX3000). No issues found, values are clean.
- **total_trips_24h**: should be a discrete number, but was stored as text because 54 rows contained the literal value "na" mixed in with numeric strings. Converted the column to numeric, which turns these "na" entries into proper missing values (NaN).
- **battery_health_score**: continuous score expected between 0 and 100. Actual range found was 51.7 to 100, so within bounds. However, 72 rows (about 4%) were missing. Left as missing at the validation/cleaning stage and only filled in later, right before model fitting, using the column median.
- **reported_issue_count_24h**: a count of rider-reported issues, which should never be negative. Found 18 rows with negative values (-1 to -5). Since a count cannot logically be negative, and the magnitudes were small and in line with the normal positive range, I treated these as sign errors and corrected them using the absolute value.
- **taken_out_of_service**: binary target column, values are clean (0 or 1). No cleaning needed, but the split is imbalanced — 87.7% of scooters stay in service and only 12.3% go out of service. This imbalance became important later during modeling and evaluation.

## Exploratory Analysis

To understand the data before modeling, I looked at the following graphics:

1. **Histogram of battery_health_score** (single variable) — the distribution is skewed towards higher values. Most scooters sit in the 80-90 range, with a tail stretching down towards 55.
2. **Bar chart of service_area counts** (single variable, different chart type) — downtown has the most scooters (about 514 after fixing the typo), waterfront has the fewest (about 185).
3. **Boxplot of battery_health_score split by taken_out_of_service** (two variables) — this compares battery health between scooters that went out of service and scooters that stayed in service. The out-of-service group has a lower median battery health (around 77) compared to the in-service group (around 82), although there is some overlap between the two groups.

**Findings:** battery health looks like a meaningful signal for predicting whether a scooter goes out of service, since the two groups show a visible difference in the boxplot, even though the separation is not perfect. Service area distribution is uneven across zones, which is useful context but was not immediately obvious as a strong predictor on its own.

## Model Development

This is a **binary classification problem** — the goal is to predict one of two outcomes for each scooter: whether it will be taken out of service (1) or not (0) in the following 24 hours.

Before fitting any model, I filled the remaining missing values in `battery_health_score` and `total_trips_24h` using the column median, since scikit-learn models cannot accept missing values directly. I also converted the `service_area` and `scooter_model` text columns into numeric 0/1 columns using one-hot encoding, since models can only work with numbers, and mapping categories to arbitrary numbers (e.g. 1, 2, 3) would incorrectly imply an order between them that doesn't exist. `scooter_id` was dropped since it is just an identifier and carries no predictive information. The data was then split into 80% training and 20% testing, using stratified sampling so that both sets kept the same 87.7/12.3 class split as the full dataset.

- **Baseline model: Logistic Regression.** Chosen because it is simple, fast to train, and easy to explain — its coefficients give a rough sense of which features push the prediction one way or the other.
- **Comparison model: Random Forest.** Chosen because it can capture non-linear relationships and interactions between features that logistic regression cannot, and it also produces a feature importance ranking that can be compared against the logistic regression coefficients.

## Model Evaluation

Because the target is imbalanced (87.7% / 12.3%), accuracy alone is a misleading metric here — a model that always predicts "in service" would already score close to 88% accuracy without learning anything useful. This is exactly what happened with the baseline model, so I evaluated both models using accuracy, precision, recall, F1 score, ROC-AUC, and the confusion matrix.

| Metric | Baseline (Logistic Regression) | Comparison (Random Forest) |
|---|---|---|
| Accuracy | 0.878 | 0.856 |
| Precision | 0.0 | 0.214 |
| Recall | 0.0 | 0.068 |
| F1 Score | 0.0 | 0.103 |
| ROC-AUC | 0.620 | 0.588 |

The baseline model predicted "in service" for every single row in the test set — it never once correctly identified a scooter that actually went out of service (confusion matrix showed 0 true positives out of 44). Despite this, it still scored 87.8% accuracy, which is the clearest evidence that accuracy is not a suitable metric for this problem.

The Random Forest model performed slightly worse on raw accuracy (85.6%), but it was the only model that identified any true out-of-service cases at all, catching 3 out of 44. Both ROC-AUC scores (0.62 and 0.59) are close to 0.5, which is what a random guess would produce, showing that with only 3 numeric features and this level of class imbalance, neither model separates the two classes strongly yet.

## Business Metrics

Given that accuracy is misleading here, I am recommending **recall** (also called the "catch rate") as the metric the business should track going forward, alongside **precision** as a secondary check.

- **Recall** answers the business's actual question: of all the scooters that really do go out of service, what percentage did we correctly flag in advance? This is the number that matters for reducing unplanned downtime.
- **Precision** is reported alongside because a low precision means technicians would be sent out on false alarms, wasting labor and parts. The business should watch both together, not recall alone.

**Current estimate**, using the Random Forest model (the one that performs better on this metric): recall = 0.068 (catching about 3 out of every 44 scooters that go out of service) and precision = 0.214. In plain terms, the current models are catching a very small fraction of real breakdowns, and are not yet reliable enough to base staffing or purchasing decisions on.

## Final Summary and Recommendations

This project set out to identify the strongest predictors of a scooter going out of service, and to build a model that could predict this with high accuracy. Based on the analysis:

- The 90% accuracy target given by the business is not a meaningful goal for this dataset. Because only 12.3% of scooters actually go out of service, a model can exceed 90% accuracy while being practically useless — our own baseline model demonstrated this by hitting 87.8% accuracy while catching zero real cases.
- Looking at feature importance, I want to flag an important caveat: the logistic regression coefficients and random forest importances disagreed on which features mattered most. This is because the numeric features were not scaled before fitting logistic regression, so its coefficient sizes are not directly comparable to each other. The random forest importances do not have this problem and are the more trustworthy ranking. Based on those, **battery_health_score is by far the strongest predictor**, followed by `total_trips_24h`, then `reported_issue_count_24h`. `service_area` and `scooter_model` had very little influence in comparison.
- Both models currently have a very low catch rate. The Random Forest model is an improvement over the baseline, but still misses the majority of real breakdowns.

**Recommendations for the business:**

1. Replace the accuracy target with recall and precision, and track both metrics monthly rather than aiming for a single accuracy number.
2. Fix the data collection issues found during validation — the typo in `service_area`, text values mixed into `total_trips_24h`, and impossible negative values in `reported_issue_count_24h` — so future data is cleaner from the start.
3. Collect additional features if possible. The three numeric features available (`total_trips_24h`, `battery_health_score`, `reported_issue_count_24h`) are not enough on their own to reliably predict breakdowns, and richer telemetry (e.g. more frequent battery readings, usage intensity, weather, scooter age) would likely help.
4. Do not rely on the current models for staffing or purchasing decisions yet, given the low catch rate. Treat this as a first version, and revisit it once better data is available.
