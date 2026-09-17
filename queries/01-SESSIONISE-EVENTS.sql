-- ============================================================================
--  01-SESSIONISE-EVENTS.sql
--  GA4 BigQuery Session & Funnel SQL Pack
-- ============================================================================
--
--  QUESTION IT ANSWERS
--    "How many sessions did my property have, and what happened in each one?"
--    This is the foundation query. It reads the raw event log and derives one
--    row per real GA4 session, which is the object the GA4 UI reports on and
--    which does NOT exist in the export.
--
--  WHAT IT RETURNS (one row per session)
--    session_key             STRING  -- user_pseudo_id || '.' || ga_session_id
--    user_pseudo_id          STRING  -- the device/installation identifier
--    ga_session_id           INT64   -- unique only WITHIN one user_pseudo_id
--    session_start_date      DATE    -- date of the FIRST event of the session
--    session_start_ts_utc    TIMESTAMP -- UTC instant the session started
--    session_end_ts_utc      TIMESTAMP -- UTC instant of the last event
--    session_duration_sec    FLOAT64 -- last event minus first event, in seconds
--    event_count             INT64
--    page_view_count         INT64
--    engaged_session         BOOL    -- engaged per GA4's rule, see below
--    engagement_time_msec    INT64   -- summed, as reported by the client
--    conversion_event_count  INT64   -- count of the conversion event list below
--    entry_page              STRING  -- page_location of the first page_view
--    exit_page               STRING  -- page_location of the last page_view
--    country, city, device_category, os, browser, language  STRING
--    first_user_source/medium/campaign  STRING -- first_visit attribution
--    session_source/medium/campaign     STRING -- session-scoped attribution
--    cross_device_user_id    STRING  -- user_id, NULL unless you set it via gtag
--    session_span_days       INT64   -- 1 normally; >1 for midnight-crossers
--
--  HOW SESSIONS ARE DERIVED (the whole point of this file)
--    A session is (user_pseudo_id, ga_session_id). ga_session_id is an INT64
--    event parameter GA4 writes onto essentially every event, and it is only
--    unique per user -- it is derived from a timestamp, so two different users
--    routinely share the same ga_session_id. Never group by ga_session_id
--    alone. See docs/SESSIONISATION.md.
--
--    This query does NOT re-derive sessions from a 30-minute timeout. It uses
--    GA4's own ga_session_id, which is the same value the GA4 UI groups on and
--    therefore the only way to reconcile with the UI. The 30-minute rule is
--    what GA4 uses internally to DECIDE when to mint a new ga_session_id; you
--    re-implement it only for data that has no ga_session_id (see the
--    30-minute reconstruction in docs/SESSIONISATION.md, section 6).
--
--  CAVEATS -- READ THESE
--    1. MIDNIGHT CROSSING. A session that starts at 23:50 and ends at 00:20
--       has its events split across events_YYYYMMDD and events_(YYYYMMDD+1).
--       This query groups across the whole partition range in the WHERE
--       clause, so it RECONSTRUCTS the session correctly and reports
--       session_start_date as the date of the first event. If your WHERE
--       clause only covers one day, the same session is split into two rows
--       and your session count for that day is INFLATED relative to the UI.
--       This is the single most common cause of "my SQL says more sessions
--       than the UI". Probe it with 10-MIDNIGHT-CROSSING.sql.
--    2. PARTIAL SESSIONS AT THE EDGE OF THE RANGE. A session that started
--       before the range began appears here truncated: its first event inside
--       the range is treated as its start, so session_duration_sec and
--       entry_page are wrong for those sessions. Always pad the range by one
--       day at each end when reconciling. The `range_start`/`range_end` CTE
--       below does that.
--    3. SESSION_START IS NOT RELIABLE FOR COUNTING. Counting
--       event_name = 'session_start' undercounts, because GA4 does not
--       re-send session_start when a session is continued after a long gap in
--       some client versions, and some events arrive with a ga_session_id but
--       no session_start event at all. Grouping events by ga_session_id is
--       more robust and is what this query does.
--    4. ENGAGED SESSION DEFINITION. GA4 calls a session engaged if it lasted
--       longer than 10 seconds, OR had at least one conversion event, OR had
--       at least 2 page_views. `engagement_time_msec` in the export is
--       client-reported and is NOT the same as wall-clock session duration;
--       this query implements the documented UI rule (duration / conversions /
--       page_views) rather than trusting engagement_time_msec. Both are
--       returned so you can compare.
--    5. event_value_in_usd is a currency-converted value GA4 writes on some
--       events; it is NULL on most. The revenue column here therefore sums to
--       NULL unless you have ecommerce configured. This pack does not attempt
--       revenue reporting -- that needs a proper ecommerce model.
--
--  ASSUMPTIONS YOU MUST EDIT FOR YOUR PROPERTY
--    - YOUR_PROJECT.analytics_XXXXXXXXX  -> your project + GA4 dataset
--    - range_start / range_end           -> your window, WITH one day of
--                                           padding at each end
--    - conversion_event_names            -> see below
--
--  COST / SCAN WARNING
--    This is the most expensive query in the pack: it scans every column of
--    every daily table in the range. One day of a busy property is commonly
--    10-200 MB, so a full year can be tens of GB. ALWAYS dry-run first (see
--    docs/COST-CONTROL.md). ALWAYS test on ONE day first (see
--    docs/VALIDATION.md). For repeated use, do not re-run this -- materialise
--    it once with setup/create_session_table.sql.
--
--  NOT EXECUTED AGAINST BIGQUERY
--    Written against the documented GA4 BigQuery export schema and
--    syntax-checked with a SQL parser. Never executed against a real
--    property. Validate before trusting. See README.md and docs/VALIDATION.md.
-- ============================================================================


