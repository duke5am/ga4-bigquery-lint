-- ============================================================================
--  05-CONVERSIONS-BY-CHANNEL.sql
--  GA4 BigQuery Session & Funnel SQL Pack
-- ============================================================================
--
--  QUESTION IT ANSWERS
--    "Which channel drives my signups?" -- and, just as important, "is the
--     channel that drives the most traffic the channel that drives the most
--     conversions, or is it just the channel that costs the most?"
--
--  WHAT IT RETURNS (one row per channel x conversion event name)
--    channel_group            STRING -- simplified default grouping
--    session_source / session_medium   STRING -- the raw values behind it
--    session_campaign         STRING
--    conversion_event_name    STRING
--    conversion_events        INT64  -- number of times the event fired
--    converting_sessions      INT64  -- sessions that fired it at least once
--    converting_users         INT64  -- distinct user_pseudo_id that fired it
--    converting_user_ids      INT64  -- distinct user_id where it is set
--    total_sessions           INT64  -- all sessions in the same channel (same
--                                      value repeated per conversion event row)
--    sessions_per_conversion  FLOAT64 -- total_sessions / converting_sessions
--    session_conversion_rate  FLOAT64 -- converting_sessions / total_sessions
--    events_per_converting_session FLOAT64
--    first_conversion_date / last_conversion_date  DATE
--    conversion_revenue_usd   FLOAT64 -- NULL unless ecommerce is configured
--
--  HOW TO READ total_sessions
--    total_sessions is the number of sessions in that channel whether or not
--    they converted -- it is the denominator. Because the query is grouped by
--    conversion event name as well, the same channel's total_sessions appears
--    on several rows if you track several conversion events. Do NOT sum that
--    column down the page; it will double count. Sum converting_sessions and
--    conversion_events; read total_sessions from any one row per channel.
--    (If you want strictly additive numbers, filter to a single
--    conversion_event_name in the WHERE clause at the bottom.)
--
--  CHANNEL ATTRIBUTION SEMANTICS -- WHICH ONE AM I ACTUALLY REPORTING?
--    This query reports SESSION-scoped attribution: it groups a conversion by
--    the source/medium of the session the conversion happened in. That is
--    "last non-direct click within the session", which is close to GA4's
--    default data-driven/last-click reports but not identical to all of them.
--    The export also lets you do two other attributions, and they give
--    different answers -- this is a real reason your numbers disagree with a
--    colleague's:
--      - FIRST-TOUCH, user-scoped: traffic_source.source / traffic_source.medium
--        (and traffic_source.name, which is the campaign). Frozen at the
--        user's very first session, so every later conversion from that user
--        is credited to the original channel.
--      - LAST-CLICK, session-scoped: session_traffic_source_last_click.
--        manual_campaign.* -- available in exports from mid-2023. This is what
--        the query prefers, falling back to the event params when the column
--        is not populated.
--    To switch, change the COALESCE lines in the `sessions` CTE. Do not mix
--    the two in one report without labelling which is which.
--
--  CAVEATS
--    1. cross-device: converting_users counts user_pseudo_id, which is
--       per-device. GA4's UI "Users" metric is also based on this identifier,
--       so the two should be close, but neither is people.
--    2. Channels that GA4's UI separates using ad-network metadata the export
--       does not fully carry will fall into 'Google Ads'/'Paid Other'/'Other
--       / Custom' here and may not line up with the UI's channel names. Read
--       docs/SCHEMA-TRAPS.md trap 9 before publishing a channel table.
--    3. Conversion event names are yours to define. The list at the top is a
--       placeholder. If a name in the list does not exist in your export the
--       query still runs and simply produces no rows for it -- it will NOT
--       error, which is a silent-failure mode. Check the list against your own
--       data with the DISTINCT-events probe described in docs/VALIDATION.md.
--    4. Sessions window: conversions are attributed to the session's START
--       date, because the query joins on the session key rather than the event
--       date. A conversion at 00:05 counts to the previous day's session, which
--       matches GA4's session-scoped reports but will look "off by a few" if
--       you compare against an event-date-based export of the same data.
--    5. Only events that carry a ga_session_id can be attributed. A conversion
--       that arrives without one (some Measurement Protocol and server-side
--       setups) is excluded entirely. This is reported as part of the
--       data-quality reconciliation in docs/VALIDATION.md and is one of the
--       legitimate reasons your total is below the UI's.
--
--  ASSUMPTIONS YOU MUST EDIT
--    - YOUR_PROJECT.analytics_XXXXXXXXX
--    - padded _TABLE_SUFFIX range
--    - conversion_event_names -- REPLACE WITH YOUR OWN EVENT NAMES
--
--  COST / SCAN WARNING
--    Two-pass shape: the session rollup needs every event in range, so this is
--    an all-columns scan of every day in the window. This is the query most
--    worth running against a materialised session table instead of raw events
--    (setup/create_session_table.sql). Test on one day, dry-run the month,
--    then decide. docs/COST-CONTROL.md.
--
--  NOT EXECUTED AGAINST BIGQUERY
--    Written against the documented GA4 BigQuery export schema and
--    syntax-checked with a SQL parser. Never executed against a real
--    property. Validate against your own property with docs/VALIDATION.md.
-- ============================================================================


