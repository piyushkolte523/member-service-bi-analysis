/* =====================================================================
   01_profile_and_clean.sql  -  SQL-1: profile, clean, build analysis set
   Engine : DuckDB (1.x)      Prerequisite: 00_load_raw.sql
   ---------------------------------------------------------------------
   PART A  Profiling       - find the issues (queries tagged @output)
   PART B  Issue log       - each issue, rows affected, impact, decision
   PART C  Staging         - stg_members, stg_interactions (typed, clean)
   PART D  Analysis set    - analysis_interactions (1 row = 1 interaction,
                             joined to member attributes, repeat flags)
   PART E  Control tests   - assertions that must all PASS
   ===================================================================== */


/* =============================== PART A ============================ */

-- A1. Row counts and key uniqueness -----------------------------------
-- @output: a1_row_counts_and_keys
SELECT 'members'      AS source,
       COUNT(*)                         AS row_count,
       COUNT(DISTINCT Member_ID)        AS distinct_key,
       COUNT(*) - COUNT(DISTINCT Member_ID) AS extra_rows_on_key
FROM raw_members
UNION ALL
SELECT 'interactions',
       COUNT(*),
       COUNT(DISTINCT Interaction_ID),
       COUNT(*) - COUNT(DISTINCT Interaction_ID)
FROM raw_interactions;


-- A2. Duplicate Interaction_IDs: exact copies or conflicting records? -
--     If every copy is identical on all 12 columns, de-duplication is
--     safe. If copies differ, we would need a source-of-truth rule.
-- @output: a2_duplicate_interactions
WITH dup_ids AS (
    SELECT Interaction_ID
    FROM raw_interactions
    GROUP BY Interaction_ID
    HAVING COUNT(*) > 1
)
SELECT r.Interaction_ID,
       COUNT(*)                 AS copies,
       COUNT(DISTINCT concat_ws('|', r.Interaction_Date, r.Member_ID, r.Channel,
             r.Product, r.Reason, r.Team, COALESCE(r.Wait_Seconds, '<null>'),
             r.Handle_Seconds, r.Outcome, COALESCE(r.Satisfaction_1_5, '<null>'),
             r.Estimated_Cost))  AS distinct_versions,   -- 1 = exact duplicate
       MIN(r.Interaction_Date)  AS interaction_date
FROM raw_interactions r
JOIN dup_ids d USING (Interaction_ID)
GROUP BY r.Interaction_ID
ORDER BY r.Interaction_ID;


-- A3. Missing / blank values per column (interactions)
-- @output: a3_missing_values
SELECT 'Interaction_ID'   AS column_name, COUNT(*) FILTER (WHERE NULLIF(TRIM(Interaction_ID),'')   IS NULL) AS missing_rows FROM raw_interactions UNION ALL
SELECT 'Interaction_Date',                COUNT(*) FILTER (WHERE NULLIF(TRIM(Interaction_Date),'') IS NULL) FROM raw_interactions UNION ALL
SELECT 'Member_ID',                       COUNT(*) FILTER (WHERE NULLIF(TRIM(Member_ID),'')        IS NULL) FROM raw_interactions UNION ALL
SELECT 'Channel',                         COUNT(*) FILTER (WHERE NULLIF(TRIM(Channel),'')          IS NULL) FROM raw_interactions UNION ALL
SELECT 'Product',                         COUNT(*) FILTER (WHERE NULLIF(TRIM(Product),'')          IS NULL) FROM raw_interactions UNION ALL
SELECT 'Reason',                          COUNT(*) FILTER (WHERE NULLIF(TRIM(Reason),'')           IS NULL) FROM raw_interactions UNION ALL
SELECT 'Team',                            COUNT(*) FILTER (WHERE NULLIF(TRIM(Team),'')             IS NULL) FROM raw_interactions UNION ALL
SELECT 'Wait_Seconds',                    COUNT(*) FILTER (WHERE NULLIF(TRIM(Wait_Seconds),'')     IS NULL) FROM raw_interactions UNION ALL
SELECT 'Handle_Seconds',                  COUNT(*) FILTER (WHERE NULLIF(TRIM(Handle_Seconds),'')   IS NULL) FROM raw_interactions UNION ALL
SELECT 'Outcome',                         COUNT(*) FILTER (WHERE NULLIF(TRIM(Outcome),'')          IS NULL) FROM raw_interactions UNION ALL
SELECT 'Satisfaction_1_5',                COUNT(*) FILTER (WHERE NULLIF(TRIM(Satisfaction_1_5),'') IS NULL) FROM raw_interactions UNION ALL
SELECT 'Estimated_Cost',                  COUNT(*) FILTER (WHERE NULLIF(TRIM(Estimated_Cost),'')   IS NULL) FROM raw_interactions
ORDER BY missing_rows DESC;


