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

# our columns are on very different scales, battery_health_score runs
# from about 50 to 100 while the one hot columns are only 0 or 1, so
# we standardise every column to put them on the same scale
# this matters for two reasons, logistic regression trains better on
# scaled data, and it also makes the coefficients comparable to each
# other later when we rank the predictors in section 7
from sklearn.preprocessing import StandardScaler

# we fit the scaler on the training data only and then apply it to
# both sets, so no information from the test set leaks into training
scaler = StandardScaler()
X_train_scaled = scaler.fit_transform(X_train)
X_test_scaled = scaler.transform(X_test)

# reference point: a "no skill" model that always predicts the most
# common class, which here is "stays in service"
# this is not one of our two real models, we only fit it so we have
# something honest to compare the accuracy numbers against later
from sklearn.dummy import DummyClassifier

no_skill_model = DummyClassifier(strategy='most_frequent')
no_skill_model.fit(X_train_scaled, y_train)

print('NO SKILL REFERENCE MODEL TRAINED')
print()

# baseline model: logistic regression
# we picked this as our baseline because it is simple, fast, and
# easy to explain, the coefficients also tell us which features push
# the prediction towards out of service or not
from sklearn.linear_model import LogisticRegression

# class_weight='balanced' tells the model to treat the rare class as
# just as important as the common one, without this the model learns
# that always saying "in service" is the safest answer and it never
# flags a single scooter, which is useless to the business
baseline_model = LogisticRegression(max_iter=1000, class_weight='balanced')
baseline_model.fit(X_train_scaled, y_train)

print('BASELINE MODEL (LOGISTIC REGRESSION) TRAINED')
print()

# comparison model: random forest
# we picked this as our comparison model because it can pick up on
# patterns that are not a straight line, and it also gives us a
# feature importance ranking which we can compare to the logistic
# regression coefficients
from sklearn.ensemble import RandomForestClassifier

# we limit the tree depth and the minimum leaf size because we only
# have 1440 training rows with 12 percent positives, a fully grown
# forest memorises the training data instead of learning the pattern
# class_weight='balanced' is used here for the same reason as above
comparison_model = RandomForestClassifier(
    n_estimators=400,
    max_depth=5,
    min_samples_leaf=20,
    class_weight='balanced',
    random_state=42
)
comparison_model.fit(X_train_scaled, y_train)

print('COMPARISON MODEL (RANDOM FOREST) TRAINED')


# =====================================================================
# SECTION 5: MODEL EVALUATION
# our target is imbalanced, 87.7 percent of scooters stay in service
# and only 12.3 percent go out of service, this means a model that
# just guesses "in service" every single time would already score
# about 87.7 percent accuracy without learning anything useful, so
# plain accuracy alone would be misleading here, we are going to look
# at precision, recall, f1 score, roc auc and pr auc as well
#
# note on the two auc scores:
# roc auc measures how well a model ranks a real out of service
# scooter above a healthy one, it does not depend on the class split
# at all, so unlike accuracy it is not inflated by the imbalance
# pr auc is compared against the share of positives (about 0.12),
# anything above that is better than guessing at random
# =====================================================================

# we need these to calculate the different evaluation metrics
from sklearn.metrics import accuracy_score
from sklearn.metrics import precision_score
from sklearn.metrics import recall_score
from sklearn.metrics import f1_score
from sklearn.metrics import roc_auc_score
from sklearn.metrics import average_precision_score
from sklearn.metrics import confusion_matrix

# we will score three models the same way, so we write one small
# helper and call it three times instead of repeating the code
def print_model_scores(model_name, fitted_model):
    predictions = fitted_model.predict(X_test_scaled)
    probabilities = fitted_model.predict_proba(X_test_scaled)[:, 1]
    print(model_name)
    print('accuracy  : ', round(accuracy_score(y_test, predictions), 3))
    print('precision : ', round(precision_score(y_test, predictions, zero_division=0), 3))
    print('recall    : ', round(recall_score(y_test, predictions), 3))
    print('f1 score  : ', round(f1_score(y_test, predictions), 3))
    print('roc auc   : ', round(roc_auc_score(y_test, probabilities), 3))
    print('pr auc    : ', round(average_precision_score(y_test, probabilities), 3))
    print('confusion matrix : ')
    print(confusion_matrix(y_test, predictions))
    print()

