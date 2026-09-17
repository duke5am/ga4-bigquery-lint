-- ============================================================================
--  09-EVENTS-PER-SESSION.sql
--  GA4 BigQuery Session & Funnel SQL Pack
-- ============================================================================
--
--  QUESTION IT ANSWERS
--    "How much data does a session actually generate?" -- the table you need
--     before you size anything downstream: a materialised session model, an
--     export pipeline, a per-user event cap, or an attribution job. It also
--     answers "is my event volume growing because I have more sessions, or
--     because each session got noisier?", which are very different problems.
--
--  WHAT IT RETURNS -- TWO RESULT SETS, RUN THEM SEPARATELY
--    QUERY A -- distribution: one row per events-per-session bucket, with the
--               count of sessions and share of sessions, plus cumulative
--               shares so you can read off a P50/P90-style statement without
--               statistics. This is the table to paste into a spreadsheet.
--    QUERY B -- percentiles and totals per month: exact percentiles are
--               expensive; APPROX_QUANTILES is the right tool and is
--               accurate to within a fraction of a percentile at these
--               volumes. Also returns mean, max and a long-tail count.
--
--  WHY BOTH
--    A mean alone is misleading here. Session event counts are heavily
--    right-skewed -- a handful of bot-like or instrumented-heavy sessions
--    carry thousands of events and drag the mean up while the median stays
--    low. If you report only the average you will over-provision, and if you
--    report only the max you will panic. Report the median and the P95, and
--    state the share of sessions above your chosen cap.
--
--  BUCKETS USED (edit if your property is different)
--    '1', '2', '3-4', '5-9', '10-19', '20-49', '50-99', '100-499', '500+'
--    A session with ONE event is normal and is usually a bounce: the user
--    loaded one page and left. It is not a data-quality problem. A session
--    with 500+ events usually IS worth investigating -- see the caveat below.
--
--  CAVEATS
--    1. Bots and instrumentation loops. Some sessions carry thousands of
--       events because of a scroll/timer/video event firing in a loop, or
--       because a bot walked the site. You cannot reliably separate those
--       inside the export -- GA4's own bot filtering has already been applied
--       at collection time and is not reversible. So: report the tail, look at
--       the top few sessions by event count, and if they are one
--       user_pseudo_id from one IP range with thousands of identical events,
--       exclude them BY ID in a follow-up query and say that you did. Do not
--       silently filter by an event-count threshold; you will remove real
--       long sessions along with the junk.
--    2. event_count here counts rows in the export, which is one row per
--       collected event. GA4's UI "Events" metric counts the same thing, so
--       the two should be comparable -- but the UI applies thresholding and
--       may differ by low single-digit percentages on small properties. See
--       docs/SCHEMA-TRAPS.md trap 8.
--    3. Sessions are counted by (user_pseudo_id, ga_session_id), never by
--       ga_session_id alone.
--    4. Sessions at the edges of the padded range are truncated, which biases
--       the LOW end of the distribution slightly upward (a truncated session
--       has fewer events than the real one). The effect is small on a month
--       and should be stated if you are quoting a median to one decimal place.
--    5. APPROX_QUANTILES returns an array; [OFFSET(n)] is how you index it.
--       The array from APPROX_QUANTILES(x, 100) has 101 elements, so the
--       median is [OFFSET(50)], P90 is [OFFSET(90)], P95 is [OFFSET(95)].
--
--  ASSUMPTIONS YOU MUST EDIT
--    - YOUR_PROJECT.analytics_XXXXXXXXX
--    - padded _TABLE_SUFFIX range
--    - the bucket boundaries, if your property runs unusually heavy or light
--
--  COST / SCAN WARNING
--    Reads event_date, event_name, event_timestamp, user_pseudo_id and
--    event_params. This is the cheapest of the session-level queries in the
--    pack because it needs few columns and the final aggregation is small, but
--    it still scans every day in range. Dry-run first, per
--    docs/COST-CONTROL.md.
--
--  NOT EXECUTED AGAINST BIGQUERY
--    Written against the documented GA4 BigQuery export schema and
--    syntax-checked with a SQL parser. Never executed against a real
--    property. Validate with docs/VALIDATION.md.
-- ============================================================================


-- ============================================================================
--  QUERY A -- DISTRIBUTION BY BUCKET  (run this one first)
-- ============================================================================
WITH range_bounds AS (
  -- EDIT ME: padded window.
  SELECT
    DATE '2024-01-01' AS report_start,
    DATE '2024-01-31' AS report_end
),

