// Regenerates the .pptx. Needs pptxgenjs (npm install pptxgenjs).
// Can be run from anywhere: node "datacamp project/presentation/build_deck.js"
const pptxgen = require('pptxgenjs');
const fs = require('fs');
const path = require('path');

// paths are worked out from where this script sits, not the current directory
const HERE = __dirname;
const PROJECT = path.dirname(HERE);
const p = new pptxgen();
p.layout = 'LAYOUT_16x9';          // 10 x 5.625 in
p.author = 'Nikhil Bansal';
p.title  = 'Scooter Reliability - Fleet Reliability Review';

const CH='36454F', AC='B85042', MU='6B7478', LT='F2F2F2', W='FFFFFF';
const HF='Cambria', BF='Calibri';
const img = f => ({ data: 'image/png;base64,' + fs.readFileSync(path.join(HERE, 'charts', f)).toString('base64') });

// title helper - no accent line, just whitespace
function head(s, t, sub) {
  s.addText(t, { x:0.5, y:0.32, w:9.0, h:0.55, fontFace:HF, fontSize:30, bold:true, color:CH, isTextBox:true, margin:0 });
  if (sub) s.addText(sub, { x:0.5, y:0.92, w:9.0, h:0.34, fontFace:BF, fontSize:14, color:MU, isTextBox:true, margin:0 });
}
function foot(s, n) {
  s.addText(String(n), { x:9.3, y:5.15, w:0.4, h:0.28, fontFace:BF, fontSize:10, color:MU, align:'right', isTextBox:true, margin:0 });
}

/* ---------------- 1. Title ---------------- */
let s = p.addSlide();
s.background = { color: CH };
s.addText('Reducing Scooter Downtime', { x:0.7, y:1.5, w:8.6, h:0.8, fontFace:HF, fontSize:40, bold:true, color:W, isTextBox:true, margin:0 });
s.addText('What actually predicts a scooter going out of service — and what to do about it',
  { x:0.7, y:2.4, w:8.6, h:0.6, fontFace:BF, fontSize:16, color:'CADCFC', isTextBox:true, margin:0 });
s.addText('Nikhil Bansal',
  { x:0.7, y:4.5, w:8.6, h:0.35, fontFace:BF, fontSize:12, color:'A8B0B5', isTextBox:true, margin:0 });
s.addNotes(
`Good morning. I am Nikhil, from the data science team.

The Fleet Reliability Team asked for two things. First, identify the strongest predictors of a scooter being taken out of service in the twenty-four hours after a snapshot. Second, predict that outcome with at least ninety percent accuracy.

I can answer the first clearly. On the second, I am going to recommend a different target, and I will show you the evidence for that.

I will cover the data and its quality, why the accuracy target is the wrong one, what actually drives failures, how the two models compare, the metric I recommend instead, and four recommendations.`);

/* ---------------- 2. The data ---------------- */
s = p.addSlide();
head(s, 'What we were working with', '1,800 scooter snapshots  ·  five usable features  ·  one 24-hour window');
s.addImage({ ...img('c1_hist.png'), x:5.15, y:1.45, w:4.35, h:2.6 });
const rows = [
  ['Spelling error', '"downtwon" merged into "downtown" (18 rows)'],
  ['Text in a number column', '54 rows held "na" — converted to missing'],
  ['Impossible values', '18 negative issue counts — sign errors, corrected'],
  ['Missing readings', '72 battery scores absent — filled with the median'],
];
s.addText('Four data quality problems found and fixed', { x:0.5, y:1.45, w:4.4, h:0.3, fontFace:BF, fontSize:14, bold:true, color:CH, isTextBox:true, margin:0 });
rows.forEach((r,i) => {
  s.addText(r[0], { x:0.5, y:1.92+i*0.66, w:4.4, h:0.26, fontFace:BF, fontSize:13, bold:true, color:AC, isTextBox:true, margin:0 });
  s.addText(r[1], { x:0.5, y:2.17+i*0.66, w:4.4, h:0.42, fontFace:BF, fontSize:12, color:CH, isTextBox:true, margin:0 });
});
s.addText('Only 12.3% of scooters go out of service. That imbalance shaped every decision that follows.',
  { x:0.5, y:4.70, w:8.6, h:0.35, fontFace:BF, fontSize:13, italic:true, color:MU, isTextBox:true, margin:0 });
