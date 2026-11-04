/*====================================================================
  VOLUME DEVIATION MONITOR                       Base SAS 9.4 / EG
  ====================================================================
  WHAT IT DOES
  Spots days, weeks and months where volume is unusually high or low.
  For each period it works out "normal" from a baseline of EARLIER
  periods (their mean and standard deviation) and flags anything more
  than K standard deviations away. A period is never part of its own
  baseline, so a spike can't hide by raising the bar.

  HOW TO RUN IT
  1. Step 0: replace the sample data with your own table (keep the
     column names DATE and VOLUME - see INPUT DATA below), or run the
     sample first to see what the output looks like.
  2. Set K, START_DATE and END_DATE just below this box.
  3. Add your bank holidays in step 1 if your data goes beyond 2026.
  4. Edit the %volume_check calls in step 4 (the bottom of the program).
  5. Run the whole program (F3 in Enterprise Guide).

  ====================================================================
  QUICK REFERENCE - every setting and argument
  ====================================================================

  SETTINGS AT THE TOP (apply to every check)
  ------------------------------------------
  k           How many standard deviations from normal counts as unusual.
                2    sensitive: about 1 in 20 normal periods gets flagged
                2.5  middle ground
                3    strong signals only: about 1 in 370 normal periods
              Default 2. Decimals are fine.

  start_date  Ignore data before this date. Write it like 01JAN2025.
              Blank = from the start of the file.
  end_date    Ignore data after this date. Write it like 30JUN2026.
              Blank = to the end of the file.
              NB the date range limits the baseline history too, so start
              about one baseline-length before the dates you care about.

  INPUT DATA (step 0) - must end up as table WORK.RAW
  ---------------------------------------------------
  date        Numeric SAS date. If yours is a date-time (e.g.
              02NOV2026:09:15:00) use  date = datepart(your_column);
  volume      Numeric. If each row is one item, use  volume = 1;
  <groups>    Optional extra columns to split by (product, channel, team...).
              Keep their own names and use them in views= .

  BANK HOLIDAYS (step 1) - table WORK.HOLIDAYS
  --------------------------------------------
  One date per line, like 25DEC2026. These days are left out of the
  daily check (so they don't flag as LOW) and don't count as open days
  in the monthly check. England & Wales 2025-26 are filled in.

  %volume_check( period=, baseline=, views=, min_obs=, charts=, tables= )
  -----------------------------------------------------------------------
  period=    REQUIRED. Which period(s) to check.
               DAY    each Mon-Sat day vs the SAME weekday (Mondays vs
                      Mondays...), plus a check that Sundays are zero
               WEEK   Monday-to-Sunday weeks, labelled by the Monday
               MONTH  calendar months, compared as AVERAGE PER OPEN DAY
                      (open day = Mon-Sat, not a bank holiday) so short
                      months don't look low
               ALL    all three - same as  DAY | WEEK | MONTH
             You can list several, separated by | , e.g.  DAY | WEEK
             DAILY / WEEKLY / MONTHLY are accepted too.

  baseline=  How much EARLIER history counts as "normal".
               ALL    every earlier period in the date range
                      (the baseline grows as time goes on)
               90D    the previous 90 days    (any number + D)
               26W    the previous 26 weeks   (any number + W)
               12M    the previous 12 months  (any number + M)
               2Y     the previous 2 years    (any number + Y)
             One value is used for every period in period=.
             A list gives one per period, in the same order:
               period=ALL, baseline=90D | 26W | 12M
             Blank = 56D for DAY, 12W for WEEK, 12M for MONTH.
             Tip: match the span to the period. 90D is plenty for DAY
             (about 13 earlier Mondays) but gives MONTH only ~3 months.
             Use a rolling span if volumes drift over time; use ALL if
             they're stable and you want the steadiest baseline.

  views=     Which splits to run, separated by | . Each view is checked
             separately, with its own baseline for every group in it.
               ALL               straight totals (everything together)
               product           each product vs its own history
               channel           each channel vs its own history
               product channel   each product/channel combination
             Use any column names from your data (max two per view is
             sensible - small groups are noisy). Blank = ALL.

  min_obs=   How many earlier periods the baseline must contain before
             anything can be flagged. Until then the period shows WARMUP.
             One value, or one per period in the same order:  4 | 6 | 6
             Blank = 4 for DAY, 6 for WEEK and MONTH. Minimum sensible: 3.

  charts=    Y  a chart per group: volume vs the shaded expected range,
                with markers on flagged periods                (default)
             N  no charts

  tables=    Y  a full table of every period, HIGH rows red, LOW rows
                purple, WARMUP rows grey                       (default)
             N  no full tables

  The KEY OBSERVATIONS table (flagged periods, worst first) is always
  printed - those are the urgent call-outs.

  EXAMPLES
    %volume_check(period=ALL);
        day, week and month with default baselines, totals only
    %volume_check(period=ALL, baseline=ALL);
        all three, each compared with all earlier history
    %volume_check(period=ALL, baseline=90D | 26W | 12M,
                  views=ALL | product | channel | product channel);
        the lot: every period, every view
    %volume_check(period=DAY, baseline=90D, views=product, charts=N);
        daily by product, no charts
    %volume_check(period=WEEK | MONTH, baseline=ALL, tables=N, min_obs=8);
        weeks and months vs all history, need 8 periods before flagging

  %flag_summary;
  --------------
  No arguments. Run it once after your %volume_check calls. Prints every
  call-out from the whole run (most recent first) and a count of HIGH,
  LOW and SUNDAY flags by period, view and group.

  WHAT THE FLAGS MEAN
  -------------------
  HIGH     above the expected range (mean + k x SD)
  LOW      below the expected range (mean - k x SD)
  SUNDAY   volume on a Sunday - Sundays should be zero
  OK       inside the expected range
  WARMUP   not enough earlier periods yet to judge (see min_obs=)

  COLUMNS IN THE OUTPUT
  ---------------------
  Expected        mean of the baseline
  Expected low    mean - k x SD (shown as 0 if it would be negative)
  Expected high   mean + k x SD
  vs expected     % difference from the expected value
  z-score         how many SDs from expected (+ above, - below)
  Periods in baseline   how many earlier periods the baseline used

  OUTPUT TABLES (in WORK - open them in EG to sort and filter)
  ------------------------------------------------------------
  ALL_FLAGS       every call-out from every check in this run, with
                  period_type, baseline, level (the view), group_name,
                  date, volume, mean, lower, upper, pct_diff, z,
                  severity (size of z), baseline_n and flag.
                  Emptied at the start of each run.
  DAILY_FLAGS     every period with its expected range, for the LAST
  WEEKLY_FLAGS    view run of each period - handy for checking one
  MONTHLY_FLAGS   group in detail.
====================================================================*/