WITH range_bounds AS (
  -- EDIT ME: padded window.
  SELECT
    DATE '2024-01-01' AS report_start,
    DATE '2024-01-31' AS report_end
),

-- EDIT ME: your conversion event names. See caveat 3.
conversion_event_names AS (
  SELECT event_name FROM UNNEST(['sign_up', 'generate_lead', 'purchase', 'form_submit']) AS event_name
),

events AS (
  SELECT
    PARSE_DATE('%Y%m%d', raw.event_date) AS event_dt,
    raw.event_timestamp,
    raw.event_name,
    raw.user_pseudo_id,
    raw.user_id,
    (SELECT value.int_value    FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id')  AS ga_session_id,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'source')         AS param_source,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'medium')         AS param_medium,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'campaign')       AS param_campaign,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'term')           AS param_term,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'content')        AS param_content,
    -- event_value_in_usd is a FLOAT64 and is NULL on almost every non-ecommerce
    -- event. Summing it without COALESCE gives NULL for the whole column.
    raw.event_value_in_usd,
    raw.session_traffic_source_last_click.manual_campaign.source AS last_click_source,
    raw.session_traffic_source_last_click.manual_campaign.medium AS last_click_medium,
    raw.session_traffic_source_last_click.manual_campaign.campaign_name   AS last_click_campaign,
    raw.traffic_source.source AS first_user_source,
    raw.traffic_source.medium AS first_user_medium,
    raw.traffic_source.name   AS first_user_campaign
  FROM
    `YOUR_PROJECT.analytics_XXXXXXXXX.events_*` AS raw
  WHERE
    raw._TABLE_SUFFIX BETWEEN '20231231' AND '20240201'
    AND (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') IS NOT NULL
),

-- One row per session, carrying the channel the session is credited to and its
-- conversion counts. MIN() over the session's own events is safe here because
-- attribution parameters are written consistently across a session -- if they
-- are not, MIN() picks one deterministically rather than at random, which is
-- the best available behaviour.
sessions AS (
  SELECT
    CONCAT(user_pseudo_id, '.', CAST(ga_session_id AS STRING)) AS session_key,
    MIN(event_dt)                                             AS session_date,
    user_pseudo_id,
    MAX(user_id)                                              AS user_id,
    COALESCE(MIN(last_click_source), MIN(param_source), MIN(first_user_source))     AS session_source,
    COALESCE(MIN(last_click_medium), MIN(param_medium), MIN(first_user_medium))     AS session_medium,
    COALESCE(MIN(last_click_campaign), MIN(param_campaign), MIN(first_user_campaign)) AS session_campaign,
    MIN(param_term)                                           AS session_term,
    MIN(param_content)                                        AS session_content,
    COUNTIF(event_name IN (SELECT event_name FROM conversion_event_names)) AS conversion_event_count,
    TIMESTAMP_DIFF(TIMESTAMP_MICROS(MAX(event_timestamp)), TIMESTAMP_MICROS(MIN(event_timestamp)), SECOND) AS duration_sec,
    SUM(COALESCE(event_value_in_usd, 0))                      AS session_revenue_usd
  FROM events
  GROUP BY session_key, user_pseudo_id, ga_session_id
),

channelised AS (
  SELECT
    s.*,
    CASE
      WHEN LOWER(COALESCE(s.session_source, '')) = 'direct'
        OR (s.session_source IS NULL AND s.session_medium IS NULL) THEN 'Direct'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(s.session_medium, '')), r'^(cpc|ppc|paidsearch|paid_search)$')
        AND REGEXP_CONTAINS(LOWER(COALESCE(s.session_source, '')), r'google') THEN 'Google Ads'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(s.session_medium, '')), r'^(cpc|ppc|paidsearch|paid_search)$')
        AND REGEXP_CONTAINS(LOWER(COALESCE(s.session_source, '')), r'bing|microsoft|msn|adwords') THEN 'Microsoft Ads'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(s.session_medium, '')), r'^(cpc|ppc|paidsearch|paid_search|paid|paid_social|paidsocial|display|banner|retargeting)$') THEN 'Paid Other'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(s.session_medium, '')), r'^organic') THEN 'Organic Search'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(s.session_medium, '')), r'^(email|e-mail|newsletter)$') THEN 'Email'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(s.session_medium, '')), r'^(referral|referrer|link)$') THEN 'Referral'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(s.session_medium, '')), r'^(social|organic_social|social-network|social-media|sms|push|whatsapp|messenger)$') THEN 'Organic Social'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(s.session_medium, '')), r'^affiliate') THEN 'Affiliates'
      ELSE 'Other / Custom'
    END AS channel_group
  FROM sessions AS s
),

