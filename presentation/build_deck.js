const pptxgen = require('pptxgenjs');
const fs = require('fs');
const p = new pptxgen();
p.layout = 'LAYOUT_16x9';          // 10 x 5.625 in
p.author = 'Nikhil Bansal';
p.title  = 'Scooter Reliability - Fleet Reliability Review';

const CH='36454F', AC='B85042', MU='6B7478', LT='F2F2F2', W='FFFFFF';
const HF='Cambria', BF='Calibri';
const img = f => ({ data: 'image/png;base64,' + fs.readFileSync(f).toString('base64') });

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
s.addText('Nikhil Bansal   |   Data Science   |   Fleet Reliability Review, QuorWatt Urban Mobility',
  { x:0.7, y:4.5, w:8.6, h:0.35, fontFace:BF, fontSize:12, color:'A8B0B5', isTextBox:true, margin:0 });
s.addNotes(
`Good morning, and thanks for making the time.

You asked two things. Which factors most strongly predict a scooter going out of service in the next twenty-four hours. And whether we could predict that with at least ninety percent accuracy.

I have a clear answer to the first. On the second I am going to push back, and I will show you exactly why — because chasing ninety percent would lead us to a model that does nothing useful.

I will also leave you something you can act on immediately, with no model at all.`);

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
`First, the data itself.

Eighteen hundred scooter snapshots. Each row is one scooter, the previous twenty-four hours summarised, and a flag for whether it went out of service in the twenty-four hours after.

I checked every column and found four problems. "Downtown" misspelt on eighteen rows, which would have been read as a sixth, separate zone. Fifty-four rows where the trip count was the text "na" instead of a number, which forced the whole column to be stored as text. Eighteen negative counts of rider-reported issues, which is impossible, so I treated those as sign errors. And seventy-two missing battery readings.

None were fatal, but they will keep recurring until collection is fixed, and I come back to that later.

The chart is the battery health distribution — most of the fleet between eighty and ninety, tailing down to fifty-five.

The most important line is at the bottom. Only twelve point three percent of scooters go out of service. Nearly seven in eight are fine. Hold onto that, because the next slide is about it.`);

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
`This is the most important slide, so let me spend a moment on it.

Look at the left pair of bars. That is a model that does nothing at all — it answers "this scooter is fine" every single time, without ever looking at the data. It scores eighty-seven point eight percent accuracy, because that is simply how often "fine" is the right answer.

Now the red bar beside it. Zero. It catches none of the forty-four scooters that actually broke down.

So we already have a model that is nearly at your target and completely worthless. Pushing it to ninety percent does not improve it — it gets there by guessing "fine" more often, catching even fewer real breakdowns.

That is why accuracy is the wrong target. We did not fail to reach ninety percent. Reaching it would have meant building something that does not help you.

The right pair is our actual model. Accuracy is lower, at fifty-nine percent, and I want to be upfront about that. But it catches twenty-two of the forty-four. That is the trade we made deliberately, and I would make it again.`);

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
`So what did we actually find?

Battery health, by a wide margin. I am confident because we tested it three separate ways — the regression coefficients, the forest's importance scores, and a shuffle test where we scramble one column at a time and measure the damage. All three put battery health first, and trip count second.

The left chart is the clearest view. Split the fleet into five equal groups by battery health. The weakest fifth goes out of service twenty-four percent of the time. The healthiest fifth, five percent. Almost a five-fold difference, and a smooth gradient the whole way down — not one odd group distorting things.

The box plot says the same differently — scooters that failed had noticeably lower median battery health. There is overlap, which is why this is not a perfect predictor, but the gap is real.

One finding surprised me. Rider-reported issues barely help — removing that column entirely does not hurt the model. Service area and scooter model add little, and no hardware family is meaningfully more fragile than the others, which matters if that was feeding the purchasing decision.`);

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
`Here are the two models side by side, with the do-nothing benchmark first for context.

The logistic regression is our baseline — simple and explainable, which matters when you make staffing calls off it. The random forest is the comparison, because it catches patterns a straight line cannot.

Read the middle row, in red. The benchmark catches zero. The regression catches twenty-two of forty-four. The forest, nineteen.

The bottom row measures how well each ranks scooters by risk. Naught point five is a coin flip. Both land near naught point six-five, confirmed by cross-validation across all eighteen hundred rows, because forty-four breakdowns in one test set is a thin basis for any claim.

We recommend the regression. It catches the most, ranks slightly better, and you can interrogate it when someone asks why a scooter was flagged.

I want to be straight about that naught point six-five. It is well above a coin flip, so the signal is real. But it is modest. Good enough to sort the fleet by risk. Not good enough to point at one scooter and promise you it fails tomorrow.`);

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
`If not accuracy, what goes on the dashboard?

Swapping one model statistic for another tells you nothing about your business. So I built the metric around the decision you actually make — how many scooters your technicians can inspect in a day.

The metric is the pre-emptive catch rate. Each morning, rank the fleet by risk, inspect the top ten percent, and measure what share of that day's breakdowns were in that group.

The comparison on the left is the honest one. Today it is zero — maintenance is reactive, so every breakdown is found after the fact, usually by a rider. With the model, at a ten percent budget, it is twenty-three percent.

Ten percent of an eighteen hundred scooter fleet is a hundred and eighty inspections a day. You catch roughly a quarter of breakdowns before they happen, and about one inspection in three and a half finds a real fault. That is two point three times better than inspecting at random.

Report catch rate and hit rate together, always. Catch rate alone pushes you to inspect everything; hit rate alone, almost nothing. The pair keeps the cost trade-off visible.`);

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
`Four recommendations, ordered by how fast you can move.

First, and I would start today: inspect from the bottom of the battery health ranking. You need neither the model nor us for this. Sort by battery health, work upward from the weakest, and you are targeting the group that fails twenty-four percent of the time instead of the fleet average of twelve.

Second, change what you measure. Replace the ninety percent accuracy target with the catch rate and hit rate pair, at whatever budget you can staff. I will be blunt: if the accuracy target stays, it will push whoever picks this up next towards a model that does nothing, because that is what accuracy rewards.

Third, use the model to order the daily queue, but do not size the technician team or the parts order from it yet. A two point three times lift is worth having; it is not precise enough to plan headcount around. I know those decisions are close, and I would rather say that now than have you over-commit.

Fourth, fix the data and capture richer battery telemetry — charge cycles, fault codes, scooter age. Battery health carrying almost all the signal tells us where the next gain is.

The first two cost you nothing.`);

