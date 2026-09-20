-- ============================================================================
--  03-ENGAGED-SESSIONS.sql
--  GA4 BigQuery Session & Funnel SQL Pack
-- ============================================================================
--
--  QUESTION IT ANSWERS
--    "What share of my sessions are engaged, and how does that vary by day,
--     channel and device?" -- the session-quality counterpart to raw session
--    counts. Traffic that went up while engagement fell is the thing this
--    query is for.
--
--  WHAT IT RETURNS (one row per date x channel group x device category)
--    session_date            DATE
--    channel_group           STRING  -- default channel grouping (see below)
--    device_category         STRING
--    sessions                INT64
--    engaged_sessions        INT64
--    engagement_rate         FLOAT64 -- engaged_sessions / sessions
--    sessions_over_10s       INT64   -- rule 1 of GA4's engagement definition
--    sessions_with_conv      INT64   -- rule 2
--    sessions_2plus_pages    INT64   -- rule 3
--    avg_session_duration_sec FLOAT64
--    avg_page_views_per_session FLOAT64
--    pct_sessions_over_10s / pct_sessions_with_conv / pct_sessions_2plus_pages
--                            FLOAT64 -- lets you see WHICH rule is doing the work
--
--  THE ENGAGEMENT DEFINITION -- GET THIS RIGHT
--    GA4's documented definition of an engaged session is ANY of:
--      (a) the session lasted longer than 10 seconds, OR
--      (b) the session had at least one conversion event, OR
--      (c) the session had at least two page views or screen views.
--    These are OR-ed, not AND-ed. A common bug is implementing it as
--    duration > 10 only, which gives a slightly-to-noticeably lower number
--    than the UI, because a short session that converted still counts as
--    engaged.
--
--    The export ALSO carries an event parameter `session_engaged`, which GA4's
--    client sets to '1' when engagement time exceeded 10 seconds. Two things
--    to know about it:
--      - It is written as a STRING ('1' / '0'), not an integer, so reading
--        value.int_value for it returns NULL. This query reads
--        value.string_value.
--      - It encodes rule (a) ONLY. It does not know about conversions or page
--        views, so counting session_engaged is NOT the same as counting
--        engaged sessions and it will disagree with the UI.
--    Both numbers are returned below so you can see the size of the gap and
--    report it honestly rather than guessing which is right.
--
--  CAVEATS
--    1. Duration is measured as (last event timestamp - first event timestamp)
--       within the session. GA4's own duration metric excludes time after the
--       last event, and for a single-event session GA4 often reports 0 while
--       this returns 0 too -- but a session with one event and a long
--       client-reported engagement_time_msec will look different here than in
--       the UI. Expect small gaps; do not chase them below the 1-3% level.
--    2. Sessions at the edges of the range are truncated (see
--       01-SESSIONISE-EVENTS.sql). Padding the range reduces but does not
--       remove this.
--    3. channel_group here is a SIMPLIFIED default grouping computed from
--       session-scoped source/medium. It will not match GA4's "Session default
--       channel group" exactly -- GA4 applies additional rules involving ad
--       network and campaign metadata that are not all in the export. Treat
--       this as a usable approximation and read docs/SCHEMA-TRAPS.md, trap 9.
--       For a closer match, run 08-CHANNEL-GROUPING.sql and read its caveats.
--    4. Date is the session START date, not the event date. This is
--       deliberate -- it is what makes midnight-crossing sessions appear once.
--       GA4's UI also attributes the session to its start date.
--
--  ASSUMPTIONS YOU MUST EDIT
--    - YOUR_PROJECT.analytics_XXXXXXXXX
--    - the _TABLE_SUFFIX range (padded by one day at each end)
--    - conversion_event_names
--
--  COST / SCAN WARNING
--    Reads event_params and the device/session attribution columns for every
--    day in range. Test on one day (change the range to a single day) before
--    running a year. Dry-run first: docs/COST-CONTROL.md.
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

-- EDIT ME: your conversion event names.
conversion_event_names AS (
  SELECT event_name FROM UNNEST(['sign_up', 'generate_lead', 'purchase', 'form_submit']) AS event_name
),

events AS (
  SELECT
    PARSE_DATE('%Y%m%d', raw.event_date) AS event_dt,
    raw.event_timestamp,
    raw.event_name,
    raw.user_pseudo_id,
    (SELECT value.int_value    FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id')      AS ga_session_id,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'session_engaged')    AS session_engaged_str,
    (SELECT value.int_value    FROM UNNEST(raw.event_params) WHERE key = 'engagement_time_msec') AS engagement_time_msec,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'source')             AS param_source,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'medium')             AS param_medium,
    raw.session_traffic_source_last_click.manual_campaign.source AS last_click_source,
    raw.session_traffic_source_last_click.manual_campaign.medium AS last_click_medium,
    raw.traffic_source.source AS first_user_source,
    raw.traffic_source.medium AS first_user_medium,
    raw.device.category AS device_category
  FROM
    `YOUR_PROJECT.analytics_XXXXXXXXX.events_*` AS raw
  WHERE
    raw._TABLE_SUFFIX BETWEEN '20231231' AND '20240201'
    AND (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') IS NOT NULL
),

