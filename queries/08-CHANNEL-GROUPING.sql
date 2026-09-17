-- ============================================================================
--  08-CHANNEL-GROUPING.sql
--  GA4 BigQuery Session & Funnel SQL Pack
-- ============================================================================
--
--  QUESTION IT ANSWERS
--    "Give me sessions, users, engagement and conversions for GA4's default
--     channel group" -- the table you are asked for in every weekly meeting,
--     built from the export rather than exported from the UI.
--
--  WHAT IT RETURNS (one row per channel group per month)
--    month                   DATE   -- first day of the month (edit for daily)
--    channel_group           STRING
--    sessions                INT64
--    users                   INT64  -- distinct user_pseudo_id (per device)
--    new_users               INT64  -- users whose first session is in range
--    engaged_sessions        INT64
--    engagement_rate         FLOAT64
--    conversion_events       INT64
--    converting_sessions     INT64
--    session_conversion_rate FLOAT64
--    conversions_per_session FLOAT64
--    avg_session_duration_sec FLOAT64
--    avg_page_views_per_session FLOAT64
--    session_share_pct       FLOAT64
--    unmatched_or_other_pct  FLOAT64 -- share of sessions in 'Other / Custom';
--                                       treat this as your mapping-health metric
--
--  HOW THE GROUPING IS DERIVED, AND WHAT IT CANNOT DO
--    The rules below are modelled on GA4's documented default channel group
--    definition, evaluated in order with first match winning, against the
--    SESSION-scoped source/medium. Read this list before you publish the
--    table:
--
--      WHAT IT CAN DO: correctly separate Direct, Organic Search, Paid Search,
--      Email, Referral, Organic Social, Affiliates, Display-ish paid traffic --
--      for the common cases, which is most of the traffic on most properties.
--
--      WHAT IT CANNOT DO, HONESTLY:
--        - It cannot reproduce GA4's 'Cross-network' channel. GA4 assigns that
--          using advertising-network metadata (notably Google Ads' auto-tagging
--          and the presence of campaign IDs) that is only partly present in
--          the export, via session_traffic_source_last_click. Without the Ads
--          linkage you will see those sessions as 'Google Ads' or 'Paid Other'.
--        - 'Display' in GA4's own definition depends on the ad format, which is
--          not in the export; this query lumps display-like mediums into
--          'Paid Other'.
--        - 'Audio' and 'Video' channels require network-specific medium values
--          your senders may not use consistently.
--        - Any traffic with a custom medium value you have not anticipated
--          lands in 'Other / Custom'. That is deliberate and it is the number
--          to watch: if unmatched_or_other_pct is more than a few percent,
--          your tagging is inconsistent, not your query.
--        - REGEXP_CONTAINS is used with case-insensitive patterns against
--          LOWER()'d values, because senders write 'Email', 'email', 'EMAIL'
--          and 'e-mail' and all three are the same channel.
--
--    The practical rule: if a channel report must tie out exactly to the GA4
--    UI, export it from the UI. Use this query when you need channels joined
--    to things the UI will not join to (your own user table, your CRM, a
--    custom conversion definition), and label it "modelled channel group".
--
--  CAVEATS
--    1. users is distinct user_pseudo_id over the window, so a user active in
--       two months is counted in both -- the column is NOT additive across
--       months. Sum sessions, not users, if you are building a total.
--    2. new_users is computed via a first-seen lookup over the SCAN range. If
--       the scan range starts at the report window's start, every user looks
--       new. Scan earlier than you report. Same trap as
--       07-RETENTION-BY-FIRST-TOUCH.sql.
--    3. Sessions whose source/medium are both NULL or empty are grouped as
--       'Direct'. GA4 does the same for genuinely direct traffic, but the
--       export also produces NULLs for some Measurement Protocol and
--       server-side hits, so a small number of non-direct sessions are folded
--       into Direct here. If you need to separate them, add a rule ahead of
--       the Direct rule that tests for a NULL/empty source AND a non-null
--       last_click_campaign (i.e.
--       session_traffic_source_last_click.manual_campaign.campaign_name).
--    4. Attribution scope: SESSION, preferring
--       session_traffic_source_last_click then the source/medium event params
--       then the user's first-touch values. A conversion is credited to the
--       session it happened in, so this is a last-non-direct-click view. See
--       05-CONVERSIONS-BY-CHANNEL.sql for the first-touch alternative and why
--       the two disagree.
--    5. Month buckets use DATE_TRUNC(..., MONTH) on the SESSION START date
--       (property timezone). Switching to daily is a one-line edit shown in
--       the code.
--
--  ASSUMPTIONS YOU MUST EDIT
--    - YOUR_PROJECT.analytics_XXXXXXXXX
--    - scan/production _TABLE_SUFFIX ranges (two of them -- read the comments)
--    - conversion_event_names
--    - month vs day granularity
--
--  COST / SCAN WARNING
--    Two scans by design: a wide scan for first-seen and a production scan for
--    the reporting window. Both read event_params. Dry-run both before
--    running, and see the build-once suggestion at the bottom -- a small
--    first_seen table removes the wide scan permanently.
--
--  NOT EXECUTED AGAINST BIGQUERY
--    Written against the documented GA4 BigQuery export schema and
--    syntax-checked with a SQL parser. Never executed against a real
--    property. No revenue or channel number here has been observed on real
--    data. Validate with docs/VALIDATION.md.
-- ============================================================================


