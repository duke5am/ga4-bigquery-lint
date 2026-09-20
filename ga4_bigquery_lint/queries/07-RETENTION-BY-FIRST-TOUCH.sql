-- ============================================================================
--  07-RETENTION-BY-FIRST-TOUCH.sql
--  GA4 BigQuery Session & Funnel SQL Pack
-- ============================================================================
--
--  QUESTION IT ANSWERS
--    "Of the users who first arrived in week X, how many came back in week
--     X+1, X+2, ... ?" -- cohort retention anchored on FIRST TOUCH, which is
--    the number people actually mean when they say "retention" and which the
--    GA4 UI's own retention report only approximates.
--
--  WHAT IT RETURNS (one row per cohort x period)
--    cohort_bucket        DATE   -- Monday of the ISO week of the user's first
--                                  session (or the month's first day if you
--                                  switch to month cohorts -- see the switch)
--    cohort_size          INT64  -- distinct users whose first session landed
--                                  in that bucket, within the window
--    period_number        INT64  -- 0 = the cohort bucket itself, 1 = the next
--                                  week, 2 = the week after that, ...
--    period_start_date    DATE
--    active_users         INT64  -- cohort users with >=1 session in the period
--    retention_rate       FLOAT64 -- active_users / cohort_size, as a percentage
--    sessions_in_period   INT64
--    sessions_per_active_user FLOAT64
--    avg_days_active_in_period FLOAT64
--
--  WHAT "FIRST TOUCH" MEANS HERE, AND THE TWO WAYS TO GET IT WRONG
--    A user's first-touch date must be computed from data OUTSIDE the report
--    window, or it is not first touch -- it is "first seen inside my filter".
--    This query handles that explicitly:
--      - `first_seen` is computed over the whole scan range.
--      - `report_start`/`report_end` then select WHICH cohorts to report on.
--    So you must scan data that begins BEFORE your first reported cohort. If
--    you set both to the same date, every user looks new on day one of the
--    window and your retention curve will be nonsense (it will look
--    spectacular, then collapse).
--
--    The second way to get it wrong: using MIN(event_date) over events
--    instead of over SESSIONS. They differ when the first event of a user's
--    first session is missing (rare) -- using sessions is more robust and is
--    what this query does.
--
--  CAVEATS -- THESE ARE REAL AND YOU SHOULD QUOTE THEM
--    1. "USER" = user_pseudo_id = ONE BROWSER/DEVICE. Retention measured this
--       way is destroyed by cookie clearing, by Safari/ITP-style expiry, and
--       by users switching device. It will be LOWER than true human retention
--       and it can also be HIGHER than you expect for a single user across a
--       long window, because the same person re-entering with a fresh
--       identifier counts as a brand-new cohort member. There is no fix inside
--       the export; user_id joins only help for signed-in traffic. Say
--       "device retention", not "user retention", in the report title.
--    2. RIGHT-CENSORING. A cohort's later periods are incomplete if the
--       cohort is younger than the period. The last bucket in your window will
--       show an artificially sharp drop because those users simply have not
--       had the chance to return yet. Filter with
--       `WHERE period_start_date + INTERVAL (period_number * 7) DAY <= report_end`
--       (the line is included, commented, at the bottom) or annotate the chart.
--       This is the single most common way a retention chart lies.
--    3. ISO WEEK MONDAY START. cohort_bucket is the MONDAY of the ISO week.
--       GA4's UI uses its own week convention in some reports, so a weekly
--       cohort chart from here will not align row-for-row with the UI unless
--       you check which convention the UI is using. Daily cohorts avoid the
--       problem entirely -- switch the cohort expression as shown.
--    4. Timezone: event_date is in the PROPERTY timezone, so cohorts are
--       property-timezone weeks. If you try to use the UTC timestamp to derive
--       the cohort you will get a different answer around midnight. Pick one
--       and be consistent; see docs/SCHEMA-TRAPS.md trap 11.
--    5. period_number 0 is the cohort bucket itself by construction, so
--       retention_rate at period 0 is 100% and carries no information. It is
--       kept so the curve starts where people expect it to.
--
--  ASSUMPTIONS YOU MUST EDIT
--    - YOUR_PROJECT.analytics_XXXXXXXXX
--    - scan range (_TABLE_SUFFIX) -- MUST start before the first cohort date
--    - report_start / report_end -- the cohorts you want to display
--    - the cohort bucket expression (week vs month vs day)
--
--  COST / SCAN WARNING
--    Because first-touch needs history, the scan range is usually much wider
--    than the report window -- e.g. report 3 months, scan 12 months, paying
--    12 months of bytes for 3 months of output. Dry-run this one before you
--    run it, with real numbers, and consider building a small
--    first_seen table once (the query for that is at the bottom of this file,
--    commented out) so you never pay for the wide scan again.
--    docs/COST-CONTROL.md covers the materialisation recipe.
--
--  NOT EXECUTED AGAINST BIGQUERY
--    Written against the documented GA4 BigQuery export schema and
--    syntax-checked with a SQL parser. Never executed against a real
--    property. Validate against your own property with docs/VALIDATION.md.
-- ============================================================================


WITH range_bounds AS (
  -- EDIT ME. scan_start must be EARLIER than report_start -- ideally by at
  -- least as long as the retention window you intend to report, so that
  -- genuinely-new users are distinguished from users who predate the scan.
  SELECT
    DATE '2023-10-01' AS scan_start,
    DATE '2024-01-31' AS scan_end,
    DATE '2024-01-01' AS report_start,
    DATE '2024-01-31' AS report_end
),