sessions AS (
  SELECT
    CONCAT(raw.user_pseudo_id, '.', CAST((SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') AS STRING)) AS session_key,
    COUNT(*) AS event_count
  FROM
    `YOUR_PROJECT.analytics_XXXXXXXXX.events_*` AS raw
  WHERE
    raw._TABLE_SUFFIX BETWEEN '20231231' AND '20240201'
    AND (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') IS NOT NULL
  GROUP BY
    session_key,
    raw.user_pseudo_id,
    (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id')
),

bucketed AS (
  SELECT
    CASE
      WHEN event_count = 1        THEN '1'
      WHEN event_count = 2        THEN '2'
      WHEN event_count <= 4       THEN '3-4'
      WHEN event_count <= 9       THEN '5-9'
      WHEN event_count <= 19      THEN '10-19'
      WHEN event_count <= 49      THEN '20-49'
      WHEN event_count <= 99      THEN '50-99'
      WHEN event_count <= 499     THEN '100-499'
      ELSE '500+'
    END AS events_per_session_bucket,
    -- Sort key so the bucket column can be ordered sensibly without a
    -- separate lookup table.
    CASE
      WHEN event_count = 1        THEN 1
      WHEN event_count = 2        THEN 2
      WHEN event_count <= 4       THEN 3
      WHEN event_count <= 9       THEN 4
      WHEN event_count <= 19      THEN 5
      WHEN event_count <= 49      THEN 6
      WHEN event_count <= 99      THEN 7
      WHEN event_count <= 499     THEN 8
      ELSE 9
    END AS bucket_sort,
    event_count
  FROM sessions
)

SELECT
  b.events_per_session_bucket,
  COUNT(*)                                                  AS sessions,
  ROUND(SAFE_DIVIDE(COUNT(*), SUM(COUNT(*)) OVER ()) * 100, 2) AS pct_of_sessions,
  SUM(COUNT(*)) OVER (ORDER BY b.bucket_sort)               AS cumulative_sessions,
  ROUND(
    SAFE_DIVIDE(SUM(COUNT(*)) OVER (ORDER BY b.bucket_sort), SUM(COUNT(*)) OVER ()) * 100,
    2
  )                                                         AS cumulative_pct_of_sessions,
  SUM(b.event_count)                                        AS events_in_bucket,
  ROUND(SAFE_DIVIDE(SUM(b.event_count), SUM(SUM(b.event_count)) OVER ()) * 100, 2) AS pct_of_all_events
FROM bucketed AS b
GROUP BY
  b.events_per_session_bucket,
  b.bucket_sort
ORDER BY
  b.bucket_sort;


-- ============================================================================
--  QUERY B -- PERCENTILES AND TOTALS PER MONTH  (paste n as -- see below)
-- ============================================================================
-- Run this as a SEPARATE query. If you prefer, merge A and B into one result
-- by turning the percentiles into scalar subqueries -- but do not add
-- percentile columns to Query A's GROUP BY, because the array index is only
-- valid over the whole population, not per bucket.
--
-- WITH range_bounds AS (
--   SELECT
--     DATE '2024-01-01' AS report_start,
--     DATE '2024-01-31' AS report_end
-- ),
--
-- events AS (
--   SELECT
--     PARSE_DATE('%Y%m%d', raw.event_date) AS event_dt,
--     raw.user_pseudo_id,
--     (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') AS ga_session_id
--   FROM `YOUR_PROJECT.analytics_XXXXXXXXX.events_*` AS raw
--   WHERE
--     raw._TABLE_SUFFIX BETWEEN '20231231' AND '20240201'
--     AND (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') IS NOT NULL
-- ),
--
-- sessions AS (
--   SELECT
--     CONCAT(user_pseudo_id, '.', CAST(ga_session_id AS STRING)) AS session_key,
--     MIN(event_dt) AS session_date,
--     COUNT(*)      AS event_count
--   FROM events
--   GROUP BY session_key, user_pseudo_id, ga_session_id
-- )
--
-- SELECT
--   DATE_TRUNC(session_date, MONTH)                        AS month,
--   COUNT(*)                                               AS sessions,
--   SUM(event_count)                                       AS total_events,
--   ROUND(AVG(event_count), 2)                             AS mean_events_per_session,
--   APPROX_QUANTILES(event_count, 100)[OFFSET(50)]         AS p50_events_per_session,
--   APPROX_QUANTILES(event_count, 100)[OFFSET(75)]         AS p75_events_per_session,
--   APPROX_QUANTILES(event_count, 100)[OFFSET(90)]         AS p90_events_per_session,
--   APPROX_QUANTILES(event_count, 100)[OFFSET(95)]         AS p95_events_per_session,
--   APPROX_QUANTILES(event_count, 100)[OFFSET(99)]         AS p99_events_per_session,
--   MAX(event_count)                                       AS max_events_per_session,
--   COUNTIF(event_count >= 500)                            AS sessions_with_500_plus_events,
--   ROUND(SAFE_DIVIDE(COUNTIF(event_count >= 500), COUNT(*)) * 100, 3) AS pct_sessions_500_plus,
--   -- The share of all events contributed by the heaviest 1% of sessions.
--   -- If this is large, a small number of sessions dominate your export size
--   -- and your cost -- worth knowing before you blame the whole property.
--   ROUND(
--     SAFE_DIVIDE(
--       SUM(IF(event_count >= APPROX_QUANTILES(event_count, 100)[OFFSET(99)], event_count, 0)),
--       SUM(event_count)
--     ) * 100, 2
--   )                                                      AS pct_events_from_heaviest_1pct
-- FROM sessions
-- GROUP BY month
-- ORDER BY month;
--
-- Note on the last column: APPROX_QUANTILES inside an aggregate over the same
-- table is a nested aggregate and BigQuery rejects it. Compute the P99 in a
-- preceding CTE and join it in:
--
--   WITH thresholds AS (
--     SELECT APPROX_QUANTILES(event_count, 100)[OFFSET(99)] AS p99
--     FROM sessions
--   )
--   SELECT
--     SUM(IF(s.event_count >= t.p99, s.event_count, 0)) AS events_in_heaviest_1pct,
--     ROUND(SAFE_DIVIDE(SUM(IF(s.event_count >= t.p99, s.event_count, 0)), SUM(s.event_count)) * 100, 2) AS pct
--   FROM sessions AS s
--   CROSS JOIN thresholds AS t;
--
-- That pattern -- materialise the threshold, then reference it -- is the same
-- trick that keeps threshold-based reports cheap. See docs/COST-CONTROL.md.
