-- ============================================================================
--  02-SESSIONS-PER-USER.sql
--  GA4 BigQuery Session & Funnel SQL Pack
-- ============================================================================
--
--  QUESTION IT ANSWERS
--    "How many sessions does a typical user have, and how concentrated is my
--     traffic?" -- i.e. what share of my sessions come from users who visited
--     once versus users who keep coming back.
--
--  WHAT IT RETURNS (one row per user_pseudo_id with >=1 session in range)
--    user_pseudo_id            STRING
--    first_session_date        DATE
--    last_session_date         DATE
--    session_count             INT64
--    active_day_count          INT64  -- distinct days with >=1 session
--    engaged_session_count     INT64
--    total_event_count         INT64
--    total_conversion_events   INT64
--    avg_sessions_per_active_day FLOAT64
--    cross_device_user_id      STRING -- NULL unless user_id is set
--    first_user_source/medium  STRING -- first-touch attribution for the user
--    sessions_per_user_bucket  STRING -- '1 (single session)', '2', '3-5', '6-10', '11+'
--
--  USE IT FOR
--    - The "1 session and gone" share, which is usually the headline number.
--    - Sizing a retention problem before you build a cohort report.
--    - Sanity-checking total sessions: SUM(session_count) over this table
--      must equal the session count from 01-SESSIONISE-EVENTS.sql. If it does
--      not, you have a GROUP BY bug.
--
--  CAVEATS
--    1. A "user" here is a BROWSER/DEVICE, not a person. user_pseudo_id is a
--       client-side identifier stored in a cookie or the device's app storage.
--       One person on laptop + phone is two users; one person who clears
--       cookies is two users. So this query ALWAYS understates how many
--       sessions a real person had, and it overstates your user count. Only
--       the cross_device_user_id column (populated when you call gtag('set',
--       'user_id', ...) or the Measurement Protocol sets user_id) can join
--       those up, and even then only for signed-in traffic.
--    2. Sessions are counted by (user_pseudo_id, ga_session_id), never by
--       ga_session_id alone, which is only unique within a user. See
--       docs/SESSIONISATION.md.
--    3. Sessions that began before the padded range start appear truncated.
--       Pad by one day at each end (range_start/range_end below).
--    4. session_count counts sessions whose FIRST event falls inside the
--       padded range. Because of the padding, a handful of sessions that
--       started on the padded first day are included even though their start
--       date is outside your report window. Filter on first_session_date at
--       the end if you need strict window membership, and expect the total to
--       be slightly lower than the UI's.
--
--  ASSUMPTIONS YOU MUST EDIT
--    - YOUR_PROJECT.analytics_XXXXXXXXX
--    - the _TABLE_SUFFIX range AND the range_start/range_end dates (keep the
--      one-day padding consistent between them)
--    - conversion_event_names
--
--  COST / SCAN WARNING
--    Scans every column of every daily table in the range, aggregated down to
--    one row per user. On a large property a year of data is tens of GB. Test
--    on one day first, then dry-run the full window before you commit to it
--    (docs/COST-CONTROL.md). If you are going to run this more than twice,
--    materialise the session table (setup/create_session_table.sql) and run
--    this query against that instead -- it is roughly 100x smaller.
--
--  NOT EXECUTED AGAINST BIGQUERY
--    Written against the documented GA4 BigQuery export schema and
--    syntax-checked with a SQL parser. Never executed against a real
--    property. Validate before trusting. See README.md.
-- ============================================================================


WITH range_bounds AS (
  -- EDIT ME. Keep the one-day padding on both sides.
  SELECT
    DATE '2024-01-01' AS report_start,
    DATE '2024-01-31' AS report_end
),

-- EDIT ME: the event names you treat as conversions.
conversion_event_names AS (
  SELECT event_name FROM UNNEST(['sign_up', 'generate_lead', 'purchase', 'form_submit']) AS event_name
),

-- One row per event, with the parameters we need pulled out as scalars. Only
-- events that carry a ga_session_id participate; see 01-SESSIONISE-EVENTS.sql
-- for why.
events AS (
  SELECT
    PARSE_DATE('%Y%m%d', e.event_date) AS event_dt,
    e.event_timestamp,
    e.event_name,
    e.user_pseudo_id,
    e.user_id,
    (SELECT value.int_value FROM UNNEST(e.event_params) WHERE key = 'ga_session_id') AS ga_session_id,
    e.traffic_source.name   AS first_user_source,
    e.traffic_source.medium AS first_user_medium
  FROM
    `YOUR_PROJECT.analytics_XXXXXXXXX.events_*` AS e
  WHERE
    -- _TABLE_SUFFIX filter = partition pruning. Required.
    e._TABLE_SUFFIX BETWEEN '20231231' AND '20240201'
    AND (SELECT value.int_value FROM UNNEST(e.event_params) WHERE key = 'ga_session_id') IS NOT NULL
),

-- Collapse to one row per SESSION first, so that counting events does not
-- require counting rows in the session-level aggregation.
sessions AS (
  SELECT
    CONCAT(user_pseudo_id, '.', CAST(ga_session_id AS STRING)) AS session_key,
    user_pseudo_id,
    ga_session_id,
    MIN(event_dt)                                       AS session_start_date,
    COUNT(*)                                            AS event_count,
    COUNTIF(event_name IN (SELECT event_name FROM conversion_event_names)) AS conversion_event_count,
    TIMESTAMP_DIFF(TIMESTAMP_MICROS(MAX(event_timestamp)), TIMESTAMP_MICROS(MIN(event_timestamp)), SECOND) AS duration_sec,
    COUNTIF(event_name = 'page_view')                   AS page_view_count,
    MIN(first_user_source)                              AS first_user_source,
    MIN(first_user_medium)                              AS first_user_medium,
    MAX(user_id)                                        AS cross_device_user_id
  FROM events
  GROUP BY session_key, user_pseudo_id, ga_session_id
),

per_user AS (
  SELECT
    user_pseudo_id,
    MIN(session_start_date)                              AS first_session_date,
    MAX(session_start_date)                              AS last_session_date,
    COUNT(*)                                             AS session_count,
    COUNT(DISTINCT session_start_date)                   AS active_day_count,
    COUNTIF(duration_sec > 10 OR conversion_event_count >= 1 OR page_view_count >= 2) AS engaged_session_count,
    SUM(event_count)                                     AS total_event_count,
    SUM(conversion_event_count)                          AS total_conversion_events,
    MIN(first_user_source)                               AS first_user_source,
    MIN(first_user_medium)                               AS first_user_medium,
    MAX(cross_device_user_id)                            AS cross_device_user_id
  FROM sessions
  GROUP BY user_pseudo_id
)

SELECT
  p.user_pseudo_id,
  p.first_session_date,
  p.last_session_date,
  p.session_count,
  p.active_day_count,
  p.engaged_session_count,
  p.total_event_count,
  p.total_conversion_events,
  ROUND(SAFE_DIVIDE(p.session_count, p.active_day_count), 2) AS avg_sessions_per_active_day,
  p.cross_device_user_id,
  p.first_user_source,
  p.first_user_medium,
  CASE
    WHEN p.session_count = 1  THEN '1 (single session)'
    WHEN p.session_count = 2  THEN '2'
    WHEN p.session_count <= 5 THEN '3-5'
    WHEN p.session_count <= 10 THEN '6-10'
    ELSE '11+'
  END AS sessions_per_user_bucket
FROM per_user AS p
ORDER BY
  p.session_count DESC,
  p.user_pseudo_id;