foot(s,2);
s.addNotes(
`First, the data.

Eighteen hundred scooter snapshots. Each row is one scooter: trips, battery health and rider-reported issues over the previous twenty-four hours, plus service area and hardware model. The target is whether it went out of service in the twenty-four hours that followed - so this is a binary classification problem.

I validated every column against the data dictionary first, and found four problems.

"Downtown" was misspelt on eighteen rows, which would have been read as a sixth, separate service area. Fifty-four rows had the text "na" where the trip count should be, which forced the whole column to be stored as text instead of numbers. Eighteen rows had a negative count of rider-reported issues, which is not possible, so I treated those as sign errors and took the absolute value. And seventy-two battery readings were missing, which I filled with the column median at the modelling step.

The chart is the battery health distribution - most of the fleet between eighty and ninety, tailing down to fifty-five.

The line at the bottom matters most. Only twelve point three percent of scooters go out of service. The next slide is about what that does to the accuracy target.`);

/* ---------------- 3. The accuracy trap ---------------- */
s = p.addSlide();
head(s, 'Why we are not chasing 90% accuracy', 'A model can beat the target and still be worthless');
s.addImage({ ...img('c3_trap.png'), x:0.55, y:1.35, w:5.7, h:3.18 });
s.addText('The trap', { x:6.52, y:1.45, w:2.98, h:0.3, fontFace:BF, fontSize:15, bold:true, color:AC, isTextBox:true, margin:0 });
s.addText([
  { text:'A model that says "in service" for every single scooter is right 87.8% of the time.', options:{ bullet:true, breakLine:true } },
  { text:'It catches zero breakdowns. It is useless.', options:{ bullet:true, breakLine:true } },
  { text:'Push it to 90% and it gets worse, not better — it just guesses "fine" more often.', options:{ bullet:true, breakLine:false } },
], { x:6.52, y:1.85, w:2.98, h:2.0, fontFace:BF, fontSize:12.5, color:CH, isTextBox:true, margin:0, paraSpaceAfter:8 });
s.addText('So we optimised for breakdowns caught, and accepted lower accuracy to get there.',
  { x:6.52, y:3.85, w:2.98, h:0.8, fontFace:BF, fontSize:12.5, bold:true, color:CH, isTextBox:true, margin:0 });
foot(s,3);
s.addNotes(
`This is the central slide, so I will spend a moment here.

The left pair of bars is a model that does nothing. It answers "this scooter is fine" every time, without looking at the data at all. It scores eighty-seven point eight percent accuracy, because that is simply how often "fine" is the correct answer when only twelve percent of scooters fail.

The red bar beside it is zero. It catches none of the forty-four scooters that actually broke down in the test set.

So a model that is almost at your ninety percent target is completely useless. And pushing it to ninety would make it worse, not better - it gets there by answering "fine" more often, which means catching even fewer real breakdowns.

The technical reason is class imbalance: accuracy is dominated by the majority class. The fix is to tell the model that the rare class matters as much as the common one - in scikit-learn, the balanced class weight setting. Without it, both of my models predicted "in service" for every single row.

The right pair is the result. Accuracy drops to fifty-nine percent, which looks worse by that measure, but it catches twenty-two of the forty-four. That is a deliberate trade.`);

/* ---------------- 4. What predicts failure ---------------- */
s = p.addSlide();
head(s, 'Battery health is the strongest driver', 'Consistent across all three ways we measured it');
s.addImage({ ...img('c4_quintile.png'), x:0.5, y:1.35, w:5.5, h:3.07 });
s.addImage({ ...img('c2_box.png'), x:6.2, y:1.35, w:3.3, h:2.28 });
s.addText('Trip count comes second. Rider-reported issues, service area and scooter model add very little.',
  { x:6.2, y:3.75, w:3.3, h:0.85, fontFace:BF, fontSize:12, color:CH, isTextBox:true, margin:0 });
s.addText('Weakest fifth of the fleet fails 24% of the time. Healthiest fifth, 5%. Nearly a 5x difference.',
  { x:0.5, y:4.55, w:5.5, h:0.45, fontFace:BF, fontSize:12.5, bold:true, color:AC, isTextBox:true, margin:0 });
foot(s,4);
s.addNotes(
`So what drives failures?

Battery health, by a clear margin. I tested this three ways rather than trusting one: the standardised logistic regression coefficients, the random forest's feature importances, and a permutation test where I shuffle one column at a time and measure how much the model's ranking ability degrades. All three rank battery health first and trip count second.

I standardised the features before fitting. Without that, the coefficients sit on different scales and cannot be compared against each other.

The left chart is the clearest view. Split the fleet into five equal groups by battery health. The weakest fifth goes out of service twenty-four percent of the time; the healthiest fifth, five percent. Close to a five-fold difference, and a smooth gradient the whole way down.

The box plot shows the same relationship - scooters that failed had a lower median battery health, around seventy-seven against eighty-two. The distributions overlap, which is why this is not a perfect predictor, but the separation is real.

One result went against expectation. Rider-reported issues add almost nothing; removing that column does not hurt the model. Service area and hardware model contribute very little, and no scooter family is meaningfully more failure-prone than the others, which is relevant to the purchasing decision.`);