-- A4. Category domains: every distinct raw value and its count --------
--     Looks for casing / whitespace variants of the same category.
-- @output: a4_category_domains
WITH v AS (
    SELECT 'Channel' AS field, Channel AS raw_value FROM raw_interactions UNION ALL
    SELECT 'Product',          Product              FROM raw_interactions UNION ALL
    SELECT 'Reason',           Reason               FROM raw_interactions UNION ALL
    SELECT 'Team',             Team                 FROM raw_interactions UNION ALL
    SELECT 'Outcome',          Outcome              FROM raw_interactions UNION ALL
    SELECT 'Segment',          Segment              FROM raw_members      UNION ALL
    SELECT 'Region',           Region               FROM raw_members
)
SELECT field,
       raw_value,
       COUNT(*)                                      AS row_count,
       LOWER(TRIM(raw_value))                        AS normalized_value,
       COUNT(*) OVER (PARTITION BY field, LOWER(TRIM(raw_value))) > 1
           OR raw_value <> TRIM(raw_value)           AS needs_standardizing
FROM v
GROUP BY field, raw_value
ORDER BY field, normalized_value, raw_value;


-- A5. Numeric / date fields: cast failures and value ranges -----------
-- @output: a5_numeric_ranges
SELECT 'Wait_Seconds' AS field,
       COUNT(*) FILTER (WHERE Wait_Seconds IS NOT NULL AND TRY_CAST(Wait_Seconds AS DOUBLE) IS NULL) AS cast_failures,
       MIN(TRY_CAST(Wait_Seconds AS DOUBLE)) AS min_val,
       MEDIAN(TRY_CAST(Wait_Seconds AS DOUBLE)) AS median_val,
       MAX(TRY_CAST(Wait_Seconds AS DOUBLE)) AS max_val,
       COUNT(*) FILTER (WHERE TRY_CAST(Wait_Seconds AS DOUBLE) < 0) AS negative_vals
FROM raw_interactions
UNION ALL
SELECT 'Handle_Seconds',
       COUNT(*) FILTER (WHERE Handle_Seconds IS NOT NULL AND TRY_CAST(Handle_Seconds AS DOUBLE) IS NULL),
       MIN(TRY_CAST(Handle_Seconds AS DOUBLE)), MEDIAN(TRY_CAST(Handle_Seconds AS DOUBLE)),
       MAX(TRY_CAST(Handle_Seconds AS DOUBLE)),
       COUNT(*) FILTER (WHERE TRY_CAST(Handle_Seconds AS DOUBLE) < 0)
FROM raw_interactions
UNION ALL
SELECT 'Satisfaction_1_5',
       COUNT(*) FILTER (WHERE Satisfaction_1_5 IS NOT NULL AND TRY_CAST(Satisfaction_1_5 AS DOUBLE) IS NULL),
       MIN(TRY_CAST(Satisfaction_1_5 AS DOUBLE)), MEDIAN(TRY_CAST(Satisfaction_1_5 AS DOUBLE)),
       MAX(TRY_CAST(Satisfaction_1_5 AS DOUBLE)),
       COUNT(*) FILTER (WHERE TRY_CAST(Satisfaction_1_5 AS DOUBLE) NOT BETWEEN 1 AND 5)
FROM raw_interactions
UNION ALL
SELECT 'Estimated_Cost',
       COUNT(*) FILTER (WHERE Estimated_Cost IS NOT NULL AND TRY_CAST(Estimated_Cost AS DOUBLE) IS NULL),
       MIN(TRY_CAST(Estimated_Cost AS DOUBLE)), MEDIAN(TRY_CAST(Estimated_Cost AS DOUBLE)),
       MAX(TRY_CAST(Estimated_Cost AS DOUBLE)),
       COUNT(*) FILTER (WHERE TRY_CAST(Estimated_Cost AS DOUBLE) < 0)
FROM raw_interactions
UNION ALL
SELECT 'Tenure_Years',
       COUNT(*) FILTER (WHERE Tenure_Years IS NOT NULL AND TRY_CAST(Tenure_Years AS DOUBLE) IS NULL),
       MIN(TRY_CAST(Tenure_Years AS DOUBLE)), MEDIAN(TRY_CAST(Tenure_Years AS DOUBLE)),
       MAX(TRY_CAST(Tenure_Years AS DOUBLE)),
       COUNT(*) FILTER (WHERE TRY_CAST(Tenure_Years AS DOUBLE) < 0)