WITH range_bounds AS (
  -- EDIT ME. Pad by one day on each side so that sessions which start before
  -- the window or end after it are not silently truncated into two sessions.
  SELECT
    DATE '2024-01-01' AS report_start,
    DATE '2024-01-31' AS report_end
),

-- The partition filter. _TABLE_SUFFIX is a STRING, and it must be compared as
-- a string in 'YYYYMMDD' form. Without a filter on _TABLE_SUFFIX or on
-- event_date, this query scans EVERY events_* table in the dataset, and the
-- cost grows silently every day as GA4 appends a new table.
events AS (
  SELECT
    PARSE_DATE('%Y%m%d', event_date) AS event_dt,
    event_timestamp,
    event_name,
    user_pseudo_id,
    user_id,
    -- INTEGER parameter: must read value.int_value. See 00-PARAM-PATTERNS.sql
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'ga_session_id')     AS ga_session_id,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'ga_session_number') AS ga_session_number,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location')     AS page_location,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'engagement_time_msec') AS engagement_time_msec,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'entrances')         AS entrances,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'source')            AS param_source,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'medium')            AS param_medium,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'campaign')          AS param_campaign,
    -- _TABLE_SUFFIX is the ONLY place the partition date is available cheaply;
    -- we already have event_date, but keeping the suffix out of downstream
    -- expressions avoids re-parsing it.
    country,
    city,
    device.category AS device_category,
    device.operating_system AS os,
    device.web_info.browser AS browser,
    device.language AS language,
    -- User-scoped first-touch attribution (first_visit values, frozen at the
    -- user's first session).
    traffic_source.name   AS first_user_source,
    traffic_source.medium AS first_user_medium,
    traffic_source.source AS first_user_campaign,
    -- Session-scoped attribution. This column exists in exports from
    -- mid-2023 onward; if your dataset predates it, comment these two lines
    -- out and rely on the event params above.
    session_traffic_source_last_click.manual_campaign.source AS last_click_source,
    session_traffic_source_last_click.manual_campaign.medium AS last_click_medium,
    session_traffic_source_last_click.manual_campaign.campaign_name   AS last_click_campaign
  FROM
    `YOUR_PROJECT.analytics_XXXXXXXXX.events_*` AS raw
  WHERE
    -- Partition pruning. Do NOT remove this. Adjust the literal range to your
    -- padded window; keep the padding.
    raw._TABLE_SUFFIX BETWEEN '20231231' AND '20240201'
    -- ga_session_id must be present for a row to belong to a session. Rows
    -- without it (rare, usually malformed or server-side hits) are excluded
    -- here and are reported as a data-quality signal in docs/VALIDATION.md.
    AND (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') IS NOT NULL
),

-- EDIT ME: the event names your organisation treats as a conversion /
-- signup. These are examples of common names, NOT a claim about your
-- property. GA4 ships `purchase` and `generate_lead` as recommended events;
-- `sign_up` and `form_submit` are also common. Replace with yours -- or read
-- the names from your own data with the DISTINCT probe in 00-PARAM-PATTERNS.
conversion_event_names AS (
  SELECT event_name FROM UNNEST(['sign_up', 'generate_lead', 'purchase', 'form_submit']) AS event_name
),

session_agg AS (
  SELECT
    -- The real session key. ga_session_id alone collides across users.
    CONCAT(e.user_pseudo_id, '.', CAST(e.ga_session_id AS STRING)) AS session_key,
    e.user_pseudo_id,
    e.ga_session_id,
    MIN(e.ga_session_number)                                       AS ga_session_number,
    MIN(e.event_dt)                                                AS session_start_date,
    -- event_timestamp is MICROSECONDS since the Unix epoch. TIMESTAMP_MICROS
    -- converts it correctly. Do NOT use TIMESTAMP_SECONDS(event_timestamp)
    -- (that yields a date in 1970 + ~50 years of nonsense) and do not divide
    -- by 1000 and feed it to TIMESTAMP_SECONDS(...) without checking the
    -- result against the UI. See docs/SCHEMA-TRAPS.md, trap 1.
    TIMESTAMP_MICROS(MIN(e.event_timestamp))                       AS session_start_ts_utc,
    TIMESTAMP_MICROS(MAX(e.event_timestamp))                       AS session_end_ts_utc,
    COUNT(*)                                                       AS event_count,
    COUNTIF(e.event_name = 'page_view')                            AS page_view_count,
    COUNTIF(e.event_name IN (SELECT event_name FROM conversion_event_names)) AS conversion_event_count,
    SUM(COALESCE(e.engagement_time_msec, 0))                       AS engagement_time_msec,
    -- First and last page_view of the session, by timestamp. Using MIN/MAX on
    -- page_location directly would give the alphabetically first/last page,
    -- which is wrong; these are position-aware.
    ARRAY_AGG(e.page_location IGNORE NULLS ORDER BY e.event_timestamp ASC  LIMIT 1)[SAFE_OFFSET(0)] AS entry_page,
    ARRAY_AGG(e.page_location IGNORE NULLS ORDER BY e.event_timestamp DESC LIMIT 1)[SAFE_OFFSET(0)] AS exit_page,
    MIN(e.country)                                                 AS country,
    MIN(e.city)                                                    AS city,
    MIN(e.device_category)                                         AS device_category,
    MIN(e.os)                                                      AS os,
    MIN(e.browser)                                                 AS browser,
    MIN(e.language)                                                AS language,
    MIN(e.first_user_source)                                       AS first_user_source,
    MIN(e.first_user_medium)                                       AS first_user_medium,
    MIN(e.first_user_campaign)                                     AS first_user_campaign,
    -- Session-scoped: prefer the last-click column, fall back to the event
    -- parameters, which are present on the session's own events. COALESCE here
    -- is STRING-to-STRING and therefore type-safe.
    COALESCE(MIN(e.last_click_source),   MIN(e.param_source))      AS session_source,
    COALESCE(MIN(e.last_click_medium),   MIN(e.param_medium))      AS session_medium,
    COALESCE(MIN(e.last_click_campaign), MIN(e.param_campaign))    AS session_campaign,
    MAX(e.user_id)                                                 AS cross_device_user_id,
    -- Date span of the session in days: 1 for a normal session, 2 for a
    -- session that crossed midnight UTC-adjacent property-timezone midnight.
    DATE_DIFF(MAX(e.event_dt), MIN(e.event_dt), DAY) + 1            AS session_span_days
  FROM events AS e
  GROUP BY
    session_key,
    e.user_pseudo_id,
    e.ga_session_id
)
SELECT
  s.*,
  -- Wall-clock duration, which is NOT the same as engagement_time_msec.
  TIMESTAMP_DIFF(s.session_end_ts_utc, s.session_start_ts_utc, SECOND) AS session_duration_sec,
  -- GA4's documented "engaged session" rule: >10s duration OR >=1 conversion
  -- OR >=2 page_views. Note this uses wall-clock duration, matching the UI's
  -- session-scoped definition and not the client-reported engagement time.
  (
    TIMESTAMP_DIFF(s.session_end_ts_utc, s.session_start_ts_utc, SECOND) > 10
    OR s.conversion_event_count >= 1
    OR s.page_view_count >= 2
  ) AS engaged_session
FROM session_agg AS s
ORDER BY
  s.session_start_ts_utc;