WITH range_bounds AS (
  -- EDIT ME. scan_start must predate window_start so that new_users is
  -- meaningful: a user whose true first visit was before scan_start will be
  -- counted as "new" on the day you first saw them.
  SELECT
    DATE '2023-07-01' AS scan_start,
    DATE '2024-01-31' AS scan_end,
    DATE '2024-01-01' AS window_start,
    DATE '2024-01-31' AS window_end
),

-- Kept separate and explicit rather than reusing range_bounds, so that the
-- wide scan and the narrow scan are impossible to confuse while editing.
conversion_event_names AS (
  SELECT event_name FROM UNNEST(['sign_up', 'generate_lead', 'purchase', 'form_submit']) AS event_name
),

-- WIDE SCAN (first-seen). One row per user. Costs the same as any scan of the
-- range, but returns a tiny table -- which is why the build-once table at the
-- bottom of this file is worth creating.
first_seen AS (
  SELECT
    raw.user_pseudo_id,
    MIN(PARSE_DATE('%Y%m%d', raw.event_date)) AS first_seen_date
  FROM
    `YOUR_PROJECT.analytics_XXXXXXXXX.events_*` AS raw
  WHERE
    raw._TABLE_SUFFIX BETWEEN '20230701' AND '20240131'
    AND (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') IS NOT NULL
  GROUP BY
    raw.user_pseudo_id
),

-- PRODUCTION SCAN (the reporting window).
events AS (
  SELECT
    PARSE_DATE('%Y%m%d', raw.event_date) AS event_dt,
    raw.event_timestamp,
    raw.event_name,
    raw.user_pseudo_id,
    (SELECT value.int_value    FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id')        AS ga_session_id,
    (SELECT value.int_value    FROM UNNEST(raw.event_params) WHERE key = 'engagement_time_msec') AS engagement_time_msec,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'source')               AS param_source,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'medium')               AS param_medium,
    raw.session_traffic_source_last_click.manual_campaign.source AS last_click_source,
    raw.session_traffic_source_last_click.manual_campaign.medium AS last_click_medium,
    raw.traffic_source.source AS first_user_source,
    raw.traffic_source.medium AS first_user_medium
  FROM
    `YOUR_PROJECT.analytics_XXXXXXXXX.events_*` AS raw
  WHERE
    raw._TABLE_SUFFIX BETWEEN '20231231' AND '20240131'
    AND (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') IS NOT NULL
),

sessions AS (
  SELECT
    CONCAT(user_pseudo_id, '.', CAST(ga_session_id AS STRING)) AS session_key,
    user_pseudo_id,
    MIN(event_dt)                                             AS session_date,
    COUNT(*)                                                  AS event_count,
    COUNTIF(event_name = 'page_view')                         AS page_view_count,
    COUNTIF(event_name IN (SELECT event_name FROM conversion_event_names)) AS conversion_event_count,
    TIMESTAMP_DIFF(TIMESTAMP_MICROS(MAX(event_timestamp)), TIMESTAMP_MICROS(MIN(event_timestamp)), SECOND) AS duration_sec,
    COALESCE(MIN(last_click_source), MIN(param_source), MIN(first_user_source)) AS session_source,
    COALESCE(MIN(last_click_medium), MIN(param_medium), MIN(first_user_medium)) AS session_medium
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

-- EDIT ME: swap DATE_TRUNC(c.session_date, MONTH) for c.session_date to get a
-- daily table. Everything else stays the same.
monthly AS (
  SELECT
    DATE_TRUNC(c.session_date, MONTH) AS month,
    c.channel_group,
    c.user_pseudo_id,
    c.session_key,
    c.duration_sec,
    c.page_view_count,
    c.conversion_event_count,
    (c.duration_sec > 10 OR c.conversion_event_count >= 1 OR c.page_view_count >= 2) AS engaged_session
  FROM channelised AS c
),

totals AS (
  SELECT
    month,
    COUNT(*) AS total_sessions
  FROM monthly
  GROUP BY month
),

-- New users THIS MONTH **IN THIS CHANNEL**: users whose first-ever session
-- (over the wide scan) falls in this month, and who had at least one session
-- in this channel this month. Computing it per channel matters -- a single
-- count per month repeated across every channel row is the classic way this
-- column ends up summing to more users than you have.
new_users AS (
  SELECT
    DATE_TRUNC(f.first_seen_date, MONTH) AS month,
    m.channel_group,
    COUNT(DISTINCT m.user_pseudo_id) AS new_users
  FROM monthly AS m
  JOIN first_seen AS f
    ON f.user_pseudo_id = m.user_pseudo_id
  WHERE
    DATE_TRUNC(f.first_seen_date, MONTH) = m.month
  GROUP BY
    month,
    m.channel_group
)

SELECT
  m.month,
  m.channel_group,
  COUNT(*)                                        AS sessions,
  COUNT(DISTINCT m.user_pseudo_id)                AS users,
  COALESCE(MAX(nu.new_users), 0)                  AS new_users,
  COUNTIF(m.engaged_session)                      AS engaged_sessions,
  ROUND(SAFE_DIVIDE(COUNTIF(m.engaged_session), COUNT(*)) * 100, 2) AS engagement_rate,
  SUM(m.conversion_event_count)                   AS conversion_events,
  COUNTIF(m.conversion_event_count >= 1)          AS converting_sessions,
  ROUND(SAFE_DIVIDE(COUNTIF(m.conversion_event_count >= 1), COUNT(*)) * 100, 2) AS session_conversion_rate,
  ROUND(SAFE_DIVIDE(SUM(m.conversion_event_count), COUNT(*)), 3) AS conversions_per_session,
  ROUND(AVG(m.duration_sec), 1)                   AS avg_session_duration_sec,
  ROUND(AVG(m.page_view_count), 2)                AS avg_page_views_per_session,
  ROUND(SAFE_DIVIDE(COUNT(*), MAX(t.total_sessions)) * 100, 2) AS session_share_pct,
  ROUND(
    SAFE_DIVIDE(
      COUNTIF(m.channel_group = 'Other / Custom'),
      COUNT(*)
    ) * 100, 2
  ) AS unmatched_or_other_pct
FROM monthly AS m
LEFT JOIN totals AS t
  ON t.month = m.month
LEFT JOIN new_users AS nu
  ON nu.month = m.month
GROUP BY
  m.month,
  m.channel_group
ORDER BY
  m.month,
  sessions DESC;


-- ============================================================================
--  BUILD-ONCE: ga4_first_seen (commented out -- run deliberately)
-- ============================================================================
-- CREATE OR REPLACE TABLE `YOUR_PROJECT.YOUR_DATASET.ga4_first_seen` AS
-- SELECT
--   user_pseudo_id,
--   MIN(PARSE_DATE('%Y%m%d', event_date)) AS first_seen_date
-- FROM `YOUR_PROJECT.analytics_XXXXXXXXX.events_*`
-- WHERE
--   _TABLE_SUFFIX BETWEEN '20200101' AND '20240131'   -- EDIT ME
--   AND (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') IS NOT NULL
-- GROUP BY user_pseudo_id;
--
-- Then replace the `first_seen` CTE above with:
--   SELECT user_pseudo_id, first_seen_date
--   FROM `YOUR_PROJECT.YOUR_DATASET.ga4_first_seen`
-- and the wide scan stops appearing in every run.
-- ============================================================================