FROM raw_members
UNION ALL
SELECT 'Products_Held',
       COUNT(*) FILTER (WHERE Products_Held IS NOT NULL AND TRY_CAST(Products_Held AS DOUBLE) IS NULL),
       MIN(TRY_CAST(Products_Held AS DOUBLE)), MEDIAN(TRY_CAST(Products_Held AS DOUBLE)),
       MAX(TRY_CAST(Products_Held AS DOUBLE)),
       COUNT(*) FILTER (WHERE TRY_CAST(Products_Held AS DOUBLE) < 1)
FROM raw_members
UNION ALL
SELECT 'Digital_Adoption_Score',
       COUNT(*) FILTER (WHERE Digital_Adoption_Score IS NOT NULL AND TRY_CAST(Digital_Adoption_Score AS DOUBLE) IS NULL),
       MIN(TRY_CAST(Digital_Adoption_Score AS DOUBLE)), MEDIAN(TRY_CAST(Digital_Adoption_Score AS DOUBLE)),
       MAX(TRY_CAST(Digital_Adoption_Score AS DOUBLE)),
       COUNT(*) FILTER (WHERE TRY_CAST(Digital_Adoption_Score AS DOUBLE) NOT BETWEEN 0 AND 1)
FROM raw_members;


-- A6. Date coverage: cast failures, range, rows per month -------------
-- @output: a6_date_coverage
SELECT strftime(TRY_CAST(Interaction_Date AS DATE), '%Y-%m') AS month,
       COUNT(*)                                                AS raw_rows,
       MIN(TRY_CAST(Interaction_Date AS DATE))                 AS first_date,
       MAX(TRY_CAST(Interaction_Date AS DATE))                 AS last_date,
       COUNT(DISTINCT TRY_CAST(Interaction_Date AS DATE))      AS days_with_data,
       COUNT(*) FILTER (WHERE TRY_CAST(Interaction_Date AS DATE) IS NULL) AS date_cast_failures
FROM raw_interactions
GROUP BY ALL
ORDER BY month;


-- A7. Referential integrity, both directions --------------------------
-- @output: a7_referential_integrity
SELECT 'interactions with no matching member' AS check_name,
       COUNT(*) AS rows_affected
FROM raw_interactions i
LEFT JOIN raw_members m ON TRIM(i.Member_ID) = TRIM(m.Member_ID)
WHERE m.Member_ID IS NULL
UNION ALL
SELECT 'members with no interactions in period',
       COUNT(*)
FROM raw_members m
WHERE NOT EXISTS (SELECT 1 FROM raw_interactions i
                  WHERE TRIM(i.Member_ID) = TRIM(m.Member_ID));


-- A8. Satisfaction coverage: is non-response random? -------------------
--     If response rate or score differs by outcome/channel, average
--     satisfaction is a biased measure of all members' experience.
-- @output: a8_satisfaction_coverage
SELECT 'Outcome' AS dimension, Outcome AS value,
       COUNT(*) AS interactions,
       COUNT(TRY_CAST(Satisfaction_1_5 AS DOUBLE)) AS survey_responses,
       ROUND(COUNT(TRY_CAST(Satisfaction_1_5 AS DOUBLE)) / COUNT(*), 3) AS response_rate,
       ROUND(AVG(TRY_CAST(Satisfaction_1_5 AS DOUBLE)), 2) AS avg_score
FROM raw_interactions GROUP BY ALL
UNION ALL
SELECT 'Channel', LOWER(TRIM(Channel)),
       COUNT(*), COUNT(TRY_CAST(Satisfaction_1_5 AS DOUBLE)),
       ROUND(COUNT(TRY_CAST(Satisfaction_1_5 AS DOUBLE)) / COUNT(*), 3),
       ROUND(AVG(TRY_CAST(Satisfaction_1_5 AS DOUBLE)), 2)
FROM raw_interactions GROUP BY ALL
ORDER BY dimension, value;