%let k = 2;              /* standard deviations that count as unusual  */

/* DATE RANGE - write dates like 01JAN2025. Blank = no limit.          */
%let start_date = ;      /* ignore data before this date                */
%let end_date   = ;      /* ignore data after this date                 */


/*--------------------------------------------------------------------
  0. SAMPLE DATA - replace with your own table (see the toolkit page).
     One row per day per product per channel, with a VOLUME.
     Planted problems sit in particular product/channel combinations.
--------------------------------------------------------------------*/

/* TO USE YOUR OWN DATA: delete the sample step below and use this
   instead (or build it with the Column mapper on the toolkit page).

data raw;
  set mylib.my_table;                 <- your library.table
  date   = datepart(created_dt);      <- your date column (drop datepart()
                                         if it's already a date)
  volume = 1;                         <- 1 per row, or your count column
  format date date9.;
  keep date volume product channel;   <- add your group columns here
run;
*/

data raw;
  call streaminit(42);
  length product $10 channel $6;
  array prod[3] $10 _temporary_ ('Cards', 'Loans', 'Mortgages');
  array base[3]     _temporary_ (500, 300, 200);
  array chan[2] $6  _temporary_ ('Phone', 'Online');
  array share[2]    _temporary_ (0.4, 0.6);

  do date = '01JAN2025'd to '30JUN2026'd;       /* 18 months of history */
    select (weekday(date));                       /* 1=Sun ... 7=Sat */
      when (1)  dayfactor = 0;                    /* Sunday: closed  */
      when (7)  dayfactor = 0.3;                  /* quiet Saturday  */
      otherwise dayfactor = 1;
    end;
    if '01APR2026'd <= date <= '30APR2026'd then
      dayfactor = dayfactor * 1.15;               /* planted busy month */

    do p = 1 to 3;
      do c = 1 to 2;
        product = prod[p];
        channel = chan[c];
        expected = base[p] * share[c] * dayfactor;
        if expected > 0 then volume = rand('poisson', expected);
        else volume = 0;

        /* planted problems */
        if date = '17MAR2026'd and product = 'Cards' and channel = 'Phone'
          then volume = volume + 400;             /* spike */
        if date = '02MAY2026'd and product = 'Loans' and channel = 'Online'
          then volume = round(volume * 0.2);      /* drop  */
        if date = '15MAR2026'd and product = 'Mortgages' and channel = 'Online'
          then volume = 40;                       /* Sunday activity */
        output;
      end;
    end;
  end;
  format date date9.;
  keep date product channel volume;
