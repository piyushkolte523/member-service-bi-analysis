/* =====================================================================
   02_monthly_kpis.sql  -  SQL-2: core monthly KPIs + actual vs target
   Engine : DuckDB (1.x)      Prerequisite: 01_profile_and_clean.sql
   Source : analysis_interactions (1 row = 1 de-duplicated interaction)
   ---------------------------------------------------------------------
   Outputs
     k0  metric dictionary (definitions live in the database, not a doc)
     k1  monthly KPI table              (view v_kpi_monthly - reusable)
     k2  actual vs target, 4 targeted KPIs, with favorable/unfavorable
     k3  satisfaction coverage by month (so the score is not over-read)
   ===================================================================== */


-- K0. Metric dictionary ------------------------------------------------
CREATE OR REPLACE TABLE metric_dictionary AS
SELECT * FROM (VALUES
 ('Interaction volume',      'COUNT of de-duplicated interactions',                                   'All rows',                                     'Trend only'),
 ('Unique members',          'COUNT DISTINCT member_id contacting in the month',                       'All rows',                                     'Trend only'),
 ('Contacts per member',     'Interactions / unique members',                                          'All rows',                                     'Lower is better'),
 ('Average wait (s)',        'AVG wait_seconds',                                                       'Rows with wait recorded (7 NULL rows excluded)', 'Lower is better; target 65s'),
 ('P90 wait (s)',            '90th percentile of wait_seconds - the experience of the slowest 10%',    'Rows with wait recorded',                      'Lower is better'),
 ('% waits > 2 min',         'Share of contacts with wait_seconds > 120',                              'Rows with wait recorded',                      'Lower is better'),
 ('Average handle time (s)', 'AVG handle_seconds',                                                     'Non-abandoned rows (no agent work on abandoned)', 'Context, not a goal'),
 ('Resolution rate',         'Resolved / all interactions',                                            'All rows (abandoned count as not resolved)',   'Higher is better; target 82%'),
 ('Transfer rate',           'Transferred / all interactions',                                         'All rows',                                     'Lower is better; target 8%'),
 ('Escalation rate',         'Escalated / all interactions',                                           'All rows',                                     'Lower is better'),
 ('Abandonment rate',        'Abandoned / all interactions',                                           'All rows',                                     'Lower is better'),
 ('Avg satisfaction (1-5)',  'AVG satisfaction among survey responses',                                'Rows with a survey response only (~28%)',      'Higher is better; target 4.2'),
 ('Survey response rate',    'Rows with satisfaction / all rows',                                      'All rows',                                     'Coverage indicator'),
 ('% satisfied (4-5)',       'Responses scoring 4 or 5 / all responses',                               'Rows with a survey response',                  'Higher is better'),
 ('7-day repeat-contact rate','Share of contacts followed by ANOTHER contact from the same member within 7 calendar days (any channel, any reason)',
                                                                                                       'Contacts dated <= 2026-06-23 (full 7-day window observable)', 'Lower is better'),
 ('7-day same-reason repeat','As above, but the next contact must have the same reason - stricter proxy for "not fixed first time"',
                                                                                                       'Contacts dated <= 2026-06-23',                 'Lower is better'),
 ('Cost per resolved contact','Total estimated cost / resolved interactions - what it really costs to get one issue resolved', 'All rows', 'Lower is better')
) AS t(metric, definition, population, direction);

-- @output: k0_metric_dictionary
SELECT * FROM metric_dictionary;


-- K1. Monthly KPI view ---------------------------------------------------
CREATE OR REPLACE VIEW v_kpi_monthly AS
SELECT month,
       COUNT(*)                                                   AS interactions,
       COUNT(DISTINCT member_id)                                  AS unique_members,
       ROUND(COUNT(*) / COUNT(DISTINCT member_id), 2)             AS contacts_per_member,
       ROUND(AVG(wait_seconds), 1)                                AS avg_wait_s,
       ROUND(QUANTILE_CONT(wait_seconds, 0.9), 0)                 AS p90_wait_s,
       ROUND(AVG(CASE WHEN wait_seconds IS NOT NULL
                      THEN (wait_seconds > 120)::INT END), 3)     AS pct_wait_over_120s,
       ROUND(AVG(handle_seconds) FILTER (WHERE is_abandoned = 0), 1) AS aht_s,
       ROUND(AVG(is_resolved), 3)                                 AS resolution_rate,
       ROUND(AVG(is_transferred), 3)                              AS transfer_rate,
       ROUND(AVG(is_escalated), 3)                                AS escalation_rate,
       ROUND(AVG(is_abandoned), 3)                                AS abandonment_rate,
       SUM(has_survey)::BIGINT                                    AS survey_responses,
       ROUND(AVG(has_survey), 3)                                  AS survey_response_rate,
       ROUND(AVG(satisfaction), 2)                                AS avg_satisfaction,
       ROUND(AVG(is_satisfied_top2), 3)                           AS pct_satisfied_top2,
       SUM(repeat_window_complete)::BIGINT                        AS repeat_eligible_contacts,
       ROUND(AVG(is_repeat_7d)             FILTER (WHERE repeat_window_complete = 1), 3) AS repeat_7d_rate,
       ROUND(AVG(is_same_reason_repeat_7d) FILTER (WHERE repeat_window_complete = 1), 3) AS same_reason_repeat_7d_rate,
       ROUND(SUM(estimated_cost), 2)                              AS total_est_cost,
       ROUND(SUM(estimated_cost) / NULLIF(SUM(is_resolved), 0), 2) AS cost_per_resolved