-- A9. Estimated_Cost: reverse-engineer the cost rule ------------------
--     Hypothesis: cost = Handle_Seconds x $0.012, plus a fixed fee
--     when the interaction is Transferred. Confirm it holds per row.
-- @output: a9_cost_rule_check
SELECT Outcome,
       COUNT(*)                                                    AS rows,
       ROUND(MIN(TRY_CAST(Estimated_Cost AS DOUBLE)
                 - TRY_CAST(Handle_Seconds AS DOUBLE) * 0.012), 2)  AS min_residual,
       ROUND(MAX(TRY_CAST(Estimated_Cost AS DOUBLE)
                 - TRY_CAST(Handle_Seconds AS DOUBLE) * 0.012), 2)  AS max_residual
FROM raw_interactions
GROUP BY Outcome
ORDER BY Outcome;


-- A10. Handle time on Abandoned contacts ------------------------------
--      An abandoned contact should have ~0 handle time. If not, the
--      field is not a pure "agent talk/work time" and AHT must exclude
--      abandoned rows.
-- @output: a10_abandoned_handle_time
SELECT Outcome,
       COUNT(*)                                          AS rows,
       ROUND(AVG(TRY_CAST(Handle_Seconds AS DOUBLE)), 1) AS avg_handle_seconds,
       MIN(TRY_CAST(Handle_Seconds AS DOUBLE))           AS min_handle_seconds
FROM raw_interactions
GROUP BY Outcome
ORDER BY Outcome;


/* =============================== PART C ============================ */
/* Staging is built before the issue log so the log can quote counts.  */

-- C1. stg_members: one row per member, typed and trimmed
CREATE OR REPLACE TABLE stg_members AS
SELECT TRIM(Member_ID)                               AS member_id,
       TRIM(Segment)                                 AS segment,
       TRIM(Region)                                  AS region,
       CAST(Tenure_Years AS DECIMAL(5,1))            AS tenure_years,
       CAST(Products_Held AS INTEGER)                AS products_held,
       CAST(Digital_Adoption_Score AS DECIMAL(4,2))  AS digital_adoption_score,
       CASE WHEN CAST(Tenure_Years AS DOUBLE) < 2  THEN '0-2 yrs'
            WHEN CAST(Tenure_Years AS DOUBLE) < 5  THEN '2-5 yrs'
            WHEN CAST(Tenure_Years AS DOUBLE) < 10 THEN '5-10 yrs'
            ELSE '10+ yrs' END                       AS tenure_band,
       CASE WHEN CAST(Digital_Adoption_Score AS DOUBLE) < 0.4 THEN 'Low (<0.40)'
            WHEN CAST(Digital_Adoption_Score AS DOUBLE) < 0.7 THEN 'Medium (0.40-0.69)'
            ELSE 'High (0.70+)' END                  AS digital_adoption_band
FROM raw_members;


-- C2. stg_interactions: de-duplicated, standardized, typed, flagged
CREATE OR REPLACE TABLE stg_interactions AS
WITH typed AS (
    SELECT TRIM(Interaction_ID)                      AS interaction_id,
           CAST(Interaction_Date AS DATE)            AS interaction_date,
           TRIM(Member_ID)                           AS member_id,
           -- explicit mapping (not INITCAP) so an unexpected new value
           -- surfaces as 'UNMAPPED' and fails the control test in Part E
           CASE LOWER(TRIM(Channel))
                WHEN 'phone'   THEN 'Phone'
                WHEN 'digital' THEN 'Digital'
                WHEN 'chat'    THEN 'Chat'
                WHEN 'branch'  THEN 'Branch'
                ELSE 'UNMAPPED' END                  AS channel,
           TRIM(Channel)                             AS channel_raw,
           TRIM(Product)                             AS product,
           TRIM(Reason)                              AS reason,
           TRIM(Team)                                AS team,
           TRY_CAST(Wait_Seconds AS INTEGER)         AS wait_seconds,     -- NULL kept as NULL
           CAST(Handle_Seconds AS INTEGER)           AS handle_seconds,
           TRIM(Outcome)                             AS outcome,
           TRY_CAST(Satisfaction_1_5 AS INTEGER)     AS satisfaction,     -- NULL = no survey response
           CAST(Estimated_Cost AS DECIMAL(10,2))     AS estimated_cost
    FROM raw_interactions
)
SELECT *,
       strftime(interaction_date, '%Y-%m')                        AS month,
       CASE WHEN interaction_date < DATE '2026-05-01'
            THEN '1) Jan-Apr' ELSE '2) May-Jun' END               AS period,
       (outcome = 'Resolved')::INTEGER                            AS is_resolved,
       (outcome = 'Transferred')::INTEGER                         AS is_transferred,
       (outcome = 'Escalated')::INTEGER                           AS is_escalated,
       (outcome = 'Abandoned')::INTEGER                           AS is_abandoned,
       (wait_seconds IS NULL)::INTEGER                            AS is_wait_missing,
       (satisfaction IS NOT NULL)::INTEGER                        AS has_survey,
       CASE WHEN satisfaction IS NULL THEN NULL
            ELSE (satisfaction >= 4)::INTEGER END                 AS is_satisfied_top2,
       (channel_raw <> channel)::INTEGER                          AS was_channel_recoded
