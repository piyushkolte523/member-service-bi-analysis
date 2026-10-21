/* =====================================================================
   03_period_drivers.sql  -  SQL-3: Jan-Apr vs May-Jun, what drives it?
   Engine : DuckDB (1.x)      Prerequisite: 01_profile_and_clean.sql
   ---------------------------------------------------------------------
   METHOD - contribution decomposition (sums exactly to the total change)
     For a dimension with values i, let w = value's share of eligible
     contacts and x = the metric for that value, in period 1 and 2.
       Overall metric       = SUM_i w_i * x_i
       Contribution_i       = w2*x2 - w1*x1        (SUM_i = total change)
         Rate effect_i      = avg(w1,w2) * (x2 - x1)   the value got better/worse
         Mix effect_i       = avg(x1,x2) * (w2 - w1)   the value got bigger/smaller
     Ranked with RANK() and shared with SUM() OVER (window functions).
     "Unfavorable" is signed so that rank 1 = biggest contributor to the
     deterioration, whichever direction is "good" for the metric.

   Outputs
     s1  volume growth by dimension value, ranked
     s2  metric-change contributions for every dimension, ranked
     s3  top contributor per dimension per metric (executive summary)
     s4  intersection drill-down (Channel x Product, Channel x Reason)
     s5  the hot-spot isolated: Phone + (Credit Card or Payment) vs rest
     s6  weekly trend with rolling average - WHEN did it change?
     s7  NEW METRIC: "Resolved-and-stayed-resolved" (true first-contact
         resolution) vs the reported resolution rate
   ===================================================================== */


-- Long (unpivoted) view: one row per interaction per dimension ---------
CREATE OR REPLACE VIEW v_dim_long AS
SELECT a.*, d.dimension, d.dim_value
FROM analysis_interactions a,
LATERAL (VALUES ('Channel',          a.channel),
                ('Product',          a.product),
                ('Reason',           a.reason),
                ('Team',             a.team),
                ('Segment',          a.segment),
                ('Region',           a.region),
                ('Tenure band',      a.tenure_band),
                ('Digital adoption', a.digital_adoption_band)) AS d(dimension, dim_value);


-- S1. Volume growth: which values account for the extra contacts? -------
--     Normalised to contacts per month (Jan-Apr = 4 months, May-Jun = 2).
-- @output: s1_volume_growth_ranked
WITH v AS (
    SELECT dimension, dim_value,
           COUNT(*) FILTER (WHERE period = '1) Jan-Apr') / 4.0 AS per_month_p1,
           COUNT(*) FILTER (WHERE period = '2) May-Jun') / 2.0 AS per_month_p2
    FROM v_dim_long
    GROUP BY dimension, dim_value
)
SELECT dimension, dim_value,
       ROUND(per_month_p1, 1)                          AS contacts_per_month_jan_apr,
       ROUND(per_month_p2, 1)                          AS contacts_per_month_may_jun,
       ROUND(per_month_p2 - per_month_p1, 1)           AS added_per_month,
       ROUND(per_month_p2 / per_month_p1 - 1, 3)       AS growth_pct,
       ROUND((per_month_p2 - per_month_p1)
             / SUM(per_month_p2 - per_month_p1) OVER (PARTITION BY dimension), 3)
                                                       AS share_of_growth,
       RANK() OVER (PARTITION BY dimension
                    ORDER BY per_month_p2 - per_month_p1 DESC) AS growth_rank
FROM v
ORDER BY dimension, growth_rank;


