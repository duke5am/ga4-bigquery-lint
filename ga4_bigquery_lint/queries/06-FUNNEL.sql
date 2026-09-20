-- ============================================================================
--  06-FUNNEL.sql
--  GA4 BigQuery Session & Funnel SQL Pack
-- ============================================================================
--
--  QUESTION IT ANSWERS
--    "Where do users drop off?" -- a step-by-step funnel with the number of
--     sessions (and users) that reach each step, computed from the raw event
--     log rather than from a pre-aggregated report.
--
--  THE FUNNEL YOU GET OUT OF THE BOX (edit the `funnel_steps` CTE to change it)
--    step 2  session_start         any session
--    step 3  view_item             viewed a product
--    step 4  add_to_cart           added to cart
--    step 5  begin_checkout        started checkout
--    step 6  purchase              purchased
--
--  WHAT IT RETURNS (one row per step)
--    step_number             INT64
--    step_name               STRING
--    sessions_at_step        INT64   -- sessions that reached this step
--    users_at_step           INT64   -- distinct user_pseudo_id at this step
--    sessions_lost_from_prev INT64
--    session_dropoff_rate    FLOAT64 -- sessions lost / sessions at previous step
--    pct_of_step_1           FLOAT64 -- sessions_at_step / sessions at step 1
--    step_conversion_rate    FLOAT64 -- sessions_at_step / sessions at prev step
--    median_seconds_from_prev_step FLOAT64
--    biggest_dropoff_flag    STRING  -- '<= biggest drop-off' on the worst step
--
--  HOW IT WORKS -- AND THE TWO DESIGN DECISIONS THAT MATTER
--
--    1. STRICTLY ORDERED, SESSION-SCOPED, ONE PASS. A session counts at step N
--       only if it fired every earlier step, in order, within the same
--       session. That is the funnel the UI draws. The tempting shortcut --
--       counting sessions that fired each event anywhere in the session,
--       independently -- produces a monotonically DECREASING-looking number
--       that is actually wrong: it will happily count a purchase as also being
--       at the add_to_cart step even if the user never added anything (GA4
--       fires purchase directly for some checkout flows), and it can produce a
--       later step with MORE sessions than an earlier one.
--
--    2. SESSION-SCOPED, NOT USER-SCOPED ACROSS SESSIONS. If a user views a
--       product on Monday and buys on Wednesday, they are NOT in this funnel:
--       the two events are in different sessions. This is the same choice GA4's
--       funnel exploration makes by default ("closed funnel", session scope)
--       and it is why this funnel's final step count is usually LOWER than the
--       number of purchases you can count directly. If you need cross-session
--       funnels, that is a different query with a different definition of
--       "converted" (usually a time window like 7 days) -- this pack does not
--       pretend to do it here. See the note at the bottom of the file.
--
--    Both facts are stated because both are legitimate answers to "how many
--    bought?", and a pack that hides them is not worth $39.
--
--  CAVEATS
--    1. Step events that occur out of order do not count. Someone who hits
--       add_to_cart before view_item (deep link, saved cart) is dropped at
--       step 3 and never appears again, so step 4+ counts can UNDERSTATE the
--       real behaviour. This is inherent to ordered funnels and the UI has the
--       same property; do not "fix" it by removing the ordering, or you get
--       decision 1's bug instead.
--    2. Sessions at the edges of the range are truncated (see
--       01-SESSIONISE-EVENTS.sql) which removes a few funnel entrants.
--    3. median_seconds_from_prev_step is only meaningful for sessions that
--       reached both steps; sessions with a missing earlier timestamp are
--       excluded from the median rather than treated as zero.
--    4. The event names are EXAMPLES. GA4's recommended names for retail are
--       view_item / add_to_cart / begin_checkout / purchase; for lead-gen you
--       will want something else entirely (form_start, form_submit,
--       generate_lead). If a step name does not exist in your export, that
--       step returns 0 and every later step returns 0 too -- no error is
--       raised. Verify each name exists before you present the funnel. The
--       probe for that is in docs/VALIDATION.md, step 2.
--    5. This funnel is by SESSION. GA4's funnel exploration can be switched to
--       by-user; the numbers will differ. Label which one you are showing.
--
--  ASSUMPTIONS YOU MUST EDIT
--    - YOUR_PROJECT.analytics_XXXXXXXXX
--    - padded _TABLE_SUFFIX range
--    - funnel_steps: step numbers and event names
--
--  COST / SCAN WARNING
--    Scans event_params, event_name and event_timestamp for every event in
--    range, then joins the session table to itself once per pair of
--    consecutive steps. On a high-traffic property over a long range this is
--    one of the heavier queries in the pack. Strongly recommended: materialise
--    the session+event table once (setup/create_session_table.sql, option B)
--    and run the funnel against that. Dry-run first. docs/COST-CONTROL.md.
--
--  NOT EXECUTED AGAINST BIGQUERY
--    Written against the documented GA4 BigQuery export schema and
--    syntax-checked with a SQL parser. Never executed against a real
--    property. The event names in funnel_steps are illustrative placeholders,
--    NOT a claim about your property. Validate with docs/VALIDATION.md.
-- ============================================================================