FROM typed
-- Duplicates were verified in A2 to be exact copies, so keeping any one
-- copy is lossless. ORDER BY makes the choice deterministic anyway.
QUALIFY ROW_NUMBER() OVER (PARTITION BY interaction_id
                           ORDER BY interaction_date, member_id) = 1;


/* =============================== PART D ============================ */
-- D1. analysis_interactions
--     GRAIN    : one row per unique interaction (interaction_id is PK)
--     JOIN     : member_id, many interactions -> one member (N:1).
--                LEFT JOIN so an unmatched interaction would be kept
--                and caught by Part E rather than silently dropped.
--     REPEATS  : window functions over each member's contact history.
--       is_repeat_7d         - this contact was FOLLOWED by another contact
--                              from the same member within 7 days (any
--                              reason). Proxy for "issue not fixed first time".
--       is_same_reason_repeat_7d - followed within 7 days by a contact
--                              with the SAME reason (stricter proxy).
--       is_return_contact_7d - this contact itself came within 7 days of
--                              a previous contact (the "extra" volume).
--       repeat_window_complete - 1 if 7 full days of follow-up exist in
--                              the data (date <= 2026-06-23). Contacts
--                              after that are right-censored and are
--                              excluded from repeat-rate denominators.
CREATE OR REPLACE TABLE analysis_interactions AS
WITH seq AS (
    SELECT i.*,
           LEAD(interaction_date) OVER w_member              AS next_contact_date,
           LAG(interaction_date)  OVER w_member              AS prev_contact_date,
           LEAD(interaction_date) OVER w_member_reason       AS next_same_reason_date,
           ROW_NUMBER()           OVER w_member              AS member_contact_seq
    FROM stg_interactions i
    WINDOW w_member        AS (PARTITION BY member_id
                               ORDER BY interaction_date, interaction_id),
           w_member_reason AS (PARTITION BY member_id, reason
                               ORDER BY interaction_date, interaction_id)
)
SELECT s.*,
       m.segment, m.region, m.tenure_years, m.tenure_band,
       m.products_held, m.digital_adoption_score, m.digital_adoption_band,
       date_diff('day', s.interaction_date, s.next_contact_date)       AS days_to_next_contact,
       COALESCE(date_diff('day', s.interaction_date, s.next_contact_date) <= 7, false)::INTEGER
                                                                       AS is_repeat_7d,
       COALESCE(date_diff('day', s.interaction_date, s.next_same_reason_date) <= 7, false)::INTEGER
                                                                       AS is_same_reason_repeat_7d,
       COALESCE(date_diff('day', s.prev_contact_date, s.interaction_date) <= 7, false)::INTEGER
                                                                       AS is_return_contact_7d,
       (s.interaction_date <= (SELECT MAX(interaction_date) FROM stg_interactions) - INTERVAL 7 DAY)::INTEGER
                                                                       AS repeat_window_complete
FROM seq s
LEFT JOIN stg_members m ON s.member_id = m.member_id;


/* =============================== PART B ============================ */
-- B1. Data-quality issue log (counts computed, not typed in)
CREATE OR REPLACE TABLE dq_issue_log AS
SELECT issue_no, issue, CAST(rows_affected AS BIGINT) AS rows_affected,
       impact_on_conclusions, decision