-- S2. Metric-change contributions, all dimensions -----------------------
CREATE OR REPLACE TABLE driver_contributions AS
WITH metric_long AS (
    -- one row per interaction per dimension per metric, with an
    -- eligibility rule per metric (matches the definitions in 02)
    SELECT dimension, dim_value, period, 'Avg wait (s)' AS metric,
           wait_seconds::DOUBLE AS val, +1 AS bad_direction
    FROM v_dim_long WHERE wait_seconds IS NOT NULL
    UNION ALL
    SELECT dimension, dim_value, period, 'Abandonment rate', is_abandoned, +1
    FROM v_dim_long
    UNION ALL
    SELECT dimension, dim_value, period, 'Resolution rate', is_resolved, -1
    FROM v_dim_long
    UNION ALL
    SELECT dimension, dim_value, period, '7-day repeat rate', is_repeat_7d, +1
    FROM v_dim_long WHERE repeat_window_complete = 1
    UNION ALL
    SELECT dimension, dim_value, period, 'Avg satisfaction', satisfaction, -1
    FROM v_dim_long WHERE satisfaction IS NOT NULL
),
cell AS (
    SELECT metric, bad_direction, dimension, dim_value,
           COUNT(*) FILTER (WHERE period = '1) Jan-Apr')  AS n1,
           COUNT(*) FILTER (WHERE period = '2) May-Jun')  AS n2,
           AVG(val) FILTER (WHERE period = '1) Jan-Apr')  AS x1,
           AVG(val) FILTER (WHERE period = '2) May-Jun')  AS x2
    FROM metric_long
    GROUP BY ALL
),
weighted AS (
    SELECT *,
           n1 / SUM(n1) OVER (PARTITION BY metric, dimension) AS w1,
           n2 / SUM(n2) OVER (PARTITION BY metric, dimension) AS w2
    FROM cell
),
contrib AS (
    SELECT *,
           w2 * x2 - w1 * x1                    AS contribution,
           (w1 + w2) / 2 * (x2 - x1)            AS rate_effect,
           (x1 + x2) / 2 * (w2 - w1)            AS mix_effect
    FROM weighted
)
SELECT metric, dimension, dim_value,
       n1 AS n_jan_apr, n2 AS n_may_jun,
       ROUND(x1, 3)                                         AS value_jan_apr,
       ROUND(x2, 3)                                         AS value_may_jun,
       ROUND(x2 - x1, 3)                                    AS change_in_value,
       ROUND(contribution, 4)                               AS contribution_to_total_change,
       ROUND(rate_effect, 4)                                AS rate_effect,
       ROUND(mix_effect, 4)                                 AS mix_effect,
       ROUND(SUM(contribution) OVER (PARTITION BY metric, dimension), 4)
                                                            AS total_change,
       ROUND(contribution / NULLIF(SUM(contribution) OVER (PARTITION BY metric, dimension), 0), 3)
                                                            AS share_of_total_change,
       RANK() OVER (PARTITION BY metric, dimension
                    ORDER BY contribution * bad_direction DESC) AS unfavorable_rank,
       -- small cells make rates noisy: flag them so they are not over-read
       (LEAST(n1, n2) < 30)                                 AS low_volume_flag
FROM contrib;

-- @output: s2_driver_contributions_ranked
SELECT * FROM driver_contributions
ORDER BY metric, dimension, unfavorable_rank;


-- S3. Executive summary: #1 contributor in each dimension, per metric ---
--     Dimensions are then ordered by how concentrated the change is:
--     if one value explains most of the change, that dimension is where
--     to look.
-- @output: s3_top_driver_per_dimension
SELECT metric,
       total_change,
       dimension,
       dim_value                AS top_contributor,
       value_jan_apr, value_may_jun,
       share_of_total_change    AS top_share_of_change,
       DENSE_RANK() OVER (PARTITION BY metric ORDER BY share_of_total_change DESC)
                                AS dimension_concentration_rank
FROM driver_contributions
WHERE unfavorable_rank = 1
ORDER BY metric, dimension_concentration_rank;


-- S4. Intersection drill-down -----------------------------------------
--     Single dimensions can hide an interaction (e.g. "Credit Card" looks
--     bad overall only because of one channel). Rank the cells.
-- @output: s4_intersection_drilldown
WITH x AS (
    SELECT 'Channel x Product' AS drill, channel || ' | ' || product AS cell, *
    FROM analysis_interactions
    UNION ALL
    SELECT 'Channel x Reason', channel || ' | ' || reason, *
    FROM analysis_interactions
),
c AS (
    SELECT drill, cell,
           COUNT(*) FILTER (WHERE period = '1) Jan-Apr')                  AS n_jan_apr,
           COUNT(*) FILTER (WHERE period = '2) May-Jun')                  AS n_may_jun,
           AVG(wait_seconds) FILTER (WHERE period = '1) Jan-Apr')         AS wait_p1,
           AVG(wait_seconds) FILTER (WHERE period = '2) May-Jun')         AS wait_p2,
           AVG(is_abandoned) FILTER (WHERE period = '1) Jan-Apr')         AS aband_p1,
           AVG(is_abandoned) FILTER (WHERE period = '2) May-Jun')         AS aband_p2,
           AVG(is_resolved)  FILTER (WHERE period = '1) Jan-Apr')         AS res_p1,
           AVG(is_resolved)  FILTER (WHERE period = '2) May-Jun')         AS res_p2,
           -- contribution of the cell to the overall avg-wait change
           SUM(wait_seconds) FILTER (WHERE period = '2) May-Jun')
             / (SELECT COUNT(wait_seconds) FROM analysis_interactions WHERE period = '2) May-Jun')
           - SUM(wait_seconds) FILTER (WHERE period = '1) Jan-Apr')
             / (SELECT COUNT(wait_seconds) FROM analysis_interactions WHERE period = '1) Jan-Apr')
                                                                          AS wait_contribution_s
    FROM x
    GROUP BY drill, cell
)
SELECT drill, cell, n_jan_apr, n_may_jun,
       ROUND(wait_p1, 1)  AS avg_wait_jan_apr,  ROUND(wait_p2, 1)  AS avg_wait_may_jun,
       ROUND(aband_p1, 3) AS abandon_jan_apr,   ROUND(aband_p2, 3) AS abandon_may_jun,
       ROUND(res_p1, 3)   AS resolution_jan_apr, ROUND(res_p2, 3)  AS resolution_may_jun,
       ROUND(wait_contribution_s, 2)                                      AS wait_contribution_s,
       ROUND(wait_contribution_s / SUM(wait_contribution_s) OVER (PARTITION BY drill), 3)
                                                                          AS share_of_wait_change,
       RANK() OVER (PARTITION BY drill ORDER BY wait_contribution_s DESC) AS rank_in_drill