/* ---------------- 8. Close ---------------- */
s = p.addSlide();
s.background = { color: CH };
s.addText('In one line', { x:0.7, y:1.15, w:8.6, h:0.45, fontFace:BF, fontSize:15, color:'A8B0B5', isTextBox:true, margin:0 });
s.addText('We cannot predict which scooter will fail.\nWe can tell you which 10% to look at first.',
  { x:0.7, y:1.75, w:8.6, h:1.3, fontFace:HF, fontSize:26, bold:true, color:W, lineSpacing:38, isTextBox:true, margin:0 });
s.addText('That moves you from catching 0% of breakdowns in advance to roughly 23% — starting with the battery health ranking you already have.',
  { x:0.7, y:3.25, w:8.6, h:0.8, fontFace:BF, fontSize:14, color:'CADCFC', isTextBox:true, margin:0 });
s.addText('Questions', { x:0.7, y:4.45, w:8.6, h:0.4, fontFace:BF, fontSize:15, bold:true, color:W, isTextBox:true, margin:0 });
s.addNotes(
`Let me close with the one sentence worth taking away.

We cannot tell you which scooter will fail tomorrow. The data does not support that, and I would rather say so plainly than dress it up.

What we can tell you is which ten percent to look at first. That moves you from catching zero percent of breakdowns in advance to roughly twenty-three — starting from a battery health ranking that is already in the data you collect today.

That is a real improvement, available now, at no extra cost. And it grows as the data gets richer.

Happy to take questions.`);

p.writeFile({ fileName: 'scooter_reliability_presentation.pptx' }).then(f => console.log('WROTE', f));
