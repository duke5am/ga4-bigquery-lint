# SCHEMA-TRAPS.md

## Why your GA4 SQL disagrees with the GA4 UI

You wrote the query. It is syntactically fine, it returns a number, and the
number is not the number in the GA4 interface. You changed your `WHERE` clause,
you changed the date range, you changed the event name, and the gap moved by a
few percent but did not close.

Almost every one of these gaps has a mechanical explanation, and almost none of
them mean your query is broken. They mean the export and the UI are answering
slightly different questions, because GA4's interface reports on a **processed,
modelled session object** while the export hands you an **event log** plus
enough raw material to build that session object yourself.

This document lists the traps in the order you will hit them. Each one has a
**symptom** (what you see) and a **fix** (what to do). Where a trap has no
complete fix, it says so rather than inventing one.

Two things to establish first, because they change how you should read
everything else:

- **The export is not a report.** It is one row per collected event, with the
  raw parameters attached. Sessions, users, engagement, channels, landing pages,
  conversions and funnels are all *derived* downstream -- by GA4's servers for
  the UI, by you for BigQuery. Two derivations, two definitions, two numbers.
  Neither is lying.
- **The export is not sampled.** GA4's BigQuery export is the raw event stream.
  The UI, however, may threshold or suppress data in specific circumstances
  (trap 8). So "the UI is sampled and BigQuery is not" is the wrong model --
  the accurate statement is that they diverge for the reasons below.

---

## Trap 1 -- `event_timestamp` is MICROSECONDS

**What is happening.** `event_timestamp` is an `INT64` holding **microseconds**
since the Unix epoch (1970-01-01 00:00:00 UTC). It is a bare integer with no
type information attached, so BigQuery will happily let you feed it to any
function that takes a number.

**Symptom.** You write `TIMESTAMP_SECONDS(event_timestamp)` and every row comes
back with a date somewhere around the year 57,000, or your `WHERE
event_timestamp > '2024-01-01'` comparison returns nothing at all. Alternatively
you divide by 1000 "to get seconds" and then compare against a `TIMESTAMP`
literal, which fails or silently compares milliseconds to microseconds.

**The fix.** Use `TIMESTAMP_MICROS`, which exists precisely for this:

```sql
SELECT
  event_timestamp                            AS raw_micros,
  TIMESTAMP_MICROS(event_timestamp)          AS event_ts_utc,
  TIMESTAMP_MICROS(event_timestamp)          AS t1,
  TIMESTAMP_SECONDS(DIV(event_timestamp, 1000000)) AS t2  -- equivalent
FROM `PROJECT.analytics_XXXXXXXXX.events_*`
WHERE _TABLE_SUFFIX = '20240115'
LIMIT 10;
```

`t1` and `t2` agree. If you see a value in 1970 when you expected 2024, you have
fed microseconds to a seconds function; if you see the year 57000, you have fed
microseconds to a function expecting a smaller unit.

**Related units, so you do not have to guess.** `event_timestamp` is
microseconds. `user_first_touch_timestamp` is microseconds.
`_TABLE_SUFFIX` is a `STRING` in `YYYYMMDD` form, not a date and not a number --
compare it to string literals. `event_date` is a `STRING` in the same form; use
`PARSE_DATE('%Y%m%d', event_date)` when you need a real `DATE`.

**One more.** Do not assume a timestamp column is in the same unit across
tables. `session_traffic_source_last_click` and the `*_timestamp` fields inside
`user_properties` have their own documented units; read the schema before you
convert.

---

## Trap 2 -- Sessions do not exist in the export; you must derive them

**What is happening.** There is no `sessions` table and no session row. What you
have is a `ga_session_id` event parameter written onto each event, an `INT64`
that GA4 mints when it decides a new session has begun. To count sessions you
must count distinct combinations of `user_pseudo_id` and `ga_session_id`.

**Symptom A -- you counted `session_start` events instead.** Your number is
close to the UI but consistently a little low, and the gap is worse on mobile.
`session_start` is an *event*, and the events are not a complete record of
sessions: clients under some conditions continue a session without re-emitting
`session_start`, and some server-side or Measurement Protocol traffic arrives
with a `ga_session_id` but no `session_start` event at all. Counting events is
counting a proxy.

