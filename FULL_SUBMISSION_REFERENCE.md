# Full Submission Reference — Report Text + Code

This file is a combined reference copy of everything going into the DataLab
workbook: the written report text (for the "Start writing report here.."
area) followed by the full code (for the single code cell). Kept here as one
place to look at both together — the actual submission still lives in the two
separate places inside DataLab.

---

# PART 1: WRITTEN REPORT

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

---

# PART 2: CODE (single DataLab code cell)

```python
# =====================================================================
# SECTION 1: DATA VALIDATION
# checking each column against what the data dictionary told us,
# not fixing/dropping anything yet, just checking and printing
# =====================================================================

import pandas as pd

# load the raw data
scooter_df = pd.read_csv('DS_capstone_scooter_snapshots.csv')

# how big is the dataset
print('SHAPE OF THE DATA (rows, columns):')
print(scooter_df.shape)
print()

# check data types, want to catch any column that should be a number
# but got stored as text
print('DATA TYPE OF EACH COLUMN:')
print(scooter_df.dtypes)
print()

# check for missing values in each column
print('COUNT OF MISSING VALUES IN EACH COLUMN:')
print(scooter_df.isnull().sum())
print()

# scooter_id should be unique, check for duplicates
number_of_duplicate_ids = scooter_df['scooter_id'].duplicated().sum()
print('NUMBER OF DUPLICATE SCOOTER IDS FOUND:')
print(number_of_duplicate_ids)
print()

# service_area is a category column, print unique values to spot
# spelling mistakes or duplicate categories
print('UNIQUE VALUES IN service_area COLUMN AND THEIR COUNTS:')
print(scooter_df['service_area'].value_counts())
print()

# scooter_model is also a category column
print('UNIQUE VALUES IN scooter_model COLUMN AND THEIR COUNTS:')
print(scooter_df['scooter_model'].value_counts())
print()

# total_trips_24h should be numeric, print unique values to check
# for any non numeric text hiding in there
print('UNIQUE VALUES IN total_trips_24h COLUMN:')
print(scooter_df['total_trips_24h'].unique())
print()

# battery_health_score should be between 0 and 100, check min/max
print('MINIMUM VALUE IN battery_health_score COLUMN:')
print(scooter_df['battery_health_score'].min())
print('MAXIMUM VALUE IN battery_health_score COLUMN:')
print(scooter_df['battery_health_score'].max())
print()

# reported_issue_count_24h is a count so it should never be negative
print('VALUE COUNTS FOR reported_issue_count_24h COLUMN (SORTED):')
print(scooter_df['reported_issue_count_24h'].value_counts().sort_index())
print()

# taken_out_of_service is our target, check unique values and the
# class balance since that matters for modeling later
print('UNIQUE VALUES IN taken_out_of_service COLUMN:')
print(scooter_df['taken_out_of_service'].unique())
print()
print('PERCENTAGE SPLIT OF taken_out_of_service COLUMN:')
print(scooter_df['taken_out_of_service'].value_counts(normalize=True))


# =====================================================================
# SECTION 2: DATA CLEANING
# fixing the issues we found in section 1, one at a time, each with
# a comment on what is being fixed and why
#
# summary of what section 1 found and what we decided to do about it:
# - service_area had a typo "downtwon" for "downtown" (18 rows) -> fix now
# - total_trips_24h was stored as text because of 'na' values mixed in
#   with the numbers -> convert to numeric now, 'na' becomes NaN
# - reported_issue_count_24h had 18 negative values (-1 to -5), a count
#   can never be negative, most likely a sign typo -> fix now using
#   absolute value
# - battery_health_score has 72 missing values, already stored as NaN
#   by pandas -> decided to leave as NaN for now, will handle this at
#   model building step instead of here
# - scooter_id had no duplicates and scooter_model had no issues, so
#   both are left as they are
# - taken_out_of_service is clean but imbalanced (87.7% vs 12.3%), this
#   is not a cleaning issue, just something to keep in mind for modeling
# =====================================================================

# service_area has a typo "downtwon" which is really "downtown", so
# we are replacing that spelling with the correct one
scooter_df['service_area'] = scooter_df['service_area'].replace('downtwon', 'downtown')

# check that the typo is gone and downtown count has gone up
print('service_area AFTER FIXING TYPO:')
print(scooter_df['service_area'].value_counts())
print()

# total_trips_24h is stored as text because of the 'na' values mixed
# in, so we convert it to a proper numeric column, this turns any
# value that is not a number (like 'na') into a NaN automatically
scooter_df['total_trips_24h'] = pd.to_numeric(scooter_df['total_trips_24h'], errors='coerce')

# check the column is numeric now and see how many NaN got created
print('total_trips_24h DATA TYPE AFTER CONVERSION:')
print(scooter_df['total_trips_24h'].dtype)
print()
print('total_trips_24h MISSING VALUES AFTER CONVERSION:')
print(scooter_df['total_trips_24h'].isnull().sum())
print()

# reported_issue_count_24h has some negative values which is not
# possible for a count, we are treating these as sign errors and
# taking the absolute value to recover the likely real count
scooter_df['reported_issue_count_24h'] = scooter_df['reported_issue_count_24h'].abs()

# check that no negative values remain
print('reported_issue_count_24h AFTER TAKING ABSOLUTE VALUE:')
print(scooter_df['reported_issue_count_24h'].value_counts().sort_index())
print()

# battery_health_score already has its missing values stored as
# proper NaN by pandas, so we are leaving this column as it is for
# now, we will decide how to handle these NaN at model building step
print('battery_health_score MISSING VALUES (LEFT AS NaN FOR NOW):')
print(scooter_df['battery_health_score'].isnull().sum())


# =====================================================================
# SECTION 3: EXPLORATORY DATA ANALYSIS
# looking at single columns first with two different chart types,
# then looking at how a column relates to our target column
# =====================================================================

# we need matplotlib to draw charts
import matplotlib.pyplot as plt

# single variable graphic 1: histogram of battery_health_score
# this shows us the shape/spread of battery health across all scooters
plt.figure()
plt.hist(scooter_df['battery_health_score'].dropna(), bins=20)
plt.title('Distribution of Battery Health Score')
plt.xlabel('battery_health_score')
plt.ylabel('number of scooters')
plt.show()

# single variable graphic 2: bar chart of service_area counts
# this is a different chart type than the histogram above, and shows
# how many scooters fall in each service area
area_counts = scooter_df['service_area'].value_counts()
plt.figure()
plt.bar(area_counts.index, area_counts.values)
plt.title('Number of Scooters by Service Area')
plt.xlabel('service_area')
plt.ylabel('number of scooters')
plt.xticks(rotation=45)
plt.show()

# multi variable graphic: boxplot of battery_health_score split by
# taken_out_of_service, this lets us compare battery health between
# scooters that went out of service and scooters that did not
in_service_battery = scooter_df[scooter_df['taken_out_of_service'] == 0]['battery_health_score'].dropna()
out_of_service_battery = scooter_df[scooter_df['taken_out_of_service'] == 1]['battery_health_score'].dropna()
plt.figure()
plt.boxplot([in_service_battery, out_of_service_battery])
plt.xticks([1, 2], ['in service (0)', 'out of service (1)'])
plt.title('Battery Health Score by Service Outcome')
plt.ylabel('battery_health_score')
plt.show()

# findings from the charts above:
# - battery_health_score is skewed towards higher values, most
#   scooters sit around 80-90 with a tail going down towards 55
# - downtown has the most scooters, waterfront has the least
# - scooters that went out of service have a lower median battery
#   health score than scooters that stayed in service, so battery
#   health looks like it could be a useful predictor, even though
#   there is some overlap between the two groups


# =====================================================================
# SECTION 4: MODEL DEVELOPMENT
# this is a binary classification problem, we are trying to predict
# one of two outcomes, taken_out_of_service is either 0 or 1
#
# before we can fit any model we still have two columns with missing
# values left over from earlier, battery_health_score and
# total_trips_24h, models in sklearn cannot take NaN as input, so we
# are filling these remaining NaN with the column median now
# =====================================================================

# fill the remaining missing values in battery_health_score with the
# median of that column
battery_median = scooter_df['battery_health_score'].median()
scooter_df['battery_health_score'] = scooter_df['battery_health_score'].fillna(battery_median)

# fill the remaining missing values in total_trips_24h with the
# median of that column
trips_median = scooter_df['total_trips_24h'].median()
scooter_df['total_trips_24h'] = scooter_df['total_trips_24h'].fillna(trips_median)

# check that there are no missing values left in the columns we use
# for modeling
print('MISSING VALUES AFTER FILLING WITH MEDIAN:')
print(scooter_df[['battery_health_score', 'total_trips_24h']].isnull().sum())
print()

# service_area and scooter_model are text categories, models need
# numbers, so we turn each category into its own 0/1 column using
# one hot encoding
scooter_df_encoded = pd.get_dummies(scooter_df, columns=['service_area', 'scooter_model'])

# scooter_id is just an identifier, it does not help predict
# anything, so we drop it from the features
# taken_out_of_service is our target column, so we also keep that
# separate from the features
feature_columns = scooter_df_encoded.drop(columns=['scooter_id', 'taken_out_of_service'])
target_column = scooter_df_encoded['taken_out_of_service']

# we need this to split our data into a training part and a testing
# part
from sklearn.model_selection import train_test_split

# splitting the data, 80 percent for training and 20 percent for
# testing, we use stratify so that the same 0/1 ratio is kept in
# both the training and testing sets since our target is imbalanced
X_train, X_test, y_train, y_test = train_test_split(
    feature_columns,
    target_column,
    test_size=0.2,
    stratify=target_column,
    random_state=42
)

# check the shapes of our train and test sets
print('TRAINING SET SHAPE:')
print(X_train.shape)
print('TESTING SET SHAPE:')
print(X_test.shape)
print()

# baseline model: logistic regression
# we picked this as our baseline because it is simple, fast, and
# easy to explain, the coefficients also tell us which features push
# the prediction towards out of service or not
from sklearn.linear_model import LogisticRegression

baseline_model = LogisticRegression(max_iter=1000)
baseline_model.fit(X_train, y_train)

print('BASELINE MODEL (LOGISTIC REGRESSION) TRAINED')
print()

# comparison model: random forest
# we picked this as our comparison model because it can pick up on
# patterns that are not a straight line, and it also gives us a
# feature importance ranking which we can compare to the logistic
# regression coefficients
from sklearn.ensemble import RandomForestClassifier

comparison_model = RandomForestClassifier(random_state=42)
comparison_model.fit(X_train, y_train)

print('COMPARISON MODEL (RANDOM FOREST) TRAINED')


# =====================================================================
# SECTION 5: MODEL EVALUATION
# our target is imbalanced, 87.7 percent of scooters stay in service
# and only 12.3 percent go out of service, this means a model that
# just guesses "in service" every single time would already score
# about 87.7 percent accuracy without learning anything useful, so
# plain accuracy alone would be misleading here, we are going to look
# at precision, recall, f1 score and roc auc as well for both models
# =====================================================================

# we need these to calculate the different evaluation metrics
from sklearn.metrics import accuracy_score
from sklearn.metrics import precision_score
from sklearn.metrics import recall_score
from sklearn.metrics import f1_score
from sklearn.metrics import roc_auc_score
from sklearn.metrics import confusion_matrix

# get predictions from the baseline model on the test set
baseline_predictions = baseline_model.predict(X_test)

# get the predicted probability of class 1 as well, roc auc needs
# probabilities and not just the final 0/1 prediction
baseline_probabilities = baseline_model.predict_proba(X_test)[:, 1]

# calculate all the metrics for the baseline model
baseline_accuracy = accuracy_score(y_test, baseline_predictions)
baseline_precision = precision_score(y_test, baseline_predictions)
baseline_recall = recall_score(y_test, baseline_predictions)
baseline_f1 = f1_score(y_test, baseline_predictions)
baseline_roc_auc = roc_auc_score(y_test, baseline_probabilities)

# print the baseline model metrics
print('BASELINE MODEL (LOGISTIC REGRESSION) METRICS:')
print('accuracy : ', baseline_accuracy)
print('precision : ', baseline_precision)
print('recall : ', baseline_recall)
print('f1 score : ', baseline_f1)
print('roc auc : ', baseline_roc_auc)
print('confusion matrix : ')
print(confusion_matrix(y_test, baseline_predictions))
print()

# get predictions from the comparison model on the test set
comparison_predictions = comparison_model.predict(X_test)

# get the predicted probability of class 1 for the comparison model
comparison_probabilities = comparison_model.predict_proba(X_test)[:, 1]

# calculate all the metrics for the comparison model
comparison_accuracy = accuracy_score(y_test, comparison_predictions)
comparison_precision = precision_score(y_test, comparison_predictions)
comparison_recall = recall_score(y_test, comparison_predictions)
comparison_f1 = f1_score(y_test, comparison_predictions)
comparison_roc_auc = roc_auc_score(y_test, comparison_probabilities)

# print the comparison model metrics
print('COMPARISON MODEL (RANDOM FOREST) METRICS:')
print('accuracy : ', comparison_accuracy)
print('precision : ', comparison_precision)
print('recall : ', comparison_recall)
print('f1 score : ', comparison_f1)
print('roc auc : ', comparison_roc_auc)
print('confusion matrix : ')
print(confusion_matrix(y_test, comparison_predictions))


# =====================================================================
# SECTION 6: BUSINESS METRIC
# the business asked for 90 percent accuracy, but we already showed
# in section 5 that accuracy alone is misleading here because just
# guessing "in service" every time already gives close to 88 percent
# accuracy without catching a single real breakdown, so instead we
# are proposing recall as the metric the business should track
#
# recall answers the question the business actually cares about:
# out of all the scooters that really do go out of service, what
# percent did we correctly warn about ahead of time, this is often
# called the "catch rate"
#
# we are also going to report precision alongside it, because if
# precision is too low it means a lot of technician visits would be
# sent out for false alarms, which wastes labor and parts cost, so
# the business should watch both numbers together, not just one
# =====================================================================

# we are picking the random forest as our recommended model since it
# is the only one that catches any real out of service cases at all
print('RECOMMENDED BUSINESS METRIC: RECALL (CATCH RATE), WITH PRECISION AS A SECONDARY CHECK')
print()

# current estimate of the catch rate using the random forest model
print('CURRENT CATCH RATE (RECALL) ESTIMATE FROM RANDOM FOREST : ', comparison_recall)

# current estimate of how many flagged scooters are true positives
print('CURRENT PRECISION ESTIMATE FROM RANDOM FOREST : ', comparison_precision)
print()

# a plain english summary of what these numbers mean today
print('IN PLAIN TERMS : out of every 44 scooters that actually go out of')
print('service in the test set, the random forest model only catches about')
print('3 of them in advance, this is a very low catch rate and shows there')
print('is a lot of room for improvement before this can be relied on for')
print('staffing or purchasing decisions')


# =====================================================================
# SECTION 7: FINAL SUMMARY AND RECOMMENDATIONS
# here we are pulling out which features mattered most to each model,
# and then writing up the overall summary and our recommendations
# =====================================================================

# get the feature names in the same order as the model was trained on
feature_names = feature_columns.columns

# baseline model coefficients tell us the direction and strength of
# each feature, a positive coefficient pushes towards out of service
# and a negative coefficient pushes towards staying in service
baseline_coefficients = baseline_model.coef_[0]
baseline_importance = pd.Series(baseline_coefficients, index=feature_names)
baseline_importance_sorted = baseline_importance.sort_values(ascending=False)

print('BASELINE MODEL (LOGISTIC REGRESSION) COEFFICIENTS, SORTED:')
print(baseline_importance_sorted)
print()

# random forest feature importances tell us how much each feature
# helped the model split the data, higher means more important
comparison_importance = pd.Series(comparison_model.feature_importances_, index=feature_names)
comparison_importance_sorted = comparison_importance.sort_values(ascending=False)

print('COMPARISON MODEL (RANDOM FOREST) FEATURE IMPORTANCES, SORTED:')
print(comparison_importance_sorted)
print()

# final written summary of everything we found, this pulls together
# the data validation, eda, modeling and business metric sections
print('FINAL SUMMARY:')
print('- this was a binary classification problem, predicting if a')
print('  scooter goes out of service in the next 24 hours')
print('- the data needed some cleaning first, a typo in service_area,')
print('  text values mixed into total_trips_24h, and negative values')
print('  in reported_issue_count_24h all had to be fixed')
print('- the target is imbalanced, only 12.3 percent of scooters go')
print('  out of service, so a 90 percent accuracy target is not a')
print('  meaningful goal on its own, our baseline model already hits')
print('  87.8 percent accuracy while catching zero real cases')
print('- note : the numeric features were not scaled before fitting the')
print('  logistic regression, so its coefficient sizes cannot be fairly')
print('  compared to each other, the random forest importances do not')
print('  have this problem and are more reliable for ranking predictors')
print('- based on the random forest importances, battery_health_score is')
print('  by far the strongest predictor, followed by total_trips_24h and')
print('  then reported_issue_count_24h, service_area and scooter_model')
print('  barely matter in comparison')
print('- both models currently have a very low catch rate (recall),')
print('  the random forest is better than the baseline but still only')
print('  catches a small share of true out of service scooters')
print()

print('RECOMMENDATIONS:')
print('- do not use accuracy as the target metric, use recall and')
print('  precision instead, and track them every month')
print('- fix the data collection issues found during validation so')
print('  future data does not have typos, text mixed into number')
print('  columns, or impossible negative counts')
print('- collect more features if possible, the current 3 numeric')
print('  features are not enough to reliably predict breakdowns')
print('- do not rely on the current models yet for staffing or')
print('  purchasing decisions given the low catch rate, treat this as')
print('  a first version and keep improving it as more data comes in')
```