FROM (VALUES
 (1, 'Exact duplicate interaction rows',
     (SELECT COUNT(*) FROM raw_interactions) - (SELECT COUNT(*) FROM stg_interactions),
     'Inflates volume and every count-based rate; double-counts those members in repeat-contact logic (a duplicate looks like a same-day repeat).',
     'Verified all copies identical on every column (A2); kept one copy per Interaction_ID.'),
 (2, 'Inconsistent Channel casing (phone vs Phone)',
     (SELECT SUM(was_channel_recoded) FROM stg_interactions),
     'Splits Phone into two groups; Phone volume, wait and rates would be understated in any channel cut.',
     'Mapped case-insensitively to a controlled list; unknown values become UNMAPPED and fail a control test.'),
 (3, 'Missing Wait_Seconds',
     (SELECT SUM(is_wait_missing) FROM stg_interactions),
     'Treating blank as 0 would understate average wait.',
     'Kept as NULL; excluded from wait averages only (row still counts in volume and outcome rates). Coverage shown with the KPI.'),
 (4, 'Satisfaction missing for most interactions (survey non-response)',
     (SELECT COUNT(*) - SUM(has_survey) FROM stg_interactions),
     'Only ~28% respond; unresolved outcomes score much lower, so the average reflects who responded, not all members. Not comparable to a 4.2 target without knowing survey method.',
     'Kept NULL = no response. Report avg score AND response rate AND n together; never impute.'),
 (5, 'Handle_Seconds populated on Abandoned contacts',
     (SELECT COUNT(*) FROM stg_interactions WHERE is_abandoned = 1 AND handle_seconds > 0),
     'Abandoned contacts have no agent work, so including them distorts AHT; field definition is unclear (may be total session time).',
     'AHT calculated on non-abandoned contacts only; definition flagged as an open question for the data owner.'),
 (6, 'Estimated_Cost is a derived field, not an observed cost',
     (SELECT COUNT(*) FROM stg_interactions),
     'Cost = Handle_Seconds x $0.012 (+ $3.00 when Transferred) on every row (A9). It contains no channel-specific cost, so cost analysis only restates handle time and transfers.',
     'Used for directional cost-of-failure estimates only; stated as an assumption.'),
 (7, 'Right-censored repeat-contact window (last 7 days of June)',
     (SELECT COUNT(*) FROM analysis_interactions WHERE repeat_window_complete = 0),
     'Contacts on Jun 24-30 cannot be followed for 7 days, which would understate June repeat rate.',
     'Flag repeat_window_complete; repeat-rate denominators use complete-window contacts only.'),
 (8, 'Targets table has no target for repeat contact, escalation, abandonment or AHT',
     NULL,
     'Leadership is measured on 4 KPIs only; deterioration elsewhere is not visible against a target.',
     'Report these KPIs as trend-only and recommend targets be defined.')
) AS t(issue_no, issue, rows_affected, impact_on_conclusions, decision);

-- @output: b1_dq_issue_log
SELECT * FROM dq_issue_log ORDER BY issue_no;


/* =============================== PART E ============================ */
-- E1. Control tests: every row must show PASS before analysis proceeds.
-- @output: e1_control_tests
WITH t AS (
    SELECT 'PK unique in analysis set' AS test,
           (SELECT COUNT(*) - COUNT(DISTINCT interaction_id) FROM analysis_interactions) = 0 AS passed
    UNION ALL SELECT 'Row count = raw minus exact duplicates (4004-12)',
           (SELECT COUNT(*) FROM analysis_interactions)
           = (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM raw_interactions))
    UNION ALL SELECT 'Join preserved rows (no fan-out)',
           (SELECT COUNT(*) FROM analysis_interactions) = (SELECT COUNT(*) FROM stg_interactions)
    UNION ALL SELECT 'Every interaction matched a member',
           (SELECT COUNT(*) FROM analysis_interactions WHERE segment IS NULL) = 0
    UNION ALL SELECT 'No UNMAPPED channels',
           (SELECT COUNT(*) FROM analysis_interactions WHERE channel = 'UNMAPPED') = 0
    UNION ALL SELECT 'Exactly one outcome flag per row',
           (SELECT COUNT(*) FROM analysis_interactions
            WHERE is_resolved + is_transferred + is_escalated + is_abandoned <> 1) = 0
    UNION ALL SELECT 'Satisfaction within 1-5 when present',
           (SELECT COUNT(*) FROM analysis_interactions
            WHERE satisfaction IS NOT NULL AND satisfaction NOT BETWEEN 1 AND 5) = 0
    UNION ALL SELECT 'Members unique',
           (SELECT COUNT(*) - COUNT(DISTINCT member_id) FROM stg_members) = 0
)
SELECT test, CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result FROM t;


-- E2. Preview of the analysis dataset
-- @output: e2_analysis_dataset_preview
SELECT interaction_id, interaction_date, month, period, member_id, segment, region,
       channel, product, reason, team, wait_seconds, handle_seconds, outcome,
       satisfaction, estimated_cost, days_to_next_contact, is_repeat_7d,
       is_same_reason_repeat_7d, is_return_contact_7d, repeat_window_complete
FROM analysis_interactions
ORDER BY interaction_id
LIMIT 15;