-- Join the session rollup back to the conversion EVENTS so that a session that
-- converted three times contributes three event rows but one session row.
-- Counting both in one pass is what lets this report events and sessions side
-- by side -- the two numbers that get confused in almost every disagreement
-- with the UI.
conversion_events AS (
  SELECT
    c.channel_group,
    c.session_source,
    c.session_medium,
    c.session_campaign,
    c.session_key,
    c.user_pseudo_id,
    c.user_id,
    c.session_date,
    e.event_name            AS conversion_event_name,
    e.event_dt              AS conversion_date,
    COALESCE(e.event_value_in_usd, 0) AS conversion_value_usd
  FROM channelised AS c
  JOIN events AS e
    ON e.user_pseudo_id = c.user_pseudo_id
   AND e.ga_session_id   = c.ga_session_id
  WHERE
    e.event_name IN (SELECT event_name FROM conversion_event_names)
),

channel_totals AS (
  SELECT
    channel_group,
    COUNT(*) AS total_sessions
  FROM channelised
  GROUP BY channel_group
)

SELECT
  ce.channel_group,
  ce.session_source,
  ce.session_medium,
  ce.session_campaign,
  ce.conversion_event_name,
  COUNT(*)                                              AS conversion_events,
  COUNT(DISTINCT ce.session_key)                        AS converting_sessions,
  COUNT(DISTINCT ce.user_pseudo_id)                     AS converting_users,
  COUNT(DISTINCT ce.user_id)                            AS converting_user_ids,
  ct.total_sessions,
  ROUND(SAFE_DIVIDE(ct.total_sessions, COUNT(DISTINCT ce.session_key)), 2) AS sessions_per_conversion,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT ce.session_key), ct.total_sessions) * 100, 2) AS session_conversion_rate,
  ROUND(SAFE_DIVIDE(COUNT(*), COUNT(DISTINCT ce.session_key)), 2) AS events_per_converting_session,
  MIN(ce.conversion_date)                                AS first_conversion_date,
  MAX(ce.conversion_date)                                AS last_conversion_date,
  -- NULL, not 0, when there is no ecommerce data: a 0 would read as "we
  -- measured zero revenue" rather than "we did not measure revenue".
  IF(SUM(ce.conversion_value_usd) = 0, NULL, SUM(ce.conversion_value_usd)) AS conversion_revenue_usd
FROM conversion_events AS ce
LEFT JOIN channel_totals AS ct
  ON ct.channel_group = ce.channel_group
GROUP BY
  ce.channel_group,
  ce.session_source,
  ce.session_medium,
  ce.session_campaign,
  ce.conversion_event_name,
  ct.total_sessions
HAVING
  -- Guard: drop rows whose channel is NULL, which would otherwise appear as a
  -- phantom 'null' channel.
  ce.channel_group IS NOT NULL
ORDER BY
  conversion_events DESC,
  ce.channel_group,
  ce.conversion_event_name;