FROM analysis_interactions
GROUP BY month;

-- @output: k1_monthly_kpis
SELECT * FROM v_kpi_monthly ORDER BY month;


-- K1b. Same KPIs at period level (Jan-Apr vs May-Jun) for quick reading
-- @output: k1b_period_kpis
SELECT period,
       COUNT(DISTINCT month)                                      AS months,
       ROUND(COUNT(*) / COUNT(DISTINCT month), 0)                 AS interactions_per_month,
       ROUND(AVG(wait_seconds), 1)                                AS avg_wait_s,
       ROUND(QUANTILE_CONT(wait_seconds, 0.9), 0)                 AS p90_wait_s,
       ROUND(AVG(handle_seconds) FILTER (WHERE is_abandoned = 0), 1) AS aht_s,
       ROUND(AVG(is_resolved), 3)                                 AS resolution_rate,
       ROUND(AVG(is_transferred), 3)                              AS transfer_rate,
       ROUND(AVG(is_escalated), 3)                                AS escalation_rate,
       ROUND(AVG(is_abandoned), 3)                                AS abandonment_rate,
       ROUND(AVG(satisfaction), 2)                                AS avg_satisfaction,
       ROUND(AVG(has_survey), 3)                                  AS survey_response_rate,
       ROUND(AVG(is_repeat_7d) FILTER (WHERE repeat_window_complete = 1), 3) AS repeat_7d_rate,
       ROUND(SUM(estimated_cost) / NULLIF(SUM(is_resolved), 0), 2) AS cost_per_resolved
FROM analysis_interactions
GROUP BY period
ORDER BY period;


-- K2. Actual vs target ---------------------------------------------------
--     Targets are stored long (month, KPI, target). Actuals are unpivoted
--     to the same shape and joined on month + KPI name.
CREATE OR REPLACE VIEW v_kpi_vs_target AS
WITH actual AS (
    SELECT month, 'Resolution_Rate'      AS kpi, AVG(is_resolved)::DOUBLE    AS actual FROM analysis_interactions GROUP BY month
    UNION ALL
    SELECT month, 'Average_Wait_Seconds',        AVG(wait_seconds)::DOUBLE             FROM analysis_interactions GROUP BY month
    UNION ALL
    SELECT month, 'Satisfaction',                AVG(satisfaction)::DOUBLE             FROM analysis_interactions GROUP BY month
    UNION ALL
    SELECT month, 'Transfer_Rate',               AVG(is_transferred)::DOUBLE           FROM analysis_interactions GROUP BY month
),
tgt AS (
    SELECT TRIM(Month) AS month, TRIM(KPI) AS kpi, CAST(Target AS DOUBLE) AS target
    FROM raw_targets
)
SELECT a.month,
       a.kpi,
       ROUND(a.actual, 3)                                          AS actual,
       t.target,
       ROUND(a.actual - t.target, 3)                               AS variance,
       CASE WHEN a.kpi IN ('Resolution_Rate', 'Satisfaction')
            THEN 'Higher is better' ELSE 'Lower is better' END     AS direction,
       CASE WHEN (a.kpi IN ('Resolution_Rate', 'Satisfaction')    AND a.actual >= t.target)
              OR (a.kpi IN ('Average_Wait_Seconds','Transfer_Rate') AND a.actual <= t.target)
            THEN 'On/Better than target' ELSE 'Missed target' END  AS status
FROM actual a
LEFT JOIN tgt t USING (month, kpi);

-- @output: k2_actual_vs_target
SELECT * FROM v_kpi_vs_target ORDER BY kpi, month;


-- K2b. Scorecard summary: months on target per KPI
-- @output: k2b_target_scorecard
SELECT kpi,
       COUNT(*) FILTER (WHERE status = 'On/Better than target') AS months_on_target,
       COUNT(*)                                                AS months,
       ROUND(AVG(actual) FILTER (WHERE month <= '2026-04'), 3) AS avg_jan_apr,
       ROUND(AVG(actual) FILTER (WHERE month >= '2026-05'), 3) AS avg_may_jun,
       MAX(target)                                             AS target
FROM v_kpi_vs_target
GROUP BY kpi
ORDER BY kpi;


-- K3. Satisfaction coverage by month (show n alongside the score) -------
-- @output: k3_satisfaction_coverage
SELECT month,
       COUNT(*)                                   AS interactions,
       SUM(has_survey)::BIGINT                    AS responses,
       ROUND(AVG(has_survey), 3)                  AS response_rate,
       ROUND(AVG(satisfaction), 2)                AS avg_score,
       -- approx. 95% margin of error on the monthly average score
       ROUND(1.96 * STDDEV_SAMP(satisfaction) / SQRT(SUM(has_survey)), 2) AS moe_95,
       ROUND(AVG(satisfaction) FILTER (WHERE is_resolved = 1), 2) AS avg_score_resolved,
       ROUND(AVG(satisfaction) FILTER (WHERE is_resolved = 0), 2) AS avg_score_not_resolved
FROM analysis_interactions
GROUP BY month
ORDER BY month;
