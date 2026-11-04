/*====================================================================
  RISING KEYWORDS IN FREE TEXT                   Base SAS 9.4 / EG
  ====================================================================
  WHAT IT DOES
  Finds words and two-word phrases that people have suddenly started
  using more (or less) in free-text comments.
  1. Cleans the text (lowercase, no punctuation or numbers) and splits
     it into words and two-word phrases, after removing stop words.
  2. Counts how many RECORDS mention each term per week - so one long
     rant can't dominate, and busy weeks don't inflate every word.
  3. Compares the share of records mentioning each term in the RECENT
     weeks with the BASELINE weeks just before (two-proportion z-test).
  4. Lists and charts the terms that have changed significantly.

  HOW TO RUN IT
  1. Step 0: replace the sample data with your own table (see INPUT
     DATA below), or run the sample first to see the output.
  2. Adjust the settings just below this box.
  3. Add words that appear everywhere in YOUR data to the stop words
     in step 1 (e.g. customer, account, complaint, please).
  4. Run the whole program (F3 in Enterprise Guide).

  ====================================================================
  QUICK REFERENCE - every setting
  ====================================================================

  recent_weeks    How many weeks count as "now". The recent period always
                  ENDS at the latest week in the data (weeks run Monday to
                  Sunday). Default 4.

  baseline_weeks  How many weeks just BEFORE the recent period count as
                  "normal". Default 12. More weeks = steadier baseline,
                  but slower to adapt if the normal mix changes.

  z_cut           How strong a change must be to be flagged (z-score).
                  You're testing thousands of terms at once, so keep this
                  high: 2 flags lots by pure chance, 3 is a sensible
                  default, 4 shows only the strongest changes.

  min_docs        A term needs at least this many recent records to be
                  flagged RISING or NEW (and this many baseline records to
                  be flagged FALLING). Stops one-off typos showing up as
                  trends. Default 10. Raise it for big data sets.

  min_len         Words shorter than this are dropped. Default 3
                  (drops "i", "a", "my", "to"...).

  top_n           How many of the top rising terms appear in the weekly
                  trend chart. Default 6.

  INPUT DATA (step 0) - must end up as table WORK.RAW_TEXT
  --------------------------------------------------------
  id     Unique per record (numeric or text). Used so a record that
         mentions a word twice still counts once.
  date   Numeric SAS date. If yours is a date-time use
         date = datepart(your_column);
  text   The free text (character). Default length 300 - if your
         comments are longer, raise  length text $300  in step 0 AND
         length clean $600  in step 2 (make clean about double).

  STOP WORDS (step 1) - table WORK.STOPWORDS
  ------------------------------------------
  Words to ignore, separated by spaces, between "datalines;" and ";".
  Lowercase, no apostrophes (write dont, not don't). "not" and "no" are
  deliberately kept because "not arrived" carries meaning.

  WHAT THE FLAGS MEAN
  -------------------
  NEW       appears in the recent weeks but not at all in the baseline
  RISING    significantly more common recently than in the baseline
  FALLING   significantly less common recently
  (blank)   no significant change

  COLUMNS IN THE OUTPUT (table WORK.RISING)
  -----------------------------------------
  term              the word or two-word phrase
  type              word or phrase
  Recent mentions   records mentioning it in the recent weeks   (x1)
  Recent share      as a % of all records in the recent weeks
  Baseline mentions records mentioning it in the baseline weeks (x0)
  Baseline share    as a % of all records in the baseline weeks
  lift              recent share / baseline share (3.0 = 3x as common)
  z                 strength of the change (+ rising, - falling)
  flag              NEW / RISING / FALLING

  OTHER OUTPUT TABLES (in WORK)
  -----------------------------
  TOKENS      one row per record per term - handy to find example
              comments:  proc print data=tokens; where term='face id'; run;
  TERM_WEEK   records mentioning each term, per week
  TREND       weekly share for the charted terms
====================================================================*/

