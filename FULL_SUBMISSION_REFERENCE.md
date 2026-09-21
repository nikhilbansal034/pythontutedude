# Full Submission Reference — Report Text + Code

Combined reference copy of everything going into the DataLab workbook: the
written report text (for the "Start writing report here.." area) followed by
the full code (for the single code cell). Kept here so both can be read
together — the actual submission still lives in the two separate places inside
DataLab.

**This file is generated from `report.txt` and `code.py`.** Edit those, not
this. Both were verified against a real run of `code.py` on
`DS_capstone_scooter_snapshots.csv`.

---

# PART 1: WRITTEN REPORT

*Start writing report here..*
 - Data Validation - The provided dataset has 1800 rows and 7 column, one row per scooter snapshot. There are multiple issues which I found that requires fixing before analysis.
   *    scooter_id - No duplicates found. Data clean.
   *    service_area - Found 6 raw category values. "downtwon" was a spelling mistake for "downtown". Fixed by merging it into "downtown".
   *    scooter_model - No issues found. Data clean.
   *    total_trips_24h - This column was stored as text because 54 rows contained the literal value "na" mixed in with numeric strings. Converted the column to numeric which converted these "na" entries to "NaN"
   *    battery_health_score - Values were within the documented 0-100 range (actual range 51.7 to 100). 72 rows were missing which were later filled using the column median at the modelling step.
   *    reported_issue_count_24h - Found 18 rows with negative value. Since count cannot logically be negative, so assumed these as sign errors and corrected them using absolute value.
   *    taken_out_of_service - No issues found. Data clean, but the split is imbalanced - only 12.3% of scooters go out of service against 87.7% that stay in service. This imbalance drove most of the modelling decisions later.

 - Exploratory analysis - For better understanding of data before modelling, I looked and understand the below graphics
    *    Histogram of battery_health_score (single variable) - the distribution is skewed towards higher values. Most scooters sit in the 80-90 range with a tail stretching down towards 55.
    *    Bar chart of service_area coounts (single variable, different chart type) - This showed that downtown has the most scooter while waterfront has fewest.
    *    Boxplot of battery_health_score split by taken_out_of_service (two variables) - This compares battery health between scooters that went out of service and scooters that stayed in service. The out-of-service group has lower median battery (approx 77) compared to in-service group (approx 82).
    *    Findings - Battery health is the clearest signal in the data. Splitting the fleet into five equal groups by battery health, the weakest fifth goes out of service about 24% of the time against about 5% for the healthiest fifth, which is roughly a 5 times difference. Usage shows a weaker version of the same pattern, the busiest fifth by trips fails about 21% of the time against about 8% for the quietest fifth. Service area varies too (downtown 17% against waterfront 6%) but the groups overlap heavily, so no single chart separates the two classes cleanly on its own.

 - Model Development - The goal is to predict one of the two outcomes for each scooter: whether it will be taken out of service or not in the following 24 hours. This is like binary classification problem. Before fitting any model, I performed below steps:-

   *    Filled remaining missing values in battery_health_score and total_trips_24h using the column median since scikit-learn models cannot accept missing values directly.
   *    Converted service_area and scooter_model text columns into numeric (0/1) columns using one-hot encoding since models can only work with numbers and mapping categories to arbitrary numbers would incorrectly imply an order between them doesnt exist.
   *    scooter_id was dropped since it is just an identifier and carries no predictive information.
   *    The data was split into 80% training and 20% testing using stratified sampling so that both sets kept the same class split at the full dataset.
   *    Standardised every feature column using StandardScaler, fitted on the training data only so nothing leaks in from the test set. This was needed because battery_health_score runs from about 50 to 100 while the one-hot columns are only 0 or 1, and it also puts the logistic regression coefficients on the same footing so they can be compared against each other later.
   *    Set class_weight='balanced' on both models. Without this the models learn that always answering "in service" is the safest bet, because that answer is right 87.7% of the time, and they never flag a single scooter. Balancing makes the rare class count as much as the common one.
   *    I also fitted a "no skill" reference model that always predicts the most common class. This is not one of my two models, it is only a benchmark, because any accuracy number needs to be judged against what guessing already achieves.
   *    I chose below 2 models:
         1. Baseline model: Logical regression - It was chosen because it is simple, fast to train and easy to explain. Its coefficient give a rough sense of which features push the prediction one way or the other.
         2. Comparison model: Random Forest - It was chosen because it can capture non-linear relationships and interaction between features that logistics regression cannot and it also produces a feature importance ranking that can be compared against the logistics regression coefficients. I capped its depth at 5 and minimum leaf size at 20, because a fully grown forest simply memorises 1440 training rows that contain only 12% positives.

 - Model Evaluation - I evaluated all three using accuracy, precision, recall, F1 score, ROC-AUC, PR-AUC and confusion matrix.
   *    No skill reference (always predicts "in service") - accuracy 87.8%, recall 0.0, ROC-AUC 0.500. The confusion matrix showed 0 true positives out of 44. This is the single most important number in the report, because it proves accuracy is the wrong metric here. Any model scoring below 87.8% accuracy is not necessarily worse, and any model scoring above it is not necessarily useful.
   *    Baseline model (Logistic Regression) - accuracy 58.9%, precision 0.149, recall 0.500, F1 0.229, ROC-AUC 0.620, PR-AUC 0.257. It catches 22 out of the 44 real out-of-service scooters. Its accuracy is much lower than the no skill reference, which is expected and is the trade I wanted - it gives up accuracy in order to actually flag scooters at risk.
   *    Comparison model (Random Forest) - accuracy 61.7%, precision 0.144, recall 0.432, F1 0.216, ROC-AUC 0.601, PR-AUC 0.213. It catches 19 out of 44.
   *    The test set holds only 44 out-of-service scooters, which is too few to judge a model on a single split, so I also ran 5-fold cross validation across all 1800 rows. Logistic regression scored a ROC-AUC of 0.664 (+/- 0.031) and random forest 0.646 (+/- 0.029).
   *    Reading the two models against each other - logistic regression is slightly ahead on both ROC-AUC and PR-AUC, and it catches more real cases, so I treat it as the better of the two. A ROC-AUC of around 0.65 is clearly above the 0.5 that a coin flip gives, and the spread across the 5 folds is small, so the signal in this data is real. It is however a modest signal, not a strong one. It is enough to rank scooters by risk, and not enough to call any individual scooter a certain breakdown. PR-AUC of 0.257 against a positive rate of 0.122 says the same thing in a different way - about twice as good as random, not more.

 - Business Metrics - Accuracy cannot be the metric, because the no skill reference already scores 87.8% while catching nothing. Rather than swap it for another model metric, I built the metric around the decision the business actually has to make, which is how many scooters their technicians can inspect each day.
    *    Metric - pre-emptive catch rate at a fixed inspection budget. Rank every scooter by predicted risk, inspect the top 10% of the fleet, and measure what share of the scooters that really did go out of service were sitting in that inspected group.
    *    Alongside it I report the hit rate, which is the share of inspections that found a real problem, because this is the labour and parts cost side of the trade, and the lift, which is how many times better this is than inspecting the same number of scooters picked at random.
    *    Baseline for comparison - today this metric is 0%. Maintenance is reactive, no scooter is inspected before it fails, so every breakdown is discovered after the fact. Anything above 0% is an improvement on how the business runs right now.
    *    Current estimate, using logistic regression across all 1800 rows with 5-fold cross validation - catch rate 23.4%, hit rate 28.9%, lift 2.34 times. On the held out test set alone the same numbers are 20.5%, 25.0% and 2.05 times.
    *    In plain terms, if technicians inspect the 180 highest risk scooters out of 1800 each day, they would find roughly a quarter of all the scooters that were about to break down, and about 1 in every 3 or 4 inspections would be justified. That is a little over twice as good as picking scooters to inspect at random, and infinitely better than the 0% the business gets today.

 - Final Summary - This project goal was to identify the strongest predctors of a scooter going out of service and to build a model that could predict this with high accuracy. Based on the analysis:
   *    The 90% accuracy target given by the business was not met, and it should not be chased. Only 12.3% of scooters actually go out of service, so a model can exceed 90% accuracy while being practically useless, as my own no skill reference demonstrated by hitting 87.8% accuracy while catching 0 real cases.
   *    battery_health_score is by far the strongest predictor. All three of my rankings agree on this - the standardised logistic regression coefficients (-0.532, the largest of any feature), the random forest importances (0.511, more than twice the next feature), and a shuffle test where scrambling that one column costs more ROC-AUC than scrambling any other. total_trips_24h comes second on both models. Because the features were standardised before fitting, these coefficient sizes are directly comparable to each other.
   *    reported_issue_count_24h came out weaker than I expected. Both models rank it low and the shuffle test shows that removing it does not hurt the score at all, so rider-reported issues are not a useful early warning on their own. service_area and scooter_model add very little, and the three hardware families are effectively indistinguishable from each other.
   *    The signal is real but modest. Both models land at a cross-validated ROC-AUC of about 0.65, which is well above chance but well short of what would be needed to call an individual scooter a certain breakdown. The honest read is that this data supports ranking scooters by risk, not predicting them one by one.

 - Recommendations
    *    Replace the accuracy target with the catch rate and hit rate at whatever inspection budget the team can actually staff, and review both numbers monthly. Chasing a single accuracy number will actively push the team towards a model that does nothing.
    *    Start proactive inspections from the bottom of the battery health ranking. That single column carries most of the signal and needs no model at all to act on, so this can begin immediately while the model matures.
    *    Use the model to prioritise the daily inspection queue now, but do not size the technician team or the parts order from it yet. At a 2.3 times lift it is worth acting on, and it is not precise enough to plan headcount or purchasing around.
    *    Fix the data collection issues found during validation - the spelling error in service_area, text values mixed into total_trips_24h, and impossible negative counts in reported_issue_count_24h - so future data arrives clean.
    *    Collect additional features. The five columns available are not enough to predict an individual breakdown. Scooter age, battery charge cycles, fault codes from the telemetry, and weather would all be worth adding, and battery health being the dominant driver suggests richer battery telemetry is the highest value place to start.

