# Regenerates the five charts used in the deck, from the same data and the same
# plain matplotlib style as code.py. Can be run from anywhere:
#     python3 "datacamp project/presentation/make_charts.py"
import os
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import pandas as pd
import numpy as np

# paths are worked out from where this script sits, not from the current
# directory, so it does not matter which folder you run it from
HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
OUT = os.path.join(HERE, 'charts') + os.sep
CSV = os.path.join(PROJECT, 'DS_capstone_scooter_snapshots.csv')
plt.rcParams.update({'font.size': 13, 'axes.titlesize': 15,
                     'figure.dpi': 200, 'savefig.bbox': 'tight'})
CH = '#36454F'   # charcoal, used for neutral bars
AC = '#B85042'   # terracotta, used to highlight the point being made
MU = '#A8B0B5'   # muted grey, used for the comparison bar

# same load and same cleaning as code.py sections 1 and 2
df = pd.read_csv(CSV)
df['service_area'] = df['service_area'].replace('downtwon', 'downtown')
df['total_trips_24h'] = pd.to_numeric(df['total_trips_24h'], errors='coerce')
df['reported_issue_count_24h'] = df['reported_issue_count_24h'].abs()

# chart 1 - the notebook's histogram, slide 2
plt.figure(figsize=(6, 3.6))
plt.hist(df['battery_health_score'].dropna(), bins=20, color=CH)
plt.title('Distribution of Battery Health Score')
plt.xlabel('battery_health_score')
plt.ylabel('number of scooters')
plt.savefig(OUT + 'c1_hist.png')
plt.close()

# chart 2 - the notebook's boxplot, slide 4
in_service = df[df['taken_out_of_service'] == 0]['battery_health_score'].dropna()
out_service = df[df['taken_out_of_service'] == 1]['battery_health_score'].dropna()
plt.figure(figsize=(5.2, 3.6))
bp = plt.boxplot([in_service, out_service], patch_artist=True,
                 medianprops={'color': 'white', 'linewidth': 2})
bp['boxes'][0].set_facecolor(MU)
bp['boxes'][1].set_facecolor(AC)
plt.xticks([1, 2], ['stayed in service', 'went out of service'])
plt.title('Battery Health by Service Outcome')
plt.ylabel('battery_health_score')
plt.savefig(OUT + 'c2_box.png')
plt.close()

# chart 3 - the accuracy trap, slide 3
# numbers come straight from the model evaluation output in code.py
fig, ax = plt.subplots(figsize=(7, 3.9))
x = np.arange(2)
accuracy = [87.8, 58.9]
caught = [0, 22]
bars_a = ax.bar(x - 0.19, accuracy, 0.38, color=MU, label='Accuracy (%)')
bars_c = ax.bar(x + 0.19, caught, 0.38, color=AC, label='Breakdowns caught (of 44)')
ax.set_xticks(x)
ax.set_xticklabels(['Always guess\n"in service"', 'Our model'])
ax.set_ylim(0, 100)
for r in bars_a:
    ax.text(r.get_x() + r.get_width() / 2, r.get_height() + 2,
            str(r.get_height()) + '%', ha='center', fontweight='bold')
for r in bars_c:
    ax.text(r.get_x() + r.get_width() / 2, r.get_height() + 2,
            str(int(r.get_height())), ha='center', fontweight='bold', color=AC)
ax.legend(frameon=False, loc='upper right')
ax.set_title('High accuracy does not mean a useful model')
# the two bars carry different units, a percentage and a count out of 44, so the
# y axis numbers are hidden on purpose, every bar is labelled with its own value
ax.set_yticks([])
ax.spines['top'].set_visible(False)
ax.spines['right'].set_visible(False)
ax.spines['left'].set_visible(False)
plt.savefig(OUT + 'c3_trap.png')
plt.close()

# chart 4 - the battery health gradient, slide 4
# same five groups code.py prints in the data analysis section
groups = df.groupby(pd.qcut(df['battery_health_score'], 5),
                    observed=True)['taken_out_of_service'].mean() * 100
fig, ax = plt.subplots(figsize=(7, 3.9))
labels = ['weakest\nfifth', '2nd', '3rd', '4th', 'healthiest\nfifth']
bars = ax.bar(labels, groups.values, color=[AC, AC, MU, MU, MU])
for r in bars:
    ax.text(r.get_x() + r.get_width() / 2, r.get_height() + 0.6,
            str(round(r.get_height())) + '%', ha='center', fontweight='bold')
ax.set_ylabel('% taken out of service')
ax.set_ylim(0, 28)
ax.set_title('Battery health is the strongest driver')
ax.spines['top'].set_visible(False)
ax.spines['right'].set_visible(False)
plt.savefig(OUT + 'c4_quintile.png')
plt.close()

# chart 5 - catch rate today against the model, slide 6
# 0% is today's reactive process, 23.4% is the 5 fold estimate from code.py
fig, ax = plt.subplots(figsize=(6.4, 3.9))
values = [0, 23.4]
bars = ax.bar(['Today\n(reactive)', 'With the model\n(inspect top 10%)'],
              values, color=[MU, AC], width=0.5)
for r, v in zip(bars, values):
    ax.text(r.get_x() + r.get_width() / 2, v + 0.8, str(round(v)) + '%',
            ha='center', fontweight='bold', fontsize=17)
ax.set_ylabel('% of breakdowns caught in advance')
ax.set_ylim(0, 30)
ax.set_title('Pre-emptive catch rate')
ax.spines['top'].set_visible(False)
ax.spines['right'].set_visible(False)
plt.savefig(OUT + 'c5_catch.png')
plt.close()

print('charts written to ' + OUT)