run;

/*--------------------------------------------------------------------
  1. One-off setup: date filter, holidays, calendar, open days per month
--------------------------------------------------------------------*/
data _null_;
  length s e $40;
  s = strip(symget('start_date'));
  e = strip(symget('end_date'));
  sd = '01JAN1900'd;
  ed = '31DEC2999'd;
  if s ne '' then do;
    sd = input(s, ?? date11.);
    if missing(sd) then do;
      put 'ERROR: start_date "' s '" not recognised - write it like 01JAN2025. No start limit applied.';
      sd = '01JAN1900'd;
    end;
  end;
  if e ne '' then do;
    ed = input(e, ?? date11.);
    if missing(ed) then do;
      put 'ERROR: end_date "' e '" not recognised - write it like 30JUN2026. No end limit applied.';
      ed = '31DEC2999'd;
    end;
  end;
  call symputx('sd_num', sd);
  call symputx('ed_num', ed);
run;

/* Bank holidays / closure days - excluded from the daily check and from
   the monthly open-day count. England & Wales dates; add your own. */
data holidays;
  input date :date9.;
  format date date9.;
  datalines;
01JAN2025
18APR2025
21APR2025
05MAY2025
26MAY2025
25AUG2025
25DEC2025
26DEC2025
01JAN2026
03APR2026
06APR2026
04MAY2026
25MAY2026
;
run;

data raw_g;                     /* filtered data + dummy group for the ALL view */
  set raw;
  where &sd_num <= date <= &ed_num;
  length _all_ $3;
  _all_ = 'All';
run;

proc sql noprint;
  select min(date), max(date), count(*)
    into :first_day trimmed, :last_day trimmed, :n_rows trimmed
  from raw_g;
quit;

%put NOTE: Using &n_rows rows from %sysfunc(putn(&first_day, date9.)) to %sysfunc(putn(&last_day, date9.)).;

data _dates;                    /* every calendar day in the data range */
  do date = &first_day to &last_day;
    output;
  end;
  format date date9.;
run;

proc sql;                       /* open days (Mon-Sat, not a holiday) per month */
  create table _mopen as
  select intnx('month', date, 0, 'b') as mo, count(*) as open_days
  from _dates
  where weekday(date) ne 1
    and date not in (select date from holidays)
  group by 1;
quit;

proc datasets lib=work nolist nowarn;   /* start each run with an empty ALL_FLAGS */
  delete all_flags;
quit;

/*--------------------------------------------------------------------
  2. Flagging macro (used by %volume_check - no need to call directly)
     Baseline uses ONLY earlier periods, so a value can't hide itself
     by inflating its own mean/SD.
     SPAN= ALL (everything earlier) or a rolling span like 90D/26W/12M.
     BY= runs a separate baseline per group.
--------------------------------------------------------------------*/
%macro _span_ok(span);
  %local s u nb;
  %let s = %upcase(&span);
  %if &s = ALL %then 1;
  %else %if %length(&s) < 2 %then 0;
  %else %do;
    %let u  = %substr(&s, %length(&s));
    %let nb = %substr(&s, 1, %eval(%length(&s) - 1));
    %if %sysfunc(notdigit(&nb)) %then 0;
    %else %if &u = D or &u = W or &u = M or &u = Y %then 1;
    %else 0;
  %end;
%mend _span_ok;