**Symptom B -- you grouped by `ga_session_id` alone.** This is worse, and it is
the most common serious error in GA4 BigQuery SQL. `ga_session_id` is derived
from a timestamp in seconds, so it is **unique only within one
`user_pseudo_id`**. Two unrelated users who start a session in the same second
get the same value. Grouping by `ga_session_id` alone silently **merges
different users' sessions into one**, so you undercount sessions and your
per-session metrics are computed across two people.

**Symptom C -- you got zero sessions and no error.** You read
`value.string_value` for `ga_session_id`. It is written as an integer, so
`string_value` is `NULL` for every row, a subsequent `IS NOT NULL` filter
removes everything, and `COUNT(DISTINCT ...)` returns 0. No exception is raised.
See trap 7.

**The fix.** Always derive a composite key:

```sql
CONCAT(user_pseudo_id, '.', CAST(ga_session_id AS STRING)) AS session_key
```

and group by that, or group by `(user_pseudo_id, ga_session_id)` explicitly.
`ga4_bigquery_lint/queries/01-SESSIONISE-EVENTS.sql` and `setup/create_session_table.sql` both
build this key once so nothing downstream can forget it. `docs/SESSIONISATION.md`
covers the 30-minute rule, midnight crossing and how to sanity-check the result.

**And read the session id correctly:**

```sql
(SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS ga_session_id
```

`int_value`, not `string_value`.

---

## Trap 3 -- one session can live in two daily tables

**What is happening.** The export writes each event into the daily table for the
event's date **in the property's timezone**. A session is a span of real time.
A session that starts at 23:52 and ends at 00:14 has its events split across
`events_20240115` and `events_20240116`.

**Symptom.** Your session count for a given day is **higher** than the UI's, and
the excess is small -- typically a fraction of a percent to a few percent. The
day before matches, the day in question does not, and the pattern is worse for
properties with a large share of late-evening traffic or very long sessions.

**Mechanism, precisely.** If you write:

```sql
SELECT event_date, COUNT(DISTINCT session_key)
FROM ... GROUP BY event_date
```

then one midnight-crossing session contributes **one session to each date it
touches**. Day 1 is correct (the session started then). Day 2 is inflated by
one. The GA4 UI attributes the whole session to its **start date**, which is why
this looks like a mysterious one-sided error.

**The fix.** Derive the session's start date first, then group by *that*:

```sql
sessions AS (
  SELECT session_key, MIN(PARSE_DATE('%Y%m%d', event_date)) AS session_start_date
  FROM events
  GROUP BY session_key
)
SELECT session_start_date, COUNT(*) FROM sessions GROUP BY session_start_date
```

**And when you are checking a single day, scan three days.** `_TABLE_SUFFIX
BETWEEN '20240114' AND '20240116'`, then filter to sessions whose start date is
the day you care about. Scanning only `20240115` makes the split unavoidable --
there is no query shape that fixes a session whose other half you did not read.

**How big should the gap be?** `ga4_bigquery_lint/queries/10-MIDNIGHT-CROSSING.sql` measures it on
your data and returns the exact number of sessions a naive per-day grouping
would invent. That converts "my SQL is wrong somewhere" into "my SQL is wrong by
exactly 412 sessions, for this mechanical reason". Run it before you start
hunting.

---

## Trap 4 -- `_TABLE_SUFFIX` needs a filter, or you scan everything

**What is happening.** GA4 appends a new table every day and never removes the
old ones. `events_*` matches all of them. The wildcard is a table-name match,
not a partition with a boundary.

**Symptom A -- cost.** A query over "the last 30 days" that actually scans three
years returns the right answer and a bill you did not expect. The cost grows
every day without anyone changing a line of SQL, which is what makes it
dangerous: the query that cost $2 at launch costs $40 a year later.

**Symptom B -- wrong results, quietly.** A date-range filter written against
`event_date` -- `WHERE event_date BETWEEN '20240101' AND '20240131'` -- **filters
rows, not tables.** BigQuery still reads every daily table in the dataset and
then discards the rows you did not want. Correct answer, full scan. This is the
most expensive way to be right.

**The fix.** Filter on the pseudo-column, always:

```sql
WHERE _TABLE_SUFFIX BETWEEN '20240101' AND '20240131'
```

Then add the `event_date` filter too if you want the semantics to be explicit.
Keep `event_date` for readability and `_TABLE_SUFFIX` for pruning; they should
express the same window.

**Check it.** Every statement in this pack that reads an `events_*` wildcard is
verified by `verify_pack.py` to contain a `_TABLE_SUFFIX` filter. Run the script
on your own queries to get the same check. And dry-run before you run:
`docs/COST-CONTROL.md` has the exact command.