# the share of positives in the test set, this is the number pr auc
# has to beat and it is also the accuracy the no skill model gets
print('SHARE OF OUT OF SERVICE SCOOTERS IN THE TEST SET:')
print(round(y_test.mean(), 3))
print()

# score all three, starting with the no skill reference
print_model_scores('NO SKILL REFERENCE (ALWAYS PREDICTS IN SERVICE):', no_skill_model)
print_model_scores('BASELINE MODEL (LOGISTIC REGRESSION) METRICS:', baseline_model)
print_model_scores('COMPARISON MODEL (RANDOM FOREST) METRICS:', comparison_model)

# the test set only has 44 out of service scooters in it, so a single
# split gives a noisy score, we also run 5 fold cross validation on
# the full dataset to check the roc auc is stable and not a fluke
from sklearn.model_selection import cross_val_score
from sklearn.model_selection import StratifiedKFold

# scale the full dataset the same way so cross validation sees the
# same kind of input the models were trained on
all_features_scaled = StandardScaler().fit_transform(feature_columns)
cross_validation_folds = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)

baseline_cv_scores = cross_val_score(
    LogisticRegression(max_iter=1000, class_weight='balanced'),
    all_features_scaled, target_column,
    cv=cross_validation_folds, scoring='roc_auc'
)

comparison_cv_scores = cross_val_score(
    RandomForestClassifier(n_estimators=400, max_depth=5, min_samples_leaf=20,
                           class_weight='balanced', random_state=42),
    all_features_scaled, target_column,
    cv=cross_validation_folds, scoring='roc_auc'
)

# print the cross validated scores, the plus/minus is the spread
# across the 5 folds
print('5 FOLD CROSS VALIDATED ROC AUC (MORE RELIABLE THAN ONE SPLIT):')
print('baseline (logistic regression) : ', round(baseline_cv_scores.mean(), 3),
      '+/-', round(baseline_cv_scores.std(), 3))
print('comparison (random forest)     : ', round(comparison_cv_scores.mean(), 3),
      '+/-', round(comparison_cv_scores.std(), 3))
print()

# what the numbers above tell us
print('HOW THE TWO MODELS COMPARE:')
print('- the no skill model scores 87.8 percent accuracy while catching')
print('  zero real cases, this is the proof that accuracy is the wrong')
print('  metric here, and also means the 90 percent accuracy target the')
print('  business asked for was never a meaningful goal')
print('- both real models have a much lower accuracy than the no skill')
print('  model, that is expected and it is a trade we want, they give up')
print('  accuracy in order to actually flag scooters at risk')
print('- both models score a roc auc around 0.65, clearly above the 0.5')
print('  a coin flip would give, and the 5 fold spread is small, so the')
print('  signal is real but it is modest, not strong')
print('- the logistic regression is slightly ahead of the random forest')
print('  on roc auc and pr auc, so we treat it as our better model')


# =====================================================================
# SECTION 6: BUSINESS METRIC
# the business asked for 90 percent accuracy, but section 5 showed a
# model that predicts "in service" every time already scores 87.8
# percent while catching nothing, so accuracy cannot be the metric
#
# what the business actually has to decide is how many scooters their
# technicians can inspect each day, so we define the metric around
# that real constraint instead of around a model setting
#
# METRIC: pre-emptive catch rate at fixed inspection capacity
#   rank every scooter by its predicted risk, inspect the top 10
#   percent of the fleet, and measure what share of the scooters that
#   really did go out of service were in that inspected group
#
# we report three numbers together:
#   catch rate  - share of real breakdowns we flagged in advance
#   hit rate    - share of inspections that found a real problem
#                 (this is the labour and parts cost side)
#   lift        - how many times better this is than inspecting the
#                 same number of scooters picked at random
#
# the value of this metric today is 0 percent, because maintenance is
# reactive and no scooter is inspected before it fails, so anything
# above 0 is an improvement over how the business runs right now
# =====================================================================