%macro flag_deviations(in=, out=, span=ALL, min_obs=4, kval=2, by=);
  %local mode nback unit interval cap;
  %let cap  = 5000;                        /* max earlier periods held per group */
  %let span = %upcase(&span);

  %if &span = ALL %then %let mode = ALL;
  %else %do;
    %let mode  = SPAN;
    %let unit  = %substr(&span, %length(&span));
    %let nback = %substr(&span, 1, %eval(%length(&span) - 1));
    %if &unit = D %then %let interval = day;
    %else %if &unit = W %then %let interval = week;
    %else %if &unit = M %then %let interval = month;
    %else %let interval = year;
  %end;

  proc sort data=&in out=_srt; by &by date; run;

  data &out;
    set _srt;
    by &by date;
    length flag $6 baseline $8;
    baseline = "&span";

  %if &mode = ALL %then %do;
    /* Expanding baseline: running totals of everything earlier */
    retain cnt s ss 0;
    if first.%scan(&by, -1) then do;
      cnt = 0; s = 0; ss = 0;
    end;
  %end;
  %else %do;
    /* Rolling baseline: earlier periods with a date inside the span */
    array bd[&cap] _temporary_;            /* dates of earlier periods   */
    array bv[&cap] _temporary_;            /* volumes of earlier periods */
    retain n 0;
    if first.%scan(&by, -1) then n = 0;

    cnt = 0; s = 0; ss = 0;
    cutoff = intnx("&interval", date, -&nback, 's');
    do j = 0 to min(n, &cap) - 1;          /* newest first, stop when too old */
      idx = mod(n - 1 - j, &cap) + 1;
      if bd[idx] < cutoff then leave;
      cnt = cnt + 1;
      s   = s + bv[idx];
      ss  = ss + bv[idx]**2;
    end;
  %end;

    baseline_n = cnt;                      /* earlier periods in the baseline */
    if cnt >= &min_obs then do;
      mean  = s / cnt;
      sd    = sqrt(max(0, (ss - cnt*mean**2) / (cnt - 1)));
      lower = max(0, mean - &kval*sd);
      upper = mean + &kval*sd;
      if sd > 0 then do;
        z = (volume - mean) / sd;
        severity = abs(z);
      end;
      if mean > 0 then pct_diff = (volume - mean) / mean;
      if      volume > upper then flag = 'HIGH';
      else if volume < mean - &kval*sd then flag = 'LOW';
      else                        flag = 'OK';
    end;
    else flag = 'WARMUP';

    /* add this period so later rows can use it */
  %if &mode = ALL %then %do;
    cnt = cnt + 1;
    s   = s + volume;
    ss  = ss + volume**2;
    drop cnt s ss;
  %end;
  %else %do;
    n = n + 1;
    idx = mod(n - 1, &cap) + 1;
    bd[idx] = date;
    bv[idx] = volume;
    drop n j idx cnt s ss cutoff;
  %end;

    format mean sd lower upper comma12.1 z 6.2 pct_diff percentn8.1;
    label baseline = 'Baseline' baseline_n = 'Periods in baseline'
          mean = 'Expected' lower = 'Expected low' upper = 'Expected high'
          pct_diff = 'vs expected' z = 'z-score' flag = 'Flag';
  run;

%mend flag_deviations;