**Note on the intraday table.** If you have streaming export enabled there is
also an `events_intraday_YYYYMMDD` table. `events_*` matches it. It is usually
what you want (fresh data), but it is replaced as data lands in the final daily
table, so a query spanning both can double count the current day. Decide
deliberately whether you include it, and do not mix them for the same date.

---

## Trap 5 -- `user_pseudo_id` is per-device, not per-person

**What is happening.** `user_pseudo_id` identifies a browser or app
installation, not a human. For web it is typically a client id held in a cookie;
for apps it is an app-instance id. It is stored client-side, so it dies with the
cookie, the browser profile, the app install, or the device.

**Symptom.** Your "users" number is far higher than the number of people you
believe you have. Your retention curve is far lower than the business expects.
A user you know signed up appears in your data as two or three different users.
Cross-device journeys are invisible: someone researches on a phone and converts
on a laptop shows as two unrelated users, the first with no conversion and the
second with no history.

There is no query that fixes this. The information is not in the export.

**The partial fix.** `user_id` is a column on the event, populated only when you
explicitly set it -- via `gtag('config', ..., {'user_id': ...})`, the
Measurement Protocol, or the Firebase SDK. Where it is present, it is a real
cross-device join key:

```sql
-- Users, counting signed-in identity where available and falling back to device
SELECT
  COUNT(DISTINCT COALESCE(user_id, user_pseudo_id)) AS users_joined_where_possible,
  COUNT(DISTINCT user_pseudo_id)                    AS users_per_device,
  COUNT(DISTINCT user_id)                           AS signed_in_users
FROM `PROJECT.analytics_XXXXXXXXX.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20240101' AND '20240131';
```

**What to do about it, honestly.**

- Label your metrics. "Users" in a GA4 BigQuery report means per-device users.
  Say so in the report title, or you will be asked to explain the gap later.
- `user_pseudo_id` retention is **device retention**. It is not a proxy for human
  retention, and it moves for reasons (cookie expiry, privacy features) that have
  nothing to do with your product.
- Do not attempt to bridge identities inside GA4's export by matching on IP
  address, device string or timestamp proximity. You will build something that
  looks like it works on small samples and is wrong on the aggregate.
- For real cross-device identity you need a CRM, a CDP, or a server-side
  identity graph joined on `user_id`. That is the honest boundary of what the
  export can tell you.

---

## Trap 6 -- `event_params` is an array; a naive join multiplies rows

**What is happening.** `event_params` is a `REPEATED RECORD` of `{key, value}`
pairs -- an array, one entry per parameter on that event. A typical event carries
ten to twenty-five entries.

**Symptom.** You unnest the array in the `FROM` clause to filter for one
parameter, and then your `COUNT(*)` is roughly 15x too large. Or you join a
parameter lookup and your event volume explodes. Or your "events per session"
distribution has numbers in the hundreds when you expect single digits.

**Mechanism.** `FROM t, UNNEST(event_params)` produces **one output row per
parameter**, so the grain silently changes from "one row per event" to "one row
per parameter". Every aggregate downstream is now computed over the wrong grain,
and nothing warns you.

**The fix -- two shapes, and only one is safe for counting.**

*For counting and reporting: a scalar subquery.* Returns at most one value and
cannot duplicate the outer row.

```sql
SELECT
  event_name,
  (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS ga_session_id,
  (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location
FROM `PROJECT.analytics_XXXXXXXXX.events_*`
WHERE _TABLE_SUFFIX = '20240115';
```

*For debugging: unnest in `FROM`, but always filter to explicit keys.*

```sql
SELECT
  event_name, p.key, p.value.string_value, p.value.int_value, p.value.double_value
FROM `PROJECT.analytics_XXXXXXXXX.events_*`, UNNEST(event_params) AS p
WHERE _TABLE_SUFFIX = '20240115' AND event_name = 'session_start';
```

Without the `key` filter this returns every parameter of every event -- useful
for "what does this event actually carry?", useless as a basis for any count.
`ga4_bigquery_lint/queries/00-PARAM-PATTERNS.sql` sets out all the patterns with their trade-offs.

**Sanity check that catches this class of bug in one line.** If
`COUNT(*)` from your events table is not close to the number of events the UI
reports for the same day and filter, check the grain before you check the
`WHERE` clause. A 10-25x discrepancy is a grain bug, not a filter bug.

---

## Trap 7 -- a parameter's value lives in one of three fields

**What is happening.** Each `event_params` entry has a `value` struct with
several typed fields: `string_value` (`STRING`), `int_value` (`INT64`),
`double_value` (`FLOAT64`), and in older exports `float_value`. GA4 writes the
value into **the field matching the type the parameter was sent as**, and leaves
the others `NULL`.

**Symptom.** A parameter returns `NULL` for every single row. No error. Your
`WHERE param = 'value'` filter removes every row, or your session count is `0`.

The classic victim is `ga_session_id`, which is an **integer**. Read
`string_value` and you get `NULL` everywhere. This one bug accounts for a
surprising share of "GA4 BigQuery is broken" reports.

**Symptom, second flavour.** You "fixed" it with
`COALESCE(value.string_value, value.int_value)` and BigQuery either refuses to
compile it (mixed types) or you force a cast and the query dies at runtime on
the first non-numeric string. `COALESCE` requires compatible types, and
`STRING` and `INT64` are not compatible.

**The fix.** Read the field that GA4 actually populates. Type-safe, cheap, and
clear about intent:

```sql
-- INTEGER parameter
(SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'ga_session_id')  AS ga_session_id
-- STRING parameter
(SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location')  AS page_location
-- DOUBLE parameter
(SELECT value.double_value FROM UNNEST(event_params) WHERE key = 'value')          AS value_param
```

**The built-in parameters, by type** (this is the table to keep beside you):

| Parameter | Field to read |
|---|---|
| `ga_session_id` | `value.int_value` |
| `ga_session_number` | `value.int_value` |
| `engagement_time_msec` | `value.int_value` |
| `entrances` | `value.int_value` |
| `percent_scrolled` | `value.int_value` |
| `page_location` | `value.string_value` |
| `page_referrer` | `value.string_value` |
| `page_title` | `value.string_value` |
| `source` | `value.string_value` |
| `medium` | `value.string_value` |
| `campaign` | `value.string_value` |
| `term` | `value.string_value` |
| `content` | `value.string_value` |
| `session_engaged` | `value.string_value` (`'1'` / `'0'` -- **not** an integer) |

`session_engaged` catches people out because everything else about engagement is
numeric. It is a string.

**When you genuinely do not know the type** (custom parameters), this union is
safe because `SAFE_CAST` returns `NULL` instead of raising, so one bad value
cannot fail the query:

```sql
COALESCE(
  (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'my_param'),
  SAFE_CAST((SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'my_param') AS STRING),
  SAFE_CAST((SELECT value.double_value FROM UNNEST(event_params) WHERE key = 'my_param') AS STRING)
) AS my_param_as_string
```

Note the argument order: `SAFE_CAST(expr AS type)`. And note the limit: this
gives you a `STRING`, fine for grouping and display, **not** for arithmetic. For
numbers, read the numeric field directly.

**Last thing.** The `key = '...'` comparison is an exact, case-sensitive string
match. A custom parameter sent as `MyParam` is not matched by `'myparam'`. If a
custom parameter returns `NULL` for everything, dump the distinct keys for one
day before you debug the query:

```sql
SELECT DISTINCT p.key
FROM `PROJECT.analytics_XXXXXXXXX.events_*`, UNNEST(event_params) AS p
WHERE _TABLE_SUFFIX = '20240115'
ORDER BY 1;
```

One day only. That `DISTINCT` over a year is a full-history scan.

---

## Trap 8 -- the UI applies thresholding, and other reporting-layer differences

**What is happening.** The export and the UI are produced by different code
paths. The export gives you raw events. The UI reports on the same events after
a reporting layer that includes, depending on feature and configuration:

- **Thresholding.** When Google Signals or demographic/interest reporting is
  involved, GA4 can withhold rows or values derived from too few users, to
  protect identity. Thresholded values may not be reported at all, or only as
  ranges.
- **Cardinality limits.** High-cardinality dimensions can be grouped into an
  `(other)` bucket in the UI. The export retains the underlying values, so your
  `GROUP BY` will show the real distribution while the UI shows `(other)` and
  appears to be missing rows.
- **Attribution model settings** applied to conversion-related reports, which
  reallocate credit without changing event counts.
- **Identity settings** (reporting identity, Google Signals) that change how
  users are counted in the UI but have no effect on `user_pseudo_id` in the
  export.
- **Filters and data settings** -- internal traffic exclusion, IP anonymisation,
  data retention -- applied at the property level.

**Symptom.** Your SQL shows more rows, or more granular dimensions, or a
different distribution than the UI, and the difference is not a clean
percentage. Some dimension values simply do not appear in the UI at all.

**The fix.** There is no query fix, because there is nothing wrong with your
query. What you do instead:

1. **Know which metric you are reconciling.** Row counts, event counts and
   session counts can each differ for different reasons. Reconcile one number
   at a time, never a whole report.
2. **Check whether the property has Google Signals on.** If it does, expect
   thresholding to affect user- and demographic-adjacent reports, and expect the
   effect to be larger on small segments. Small segments are exactly where
   thresholding bites hardest, so do not chase a gap on a segment with 40 users.
3. **Expect the export to be the more complete source** in most
   thresholding-related cases, and say so rather than assuming you are wrong.
   But do not assume the export is authoritative for *identity* -- it is not
   (trap 5).
4. **Do not attempt to "correct" your SQL to match the UI on thresholded
   numbers.** You would be modelling Google's privacy suppression logic, which
   is neither published nor stable.
5. **Report the difference.** "BigQuery reports 1,240 sessions, the UI reports
   1,198; the gap is consistent with UI thresholding on the small segments in
   this view" is a complete and professional statement. It is also a much better
   position than quietly adjusting a query until the numbers match.

---

## Trap 9 -- channel grouping is not in the export

**What is happening.** GA4's "Session default channel group" is a **derived
dimension**. It is computed by GA4's reporting layer from source, medium and
campaign values, plus advertising-network metadata. The export does not contain
a `channel_group` column. It contains the raw inputs.

**What the export does give you**, and where each comes from:

| Column | Scope | What it holds |
|---|---|---|
| `traffic_source.name` | user, first touch | campaign name from the user's first acquisition |
| `traffic_source.medium` | user, first touch | medium from the user's first acquisition |
| `traffic_source.source` | user, first touch | source from the user's first acquisition |
| `collected_traffic_source.manual_campaign_name` | event | the `utm_campaign` value that was collected |
| `collected_traffic_source.manual_source` | event | the `utm_source` value that was collected |
| `collected_traffic_source.manual_medium` | event | the `utm_medium` value that was collected |
| `collected_traffic_source.gclid` / `dclid` / `srsltid` | event | click identifiers for paid traffic |
| `session_traffic_source_last_click.manual_campaign.campaign_name` | session | last-clicked manual campaign NAME (exports from mid-2023) |
| `session_traffic_source_last_click.manual_campaign.source` / `.medium` | session | last-clicked source and medium |
| `session_traffic_source_last_click.google_ads_campaign.campaign_name` | session | last-clicked Google Ads campaign, where Ads is linked |
| `session_traffic_source_last_click.cross_channel_campaign.campaign_name` | session | last-clicked cross-channel campaign |

> **Two records, two shapes -- do not mix them up.**
>
> `collected_traffic_source` is **flat**, with underscores:
> `manual_campaign_name`, `manual_source`, `manual_medium`, `manual_term`,
> `manual_content`, `gclid`, `dclid`, `srsltid`. There is **no** nested
> `manual_campaign` record inside it. Writing
> `collected_traffic_source.manual_campaign.name` is a documented field that
> does not exist and returns an error.
>
> `session_traffic_source_last_click` is **nested**, with sub-records:
> `manual_campaign.<field>`, `google_ads_campaign.<field>`,
> `cross_channel_campaign.<field>`. And the campaign name field inside it is
> **`campaign_name`**, not `name` -- `manual_campaign.name` does not exist.
> `traffic_source.name` (top level, user-scoped) *is* correct, so `name` is a
> real GA4 field in one context and a bug in another. That is exactly the kind
> of thing that survives review.
>
> This pack's verification catches both wrong forms:
> `verify_pack.py` and `audit_pack.py` fail on `manual_campaign.name` and on
> any dotted path through `collected_traffic_source.manual_campaign`.

**Symptom.** Your channel table does not line up with the UI's. Sessions appear
under `Google Ads` or `Other` that the UI puts under `Cross-network`, or the UI
shows a channel you cannot reproduce at all.

**Why, specifically.** GA4's `Cross-network` group requires advertising-network
metadata -- principally the linkage that auto-tagging and campaign IDs provide.
Not all of that is present per session in the export. `Display` depends on ad
format, which is not exported. `Audio` and `Video` require network-specific
medium values your senders may not send consistently.

**The fix -- be explicit about which attribution you are reporting.** All three
of these are defensible and they give different answers:

- **First-touch (user-scoped):** `traffic_source.*`. Frozen at the user's first
  session. Every later conversion from that user credits the original channel.
- **Last-click (session-scoped):** `session_traffic_source_last_click.*`.
  Preferred when present; this is closest to what the UI's session-scoped
  channel reports use.
- **Collected (event-scoped):** `collected_traffic_source.*`. What the tag
  actually saw on that hit, before any modelling.

`ga4_bigquery_lint/queries/05-CONVERSIONS-BY-CHANNEL.sql` lets you switch between them with a
change to one `COALESCE`. Pick one, **label the report with which one it is**, and
never mix them in a single table.

**And be realistic about matching.** A modelled channel group built from the
export is a good approximation, not a replica. If a report must tie out exactly
to the UI's channel names, export it from the UI. Use SQL when you need channels
*joined* to things the UI cannot join to -- your own user table, your CRM, a
custom conversion definition. `ga4_bigquery_lint/queries/08-CHANNEL-GROUPING.sql` implements the
mapping and returns a `unmatched_or_other_pct` health metric; when that number
climbs, your tagging changed, not your query.

---

## Trap 10 -- landing pages need position, not `MIN()`

**What is happening.** There is no `landing_page` column. There is a
`page_location` parameter on `page_view` events. "Landing page" means the first
one in the session, which requires an ordering.

**Symptom A.** You used `MIN(page_location)` and your landing pages are
alphabetically first, not temporally first. `ANY_VALUE(page_location)` is worse:
a different page every run, so the report is not reproducible.

**Symptom B.** Your route-level report is fragmented -- `/pricing` and
`/pricing?utm_source=newsletter` counted separately, plus every `gclid`
variation. Or, after cleaning, genuinely different pages got merged.

**The fix -- ordering first:**

```sql
ARRAY_AGG(page_location IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS landing_page
```

`IGNORE NULLS` keeps events with no `page_location` from being selected, and
the `LIMIT 1` keeps this cheap. Do not use the `entrances` parameter for this:
it exists, but it is not reliably present on every session's first event, while
"earliest `page_location` by timestamp" works for every session that has any
page view at all.

**The fix for fragmentation -- and the honest limit of it.** `page_location` is
a **full URL**, query string included. Stripping it is a judgement call, not a
cleanup:

```sql
REGEXP_REPLACE(page_location, r'[?#].*$', '')   -- path only
```

That regex is fine. What it cannot do:

- It **merges** URLs that differ only by a content-bearing query parameter.
  `/product?sku=1` and `/product?sku=2` become one row. If your site uses query
  parameters for content, this merges real pages.
- It does **not** merge URLs that differ by trailing slash (`/pricing` vs
  `/pricing/`), by case (`/Pricing`), or by tracking parameters that GA4 itself
  appends (`gclid`, `gbraid`, `wbraid`, `dclid`, `srsltid`, `utm_*`) -- those
  become indistinguishable from your own `utm_` parameters unless you strip
  specific keys by name.
- It cannot recover the page a **single-page app** was on if the app never
  updates `page_location` (or never fires a `page_view`). You get one landing
  page for the whole session, and the session's real journey is invisible.

So: strip the query string, document that you did, and if the parameter names in
your URLs matter, strip by allow-list instead of by rule. Where an app does not
send page views, use `screen_view` and `page_title` deliberately rather than
pretending the page dimension is complete.

**Also, do not drop the sessions with no page view.** App traffic, Measurement
Protocol hits and conversion-only sessions have no `page_location`. If you filter
them out, your totals stop reconciling with your session count. Report them as
`(no landing page)` instead.

---

## Trap 11 -- `event_date` is property timezone; `event_timestamp` is an absolute instant

**What is happening.** This is the trap that produces the most confusing
disagreements, because both columns are "the date" and they are not the same
date.

- **`event_date`** is a `STRING` (`YYYYMMDD`) in the **property's reporting
  timezone**. GA4 uses it to decide which daily table the event goes into.
- **`event_timestamp`** is **microseconds since the Unix epoch** -- an absolute
  UTC instant with no timezone attached. `TIMESTAMP_MICROS(event_timestamp)`
  gives you a UTC timestamp.

**Symptom.** Everything reconciles nicely for most of the day, then your
`WHERE` clause and the UI disagree for two hours out of every twenty-four.
`EXTRACT(DATE FROM TIMESTAMP_MICROS(event_timestamp))` gives a different daily
count from `PARSE_DATE('%Y%m%d', event_date)`, and the difference is
concentrated in a band of hours. Your daily totals are shifted, not just noisy.

**Why it matters for sessions specifically.** The property timezone determines
when a *session* is considered to cross midnight, because GA4 mints
`ga_session_id` and assigns `event_date` in property time. If you rebuild daily
session counts using UTC dates, you move the midnight boundary and you will
split the wrong sessions.

**The fix.** Be explicit about which one you mean, and do not convert between
them casually:

```sql
SELECT
  -- Property-timezone date: the date GA4 itself uses. Use this to match the UI.
  PARSE_DATE('%Y%m%d', event_date)             AS property_date,
  -- Absolute UTC instant of the event.
  TIMESTAMP_MICROS(event_timestamp)            AS event_ts_utc,
  -- UTC date, which is NOT the property date. Compare the two and you will see
  -- the offset band.
  EXTRACT(DATE FROM TIMESTAMP_MICROS(event_timestamp)) AS utc_date,
  -- Property-timezone timestamp, only possible if you know the property offset.
  -- DATE(TIMESTAMP_MICROS(event_timestamp), 'America/New_York') AS event_ts_property_tz
FROM `PROJECT.analytics_XXXXXXXXX.events_*`
WHERE _TABLE_SUFFIX = '20240115'
LIMIT 20;
```

**Practical rules.**

1. **For anything you reconcile against the UI, use `event_date`.** It is
   already in the right timezone, it is what the daily tables are keyed on, and
   it is what the UI reports.
2. **For durations, ordering and time-of-day analysis, use
   `TIMESTAMP_MICROS(event_timestamp)`.** Timestamps are absolute, so
   subtracting them is always correct regardless of timezone. Do not compute a
   session duration by subtracting dates.
3. **If you need a property-timezone timestamp**, you must supply the offset
   yourself -- it is not in the export. The `DATE(timestamp, time_zone)`
   function takes a timezone string; find your property's timezone in GA4 admin
   settings and hard-code it, or store it as a parameter. Guessing it from the
   data is a way to be subtly wrong for two hours a day.
4. **A DST change will move your offset band.** If you hard-code an offset
   rather than a timezone name, be aware that it is wrong for part of the year.

---

## Quick reference -- symptom to trap

| Symptom | Trap |
|---|---|
| Dates around the year 57000; `WHERE` on a timestamp matches nothing | 1 -- microseconds |
| Zero sessions, no error raised | 2C / 7 -- wrong value field |
| Sessions undercounted; two users merged | 2B -- grouped by `ga_session_id` alone |
| Sessions slightly over the UI, one day only | 3 -- midnight crossing |
| Cost far above expectation; grows over time | 4 -- no `_TABLE_SUFFIX` |
| `event_date` filter right, but the bill is huge | 4 -- filter does not prune |
| Users far above headcount; retention implausibly low | 5 -- per-device identity |
| `COUNT(*)` about 10-25x too high | 6 -- unnesting changed the grain |
| A parameter is `NULL` for every row | 7 -- wrong value field |
| Dimension values missing from the UI; gaps on small segments | 8 -- thresholding |
| Channel table will not line up with the UI | 9 -- channel group is derived |
| Landing pages alphabetical or random; page list fragmented | 10 -- need position, not `MIN()` |
| Numbers agree except for a two-hour band each day | 11 -- timezone |

---

## What is not in this document

- **A promise that your numbers will match the UI exactly.** They will not, and
  any pack claiming otherwise is either wrong or has not reconciled against a
  real property. `docs/VALIDATION.md` gives you a worked reconciliation with a
  realistic expected gap and tells you which discrepancies are acceptable.
- **Any claim that these queries were run against BigQuery.** They were not. No
  GCP account was available. They were written against the documented export
  schema and syntax-checked with a BigQuery SQL parser (`verify_pack.py`); see
  `README.md` for exactly what that does and does not prove.
- **Revenue and ecommerce modelling.** `event_value_in_usd` exists and is
  returned where relevant, but proper revenue reporting needs refunds,
  currency conversion, item-level detail and a defined revenue definition. That
  is a different product.