/* ---------------- 5. The models ---------------- */
s = p.addSlide();
head(s, 'How the two models compare', 'Both trained on 1,440 scooters, tested on 360 held back');
const tbl = [
  [{text:'',options:{fill:W}},{text:'No-skill\nbenchmark',options:{bold:true,align:'center'}},{text:'Logistic Regression\n(baseline)',options:{bold:true,align:'center'}},{text:'Random Forest\n(comparison)',options:{bold:true,align:'center'}}],
  ['Accuracy',{text:'87.8%',options:{align:'center'}},{text:'58.9%',options:{align:'center'}},{text:'61.7%',options:{align:'center'}}],
  [{text:'Breakdowns caught (of 44)',options:{bold:true}},{text:'0',options:{align:'center',color:AC,bold:true}},{text:'22',options:{align:'center',color:AC,bold:true}},{text:'19',options:{align:'center',color:AC,bold:true}}],
  ['Ranking quality (ROC-AUC)',{text:'0.50',options:{align:'center'}},{text:'0.66',options:{align:'center'}},{text:'0.65',options:{align:'center'}}],
];
s.addTable(tbl, { x:0.5, y:1.5, w:9.0, colW:[3.0,2.0,2.0,2.0], rowH:0.52,
  fontFace:BF, fontSize:13, color:CH, border:{type:'solid',color:'DDDDDD',pt:1}, fill:{color:LT}, valign:'middle' });
s.addText('We recommend the logistic regression. It catches the most real breakdowns, ranks risk slightly better, and is simple enough to explain to anyone.',
  { x:0.5, y:3.85, w:9.0, h:0.5, fontFace:BF, fontSize:13, bold:true, color:CH, isTextBox:true, margin:0 });
s.addText('A ranking score of 0.50 is a coin flip. 0.66 is a real signal, but a modest one — good enough to sort scooters by risk, not good enough to call any single scooter a certain breakdown.',
  { x:0.5, y:4.45, w:9.0, h:0.6, fontFace:BF, fontSize:12, italic:true, color:MU, isTextBox:true, margin:0 });
foot(s,5);
s.addNotes(
`Here are the two models, with the do-nothing benchmark in the first column for reference.

On method: I split the data eighty-twenty, stratified so both halves keep the same twelve point three percent failure rate. Fourteen hundred and forty scooters to train on, three hundred and sixty held back.

The baseline is logistic regression - simple and explainable, which matters when someone asks why a scooter was flagged. The comparison is a random forest, which captures non-linear patterns a straight line cannot. I capped its depth, because a fully grown forest memorises fourteen hundred rows rather than learning from them.

The middle row, in red, is the one that matters. The benchmark catches zero. Logistic regression catches twenty-two of forty-four. The forest, nineteen.

The bottom row is ROC-AUC, which measures how well each model ranks scooters by risk. Zero point five is a coin flip. Both land near zero point six-five, confirmed with five-fold cross-validation across all eighteen hundred rows, because forty-four failures in one test set is too small a sample to conclude from.

I recommend the logistic regression - it catches the most and ranks marginally better.

On that zero point six-five: clearly above chance, so the signal is real, but modest. Enough to rank the fleet by risk. Not enough to say a specific scooter will fail tomorrow.`);

/* ---------------- 6. The metric ---------------- */
s = p.addSlide();
head(s, 'The metric to track from here', 'Built around your real constraint: how many scooters a technician can inspect');
s.addImage({ ...img('c5_catch.png'), x:0.5, y:1.4, w:5.0, h:3.05 });
s.addText('Pre-emptive catch rate', { x:5.82, y:1.45, w:3.68, h:0.32, fontFace:BF, fontSize:15, bold:true, color:AC, isTextBox:true, margin:0 });
s.addText('Rank the fleet by risk each morning, inspect the top 10%, and measure what share of that day\'s breakdowns you caught before they happened.',
  { x:5.82, y:1.83, w:3.68, h:0.95, fontFace:BF, fontSize:12.5, color:CH, isTextBox:true, margin:0 });
