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
