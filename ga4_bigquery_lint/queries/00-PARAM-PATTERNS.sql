-- ============================================================================
--  00-PARAM-PATTERNS.sql
--  GA4 BigQuery Session & Funnel SQL Pack
-- ============================================================================
--
--  WHAT THIS FILE IS
--    A reference file, not a report. It contains the parameter-extraction
--    patterns used by every other query in this pack, plus the lookups for
--    the four GA4 event parameters you will use constantly:
--      ga_session_id, ga_session_number, page_location, page_title
--    and the session-scoped attribution parameters that GA4 writes on the
--    event where the session started (ga_session_number = 1 is NOT the test
--    for "new session" -- see docs/SESSIONISATION.md).
--
--  WHY IT EXISTS
--    event_params is a REPEATED RECORD of {key, value}. It is the single
--    biggest source of wrong numbers in GA4 BigQuery SQL, for three reasons:
--
--      1. There is no single "the value" column. A parameter's payload lives
--         in exactly one of value.string_value, value.int_value,
--         value.double_value. Reading only string_value silently drops every
--         numeric parameter -- including ga_session_id, which GA4 writes as
--         an INTEGER. A query that reads only string_value for ga_session_id
--         gets NULL for every row and "0 sessions" comes back.
--
--      2. COALESCE over the three fields is NOT safe in the general case.
--         If you COALESCE a numeric and a string you force a type. Casting
--         string_value to INT64 errors the whole query the moment one event
--         carries a non-numeric string in that key. COALESCE is only correct
--         when you can prove the parameter is written with a single value
--         type (true for the GA4 built-ins) -- and even then you cannot mix
--         types in one COALESCE, so you must COALESCE within a type, or
--         branch on which field is present.
--
--      3. UNNEST(event_params) MULTIPLIES ROWS. If you unnest the whole
--         array in the FROM clause and then join or aggregate, every event
--         is repeated once per parameter (typically 10-25 rows). A COUNT(*)
--         over that is meaningless. Only ever unnest in a scalar subquery,
--         or in a FROM clause together with an explicit `WHERE key = ...`
--         that keeps at most one row per event.
--
--    Every query in this pack unnest event_params in a scalar subquery so
--    that one source row stays one output row. Keep that discipline.
--
--  COST
--    This file scans nothing on its own: every statement below is either a
--    comment or a self-contained SELECT against a single day. To cost-check
--    a real query, use the dry run recipe in docs/COST-CONTROL.md.
--
--  NOT EXECUTED AGAINST BIGQUERY
--    These statements were written against the documented GA4 BigQuery
--    export schema and syntax-checked with a SQL parser. They were never run
--    against a real property -- no GCP account was available. Validate
--    against your own property using docs/VALIDATION.md before you trust a
--    number. See README.md.
--
-- ============================================================================


-- ============================================================================
-- PATTERN 1 -- Scalar string parameter (one row per event, never multiplies)
-- ============================================================================
-- Use for: page_location, page_referrer, page_title, source, medium, campaign,
--          term, content, gclid, dclid, srclt -- anything GA4 writes as text.
--
-- The subquery form returns at most one value and cannot duplicate the
-- outer row. This is the pattern to copy.