/*--------------------------------------------------------------------
  3. One period, one view (used by %volume_check)
--------------------------------------------------------------------*/
%macro _check_view(period=, baseline=, min_obs=, groups=, view_no=, charts=, tables=);
  %local grp gcomma showgrp label res plabel pnoun period_no nkey;

  %if %length(&groups) = 0 %then %do;
    %let grp     = _all_;
    %let gcomma  = _all_;
    %let showgrp = ;
    %let label   = Everything;
  %end;
  %else %do;
    %let grp     = %sysfunc(compbl(&groups));
    %let gcomma  = %unquote(%sysfunc(translate(&grp, %str(,), %str( ))));
    %let showgrp = &grp;
    %let label   = By &grp;
  %end;

  /* Daily totals per group, with zero-filled gaps */
  proc sql;
    create table _daily_raw as
    select &gcomma, date, sum(volume) as volume
    from raw_g
    group by &gcomma, date;

    create table _groups as
    select distinct &gcomma from raw_g;

    create table _grid as
    select * from _groups, _dates;

    create table daily as
    select * from _grid natural left join _daily_raw
    order by &gcomma, date;
  quit;

  data daily;
    set daily;
    if missing(volume) then volume = 0;
  run;

  %if &period = DAY %then %do;
    %let res = daily_flags;  %let plabel = Daily;   %let period_no = 1;
    %let pnoun = days (each weekday vs the same weekday);

    /* Sundays should be zero; Mon-Sat checked vs the same weekday */
    proc sql;
      create table daily_dow as
      select d.*, weekday(d.date) as dow
      from daily d
      where d.date not in (select date from holidays);
    quit;

    data sunday_check open_days;
      set daily_dow;
      length flag $6;
      if dow = 1 then do;
        if volume > 0 then flag = 'SUNDAY';
        else flag = 'OK';
        output sunday_check;
      end;
      else output open_days;
    run;

    %flag_deviations(in=open_days, out=daily_flags, span=&baseline, min_obs=&min_obs,
                     kval=&k, by=&grp dow);
    proc sort data=daily_flags; by &grp date; run;
  %end;

  %else %if &period = WEEK %then %do;
    %let res = weekly_flags; %let plabel = Weekly;  %let period_no = 2;
    %let pnoun = weeks (Monday to Sunday);

    data _wk;
      set daily(rename=(date=day));
      wk = intnx('week.2', day, 0, 'b');
    run;

    proc sql;
      create table weekly as
      select &gcomma, wk as date format=date9., sum(volume) as volume
      from _wk
      group by &gcomma, wk
      order by &gcomma, date;
    quit;

    %flag_deviations(in=weekly, out=weekly_flags, span=&baseline, min_obs=&min_obs,
                     kval=&k, by=&grp);
  %end;

  %else %do;
    %let res = monthly_flags; %let plabel = Monthly; %let period_no = 3;
    %let pnoun = months (average per open day);

    data _mo;
      set daily(rename=(date=day));
      mo = intnx('month', day, 0, 'b');
    run;

    proc sql;
      create table _mtot as
      select &gcomma, mo, sum(volume) as total_volume
      from _mo
      group by &gcomma, mo;

      create table monthly as
      select t.*, o.open_days,
             t.mo as date format=monyy7.,
             t.total_volume / o.open_days as volume format=comma12.1
      from _mtot t inner join _mopen o
        on t.mo = o.mo
      order by &gcomma, date;
    quit;

    %flag_deviations(in=monthly, out=monthly_flags, span=&baseline, min_obs=&min_obs,
                     kval=&k, by=&grp);
  %end;

  /* ---------- Key observations: the urgent call-outs ---------- */
  data _key;
    set &res(where=(flag in ('HIGH', 'LOW')))
        %if &period = DAY %then sunday_check(where=(flag = 'SUNDAY'));
        ;
  run;

  proc sort data=_key; by descending severity descending date; run;

  proc sql noprint;
    select count(*) into :nkey trimmed from _key;
  quit;

  title1 "KEY OBSERVATIONS - &plabel | &label | baseline &baseline | &k SD";
  title2 "Unusual &pnoun, worst first";
  %if &nkey = 0 %then %do;
    data _msg;
      length Result $80;
      Result = "No unusual &plabel periods found for this view.";
    run;
    proc print data=_msg noobs; run;
  %end;
  %else %do;
    proc print data=_key noobs label;
      var &showgrp date
          %if &period = MONTH %then total_volume open_days;
          volume mean lower upper pct_diff z flag;
      %if &period = MONTH %then %do;
        format total_volume comma12.;
        label date = 'Month' total_volume = 'Total volume' open_days = 'Open days'
              volume = 'Avg per open day';
      %end;
      %else %do;
        label date = %if &period = WEEK %then 'Week starting'; %else 'Date'; volume = 'Volume';
      %end;
    run;
  %end;

  /* Add this check's call-outs to the combined table */
  data _new;
    length view_no period_no 8 level $60 group_name $200 period_type $7
           baseline $8 baseline_n total_volume open_days mean lower upper
           pct_diff sd z severity 8;
    set _key;
    view_no    = &view_no;
    period_no  = &period_no;
    level      = "&label";
    group_name = catx(' / ', &gcomma);
    if flag = 'SUNDAY' then period_type = 'Sunday';
    else period_type = "&plabel";
    format date date9.;
    keep view_no period_no level group_name period_type baseline baseline_n
         date volume total_volume open_days mean lower upper pct_diff sd z
         severity flag;
  run;

  proc append base=all_flags data=_new force; run;

  /* ---------- Charts: one per group ---------- */
  %if %upcase(&charts) = Y %then %do;
    title1 "&plabel | &label | baseline &baseline";
    title2 "Volume against the expected range (&k SD). Markers show flagged &pnoun.";
    proc sgplot data=&res;
      by &grp;
      where flag ne 'WARMUP';
      band   x=date lower=lower upper=upper / transparency=0.6 legendlabel="Expected range";
      series x=date y=mean   / lineattrs=(pattern=dash) legendlabel="Expected";
      series x=date y=volume / lineattrs=(thickness=2) legendlabel=
             %if &period = MONTH %then "Avg per open day"; %else "Volume";;
      scatter x=date y=volume / group=flag markerattrs=(symbol=circlefilled size=10)
              name="pts";
      xaxis display=(nolabel) grid;
      yaxis grid label=%if &period = MONTH %then "Average per open day"; %else "Volume";;
    run;
  %end;

  /* ---------- Full table: every period, flagged rows highlighted ---------- */
  %if %upcase(&tables) = Y %then %do;
    title1 "All &plabel periods | &label | baseline &baseline";
    title2 "Red = HIGH, purple = LOW, grey = WARMUP (not enough history yet)";
    proc report data=&res nowd;
      column &showgrp date
             %if &period = MONTH %then total_volume open_days;
             volume mean lower upper pct_diff z baseline_n flag;
      %if %length(&showgrp) %then %do;
        %local gi;
        %do gi = 1 %to %sysfunc(countw(&showgrp));
          define %scan(&showgrp, &gi) / display;
        %end;
      %end;
      define date       / display %if &period = WEEK %then 'Week starting'; %else %if &period = MONTH %then 'Month'; %else 'Date';;
      %if &period = MONTH %then %do;
        define total_volume / display 'Total volume' format=comma12.;
        define open_days    / display 'Open days';
        define volume       / display 'Avg per open day' format=comma12.1;
      %end;
      %else %do;
        define volume     / display 'Volume' format=comma12.;
      %end;
      define mean       / display 'Expected'      format=comma12.1;
      define lower      / display 'Expected low'  format=comma12.1;
      define upper      / display 'Expected high' format=comma12.1;
      define pct_diff   / display 'vs expected'   format=percentn8.1;
      define z          / display 'z-score'       format=6.2;
      define baseline_n / display 'Periods in baseline';
      define flag       / display 'Flag';
      compute flag;
        if flag = 'HIGH' then
          call define(_row_, 'style', 'style={background=cxFDE2D8 fontweight=bold}');
        else if flag = 'LOW' then
          call define(_row_, 'style', 'style={background=cxEDE4FD fontweight=bold}');
        else if flag = 'WARMUP' then
          call define(_row_, 'style', 'style={foreground=cx8A8A8A}');
      endcomp;
    run;
  %end;
  title;
