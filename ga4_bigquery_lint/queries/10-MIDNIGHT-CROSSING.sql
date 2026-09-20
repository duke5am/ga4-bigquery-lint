-- ============================================================================
--  10-MIDNIGHT-CROSSING.sql
--  GA4 BigQuery Session & Funnel SQL Pack
-- ============================================================================
--
--  QUESTION IT ANSWERS
--    "Why does my SQL report MORE sessions for a day than the GA4 UI does?"
--    Almost always this: sessions that cross midnight are split in two when
--    you group per day, and counted twice.
--
--  WHAT IT RETURNS (one row per session that has events on more than one date)
--    session_key             STRING
--    user_pseudo_id          STRING
--    ga_session_id           INT64
--    first_event_date        DATE   -- the date the session COUNTED for
--    last_event_date         DATE   -- the date the session spilled into
--    span_days               INT64  -- 2 for a single midnight crossing
--    session_start_ts_utc    TIMESTAMP
--    session_end_ts_utc      TIMESTAMP
--    events_on_first_date    INT64
--    events_on_last_date     INT64
--    total_events            INT64
--    entry_page              STRING
--    exit_page               STRING
--
--  ALSO RETURNS (second statement, run separately) a per-day count of INFLATED
--  sessions -- how many extra sessions a naive per-day query would invent.
--  That number is the size of your reconciliation gap, and knowing it turns
--  "my SQL is wrong somewhere" into "my SQL is wrong by exactly this much, for
--  this mechanical reason".
--
--  THE MECHANISM, PRECISELY
--    GA4's export writes each event into the events_YYYYMMDD table for the
--    event's date IN THE PROPERTY TIMEZONE. A session is identified by
--    (user_pseudo_id, ga_session_id) and it spans real time, so a session that
--    starts at 23:52 and ends at 00:14 has its events in two different daily
--    tables -- and even inside one day, GROUP BY event_date splits it.
--
--    If you write:
--        SELECT event_date, COUNT(DISTINCT session_key) ...
--        GROUP BY event_date
--    then that one session contributes one session to day 1 and one to day 2.
--    Day 1 is CORRECT (the session started then), day 2 is INFLATED by one.
--    The GA4 UI attributes the whole session to its START date, which is why
--    the UI's number for the earlier day matches and the later day is high.
--
--    The fix is to compute the session's start date first, then group by that
--    start date. Which is exactly what 01-SESSIONISE-EVENTS.sql does.
--
--  CAVEATS
--    1. This query must scan a WIDER range than the day you are checking --
--       it needs the day before and the day after to see both halves. The
--       range below is written for a single report day (`20240115`) with one
--       day of padding each side. Widen `report_day` and the suffixes together.
--    2. A session that starts at 23:59:59 and has one event is NOT a
--       midnight-crosser even though it is 'late' -- it only appears here if
--       it genuinely has events on two dates.
--    3. To be precise about it: because event_date is property-timezone, a
--       session crossing a UTC midnight but not a property midnight does NOT
--       appear here, and a session crossing property midnight may not cross
--       UTC midnight. Both are correct; the export follows the property
--       timezone, the raw event_timestamp is an absolute UTC instant. Do not
--       'fix' this by comparing UTC dates with property dates -- see
--       docs/SCHEMA-TRAPS.md trap 11.
--    4. Span can exceed 2 days for a session left open in a background tab on
--       a mobile device: GA4 will keep the session id alive if events keep
--       arriving within the timeout window. Those are rare, real, and are
--       returned here rather than filtered out. A span_days value above 2 is
--       worth eyeballing but is not automatically a bug.
--    5. Sessions where ga_session_id is NULL cannot be identified at all and
--       are excluded. That exclusion is deliberate and is measured separately
--       in docs/VALIDATION.md.
--
--  ASSUMPTIONS YOU MUST EDIT
--    - YOUR_PROJECT.analytics_XXXXXXXXX
--    - report_day (a single DATE) and the day before/after as the
--      _TABLE_SUFFIX range
--
--  COST / SCAN WARNING
--    Three days of data. This is the cheapest meaningful query in the pack --
--    run it BEFORE anything else on a new property, because it tells you how
--    large your reconciliation gap is and therefore how much time to spend
--    chasing it. Dry-run is optional at this size; docs/COST-CONTROL.md.
--
--  NOT EXECUTED AGAINST BIGQUERY
--    Written against the documented GA4 BigQuery export schema and
--    syntax-checked with a SQL parser. Never executed against a real
--    property. The claim that this is your reconciliation gap is a diagnosis,
--    not a measurement -- run it on your data. See docs/VALIDATION.md.
-- ============================================================================


-- ============================================================================
--  STATEMENT 1 -- the midnight-crossing sessions themselves
-- ============================================================================
WITH params AS (
  -- EDIT ME: the single day you are investigating.
  SELECT
    DATE '2024-01-15' AS report_day,
    '20240115'        AS report_day_suffix
),

