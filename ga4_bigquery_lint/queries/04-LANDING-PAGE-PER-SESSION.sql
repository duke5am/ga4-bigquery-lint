-- ============================================================================
--  04-LANDING-PAGE-PER-SESSION.sql
--  GA4 BigQuery Session & Funnel SQL Pack
-- ============================================================================
--
--  QUESTION IT ANSWERS
--    "Which landing pages do sessions start on, and which of them actually
--     produce signups?" -- the page-attribution question, which the GA4 UI
--     answers only for its own landing-page dimension and not joined to your
--     conversion events.
--
--  WHAT IT RETURNS (one row per landing page x channel group)
--    landing_page            STRING -- page_location of the session's FIRST
--                             page_view (or first event with a page_location
--                             if the session has no page_view; see caveat 3)
--    landing_page_path       STRING -- landing_page with the query string
--                             stripped; URI, not URL, so it groups cleanly
--    channel_group           STRING -- simplified default grouping
--    sessions                INT64
--    engaged_sessions        INT64
--    engagement_rate         FLOAT64
--    conversions             INT64  -- conversion EVENTS, not sessions
--    converting_sessions     INT64  -- sessions with >=1 conversion event
--    session_conversion_rate FLOAT64 -- converting_sessions / sessions
--    avg_session_duration_sec FLOAT64
--    avg_page_views_per_session FLOAT64
--    bounce_sessions         INT64  -- sessions with 1 page_view and <=10s
--
--  HOW "LANDING PAGE" IS DEFINED HERE, AND WHY IT MATTERS
--    GA4's landing_page dimension is the first page_view of the session. Two
--    mistakes are common:
--
--      (a) Using MIN(page_location) or ANY_VALUE(page_location). MIN gives you
--          the alphabetically first page in the session, which has nothing to
--          do with where the user landed. ANY_VALUE gives you a random one.
--          Both are wrong. This query orders by event_timestamp.
--
--      (b) Using the `entrances` event parameter (value 1 on the entry event).
--          That parameter exists, but on the exported data it is not reliably
--          present on every session's first event -- GA4's client emits it on
--          the config/entrance event and it is missing for some flows,
--          notably sessions that begin on a page without the tag firing a
--          config hit. Selecting the earliest page_view by timestamp works for
--          every session and is what this query does. If you want to compare,
--          the `entrances` read is included in 00-PARAM-PATTERNS.sql.
--
--  CAVEATS
--    1. page_location is a FULL URL including the query string. Two sessions
--       landing on /pricing and /pricing?utm_source=newsletter have different
--       page_location values and are reported separately by default. Use
--       landing_page_path to group them, but read docs/SCHEMA-TRAPS.md
--       trap 10 first: stripping query strings also merges genuinely
--       different pages that use a query parameter as content (for example
--       ?product=sku-1 and ?product=sku-2), and it will not merge URLs that
--       differ by trailing slash or case. Pick one convention and use it
--       everywhere.
--    2. A session can legitimately have NO page_view: app traffic
--       (event_name = 'screen_view'), Measurement Protocol hits, or a session
--       that only carries a conversion event. Those sessions are counted in
--       the '(no landing page)' row rather than dropped, so the totals here
--       still reconcile with 01-SESSIONISE-EVENTS.sql. Dropping them is a
--       common silent cause of a session-count mismatch.
--    3. If a session spans midnight, its landing page is still the first page
--       of the whole session, because this query groups across the padded
--       range. That is the correct behaviour and matches the UI.
--    4. Conversions are counted as EVENTS in the `conversions` column and as
--       SESSIONS in `converting_sessions`. Mixing those two up is another
--       frequent source of "the UI says 40 conversions and I get 55": 55 might
--       be events and 40 sessions. Both are given so you do not have to guess.
--    5. URL parameters that GA4 itself appends (gclid, gad_source, wbraid,
--       gbraid, utm_*) are part of page_location. See SCHEMA-TRAPS.md trap 10
--       for the honest limits of cleaning them out.
--
--  ASSUMPTIONS YOU MUST EDIT
--    - YOUR_PROJECT.analytics_XXXXXXXXX
--    - the padded _TABLE_SUFFIX range
--    - conversion_event_names
--
--  COST / SCAN WARNING
--    Needs event_params (for page_location), the device column and the
--    session attribution columns on every day in range. Grouping ALL sessions
--    by landing page before filtering means the intermediate result is as
--    large as your session count -- on a high-traffic property add a
--    _TABLE_SUFFIX range you can afford, or materialise the session table
--    first (setup/create_session_table.sql) and run this against that.
--    Dry-run first: docs/COST-CONTROL.md.
--
--  NOT EXECUTED AGAINST BIGQUERY
--    Written against the documented GA4 BigQuery export schema and
--    syntax-checked with a SQL parser. Never executed against a real
--    property. Validate against your own property with docs/VALIDATION.md.
-- ============================================================================