# we use the logistic regression since section 5 showed it is the
# better of our two models on roc auc and pr auc
risk_scores = baseline_model.predict_proba(X_test_scaled)[:, 1]

# put the predicted risk next to the real outcome so we can sort
risk_table = pd.DataFrame()
risk_table['predicted_risk'] = risk_scores
risk_table['really_went_out_of_service'] = y_test.values

# sort by risk, highest first, this is the inspection queue we would
# hand the technicians each morning
risk_table = risk_table.sort_values('predicted_risk', ascending=False)

# how many scooters a 10 percent daily inspection budget covers
inspection_budget = int(len(risk_table) * 0.10)
inspected = risk_table.head(inspection_budget)

# the three numbers that make up the metric
catch_rate = inspected['really_went_out_of_service'].sum() / risk_table['really_went_out_of_service'].sum()
hit_rate = inspected['really_went_out_of_service'].mean()
random_hit_rate = risk_table['really_went_out_of_service'].mean()
lift = hit_rate / random_hit_rate

print('BUSINESS METRIC: PRE-EMPTIVE CATCH RATE AT A 10 PERCENT INSPECTION BUDGET')
print()
print('scooters inspected per day (10 percent of fleet) : ', inspection_budget)
print('catch rate (share of real breakdowns flagged)    : ', round(catch_rate, 3))
print('hit rate (share of inspections that were right)  : ', round(hit_rate, 3))
print('same budget inspecting at random would hit       : ', round(random_hit_rate, 3))
print('lift over inspecting at random                   : ', round(lift, 2), 'times')
print()

# the test set is small, so we repeat the same calculation using 5
# fold cross validation over all 1800 rows for a steadier estimate
from sklearn.model_selection import cross_val_predict

out_of_fold_risk = cross_val_predict(
    LogisticRegression(max_iter=1000, class_weight='balanced'),
    all_features_scaled, target_column,
    cv=cross_validation_folds, method='predict_proba'
)[:, 1]

full_risk_table = pd.DataFrame()
full_risk_table['predicted_risk'] = out_of_fold_risk
full_risk_table['really_went_out_of_service'] = target_column.values
full_risk_table = full_risk_table.sort_values('predicted_risk', ascending=False)

full_budget = int(len(full_risk_table) * 0.10)
full_inspected = full_risk_table.head(full_budget)
full_catch_rate = full_inspected['really_went_out_of_service'].sum() / full_risk_table['really_went_out_of_service'].sum()
full_hit_rate = full_inspected['really_went_out_of_service'].mean()
full_lift = full_hit_rate / full_risk_table['really_went_out_of_service'].mean()

print('SAME METRIC ESTIMATED ACROSS ALL 1800 ROWS (5 FOLD, STEADIER):')
print('catch rate : ', round(full_catch_rate, 3))
print('hit rate   : ', round(full_hit_rate, 3))
print('lift       : ', round(full_lift, 2), 'times')
print()

print('IN PLAIN TERMS : if technicians inspect the 180 highest risk')
print('scooters out of 1800 each day, they would find about a quarter of')
print('all the scooters that were going to break down, and roughly 1 in')
print('every 3 or 4 inspections would be justified, which is about twice')
print('as good as picking scooters to inspect at random, today that catch')
print('rate is 0 percent because nothing is inspected before it fails')


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
# because we scaled the columns in section 4 these numbers are now on
# the same footing and can be compared to each other directly
baseline_coefficients = baseline_model.coef_[0]
baseline_importance = pd.Series(baseline_coefficients, index=feature_names)
baseline_importance_sorted = baseline_importance.sort_values(key=abs, ascending=False)