SELECT
  event_date,
  event_name,
  user_pseudo_id,
  (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location
FROM
  `YOUR_PROJECT.analytics_XXXXXXXXX.events_*`
WHERE
  _TABLE_SUFFIX = '20240101'
LIMIT 100;


-- ============================================================================
-- PATTERN 2 -- Scalar INTEGER parameter, the correct way
-- ============================================================================
-- Use for: ga_session_id, ga_session_number, engagement_time_msec,
--          entrances, percent_scrolled, and any custom numeric parameter GA4
--          sends as an integer.
--
-- ga_session_id is an INT64. Read value.int_value. If you read
-- value.string_value here you get NULL for every row, and every query built
-- on it returns zero sessions with no error message. This is trap #1.
--
-- WHY NOT COALESCE(int_value, string_value): those are INT64 and STRING.
-- BigQuery will not COALESCE mixed types without a cast, and casting a string
-- to INT64 raises a runtime error on the first non-numeric value. Read the
-- field that GA4 actually populates.

SELECT
  event_date,
  event_name,
  user_pseudo_id,
  (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS ga_session_id,
  (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_number') AS ga_session_number
FROM
  `YOUR_PROJECT.analytics_XXXXXXXXX.events_*`
WHERE
  _TABLE_SUFFIX = '20240101'
  AND event_name = 'session_start'
LIMIT 100;


-- ============================================================================
-- PATTERN 3 -- Scalar DOUBLE parameter
-- ============================================================================
-- Use for: value parameters written as floats, e.g. a custom numeric metric,
--          or ecommerce parameters that arrive as doubles.
--
-- Note the argument order: SAFE_CAST(x AS FLOAT64), not the other way round.
-- Prefer SAFE_CAST over CAST for anything that came from a string.

SELECT
  event_date,
  event_name,
  (SELECT value.double_value FROM UNNEST(event_params) WHERE key = 'value') AS double_value_param,
  (SELECT SAFE_CAST(value.string_value AS FLOAT64) FROM UNNEST(event_params) WHERE key = 'value') AS double_from_string
FROM
  `YOUR_PROJECT.analytics_XXXXXXXXX.events_*`
WHERE
  _TABLE_SUFFIX = '20240101'
  AND event_name = 'purchase'
LIMIT 100;


-- ============================================================================
-- PATTERN 4 -- "I do not know which field this key uses" -- the safe union
-- ============================================================================
-- Use for CUSTOM parameters of unknown type. Do not use this for ga_session_id
-- (Pattern 2 is clearer and cheaper); use it when a parameter might be sent as
-- either a string or a number depending on the client.
--
-- COALESCE(string_value, SAFE_CAST(...)) is type-safe here because SAFE_CAST
-- returns NULL instead of raising on unparseable input, and the result is
-- STRING throughout. Always bind the result to a known type at the edge.
--
-- Caveat: an integer 42 and a string '42' both come back as '42', so this
-- pattern is fine for display and grouping and NOT fine if you need to do
-- arithmetic on the value. For arithmetic, use Pattern 2.

SELECT
  event_date,
  event_name,
  COALESCE(
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'my_custom_param'),
    SAFE_CAST((SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'my_custom_param') AS STRING),
    SAFE_CAST((SELECT value.double_value FROM UNNEST(event_params) WHERE key = 'my_custom_param') AS STRING)
  ) AS my_custom_param_as_string
FROM
  `YOUR_PROJECT.analytics_XXXXXXXXX.events_*`
WHERE
  _TABLE_SUFFIX = '20240101'
LIMIT 100;


-- ============================================================================
-- PATTERN 5 -- The ONE legitimate use of unnesting in the FROM clause
-- ============================================================================
-- When you want a long-format parameter dump for a single event, unnest in
-- FROM -- but then you MUST filter to explicit keys, because otherwise the
-- output has one row per parameter per event and every count you derive from
-- it is inflated by roughly 10-25x.
--
-- Use this for debugging ("what parameters does this event actually carry?"),
-- not for reporting.

SELECT
  event_date,
  event_name,
  user_pseudo_id,
  p.key,
  p.value.string_value,
  p.value.int_value,
  p.value.double_value,
  p.value.float_value   -- legacy field; present in older exports, may be NULL
FROM
  `YOUR_PROJECT.analytics_XXXXXXXXX.events_*`,
  UNNEST(event_params) AS p
WHERE
  _TABLE_SUFFIX = '20240101'
  AND event_name = 'session_start'
LIMIT 1000;


-- ============================================================================
-- PATTERN 6 -- Reading user_properties (same shape, same three-field problem)
-- ============================================================================
-- user_properties is ALSO a repeated record of {key, value}. value here is a
-- single struct with string_value / int_value / double_value / set_timestamp_micros.
-- GA4 writes almost all user properties as strings.

SELECT
  user_pseudo_id,
  (SELECT value.string_value FROM UNNEST(user_properties) WHERE key = 'membership_tier') AS membership_tier,
  (SELECT value.int_value    FROM UNNEST(user_properties) WHERE key = 'account_age_days') AS account_age_days
FROM
  `YOUR_PROJECT.analytics_XXXXXXXXX.events_*`
WHERE
  _TABLE_SUFFIX = '20240101'
LIMIT 100;


-- ============================================================================
-- PATTERN 7 -- Case-sensitivity and whitespace
-- ============================================================================
-- The `key = 'ga_session_id'` filter is an exact string comparison and it is
-- case-sensitive. GA4's own parameters are lowercase snake_case. Custom
-- parameters keep whatever casing the sender used, so 'MyParam' and 'myparam'
-- are two different parameters and both can appear in the same export.
-- If a custom parameter returns NULL for everything, check the sender's
-- casing before you assume the query is broken:
--
--   SELECT DISTINCT p.key
--   FROM `...events_*`, UNNEST(event_params) AS p
--   WHERE _TABLE_SUFFIX = '20240101'
--   ORDER BY 1;   -- then eyeball the exact spelling you need
--
-- That DISTINCT-scan is cheap on one day and expensive over a year. Run it on
-- one day only.


-- ============================================================================
-- SUMMARY OF THE RULES
-- ============================================================================
--   1. ga_session_id and ga_session_number are INTEGERS -> value.int_value.
--   2. page_* and most custom params are STRINGS     -> value.string_value.
--   3. Never COALESCE across string_value and int_value without SAFE_CAST.
--   4. Never unnest event_params in FROM unless every key is filtered.
--   5. A session key is CONCAT(user_pseudo_id, '.', ga_session_id) -- the
--      session id alone collides across users. See docs/SESSIONISATION.md.
-- ============================================================================