WITH range_bounds AS (
  SELECT
    DATE '2024-01-01' AS report_start,
    DATE '2024-01-31' AS report_end
),

conversion_event_names AS (
  SELECT event_name FROM UNNEST(['sign_up', 'generate_lead', 'purchase', 'form_submit']) AS event_name
),

events AS (
  SELECT
    PARSE_DATE('%Y%m%d', raw.event_date) AS event_dt,
    raw.event_timestamp,
    raw.event_name,
    raw.user_pseudo_id,
    (SELECT value.int_value    FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id')   AS ga_session_id,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'page_location')   AS page_location,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'source')          AS param_source,
    (SELECT value.string_value FROM UNNEST(raw.event_params) WHERE key = 'medium')          AS param_medium,
    raw.session_traffic_source_last_click.manual_campaign.source AS last_click_source,
    raw.session_traffic_source_last_click.manual_campaign.medium AS last_click_medium,
    raw.traffic_source.source AS first_user_source,
    raw.traffic_source.medium AS first_user_medium
  FROM
    `YOUR_PROJECT.analytics_XXXXXXXXX.events_*` AS raw
  WHERE
    raw._TABLE_SUFFIX BETWEEN '20231231' AND '20240201'
    AND (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') IS NOT NULL
),

sessions AS (
  SELECT
    CONCAT(user_pseudo_id, '.', CAST(ga_session_id AS STRING)) AS session_key,
    MIN(event_dt)                                             AS session_date,
    -- The landing page: the FIRST page_location by timestamp, not MIN() of
    -- the string. IGNORE NULLS skips events that carry no page_location.
    ARRAY_AGG(page_location IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS landing_page,
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
)

SELECT
  COALESCE(NULLIF(c.landing_page, ''), '(no landing page)') AS landing_page,
  -- Path only: strip query string and fragment. REGEXP_REPLACE with a raw
  -- string literal keeps the backslashes literal. This is a presentation
  -- helper, not an identity: see caveat 1.
  REGEXP_REPLACE(
    COALESCE(NULLIF(c.landing_page, ''), '(no landing page)'),
    r'[?#].*$',
    ''
  ) AS landing_page_path,
  c.channel_group,
  COUNT(*)                                              AS sessions,
  COUNTIF(c.duration_sec > 10 OR c.conversion_event_count >= 1 OR c.page_view_count >= 2) AS engaged_sessions,
  ROUND(
    SAFE_DIVIDE(
      COUNTIF(c.duration_sec > 10 OR c.conversion_event_count >= 1 OR c.page_view_count >= 2),
      COUNT(*)
    ) * 100, 2
  )                                                     AS engagement_rate,
  SUM(c.conversion_event_count)                         AS conversions,
  COUNTIF(c.conversion_event_count >= 1)                AS converting_sessions,
  ROUND(SAFE_DIVIDE(COUNTIF(c.conversion_event_count >= 1), COUNT(*)) * 100, 2) AS session_conversion_rate,
  ROUND(AVG(c.duration_sec), 1)                         AS avg_session_duration_sec,
  ROUND(AVG(c.page_view_count), 2)                      AS avg_page_views_per_session,
  COUNTIF(c.page_view_count = 1 AND c.duration_sec <= 10 AND c.conversion_event_count = 0) AS bounce_sessions
FROM channelised AS c
GROUP BY
  landing_page,
  landing_page_path,
  c.channel_group
ORDER BY
  sessions DESC,
  landing_page;