WITH range_bounds AS (
  -- EDIT ME: padded window.
  SELECT
    DATE '2024-01-01' AS report_start,
    DATE '2024-01-31' AS report_end
),

-- EDIT ME: the funnel definition, in order. step_number must be dense and
-- start at 1. The first step should normally be an event every session has
-- (session_start or page_view) or your percentages will be against a partial
-- denominator.
funnel_steps AS (
  SELECT 1 AS step_number, 'session_start'  AS event_name, 'Session started'       AS step_name
  UNION ALL SELECT 2, 'view_item',       'Viewed item'
  UNION ALL SELECT 3, 'add_to_cart',     'Added to cart'
  UNION ALL SELECT 4, 'begin_checkout',  'Began checkout'
  UNION ALL SELECT 5, 'purchase',        'Purchased'
),

events AS (
  SELECT
    PARSE_DATE('%Y%m%d', raw.event_date) AS event_dt,
    raw.event_timestamp,
    raw.event_name,
    raw.user_pseudo_id,
    (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') AS ga_session_id
  FROM
    `YOUR_PROJECT.analytics_XXXXXXXXX.events_*` AS raw
  WHERE
    raw._TABLE_SUFFIX BETWEEN '20231231' AND '20240201'
    AND (SELECT value.int_value FROM UNNEST(raw.event_params) WHERE key = 'ga_session_id') IS NOT NULL
    -- Push the funnel's event names into the partition scan. This is a real
    -- cost saving: without it we would aggregate every event in the range,
    -- with it we only carry the handful of event names the funnel uses.
    AND raw.event_name IN (SELECT event_name FROM funnel_steps)
),

-- One row per session x step: the FIRST time that session fired that step's
-- event. MIN(event_timestamp) is what makes the ordering test meaningful -- a
-- session that fires 'purchase' after 'begin_checkout' is ordered, one that
-- fires it before is not.
session_step_hits AS (
  SELECT
    CONCAT(e.user_pseudo_id, '.', CAST(e.ga_session_id AS STRING)) AS session_key,
    e.user_pseudo_id,
    fs.step_number,
    fs.event_name,
    MIN(e.event_timestamp) AS first_hit_timestamp_micros
  FROM events AS e
  JOIN funnel_steps AS fs
    ON fs.event_name = e.event_name
  GROUP BY
    session_key,
    e.user_pseudo_id,
    fs.step_number,
    fs.event_name
),

-- The reachability walk. A session reaches step N iff it has a hit at step N
-- AND reached step N-1 AND that earlier hit happened no later than this one.
-- The recursive CTE is the clean way to express "reached every previous step
-- in order" without a join per step.
reached AS (
  -- Base: sessions that reached step 1.
  SELECT
    h.session_key,
    h.user_pseudo_id,
    1 AS step_number,
    h.first_hit_timestamp_micros
  FROM session_step_hits AS h
  WHERE h.step_number = 1

  UNION ALL

  SELECT
    next_hit.session_key,
    next_hit.user_pseudo_id,
    prev.step_number + 1 AS step_number,
    next_hit.first_hit_timestamp_micros
  FROM reached AS prev
  JOIN session_step_hits AS next_hit
    ON next_hit.session_key = prev.session_key
   AND next_hit.step_number = prev.step_number + 1
  WHERE
    -- The ordering test. >= rather than > so that two steps fired inside the
    -- same microsecond (possible on fast single-page flows) still count.
    next_hit.first_hit_timestamp_micros >= prev.first_hit_timestamp_micros
),

step_counts AS (
  SELECT
    fs.step_number,
    fs.event_name,
    fs.step_name,
    COUNT(DISTINCT r.session_key)   AS sessions_at_step,
    COUNT(DISTINCT r.user_pseudo_id) AS users_at_step
  FROM funnel_steps AS fs
  LEFT JOIN reached AS r
    ON r.step_number = fs.step_number
  GROUP BY
    fs.step_number,
    fs.event_name,
    fs.step_name
),

step_timing AS (
  SELECT
    cur.step_number,
    APPROX_QUANTILES(
      TIMESTAMP_DIFF(
        TIMESTAMP_MICROS(cur.first_hit_timestamp_micros),
        TIMESTAMP_MICROS(prev.first_hit_timestamp_micros),
        SECOND
      ),
      100
    )[SAFE_OFFSET(50)] AS median_seconds_from_prev_step
  FROM reached AS cur
  JOIN reached AS prev
    ON prev.session_key = cur.session_key
   AND prev.step_number = cur.step_number - 1
  GROUP BY cur.step_number
),

final AS (
  SELECT
    sc.step_number,
    sc.event_name,
    sc.step_name,
    sc.sessions_at_step,
    sc.users_at_step,
    LAG(sc.sessions_at_step) OVER (ORDER BY sc.step_number) AS sessions_at_prev_step,
    st.median_seconds_from_prev_step
  FROM step_counts AS sc
  LEFT JOIN step_timing AS st
    ON st.step_number = sc.step_number
)

SELECT
  f.step_number,
  f.step_name,
  f.event_name,
  f.sessions_at_step,
  f.users_at_step,
  IF(f.sessions_at_prev_step IS NULL, NULL, f.sessions_at_prev_step - f.sessions_at_step) AS sessions_lost_from_prev,
  IF(f.sessions_at_prev_step IS NULL OR f.sessions_at_prev_step = 0, NULL,
     ROUND(SAFE_DIVIDE(f.sessions_at_prev_step - f.sessions_at_step, f.sessions_at_prev_step) * 100, 2)) AS session_dropoff_rate,
  ROUND(SAFE_DIVIDE(f.sessions_at_step, FIRST_VALUE(f.sessions_at_step) OVER (ORDER BY f.step_number)) * 100, 2) AS pct_of_step_1,
  ROUND(SAFE_DIVIDE(f.sessions_at_step, f.sessions_at_prev_step) * 100, 2) AS step_conversion_rate,
  f.median_seconds_from_prev_step,
  CASE
    WHEN f.sessions_at_prev_step IS NULL THEN NULL
    WHEN f.sessions_at_prev_step - f.sessions_at_step
         = MAX(f.sessions_at_prev_step - f.sessions_at_step) OVER () THEN '<= biggest drop-off'
    ELSE ''
  END AS biggest_dropoff_flag
FROM final AS f
ORDER BY
  f.step_number;


-- ============================================================================
--  NOTE: CROSS-SESSION (OPEN) FUNNELS
-- ============================================================================
-- If your funnel is genuinely cross-session -- "signed up within 7 days of
-- first visiting" -- you cannot get it from the query above, and you should
-- not try to by dropping the session_key from the join, because that silently
-- turns it into "any user who ever did both things at any time", which is a
-- different and much larger number.
--
-- The honest approach is to define an explicit window and an explicit anchor:
--
--   anchor      = each user's first session date in range
--   step window = event_date BETWEEN anchor_date AND anchor_date + 7
--
-- and then run the same ordered-reachability logic keyed on
-- (user_pseudo_id, ga_session_id) with the window filter applied to the event
-- timestamps, NOT to the session key. Keep the session_key in the output so a
-- reviewer can see how many sessions each user needed. And state the window
-- in the report title -- a 7-day and a 30-day number are not comparable and
-- mixing them is how funnel numbers get a reputation for being fiction.
-- ============================================================================