events AS (
  SELECT
    PARSE_DATE('%Y%m%d', raw.event_date) AS event_dt,
    raw.event_timestamp,
    raw.user_pseudo_id,
    (SELECT value.int_value    FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') AS ga_session_id,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'page_location')  AS page_location
  FROM
    `YOUR_PROJECT.analytics_XXXXXXXXX.events_*` AS raw
  WHERE
    -- Report day plus one day either side. EDIT ME alongside report_day.
    raw._TABLE_SUFFIX BETWEEN '20240114' AND '20240116'
    AND (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') IS NOT NULL
),

sessions AS (
  SELECT
    CONCAT(user_pseudo_id, '.', CAST(ga_session_id AS STRING)) AS session_key,
    user_pseudo_id,
    ga_session_id,
    MIN(event_dt)                                    AS first_event_date,
    MAX(event_dt)                                    AS last_event_date,
    DATE_DIFF(MAX(event_dt), MIN(event_dt), DAY) + 1 AS span_days,
    TIMESTAMP_MICROS(MIN(event_timestamp))           AS session_start_ts_utc,
    TIMESTAMP_MICROS(MAX(event_timestamp))           AS session_end_ts_utc,
    COUNT(*)                                         AS total_events,
    COUNTIF(event_dt = MIN(event_dt))                AS events_on_first_date,
    COUNTIF(event_dt = MAX(event_dt))                AS events_on_last_date,
    ARRAY_AGG(page_location IGNORE NULLS ORDER BY event_timestamp ASC  LIMIT 1)[SAFE_OFFSET(0)] AS entry_page,
    ARRAY_AGG(page_location IGNORE NULLS ORDER BY event_timestamp DESC LIMIT 1)[SAFE_OFFSET(0)] AS exit_page
  FROM events
  GROUP BY
    session_key,
    user_pseudo_id,
    ga_session_id
)

SELECT
  s.session_key,
  s.user_pseudo_id,
  s.ga_session_id,
  s.first_event_date,
  s.last_event_date,
  s.span_days,
  s.session_start_ts_utc,
  s.session_end_ts_utc,
  s.events_on_first_date,
  s.events_on_last_date,
  s.total_events,
  s.entry_page,
  s.exit_page
FROM sessions AS s
CROSS JOIN params AS p
WHERE
  -- Only the sessions that genuinely span more than one date.
  s.span_days > 1
  -- And only those whose span touches the report day, so the output stays
  -- small even on a very large property.
  AND p.report_day BETWEEN s.first_event_date AND s.last_event_date
ORDER BY
  s.total_events DESC,
  s.session_key;


-- ============================================================================
--  STATEMENT 2 -- how many sessions a naive per-day query would invent
-- ============================================================================
-- Run this separately. The output is the daily size of your reconciliation
-- gap: `invented_sessions_by_naive_grouping` is the number of EXTRA rows a
-- `GROUP BY event_date, session_key` query produces compared with a correct
-- session-start-date grouping, for that one day.
--
-- WITH params AS (
--   SELECT DATE '2024-01-15' AS report_day, '20240115' AS report_day_suffix
-- ),
--
-- events AS (
--   SELECT
--     PARSE_DATE('%Y%m%d', raw.event_date) AS event_dt,
--     raw.user_pseudo_id,
--     (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') AS ga_session_id
--   FROM `YOUR_PROJECT.analytics_XXXXXXXXX.events_*` AS raw
--   WHERE
--     raw._TABLE_SUFFIX BETWEEN '20240114' AND '20240116'
--     AND (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') IS NOT NULL
-- ),
--
-- sessions AS (
--   SELECT
--     CONCAT(user_pseudo_id, '.', CAST(ga_session_id AS STRING)) AS session_key,
--     MIN(event_dt) AS session_start_date,
--     MAX(event_dt) AS session_end_date
--   FROM events
--   GROUP BY session_key, user_pseudo_id, ga_session_id
-- )
--
-- SELECT
--   p.report_day,
--   -- Correct answer: sessions that STARTED on the report day.
--   COUNTIF(s.session_start_date = p.report_day)                       AS sessions_by_start_date,
--   -- What a naive per-day GROUP BY would produce: sessions with any event
--   -- on the report day, including their spillover half.
--   COUNTIF(s.session_start_date <= p.report_day AND s.session_end_date >= p.report_day)
--                                                                     AS sessions_touching_day,
--   COUNTIF(s.session_start_date < p.report_day AND s.session_end_date >= p.report_day)
--                                                                     AS invented_sessions_by_naive_grouping,
--   -- The share of the day's correct count that the naive query inflates by.
--   -- If you want the UI's number, use sessions_by_start_date.
--   ROUND(
--     SAFE_DIVIDE(
--       COUNTIF(s.session_start_date < p.report_day AND s.session_end_date >= p.report_day),
--       COUNTIF(s.session_start_date = p.report_day)
--     ) * 100, 3
--   )                                                                  AS pct_inflation
-- FROM sessions AS s
-- CROSS JOIN params AS p
-- GROUP BY p.report_day;
--
-- Reading the result:
--   pct_inflation of 0.0-2%  -> normal. A handful of sessions, ignore it, but
--                               still use the start-date grouping so it does
--                               not compound over a year.
--   pct_inflation above ~5%  -> something else is going on. Check for events
--                               with a stale ga_session_id arriving late, or
--                               a large volume of long-lived sessions. Read
--                               docs/SESSIONISATION.md section 7.
-- ============================================================================