%mend _check_view;

/*--------------------------------------------------------------------
  The macro you call:
    period   = DAY, WEEK, MONTH, a list such as DAY | WEEK,
               or ALL (= DAY | WEEK | MONTH)                    (required)
    baseline = ALL, or a rolling span: 90D, 26W, 12M, 2Y ...
               One value applies to every period; or give one per
               period in the same order, e.g. 90D | 26W | 12M.
               Blank = 56D for DAY, 12W for WEEK, 12M for MONTH.
    views    = splits to run, separated by |                    (blank = ALL)
               ALL | product | channel | product channel
    min_obs  = earlier periods needed before anything is flagged.
               One value, or one per period. Blank = 4 / 6 / 6.
    charts   = Y/N  chart per group                             (default Y)
    tables   = Y/N  full table of every period                  (default Y)
  Key observations are always printed.
--------------------------------------------------------------------*/
%macro volume_check(period=, baseline=, views=, min_obs=, charts=Y, tables=Y);
  %local plist np nb nm j p b m i n lvl;

  %let plist = %upcase(&period);
  %if &plist = ALL %then %let plist = DAY | WEEK | MONTH;
  %if %length(&plist) = 0 %then %do;
    %put ERROR: volume_check: period= is required (DAY, WEEK, MONTH or ALL).;
    %return;
  %end;
  %let np = %sysfunc(countw(&plist, |));

  %let nb = 0;
  %if %length(&baseline) %then %let nb = %sysfunc(countw(&baseline, |));
  %if &nb > 1 and &nb ne &np %then %do;
    %put ERROR: volume_check: give one baseline, or one per period (&np periods, &nb baselines).;
    %return;
  %end;

  %let nm = 0;
  %if %length(&min_obs) %then %let nm = %sysfunc(countw(&min_obs, |));
  %if &nm > 1 and &nm ne &np %then %do;
    %put ERROR: volume_check: give one min_obs, or one per period (&np periods, &nm values).;
    %return;
  %end;

  %if %length(&views) = 0 %then %let views = ALL;

  %do j = 1 %to &np;
    /* which period */
    %let p = %scan(&plist, &j, |);
    %if &p = DAILY   %then %let p = DAY;
    %if &p = WEEKLY  %then %let p = WEEK;
    %if &p = MONTHLY %then %let p = MONTH;
    %if &p ne DAY and &p ne WEEK and &p ne MONTH %then %do;
      %put ERROR: volume_check: period "&p" not recognised - use DAY, WEEK, MONTH or ALL.;
      %return;
    %end;

    /* which baseline */
    %if &nb = 0 %then %do;
      %if &p = DAY %then %let b = 56D;
      %else %if &p = WEEK %then %let b = 12W;
      %else %let b = 12M;
    %end;
    %else %if &nb = 1 %then %let b = &baseline;
    %else %let b = %scan(&baseline, &j, |);
    %let b = %upcase(%sysfunc(compress(&b)));
    %if %_span_ok(&b) = 0 %then %do;
      %put ERROR: volume_check: baseline "&b" not recognised - use ALL, or a number followed by D, W, M or Y (e.g. 90D).;
      %return;
    %end;

    /* how much history before flagging */
    %if &nm = 0 %then %do;
      %if &p = DAY %then %let m = 4;
      %else %let m = 6;
    %end;
    %else %if &nm = 1 %then %let m = %sysfunc(compress(&min_obs));
    %else %let m = %sysfunc(compress(%scan(&min_obs, &j, |)));

    /* run each view */
    %let n = %sysfunc(countw(&views, |));
    %do i = 1 %to &n;
      %let lvl = %scan(&views, &i, |);
      %if %upcase(&lvl) = ALL %then %do;
        %_check_view(period=&p, baseline=&b, min_obs=&m, groups=,
                     view_no=&i, charts=&charts, tables=&tables)
      %end;
      %else %do;
        %_check_view(period=&p, baseline=&b, min_obs=&m, groups=&lvl,
                     view_no=&i, charts=&charts, tables=&tables)
      %end;
    %end;
  %end;