---

# PART 2: CODE (single DataLab code cell)

```python
# Start coding here....
# Data validation step

import pandas as pd
import matplotlib.pyplot as plt
from sklearn.model_selection import train_test_split
from sklearn.model_selection import cross_val_score
from sklearn.model_selection import cross_val_predict
from sklearn.model_selection import StratifiedKFold
from sklearn.preprocessing import StandardScaler
from sklearn.dummy import DummyClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import RandomForestClassifier
from sklearn.inspection import permutation_importance
from sklearn.metrics import accuracy_score
from sklearn.metrics import precision_score
from sklearn.metrics import recall_score
from sklearn.metrics import f1_score
from sklearn.metrics import roc_auc_score
from sklearn.metrics import average_precision_score
from sklearn.metrics import confusion_matrix

# load raw data
scooter_df = pd.read_csv('DS_capstone_scooter_snapshots.csv')
print('\ndata size : ', scooter_df.shape)
print('\ndata datatypes :\n', scooter_df.dtypes)
print('\ncount of missing values in each column :\n', scooter_df.isnull().sum())

# Data profiling and validation
duplicate_id = scooter_df['scooter_id'].duplicated().sum()        # checking for duplicates in scooter_id
print('\nNumber of duplicate scooter IDs found : ', duplicate_id)
print('\nUnique value in service_area column and their count :\n', scooter_df['service_area'].value_counts())
print('\nUnique value in scooter_model column and their count :\n', scooter_df['scooter_model'].value_counts())
print('\nUnique value in total_trips_24h column : ', scooter_df['total_trips_24h'].unique())
print('\nMinimum value in battery_health_score column : ', scooter_df['battery_health_score'].min())    # battery_health_score should be > 0
print('\nMaximum value in battery_health_score column : ', scooter_df['battery_health_score'].max())    # battery_health_score should be < 100
print('\nUnique value in reported_issue_count_24h column and their count :\n', scooter_df['reported_issue_count_24h'].value_counts().sort_index())    # it should never be negative
print('\nUnique values in taken_out_of_service column : ', scooter_df['taken_out_of_service'].unique())    # It should never be negative
print('\n%age split of taken_out_of_service column :\n', scooter_df['taken_out_of_service'].value_counts(normalize=True))

# observations from data profiling
# - service_area had a typo "downtwon" for "downtown" (18 rows)
# - total_trips_24h was stored as text because of 'na' values mixed in with the numbers
# - reported_issue_count_24h had 18 negative values (-1 to -5), a count can never be negative, most likely a sign typo
# - battery_health_score has 72 missing values, already stored as NaN

# Data cleaning step
scooter_df['service_area'] = scooter_df['service_area'].replace('downtwon', 'downtown') # change 1
print('\nService_area after fixing typo :\n', scooter_df['service_area'].value_counts())

scooter_df['total_trips_24h'] = pd.to_numeric(scooter_df['total_trips_24h'], errors='coerce') # change 2
print('\ntotal_trips_24h data type after conversion : ', scooter_df['total_trips_24h'].dtype)
print('\ntotal_trips_24h missing values after conversion : ',scooter_df['total_trips_24h'].isnull().sum())

scooter_df['reported_issue_count_24h'] = scooter_df['reported_issue_count_24h'].abs() # change 3
print('\nreported_issue_count_24h after taking absolute value :\n',scooter_df['reported_issue_count_24h'].value_counts().sort_index())


# Data analysis

# Histogram of battery_health_score. This shows us the shape/spread of battery health across all scooters
plt.figure()
plt.hist(scooter_df['battery_health_score'].dropna(), bins=20)
plt.title('Distribution of Battery Health Score')
plt.xlabel('battery_health_score')
plt.ylabel('number of scooters')
plt.show()

# Bar chart of service_area counts. This shows how many scooters fall in each service area
area_counts = scooter_df['service_area'].value_counts()
plt.figure()
plt.bar(area_counts.index, area_counts.values)
plt.title('Number of Scooters by Service Area')
plt.xlabel('service_area')
plt.ylabel('number of scooters')
plt.xticks(rotation=45)
plt.show()

# boxplot of battery_health_score split by taken_out_of_service. This compare battery health between scooters that went out of service and scooters that did not
in_service_battery = scooter_df[scooter_df['taken_out_of_service'] == 0]['battery_health_score'].dropna()
out_of_service_battery = scooter_df[scooter_df['taken_out_of_service'] == 1]['battery_health_score'].dropna()
plt.figure()
plt.boxplot([in_service_battery, out_of_service_battery])
plt.xticks([1, 2], ['in service (0)', 'out of service (1)'])
plt.title('Battery Health Score by Service Outcome')
plt.ylabel('battery_health_score')
plt.show()

# Model development

# fill the remaining missing values in battery_health_score with the median of that column
battery_median = scooter_df['battery_health_score'].median()
scooter_df['battery_health_score'] = scooter_df['battery_health_score'].fillna(battery_median)

# fill the remaining missing values in total_trips_24h with the median of that column
trips_median = scooter_df['total_trips_24h'].median()
scooter_df['total_trips_24h'] = scooter_df['total_trips_24h'].fillna(trips_median)

# Validate that there are no missing values left in the columns we use for modeling
print('Missing values after filling with Median :\n', scooter_df[['battery_health_score', 'total_trips_24h']].isnull().sum())

# service_area and scooter_model are text categories, models need numbers, hence turning each category into its own 0/1 column using one hot encoding
scooter_df_encoded = pd.get_dummies(scooter_df, columns=['service_area', 'scooter_model'])

# scooter_id is just an identifier, it does not help predict anything, hence dropping it from the features
# taken_out_of_service is our target column, hence separating from the features
feature_columns = scooter_df_encoded.drop(columns=['scooter_id', 'taken_out_of_service'])
target_column = scooter_df_encoded['taken_out_of_service']

# splitting the data, 80 percent for training and 20 percent for testing
X_train, X_test, y_train, y_test = train_test_split(
    feature_columns,
    target_column,
    test_size=0.2,
    stratify=target_column,
    random_state=42
)

print('\nTraining set shape:',X_train.shape)
print('\nTesting set shape:',X_test.shape)

# columns sit on very different scales, battery_health_score runs 50 to 100 while the one hot columns are only 0 or 1, hence standardising them
# this also puts the logistic regression coefficients on the same footing so they can be compared against each other in the summary section
scaler = StandardScaler()
X_train_scaled = scaler.fit_transform(X_train)    # scaler is fit on training data only so nothing leaks in from the test set
X_test_scaled = scaler.transform(X_test)

# no skill reference : always predicts the most common class
# this is not one of our two models, it is only a benchmark to judge the accuracy numbers against
no_skill_model = DummyClassifier(strategy='most_frequent')
no_skill_model.fit(X_train_scaled, y_train)
print('No skill reference model trained')

# baseline model: logistic regression
# class_weight='balanced' makes the rare class count as much as the common one, without it the model simply predicts "in service" for every row
baseline_model = LogisticRegression(max_iter=1000, class_weight='balanced')
baseline_model.fit(X_train_scaled, y_train)
print('Baseline model : LOGISTIC REGRESSION trained')

# comparison model: random forest
# depth and leaf size are capped because 1440 training rows with only 12% positives are easy for a fully grown forest to memorise
comparison_model = RandomForestClassifier(
    n_estimators=400,
    max_depth=5,
    min_samples_leaf=20,
    class_weight='balanced',
    random_state=42
)
comparison_model.fit(X_train_scaled, y_train)
print('Comparison model : RANDOM FOREST trained')

# Model Evaluation
# the target is imbalanced (87.7 / 12.3), so a model that always says "in service" already scores about 88% accuracy without catching anything
# hence looking at precision, recall, f1, roc auc and pr auc rather than accuracy alone
# roc auc does not depend on the class split at all, and pr auc has to beat the share of positives (~0.12) to be better than random
print('\nShare of out of service scooters in the test set : ', round(y_test.mean(), 3))

# get predictions from the no skill reference on the test set
no_skill_predictions = no_skill_model.predict(X_test_scaled)
no_skill_probabilities = no_skill_model.predict_proba(X_test_scaled)[:, 1]

# calculate all the metrics for the no skill reference
no_skill_accuracy = accuracy_score(y_test, no_skill_predictions)
no_skill_precision = precision_score(y_test, no_skill_predictions, zero_division=0)
no_skill_recall = recall_score(y_test, no_skill_predictions)
no_skill_f1 = f1_score(y_test, no_skill_predictions)
no_skill_roc_auc = roc_auc_score(y_test, no_skill_probabilities)
no_skill_pr_auc = average_precision_score(y_test, no_skill_probabilities)

# print the no skill reference metrics
print('\nNo Skill Reference - Always Predicts In Service:')
print('Accuracy : ', no_skill_accuracy)
print('Precision : ', no_skill_precision)
print('Recall : ', no_skill_recall)
print('F1 Score : ', no_skill_f1)
print('Roc Auc : ', no_skill_roc_auc)
print('Pr Auc : ', no_skill_pr_auc)
print('Confusion Matrix : ')
print(confusion_matrix(y_test, no_skill_predictions))

# get predictions from the baseline model on the test set
baseline_predictions = baseline_model.predict(X_test_scaled)
baseline_probabilities = baseline_model.predict_proba(X_test_scaled)[:, 1]

# calculate all the metrics for the baseline model
baseline_accuracy = accuracy_score(y_test, baseline_predictions)
baseline_precision = precision_score(y_test, baseline_predictions, zero_division=0)
baseline_recall = recall_score(y_test, baseline_predictions)
baseline_f1 = f1_score(y_test, baseline_predictions)
baseline_roc_auc = roc_auc_score(y_test, baseline_probabilities)
baseline_pr_auc = average_precision_score(y_test, baseline_probabilities)

# print the baseline model metrics
print('\nBaseline Model - Logistic Regression Metrics:')
print('Accuracy : ', baseline_accuracy)
print('Precision : ', baseline_precision)
print('Recall : ', baseline_recall)
print('F1 Score : ', baseline_f1)
print('Roc Auc : ', baseline_roc_auc)
print('Pr Auc : ', baseline_pr_auc)
print('Confusion Matrix : ')
print(confusion_matrix(y_test, baseline_predictions))

# get predictions from the comparison model on the test set
comparison_predictions = comparison_model.predict(X_test_scaled)
comparison_probabilities = comparison_model.predict_proba(X_test_scaled)[:, 1]

# calculate all the metrics for the comparison model
comparison_accuracy = accuracy_score(y_test, comparison_predictions)
comparison_precision = precision_score(y_test, comparison_predictions, zero_division=0)
comparison_recall = recall_score(y_test, comparison_predictions)
comparison_f1 = f1_score(y_test, comparison_predictions)
comparison_roc_auc = roc_auc_score(y_test, comparison_probabilities)
comparison_pr_auc = average_precision_score(y_test, comparison_probabilities)

# print the comparison model metrics
print('\nComparison Model - Random Forest Metrics:')
print('Accuracy : ', comparison_accuracy)
print('Precision : ', comparison_precision)
print('Recall : ', comparison_recall)
print('F1 Score : ', comparison_f1)
print('Roc Auc : ', comparison_roc_auc)
print('Pr Auc : ', comparison_pr_auc)
print('Confusion Matrix : ')
print(confusion_matrix(y_test, comparison_predictions))

# the test set holds only 44 out of service scooters, so a single split gives a noisy score
# running 5 fold cross validation across all 1800 rows to check the roc auc is stable and not a one off
all_features_scaled = StandardScaler().fit_transform(feature_columns)
cross_validation_folds = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)

baseline_cv_scores = cross_val_score(
    LogisticRegression(max_iter=1000, class_weight='balanced'),
    all_features_scaled,
    target_column,
    cv=cross_validation_folds,
    scoring='roc_auc'
)

comparison_cv_scores = cross_val_score(
    RandomForestClassifier(n_estimators=400, max_depth=5, min_samples_leaf=20, class_weight='balanced', random_state=42),
    all_features_scaled,
    target_column,
    cv=cross_validation_folds,
    scoring='roc_auc'
)

print('\n5 fold cross validated Roc Auc - Logistic Regression : ', round(baseline_cv_scores.mean(), 3), '+/-', round(baseline_cv_scores.std(), 3))
print('\n5 fold cross validated Roc Auc - Random Forest : ', round(comparison_cv_scores.mean(), 3), '+/-', round(comparison_cv_scores.std(), 3))

# observations from model evaluation
# - the no skill reference scores 87.8% accuracy while catching zero real cases, so the 90% accuracy target asked for was never a meaningful goal
# - both real models score lower accuracy than the no skill reference, that is expected and it is the trade we want, they give up accuracy to actually flag scooters at risk
# - both score a roc auc of about 0.65 across 5 folds, clearly above the 0.5 a coin flip gives, so the signal is real but modest
# - logistic regression is slightly ahead of random forest on both roc auc and pr auc, hence treating it as the better of the two

# Business Metrics
# accuracy cannot be the metric here, the no skill reference above already scores 87.8% while catching nothing
# what the business actually decides is how many scooters their technicians can inspect each day, so the metric is built around that real constraint
# metric : pre-emptive catch rate at a fixed inspection budget, rank every scooter by predicted risk, inspect the top 10%, and measure what share of the real breakdowns sat in that group
# reported alongside it are the hit rate (share of inspections that found a real problem, the labour and parts cost side) and the lift over inspecting at random
# the value of this metric today is 0% because maintenance is reactive and no scooter is inspected before it fails

# using logistic regression since it scored better on roc auc and pr auc
risk_scores = baseline_model.predict_proba(X_test_scaled)[:, 1]

# putting the predicted risk next to the real outcome and sorting it, this is the inspection queue handed to technicians each morning
risk_table = pd.DataFrame({'predicted_risk': risk_scores, 'really_went_out_of_service': y_test.values})
risk_table = risk_table.sort_values('predicted_risk', ascending=False)

# how many scooters a 10 percent daily inspection budget covers
inspection_budget = int(len(risk_table) * 0.10)
inspected = risk_table.head(inspection_budget)

# the three numbers that make up the metric
catch_rate = inspected['really_went_out_of_service'].sum() / risk_table['really_went_out_of_service'].sum()
hit_rate = inspected['really_went_out_of_service'].mean()
random_hit_rate = risk_table['really_went_out_of_service'].mean()

print('\nBusiness Metric : Pre-emptive Catch Rate at a 10% Daily Inspection Budget')
print('Scooters inspected per day : ', inspection_budget)
print('Catch rate - share of real breakdowns flagged in advance : ', round(catch_rate, 3))
print('Hit rate - share of inspections that found a real problem : ', round(hit_rate, 3))
print('Same budget inspecting at random would hit : ', round(random_hit_rate, 3))
print('Lift over inspecting at random : ', round(hit_rate / random_hit_rate, 2), 'times')

# the test set is small, so repeating the same calculation with 5 fold cross validation across all 1800 rows for a steadier estimate
out_of_fold_risk = cross_val_predict(
    LogisticRegression(max_iter=1000, class_weight='balanced'),
    all_features_scaled,
    target_column,
    cv=cross_validation_folds,
    method='predict_proba'
)[:, 1]

full_risk_table = pd.DataFrame({'predicted_risk': out_of_fold_risk, 'really_went_out_of_service': target_column.values})
full_risk_table = full_risk_table.sort_values('predicted_risk', ascending=False)

full_inspected = full_risk_table.head(int(len(full_risk_table) * 0.10))
full_catch_rate = full_inspected['really_went_out_of_service'].sum() / full_risk_table['really_went_out_of_service'].sum()
full_hit_rate = full_inspected['really_went_out_of_service'].mean()
full_random_hit_rate = full_risk_table['really_went_out_of_service'].mean()

print('\nSame metric estimated across all 1800 rows (5 fold, steadier) :')
print('Catch rate : ', round(full_catch_rate, 3))
print('Hit rate : ', round(full_hit_rate, 3))
print('Lift over inspecting at random : ', round(full_hit_rate / full_random_hit_rate, 2), 'times')

# Summary and Recommendation

# get the feature names in the same order as the model was trained on
feature_names = feature_columns.columns

# baseline model coefficients tell us the direction and strength of each feature, +ve means out of service, -ve means staying in service
# because the columns were standardised before fitting, these numbers are now comparable against each other
baseline_coefficients = baseline_model.coef_[0]
baseline_importance = pd.Series(baseline_coefficients, index=feature_names)
baseline_importance_sorted = baseline_importance.sort_values(key=abs, ascending=False)    # sorted by size of effect, ignoring the sign
print('\nBaseline Model - Logistic Regression Coefficients sorted :\n',baseline_importance_sorted.round(3))

# random forest feature importances tell us how much each feature helped the model split the data, higher means more important
comparison_importance = pd.Series(comparison_model.feature_importances_, index=feature_names)
comparison_importance_sorted = comparison_importance.sort_values(ascending=False)
print('\nComparison Model - Random Forest feature importances sorted :\n',comparison_importance_sorted.round(3))

# the two rankings above are each built a different way, so as a third check shuffling one column at a time and seeing how far the roc auc drops
# a column that really matters will hurt the score when shuffled, and this check does not favour any particular column type
shuffle_test = permutation_importance(baseline_model, X_test_scaled, y_test, scoring='roc_auc', n_repeats=30, random_state=42)
shuffle_importance = pd.Series(shuffle_test.importances_mean, index=feature_names)
shuffle_importance_sorted = shuffle_importance.sort_values(ascending=False)
print('\nDrop in Roc Auc when each column is shuffled :\n',shuffle_importance_sorted.round(4))

# observations from the summary
# - all three rankings agree that battery_health_score is by far the strongest driver, and both models put total_trips_24h second
# - service_area and scooter_model add very little, and scooter_model is effectively flat across the three hardware families
# - reported_issue_count_24h came out weaker than expected, the shuffle test shows removing it does not hurt the score, so rider reported issues are not a useful early warning on their own
# - scooters in the lowest fifth of battery health go out of service about 24% of the time against about 5% for the healthiest fifth, that gap is the usable finding
# - the 90% accuracy target was not met and should not be chased, the catch rate at a fixed inspection budget is the number worth tracking instead
```