-- Keep the _TABLE_SUFFIX literals consistent with range_bounds above. The
-- padded scan start lets a session that began on scan_start-1 be recognised.
events AS (
  SELECT
    PARSE_DATE('%Y%m%d', raw.event_date) AS event_dt,
    raw.user_pseudo_id,
    (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') AS ga_session_id
  FROM
    `YOUR_PROJECT.analytics_XXXXXXXXX.events_*` AS raw
  WHERE
    raw._TABLE_SUFFIX BETWEEN '20230930' AND '20240131'
    AND (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') IS NOT NULL
),

-- One row per session per user, with the session's start date.
sessions AS (
  SELECT
    CONCAT(user_pseudo_id, '.', CAST(ga_session_id AS STRING)) AS session_key,
    user_pseudo_id,
    MIN(event_dt) AS session_date
  FROM events
  GROUP BY session_key, user_pseudo_id, ga_session_id
),

-- FIRST SEEN per user, over the WHOLE scan range. This is the anchor.
first_seen AS (
  SELECT
    user_pseudo_id,
    MIN(session_date) AS first_seen_date,
    -- EDIT ME for a different cohort grain. Weekly (ISO Monday) is the default:
    DATE_TRUNC(MIN(session_date), ISOWEEK) AS cohort_bucket,
    -- Monthly alternative:  DATE_TRUNC(MIN(session_date), MONTH) AS cohort_bucket,
    -- Daily alternative:    MIN(session_date)                     AS cohort_bucket,
    COUNT(*)          AS lifetime_sessions_in_scan
  FROM sessions
  GROUP BY user_pseudo_id
),

-- Restrict to users whose first touch falls in the REPORT window, and to
-- sessions that fall within the report window.
cohort_members AS (
  SELECT
    f.user_pseudo_id,
    f.cohort_bucket,
    f.first_seen_date,
    f.lifetime_sessions_in_scan,
    s.session_key,
    s.session_date
  FROM first_seen AS f
  JOIN sessions AS s
    ON s.user_pseudo_id = f.user_pseudo_id
  CROSS JOIN range_bounds AS rb
  WHERE
    f.first_seen_date BETWEEN rb.report_start AND rb.report_end
    AND s.session_date  BETWEEN rb.report_start AND rb.report_end
),

-- Period offsets. DATE_DIFF in ISOWEEK units counts week boundaries crossed,
-- which is exactly what a weekly cohort needs.
periodised AS (
  SELECT
    cm.cohort_bucket,
    cm.user_pseudo_id,
    cm.session_key,
    cm.session_date,
    DATE_DIFF(DATE_TRUNC(cm.session_date, ISOWEEK), cm.cohort_bucket, ISOWEEK) AS period_number,
    -- Monthly cohorts: DATE_DIFF(DATE_TRUNC(cm.session_date, MONTH), cm.cohort_bucket, MONTH)
  FROM cohort_members AS cm
),

aggregated AS (
  SELECT
    p.cohort_bucket,
    p.period_number,
    COUNT(DISTINCT p.user_pseudo_id) AS active_users,
    COUNT(DISTINCT p.session_key)    AS sessions_in_period,
    COUNT(DISTINCT p.session_date)   AS distinct_active_days
  FROM periodised AS p
  WHERE
    p.period_number >= 0
  GROUP BY
    p.cohort_bucket,
    p.period_number
),

cohort_sizes AS (
  SELECT
    cohort_bucket,
    COUNT(DISTINCT user_pseudo_id) AS cohort_size
  FROM cohort_members
  GROUP BY cohort_bucket
)

SELECT
  a.cohort_bucket,
  cs.cohort_size,
  a.period_number,
  -- Period start date: cohort_bucket is already the Monday of the cohort week.
  DATE_ADD(a.cohort_bucket, INTERVAL a.period_number WEEK) AS period_start_date,
  a.active_users,
  ROUND(SAFE_DIVIDE(a.active_users, cs.cohort_size) * 100, 2) AS retention_rate,
  a.sessions_in_period,
  ROUND(SAFE_DIVIDE(a.sessions_in_period, a.active_users), 2) AS sessions_per_active_user,
  ROUND(SAFE_DIVIDE(a.distinct_active_days, a.active_users), 2) AS avg_days_active_in_period
FROM aggregated AS a
JOIN cohort_sizes AS cs
  ON cs.cohort_bucket = a.cohort_bucket
-- Right-censoring guard. Uncomment to report only cohorts/periods that have
-- had a full period of observation. Without it the newest cohort's tail is
-- guaranteed to look bad, for mechanical reasons rather than behavioural ones.
--
-- CROSS JOIN range_bounds AS rb
-- WHERE DATE_ADD(a.cohort_bucket, INTERVAL (a.period_number + 1) WEEK) <= rb.report_end
ORDER BY
  a.cohort_bucket,
  a.period_number;


-- ============================================================================
--  BUILD-ONCE: a tiny first_seen table (commented out -- run it deliberately)
-- ============================================================================
-- Retention is the query family where a small materialised table pays for
-- itself fastest: first_seen is one row per user, so it is thousands of times
-- smaller than the event log, and it never needs recomputing for the past.
--
-- CREATE OR REPLACE TABLE `YOUR_PROJECT.YOUR_DATASET.ga4_first_seen` AS
-- SELECT
--   user_pseudo_id,
--   MIN(PARSE_DATE('%Y%m%d', event_date)) AS first_seen_date,
--   MIN(event_timestamp)                  AS first_seen_timestamp_micros
-- FROM `YOUR_PROJECT.analytics_XXXXXXXXX.events_*`
-- WHERE
--   _TABLE_SUFFIX BETWEEN '20200101' AND '20240131'   -- EDIT ME, and re-run
--   AND (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') IS NOT NULL
-- GROUP BY user_pseudo_id;
--
-- Then this file's `first_seen` CTE becomes a plain SELECT from that table,
-- and the wide scan disappears from your monthly bill.
-- ============================================================================