%let recent_weeks   = 4;    /* weeks that count as "now" (ending at the latest week) */
%let baseline_weeks = 12;   /* weeks just before that count as "normal"              */
%let min_docs       = 10;   /* fewest records a term needs before it can be flagged  */
%let z_cut          = 3;    /* strength of change needed: 3 = sensible, 4 = strict   */
%let min_len        = 3;    /* drop words shorter than this                          */
%let top_n          = 6;    /* rising terms to show in the trend chart               */

/*--------------------------------------------------------------------
  0. SAMPLE DATA - replace with your table: ID, DATE, TEXT
     (a new login problem appears from June)
--------------------------------------------------------------------*/

/* TO USE YOUR OWN DATA: delete the sample step below and use this
   instead (or build it with the Column mapper on the toolkit page).

data raw_text;
  set mylib.my_table;                 <- your library.table
  length text $300;                   <- raise if comments are longer
  id   = complaint_ref;               <- your unique ID column
  date = datepart(received_dt);       <- your date column (drop datepart()
                                         if it's already a date)
  text = description;                 <- your free-text column
  keep id date text;
run;
*/

data raw_text;
  call streaminit(7);
  length text $300;
  array p[8] $80 _temporary_ (
    "My card was declined at the shop",
    "The app keeps crashing when I open it",
    "Waiting too long on the phone for help",
    "Charged a fee I did not expect",
    "Transfer has not arrived after three days",
    "Staff were rude and unhelpful in branch",
    "Statement shows a payment I don't recognise",
    "Interest rate changed without any notice");
  do date = '01JAN2026'd to '30JUN2026'd;
    if weekday(date) = 1 then continue;              /* closed Sundays */
    n = 20 + ceil(20*rand('uniform'));
    do j = 1 to n;
      text = p[ceil(8*rand('uniform'))];
      if date >= '01JUN2026'd and rand('uniform') < 0.25 then
        text = "Since the app update it logs me out and Face ID login fails!";
      id + 1;
      output;
    end;
  end;
  format date date9.;
  keep id date text;
run;

/*--------------------------------------------------------------------
  1. Stop words - extend with words that are everywhere in YOUR data
     (e.g. customer, bank, account, complaint, please)
     'not' / 'no' are deliberately kept: "not arrived" matters.
--------------------------------------------------------------------*/
data stopwords;
  length word $40;
  input word $ @@;
  datalines;
a about above after again against all also am an and any are as at be
because been before being below between both but by can could did do does
doing down during each few for from further had has have having he her here
hers herself him himself his how i if in into is it its itself just me more
most my myself nor of off on once only or other our ours ourselves out over
own same she should so some such than that the their theirs them themselves
then there these they this those through to too under until up very was we
were what when where which while who whom why will with would you your yours
yourself yourselves dont didnt doesnt cant wont im ive its get got been
since it they them
;
run;

proc sort data=stopwords nodupkey; by word; run;

/*--------------------------------------------------------------------
  2. Tokenise: one row per record per term (words + two-word phrases)
--------------------------------------------------------------------*/
data tokens;
  if _n_ = 1 then do;
    declare hash sw(dataset:'stopwords');
    sw.definekey('word');
    sw.definedone();
  end;

  set raw_text;
  length clean $600 word prev $40 term $81 type $6;
  week = intnx('week.2', date, 0, 'b');              /* Monday-start weeks */
  format week date9.;

  clean = compress(lowcase(text), "'");             /* don't -> dont      */
  clean = prxchange('s/[^a-z]+/ /', -1, clean);      /* punctuation/digits -> space */

  prev = '';
  do i = 1 to countw(clean, ' ');
    word = scan(clean, i, ' ');
    if length(word) < &min_len then continue;
    if sw.check() = 0 then continue;                  /* stop word */

    term = word; type = 'word';   output;
    if prev ne '' then do;
      term = catx(' ', prev, word); type = 'phrase'; output;
    end;
    prev = word;
  end;
  keep id week term type;
run;