-- One row per session, with all three engagement rules evaluated separately.
sessions AS (
  SELECT
    CONCAT(user_pseudo_id, '.', CAST(ga_session_id AS STRING)) AS session_key,
    MIN(event_dt)                                             AS session_date,
    COUNT(*)                                                  AS event_count,
    COUNTIF(event_name = 'page_view')                         AS page_view_count,
    COUNTIF(event_name IN (SELECT event_name FROM conversion_event_names)) AS conversion_event_count,
    TIMESTAMP_DIFF(TIMESTAMP_MICROS(MAX(event_timestamp)), TIMESTAMP_MICROS(MIN(event_timestamp)), SECOND) AS duration_sec,
    -- session_engaged is a STRING param: '1' means engaged, '0' means not.
    -- MAX over the session handles the fact that the value is only set on
    -- later events in some clients; '1' sorts above '0' so MAX is correct.
    MAX(session_engaged_str)                                  AS session_engaged_str,
    MIN(device_category)                                      AS device_category,
    -- Session-scoped source/medium, preferring the last-click column.
    COALESCE(MIN(last_click_source), MIN(param_source), MIN(first_user_source)) AS session_source,
    COALESCE(MIN(last_click_medium), MIN(param_medium), MIN(first_user_medium)) AS session_medium
  FROM events
  GROUP BY session_key, user_pseudo_id, ga_session_id
),

session_level AS (
  SELECT
    s.*,
    (s.duration_sec > 10)                 AS rule_over_10s,
    (s.conversion_event_count >= 1)       AS rule_has_conversion,
    (s.page_view_count >= 2)              AS rule_2plus_pages,
    (s.session_engaged_str = '1')         AS rule_session_engaged_param,
    (s.duration_sec > 10 OR s.conversion_event_count >= 1 OR s.page_view_count >= 2) AS engaged_session
  FROM sessions AS s
),

-- Simplified default channel grouping. Rules are applied in order, first match
-- wins -- the same shape as GA4's default channel group definition, with the
-- caveat in the header. Lower-cased comparisons make this robust to senders
-- that use 'Google' vs 'google'.
channelised AS (
  SELECT
    sl.*,
    CASE
      WHEN LOWER(COALESCE(sl.session_source, '')) = 'direct'
        OR (sl.session_source IS NULL AND sl.session_medium IS NULL) THEN 'Direct'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(sl.session_medium, '')), r'^(cpc|ppc|paidsearch|paid_search)$')
        AND REGEXP_CONTAINS(LOWER(COALESCE(sl.session_source, '')), r'google') THEN 'Google Ads'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(sl.session_medium, '')), r'^(cpc|ppc|paidsearch|paid_search)$')
        AND REGEXP_CONTAINS(LOWER(COALESCE(sl.session_source, '')), r'bing|microsoft|msn|adwords') THEN 'Microsoft Ads'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(sl.session_medium, '')), r'^(cpc|ppc|paidsearch|paid_search|paid|paid_social|paidsocial|display|banner|retargeting)$') THEN 'Paid Other'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(sl.session_medium, '')), r'^organic') THEN
        CASE
          WHEN REGEXP_CONTAINS(LOWER(COALESCE(sl.session_source, '')), r'google') THEN 'Organic Google Search'
          WHEN REGEXP_CONTAINS(LOWER(COALESCE(sl.session_source, '')), r'bing|yahoo|duckduckgo|ecosia') THEN 'Organic Search'
          ELSE 'Organic Search'
        END
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(sl.session_medium, '')), r'^(email|e-mail|newsletter)$') THEN 'Email'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(sl.session_medium, '')), r'^(referral|referrer|link)$') THEN 'Referral'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(sl.session_medium, '')), r'^(social|organic_social|social-network|social-media)$') THEN 'Organic Social'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(sl.session_medium, '')), r'^(affiliate)$') THEN 'Affiliates'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(sl.session_medium, '')), r'^(sms|push|whatsapp|messenger)$') THEN 'Organic Social'
      WHEN sl.session_source IS NULL AND sl.session_medium IS NULL THEN 'Unassigned'
      ELSE 'Other / Custom'
    END AS channel_group
  FROM session_level AS sl
)

SELECT
  c.session_date,
  c.channel_group,
  c.device_category,
  COUNT(*)                                                AS sessions,
  COUNTIF(c.engaged_session)                              AS engaged_sessions,
  ROUND(SAFE_DIVIDE(COUNTIF(c.engaged_session), COUNT(*)) * 100, 2) AS engagement_rate,
  COUNTIF(c.rule_over_10s)                                AS sessions_over_10s,
  COUNTIF(c.rule_has_conversion)                          AS sessions_with_conv,
  COUNTIF(c.rule_2plus_pages)                             AS sessions_2plus_pages,
  COUNTIF(c.rule_session_engaged_param)                   AS sessions_engaged_param_set,
  ROUND(SAFE_DIVIDE(COUNTIF(c.rule_over_10s), COUNT(*)) * 100, 2)          AS pct_sessions_over_10s,
  ROUND(SAFE_DIVIDE(COUNTIF(c.rule_has_conversion), COUNT(*)) * 100, 2)    AS pct_sessions_with_conv,
  ROUND(SAFE_DIVIDE(COUNTIF(c.rule_2plus_pages), COUNT(*)) * 100, 2)       AS pct_sessions_2plus_pages,
  ROUND(AVG(c.duration_sec), 1)                           AS avg_session_duration_sec,
  ROUND(AVG(c.page_view_count), 2)                        AS avg_page_views_per_session,
  ROUND(SAFE_DIVIDE(COUNTIF(c.rule_session_engaged_param), COUNT(*)) * 100, 2) AS pct_session_engaged_param
FROM channelised AS c
GROUP BY
  c.session_date,
  c.channel_group,
  c.device_category
HAVING
  -- Defensive guard against GROUPING SETS-style empty groups; harmless with
  -- this plain GROUP BY but kept so the query is safe to extend.
  c.session_date IS NOT NULL
ORDER BY
  c.session_date,
  sessions DESC;
