# Start coding here....
# Data validation step

import pandas as pd
import matplotlib.pyplot as plt
from sklearn.model_selection import train_test_split
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score
from sklearn.metrics import precision_score
from sklearn.metrics import recall_score
from sklearn.metrics import f1_score
from sklearn.metrics import roc_auc_score
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

# baseline model: logistic regression
baseline_model = LogisticRegression(max_iter=1000)
baseline_model.fit(X_train, y_train)
print('Baseline model : LOGISTIC REGRESSION trained')

# comparison model: random forest
comparison_model = RandomForestClassifier(random_state=42)
comparison_model.fit(X_train, y_train)
print('Comparison model : RANDOM FOREST trained')

# Model Evaluation
# get predictions from the baseline model on the test set
baseline_predictions = baseline_model.predict(X_test)
baseline_probabilities = baseline_model.predict_proba(X_test)[:, 1]

# calculate all the metrics for the baseline model
baseline_accuracy = accuracy_score(y_test, baseline_predictions)
baseline_precision = precision_score(y_test, baseline_predictions)
baseline_recall = recall_score(y_test, baseline_predictions)
baseline_f1 = f1_score(y_test, baseline_predictions)
baseline_roc_auc = roc_auc_score(y_test, baseline_probabilities)

# print the baseline model metrics
print('\nBaseline Model - Logistic Regression Metrics:')
print('Accuracy : ', baseline_accuracy)
print('Precision : ', baseline_precision)
print('Recall : ', baseline_recall)
print('F1 Score : ', baseline_f1)
print('Roc Auc : ', baseline_roc_auc)
print('Confusion Matrix : ')
print(confusion_matrix(y_test, baseline_predictions))

# get predictions from the comparison model on the test set
comparison_predictions = comparison_model.predict(X_test)
comparison_probabilities = comparison_model.predict_proba(X_test)[:, 1]

# calculate all the metrics for the comparison model
comparison_accuracy = accuracy_score(y_test, comparison_predictions)
comparison_precision = precision_score(y_test, comparison_predictions)
comparison_recall = recall_score(y_test, comparison_predictions)
comparison_f1 = f1_score(y_test, comparison_predictions)
comparison_roc_auc = roc_auc_score(y_test, comparison_probabilities)

# print the comparison model metrics
print('\nComparison Model - Random Forest Metrics:')
print('Accuracy : ', comparison_accuracy)
print('Precision : ', comparison_precision)
print('Recall : ', comparison_recall)
print('F1 Score : ', comparison_f1)
print('Roc Auc : ', comparison_roc_auc)
print('Confusion Matrix : ')
print(confusion_matrix(y_test, comparison_predictions))

# Business Metrics
# Picking the random forest as our recommended model since it is the only one that catches any real out of service cases at all
print('\nRecommended Business Metrics: Recall (Catch Rate), with Precision as a secondary check')

# current estimate of the catch rate using the random forest model
print('Current Catch rate (RECALL) Estimate from Random Forest : ', comparison_recall)

# current estimate of how many flagged scooters are true positives
print('Current Precision Estimate from Random Forest : ', comparison_precision)

# Summary and Recommendation

# get the feature names in the same order as the model was trained on
feature_names = feature_columns.columns

# baseline model coefficients tell us the direction and strength of each feature, +ve means out of service, -ve means staying in service
baseline_coefficients = baseline_model.coef_[0]
baseline_importance = pd.Series(baseline_coefficients, index=feature_names)
baseline_importance_sorted = baseline_importance.sort_values(ascending=False)
print('\nBaseline Model - Logistic Regression Coefficients sorted :\n',baseline_importance_sorted)

# random forest feature importances tell us how much each feature helped the model split the data, higher means more important
comparison_importance = pd.Series(comparison_model.feature_importances_, index=feature_names)
comparison_importance_sorted = comparison_importance.sort_values(ascending=False)
print('\nComparison Model - Random Forest feature importances sorted :\n',comparison_importance_sorted)