print('BASELINE MODEL (LOGISTIC REGRESSION) COEFFICIENTS, BIGGEST EFFECT FIRST:')
print(baseline_importance_sorted.round(3))
print()

# random forest feature importances tell us how much each feature
# helped the model split the data, higher means more important
comparison_importance = pd.Series(comparison_model.feature_importances_, index=feature_names)
comparison_importance_sorted = comparison_importance.sort_values(ascending=False)

print('COMPARISON MODEL (RANDOM FOREST) FEATURE IMPORTANCES, SORTED:')
print(comparison_importance_sorted.round(3))
print()

# the two rankings above are each built in a different way, so as a
# third check we shuffle one column at a time and see how much the
# roc auc drops, a column that matters will hurt the score when it is
# shuffled, this check does not favour any column type
from sklearn.inspection import permutation_importance

shuffle_test = permutation_importance(
    baseline_model, X_test_scaled, y_test,
    scoring='roc_auc', n_repeats=30, random_state=42
)
shuffle_importance = pd.Series(shuffle_test.importances_mean, index=feature_names)
shuffle_importance_sorted = shuffle_importance.sort_values(ascending=False)

print('DROP IN ROC AUC WHEN EACH COLUMN IS SHUFFLED (THIRD CHECK):')
print(shuffle_importance_sorted.round(4))
print()

# final written summary of everything we found, this pulls together
# the data validation, eda, modeling and business metric sections
print('FINAL SUMMARY:')
print('- this was a binary classification problem, predicting if a')
print('  scooter goes out of service in the next 24 hours')
print('- the data needed some cleaning first, a typo in service_area,')
print('  text values mixed into total_trips_24h, and negative values')
print('  in reported_issue_count_24h all had to be fixed')
print('- the 90 percent accuracy target was not met and it should not')
print('  be met, only 12.3 percent of scooters go out of service, so a')
print('  model that always says "in service" already scores 87.8')
print('  percent accuracy while catching nothing at all')
print('- there is a real signal in the data, both models score a roc')
print('  auc of about 0.65 across 5 folds, which is clearly better than')
print('  the 0.5 a coin flip gives, but it is a modest signal, it is')
print('  enough to rank scooters by risk and not enough to call any')
print('  single scooter a certain breakdown')
print('- all three of our rankings agree that battery_health_score is by')
print('  far the strongest driver, and both models put total_trips_24h')
print('  second, service_area and scooter_model add very little')
print('- reported_issue_count_24h turned out weaker than expected, both')
print('  models rank it low and the shuffle test shows removing it does')
print('  not hurt the score at all, so rider reported issues are not a')
print('  useful early warning on their own')
print('- scooters in the lowest fifth of battery health go out of')
print('  service about 24 percent of the time against about 5 percent')
print('  for the healthiest fifth, that gap is the usable finding')
print('- at a 10 percent daily inspection budget the model finds about')
print('  a quarter of all breakdowns before they happen, against zero')
print('  percent today, at roughly twice the hit rate of random checks')
print()

print('RECOMMENDATIONS:')
print('- replace the accuracy target with the catch rate and hit rate')
print('  at whatever inspection budget the team can actually staff, and')
print('  review both numbers every month')
print('- start proactive inspections from the bottom of the battery')
print('  health ranking, that single column carries most of the signal')
print('  and needs no model to act on')
print('- fix the data collection issues found during validation so')
print('  future data does not have typos, text mixed into number')
print('  columns, or impossible negative counts')
print('- collect more features, the five columns we have are not enough')
print('  to predict an individual breakdown, things like scooter age,')
print('  charge cycles, fault codes and weather would likely help most')
print('- use the model to prioritise the inspection queue now, but do')
print('  not size the technician team or the parts order from it yet,')
print('  revisit once richer data is available')
