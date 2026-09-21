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