FROM c
QUALIFY rank_in_drill <= 10
ORDER BY drill, rank_in_drill;


-- S5. The hot-spot isolated ---------------------------------------------
--     Phone contacts about Credit Card OR Payment vs everything else.
-- @output: s5_hotspot_isolated
SELECT CASE WHEN channel = 'Phone' AND (product = 'Credit Card' OR reason = 'Payment')
            THEN 'A) Phone: Credit Card or Payment'
            WHEN channel = 'Phone' THEN 'B) Phone: all other'
            ELSE 'C) Digital / Chat / Branch' END                 AS group_name,
       period,
       COUNT(*)                                                   AS interactions,
       ROUND(AVG(wait_seconds), 1)                                AS avg_wait_s,
       ROUND(AVG(CASE WHEN wait_seconds IS NOT NULL
                      THEN (wait_seconds > 120)::INT END), 3)     AS pct_wait_over_120s,
       ROUND(AVG(is_abandoned), 3)                                AS abandonment_rate,
       ROUND(AVG(is_resolved), 3)                                 AS resolution_rate,
       ROUND(AVG(is_repeat_7d) FILTER (WHERE repeat_window_complete = 1), 3) AS repeat_7d_rate,
       ROUND(AVG(satisfaction), 2)                                AS avg_satisfaction,
       SUM(has_survey)::BIGINT                                    AS survey_n
FROM analysis_interactions
GROUP BY ALL
ORDER BY group_name, period;


-- S6. When did it change? Weekly trend, 4-week rolling avg, WoW change ---
-- @output: s6_weekly_trend
WITH wk AS (
    SELECT date_trunc('week', interaction_date)::DATE             AS week_start,
           COUNT(DISTINCT interaction_date)                       AS days_in_data,
           COUNT(*)                                               AS interactions,
           AVG(wait_seconds) FILTER (WHERE channel = 'Phone'
                 AND (product = 'Credit Card' OR reason = 'Payment')) AS hotspot_wait_s,
           AVG(wait_seconds) FILTER (WHERE NOT (channel = 'Phone'
                 AND (product = 'Credit Card' OR reason = 'Payment'))) AS other_wait_s,
           AVG(is_abandoned)                                      AS abandonment_rate
    FROM analysis_interactions
    GROUP BY 1
)
SELECT week_start,
       days_in_data < 7                                           AS partial_week,
       interactions,
       ROUND(AVG(interactions) OVER (ORDER BY week_start
             ROWS BETWEEN 3 PRECEDING AND CURRENT ROW), 1)         AS interactions_4wk_avg,
       ROUND(hotspot_wait_s, 1)                                   AS hotspot_wait_s,
       ROUND(hotspot_wait_s - LAG(hotspot_wait_s) OVER (ORDER BY week_start), 1)
                                                                  AS hotspot_wait_wow_change,
       ROUND(other_wait_s, 1)                                     AS other_wait_s,
       ROUND(abandonment_rate, 3)                                 AS abandonment_rate
FROM wk
ORDER BY week_start;


-- S7. NEW METRIC leadership did not request ----------------------------
--     "Resolved-and-stayed-resolved rate" (true first-contact resolution):
--     contact coded Resolved AND the member did not come back about the
--     SAME reason within 7 days. The reported resolution rate trusts the
--     agent's outcome code; this one checks it against member behavior.
-- @output: s7_true_fcr_vs_reported
SELECT period,
       COUNT(*)                                                    AS eligible_contacts,
       ROUND(AVG(is_resolved), 3)                                  AS reported_resolution_rate,
       ROUND(AVG((is_resolved = 1 AND is_same_reason_repeat_7d = 0)::INT), 3)
                                                                   AS resolved_and_stayed_resolved,
       ROUND(AVG(is_same_reason_repeat_7d) FILTER (WHERE is_resolved = 1), 3)
                                                                   AS pct_resolved_that_came_back_same_reason,
       ROUND(AVG(is_same_reason_repeat_7d) FILTER (WHERE is_resolved = 0), 3)
                                                                   AS pct_unresolved_that_came_back_same_reason
FROM analysis_interactions
WHERE repeat_window_complete = 1
GROUP BY period
ORDER BY period;