%mend volume_check;

/* Run summary: every call-out from every %volume_check call, most
   recent first, plus a count by period, view and group */
%macro flag_summary;
  %if %sysfunc(exist(all_flags)) %then %do;
    proc sort data=all_flags out=_summary;
      by descending date descending severity;
    run;

    title1 "RUN SUMMARY - every call-out from this run, most recent first";
    title2 "Data from %sysfunc(putn(&first_day, date9.)) to %sysfunc(putn(&last_day, date9.)) | &k SD";
    proc print data=_summary noobs label;
      var date period_type baseline level group_name volume mean pct_diff z flag;
      label date = 'Date / start' period_type = 'Period' level = 'View'
            group_name = 'Group' volume = 'Volume';
      format volume comma12.1;
    run;

    title1 "RUN SUMMARY - number of call-outs by period, view and group";
    title2;
    proc sql;
      select period_type label='Period', baseline label='Baseline',
             level label='View', group_name label='Group',
             sum(flag = 'HIGH')   as n_high   label='HIGH',
             sum(flag = 'LOW')    as n_low    label='LOW',
             sum(flag = 'SUNDAY') as n_sunday label='SUNDAY',
             max(date) as latest format=date9. label='Most recent'
      from all_flags
      group by period_no, period_type, baseline, view_no, level, group_name
      order by period_no, baseline, view_no, group_name;
    quit;
    title;
  %end;
  %else %do;
    title1 "RUN SUMMARY";
    data _msg;
      length Result $80;
      Result = "No unusual periods found in any check.";
    run;
    proc print data=_msg noobs; run;
    title;
  %end;
%mend flag_summary;

/*--------------------------------------------------------------------
  4. RUN THE CHECKS - delete, add or change calls freely.
--------------------------------------------------------------------*/

/* Everything in one go: day, week and month, each with its own baseline */
%volume_check(period=ALL, baseline=90D | 26W | 12M,
              views=ALL | product | channel | product channel);

/* Or one period at a time, e.g.
%volume_check(period=DAY,   baseline=90D, views=ALL | product);
%volume_check(period=WEEK,  baseline=ALL, views=ALL, charts=N);
%volume_check(period=MONTH, baseline=12M, views=ALL, tables=N);
*/

%flag_summary;

/* Every call-out is also in WORK.ALL_FLAGS - open it in EG to filter or sort. */