/*--------------------------------------------------------------------
  3. Weekly counts
--------------------------------------------------------------------*/
proc sql;
  create table week_docs as
  select intnx('week.2', date, 0, 'b') as week format=date9.,
         count(distinct id) as docs
  from raw_text
  group by 1
  order by 1;

  create table term_week as
  select term, type, week, count(distinct id) as docs_with
  from tokens
  group by term, type, week;
quit;

proc sql noprint;
  select max(week) into :last_week trimmed from week_docs;
quit;

/* NB: if the latest week is incomplete, that's fine - we use shares,
   not raw counts - but very small weeks are noisy */
data _null_;
  recent_start = intnx('week.2', &last_week, -(&recent_weeks - 1), 'b');
  base_start   = intnx('week.2', recent_start, -&baseline_weeks, 'b');
  call symputx('recent_start', recent_start);
  call symputx('base_start',   base_start);
  put 'Baseline from ' base_start date9. ' | Recent from ' recent_start date9.;
run;

/*--------------------------------------------------------------------
  4. Recent vs baseline - two-proportion z-test per term
--------------------------------------------------------------------*/
proc sql;
  create table period_docs as
  select sum(case when week >= &recent_start then docs else 0 end) as n1,
         sum(case when week >= &base_start and week < &recent_start
                  then docs else 0 end)                         as n0
  from week_docs;

  create table term_period as
  select term, type,
         sum(case when week >= &recent_start then docs_with else 0 end) as x1,
         sum(case when week >= &base_start and week < &recent_start
                  then docs_with else 0 end)                         as x0
  from term_week
  group by term, type;
quit;

data rising;
  if _n_ = 1 then set period_docs;
  set term_period;
  length flag $8;

  share_recent   = x1 / n1;
  share_baseline = x0 / n0;
  pooled = (x1 + x0) / (n1 + n0);
  if 0 < pooled < 1 then
    z = (share_recent - share_baseline) /
        sqrt(pooled*(1 - pooled)*(1/n1 + 1/n0));
  if x0 > 0 then lift = share_recent / share_baseline;

  if x1 >= &min_docs and z >= &z_cut then do;
    if x0 = 0 then flag = 'NEW';
    else           flag = 'RISING';
  end;
  else if x0 >= &min_docs and not missing(z) and z <= -&z_cut then flag = 'FALLING';

  format share_recent share_baseline percent8.1 z 6.1 lift 6.1;
run;

proc sort data=rising; by descending z; run;

title "Terms rising significantly (last &recent_weeks weeks vs previous &baseline_weeks)";
proc print data=rising noobs;
  where flag in ('NEW', 'RISING');
  var term type x1 share_recent x0 share_baseline lift z flag;
  label x1 = 'Recent mentions' x0 = 'Baseline mentions'
        share_recent = 'Recent share' share_baseline = 'Baseline share';
run;

title "Terms falling significantly";
proc print data=rising noobs;
  where flag = 'FALLING';
  var term type x1 share_recent x0 share_baseline z;
run;

/*--------------------------------------------------------------------
  5. Weekly trend chart for the top rising terms
     (fills in zero weeks so lines don't skip)
--------------------------------------------------------------------*/
data top_terms;
  set rising(where=(flag in ('NEW', 'RISING')));
  if _n_ > &top_n then stop;
  keep term;
run;

proc sql;
  create table trend as
  select t.term, w.week, w.docs,
         coalesce(c.docs_with, 0) as docs_with,
         calculated docs_with / w.docs as share format=percent8.1
  from top_terms t
       cross join week_docs w
       left join term_week c
         on c.term = t.term and c.week = w.week
  order by t.term, w.week;
quit;

title "Share of records mentioning each rising term, by week";
proc sgplot data=trend;
  series x=week y=share / group=term markers lineattrs=(thickness=2);
  refline &recent_start / axis=x lineattrs=(pattern=dash) label="Recent period";
  yaxis label="Share of records" grid;
  xaxis label="Week starting";
run;
title;