[['180','scooters inspected per day'],['23%','of breakdowns caught first'],['29%','of inspections find a real fault'],['2.3x','better than random checks']].forEach((r,i)=>{
  s.addText(r[0], { x:5.82, y:2.92+i*0.53, w:0.85, h:0.42, fontFace:HF, fontSize:19, bold:true, color:CH, isTextBox:true, margin:0 });
  s.addText(r[1], { x:6.77, y:3.0+i*0.53, w:2.73, h:0.36, fontFace:BF, fontSize:11.5, color:MU, isTextBox:true, margin:0 });
});
foot(s,6);
s.addNotes(
`So if not accuracy, what should you track?

Swapping one model statistic for another tells you nothing about the business, so I built the metric around the decision you actually make: how many scooters your technicians can inspect in a day.

The metric is the pre-emptive catch rate. Each morning, rank the fleet by predicted risk, inspect the top ten percent, and measure what share of that day's breakdowns were in the group you inspected.

The comparison on the left is the honest baseline. Today it is zero percent - maintenance is reactive, so every breakdown is found after it happens, usually by a rider. With the model, at a ten percent inspection budget, it is twenty-three percent.

In operational terms: ten percent of an eighteen hundred scooter fleet is a hundred and eighty inspections a day. You would catch roughly a quarter of breakdowns before they occur, and about one inspection in three and a half would find a real fault - two point three times better than inspecting at random. These figures are cross-validated across the full dataset.

Report catch rate and hit rate together. Catch rate alone pushes you to inspect everything; hit rate alone, almost nothing. The pair keeps labour and parts cost visible against the downtime saved.`);

/* ---------------- 7. Recommendations ---------------- */
s = p.addSlide();
head(s, 'What we recommend', 'Ordered by how quickly you can act');
const recs = [
  ['1','Start inspecting from the bottom of the battery ranking','This needs no model at all. Sort the fleet by battery health and work upward. You can start Monday.'],
  ['2','Replace the accuracy target with catch rate and hit rate','Review both monthly, at whatever inspection budget you can staff. Chasing accuracy pushes us towards a model that does nothing.'],
  ['3','Use the model to order the daily queue — not to size the team','A 2.3x lift is worth acting on. It is not precise enough to set headcount or parts orders against.'],
  ['4','Fix the data collection issues, and capture richer battery telemetry','Charge cycles, fault codes and scooter age. Battery health dominating tells us where the next gain is.'],
];
recs.forEach((r,i)=>{
  const y = 1.42 + i*0.92;
  s.addShape(p.ShapeType.ellipse, { x:0.5, y:y, w:0.42, h:0.42, fill:{color: i<2 ? AC : CH} });
  s.addText(r[0], { x:0.5, y:y, w:0.42, h:0.42, fontFace:BF, fontSize:14, bold:true, color:W, align:'center', valign:'middle', isTextBox:true, margin:0 });
  s.addText(r[1], { x:1.12, y:y-0.04, w:8.36, h:0.3, fontFace:BF, fontSize:14, bold:true, color:CH, isTextBox:true, margin:0 });
  s.addText(r[2], { x:1.12, y:y+0.26, w:8.36, h:0.48, fontFace:BF, fontSize:11.5, color:MU, isTextBox:true, margin:0 });
});
s.addText('The first two cost nothing and can begin immediately.',
  { x:0.5, y:4.86, w:8.6, h:0.35, fontFace:BF, fontSize:12.5, italic:true, bold:true, color:AC, isTextBox:true, margin:0 });
foot(s,7);
s.addNotes(
`Four recommendations, ordered by how quickly you can act.

First, start today: inspect from the bottom of the battery health ranking. This needs no model. Sort the fleet by battery health and work upward from the weakest, and you are targeting a group that fails twenty-four percent of the time instead of the fleet average of twelve.

Second, replace the ninety percent accuracy target with catch rate and hit rate, at whatever inspection budget you can staff, reviewed monthly. If the accuracy target stays, it will push whoever works on this next toward a model that does nothing, because that is what accuracy rewards on imbalanced data.

Third, use the model to order the daily inspection queue, but do not size the technician team or the parts order from it yet. A two point three times lift is worth acting on; it is not precise enough to plan headcount against, and I know those decisions are close.

Fourth, fix the collection issues I showed earlier, and capture richer battery telemetry - charge cycles, fault codes, and scooter age. Battery health carrying most of the signal tells us where the next improvement will come from.

To close. We cannot tell you which scooter will fail tomorrow; the data does not support that. We can tell you which ten percent to inspect first, which moves you from catching zero percent of breakdowns in advance to roughly twenty-three, using data you already collect.

Thank you. Happy to take questions.`);

p.writeFile({ fileName: path.join(PROJECT, 'scooter_reliability_presentation.pptx') }).then(f => console.log('WROTE', f));
