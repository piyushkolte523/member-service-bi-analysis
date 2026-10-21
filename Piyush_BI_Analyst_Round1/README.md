# BI Analyst – Round 1 Technical Assessment

**Candidate:** Piyush · **Submitted:** October 2026 · **Data:** synthetic workbook provided by the hiring manager (no real member data)

**Question:** Leadership believes member-service performance is improving. Is it?
**Answer:** No. Average wait met its 65-second target every month, but from **May 1** phone contacts about **Credit Card or Payment** went from a 51s to a 137s average wait, 1 in 5 of those callers hung up, and resolution fell from 80% to 67%. That one queue explains 96% of the wait increase and almost all of the resolution drop. Demand also rose 28% everywhere. Full findings: `deliverables/Insights_and_Recommendations_Memo.docx`.

---

## 1. Deliverables map

| # | Requirement | File(s) |
|---|---|---|
| 1 | **SQL** (SQL-1, 2, 3) | `sql/00_load_raw.sql` … `sql/03_period_drivers.sql`, results in `outputs/sql/*.csv`, notes in `SQL_NOTES.md` |
| 2 | **Python** (PY-1, 2, 3) | `notebooks/01_validation_and_rca.ipynb` (PY-1), `notebooks/02_abandonment_model.ipynb` (PY-2), `python/monthly_kpi_pack.py` + `python/test_kpi_pack.py` (PY-3); outputs in `outputs/python/` and `outputs/kpi_pack/` |
| 3 | **Interactive dashboard** (D-1 … D-7) | `dashboard/Member_Service_Dashboard.html` (native file), `dashboard/Dashboard_Screenshots.pdf` and `dashboard/screenshots/*.png` |
| 4 | **Insights & recommendations** (I-1 … I-5) | `deliverables/Insights_and_Recommendations_Memo.docx` |
| 5 | **PM & stakeholders** (PM-1 … PM-3) | `deliverables/PM_and_Stakeholder_Plan.docx` |
| 6 | **AI usage log** | `deliverables/AI_Usage_Log.xlsx` |
| 7 | **README** | this file |

No hyperlinks or URLs appear in any file. All work ran locally, and no data was uploaded anywhere.

## 2. Tools and environment

- **Python 3.10+** with the packages in `requirements.txt` (DuckDB, pandas, statsmodels, scikit-learn, matplotlib, …)
- **SQL engine: DuckDB** (embedded, file-based, standard SQL). Chosen because reviewers can run it with one `pip install`, with no server or account needed.
- **Dashboard: browser-based local interactive dashboard** (option allowed in the brief). It is a single self-contained HTML file with plain JavaScript and SVG, no external libraries and no internet, and it opens by double-click. It was chosen over Power BI so reviewers can open the native file without a licence. Section 8 shows how it maps to Power BI.

## 3. How to reproduce (about 5 minutes)

From this folder, in a terminal:

```
python -m pip install -r requirements.txt
python run_all.py
```

`run_all.py` runs every step in order from the original Excel file, and stops at the first failure:

1. `export_raw_csv.py`: Excel to `data/*_raw.csv`, unchanged
2. `run_sql.py`: runs the 4 SQL scripts in DuckDB (creates `tcu_assessment.duckdb`) and saves every tagged result to `outputs/sql/`
3. Executes both notebooks in place, so their outputs and charts are refreshed
4. `python/monthly_kpi_pack.py`: PY-3 pack for the latest month
5. `python/test_kpi_pack.py`: PY-3 validation tests (should print `ALL TESTS PASSED`)
6. `python/build_dashboard.py`: rebuilds the dashboard HTML

Individual steps can also be run on their own, in the same order. To run the SQL by hand in the DuckDB CLI, open `duckdb tcu_assessment.duckdb` and then `.read sql/01_profile_and_clean.sql`. To open the notebooks interactively, use Jupyter or VS Code.

**Expected checks:** `outputs/sql/01_profile_and_clean__e1_control_tests.csv` shows 8 × PASS; `outputs/python/py1_validation_results.csv` shows 14 × MATCH; `test_kpi_pack.py` passes all 10 tests.

## 4. Data model and key assumptions

- **Layers:** raw (as delivered, all text) → staging (typed, standardized, de-duplicated) → `analysis_interactions` (one row per unique interaction, joined N:1 to members on `member_id`).
- **Source of truth:** member attributes from Members, contact events from Interactions, targets from Targets.
- **Duplicates:** 12 exact copies removed (verified identical on all columns).
- **Channel casing:** "phone" mapped to "Phone" (8 rows) via an explicit map. Unknown values fail a control.
- **Missing wait** (7 rows): excluded from wait KPIs only.
- **Satisfaction:** blank means no survey response. Never imputed. Always reported with n and response rate.
- **AHT** excludes abandoned contacts, which carry handle time that is not plausible as agent work.
- **Estimated_Cost** is a formula (handle s × $0.012, +$3 if transferred), so it is used directionally only.
- **Periods:** Jan–Apr (4 months) vs May–Jun (2 months). Volumes are normalized per month.
- **Repeat contact:** a contact followed by another contact from the same member within 7 calendar days. Contacts after Jun 23 are excluded because the follow-up window is incomplete. A **same-reason** version is also reported and recommended.

Full issue log with impacts and decisions: `SQL_NOTES.md` §2 and `outputs/sql/01_profile_and_clean__b1_dq_issue_log.csv`.

## 5. Metric definitions

Stored in the database as `metric_dictionary` (`outputs/sql/02_monthly_kpis__k0_metric_dictionary.csv`) and shown in the dashboard. Summary:

| KPI | Definition | Population | Target |
|---|---|---|---|
| Interaction volume | Count of de-duplicated interactions (per month) | All | – |
| Avg wait | Mean wait seconds | Wait recorded | 65s |
| % waits > 2 min | Share with wait > 120s | Wait recorded | – (recommended) |
| P90 wait | 90th percentile wait | Wait recorded | – |
| AHT | Mean handle seconds | Non-abandoned | – |
| Resolution rate | Resolved / all | All | 82% |
| Transfer rate | Transferred / all | All | 8% |
| Escalation rate | Escalated / all | All | – |
| Abandonment rate | Abandoned / all | All | – (recommended) |
| Avg satisfaction | Mean 1–5 score | Responders only (~28%) | 4.2 |
| 7-day repeat (any reason) | Followed by any contact within 7 days | Complete-window contacts | – |
| 7-day same-reason repeat | Followed by a same-reason contact within 7 days | Complete-window contacts | – (recommended) |
| Resolved-and-stayed-resolved *(new)* | Resolved and no same-reason contact within 7 days | Complete-window contacts | – |
| Cost per resolved | Total estimated cost / resolved contacts | All | – |

## 6. Python summary

**PY-1 (validation and root cause).** Rebuilds the cleaned data from the raw Excel file in pandas, separately from SQL. 14 of 14 checks against SQL results match: data-quality counts, all 120 monthly KPI cells, repeat rate, hot-spot table and the decomposition. Two definitional sensitivities are documented (P90 method, AHT with or without abandoned contacts). Seven hypotheses tested:

| Hypothesis | Result |
|---|---|
| Volume overwhelmed the operation | Rejected: other phone queues absorbed +24% volume with flat wait |
| One team | Rejected: all teams +80–89s |
| Member mix | Rejected: effect +85s with controls; mix < 0.5s |
| Timing | Step change on May 1, no recovery |
| Wait drives outcomes | Supported (association): abandonment ~3–8% below 120s, ~24% above |
| Repeats mean failure | Mostly rejected: any-reason repeat ≈ random-timing baseline; same-reason up ~40% |
| Satisfaction reliable | Not reliable for targets |

The notebook ends with a table separating association from causation.

**PY-2 (model).** Business question: *what wait standard keeps members from abandoning, and what is it worth?* Logistic regression with a natural cubic spline on wait. Three models were compared with 5-fold stratified CV (AUC, Brier skill), plus calibration by decile, a decision-stump check on the threshold, and an out-of-time test that shows the extrapolation limit. Result: risk is ~3% up to 60s, 5.6% at 90s, 14% at 120s and 25% at 150s. Holding hot-spot waits at or under 90s avoids an estimated 15–20 abandoned contacts a month. Verdict: use it to set the service-level standard, not to predict individual callers.

**PY-3 (automation).** `monthly_kpi_pack.py` replaces the manual monthly routine (extract, clean in Excel, rebuild pivots, compare to targets, scan for problems, paste into slides: about 3–4 hours).

- **Inputs:** the workbook (or any extract with the same schema), `--month`, `--out`.
- **Outputs:** `KPI_Pack_<month>.xlsx` (Summary with chart, KPI_Trend, Vs_Target, Alerts, Controls, Thresholds), a trend PNG, and a JSON run log.
- **Controls:** schema, conflicting duplicates (FAIL), exact duplicates (WARN, removed), row reconciliation, category mapping, referential integrity, completeness, day coverage, volume swing vs trailing 3 months, target availability, repeat-window censoring. Any FAIL stops publication with exit code 1.
- **Alerts:** missed targets, threshold breaches for KPIs without targets, and automatic hot-spot detection (Channel × Product / Reason cells with ≥ 30 contacts whose wait is ≥ 1.5× their trailing 3-month average). Run on May data, it flags Phone | Credit Card and Phone | Payment in the first month.
- **Validation:** `test_kpi_pack.py` reconciles the pack's KPIs and target scorecard to the SQL outputs, confirms the detector flags May and stays quiet in March, and confirms that a corrupted file (conflicting duplicate and unknown channel) is refused.
- **Production approach:** the extract lands in the warehouse; the script runs as a scheduled job (Airflow, Databricks Jobs or Windows Task Scheduler), monthly on business day 2 and weekly for alerts. Code is in version control with these tests in CI. Thresholds are owned by Operations. Outputs are published to the BI workspace, alerts are emailed to the queue owner, and the run log is kept for audit.

## 7. Dashboard: why these KPIs, visuals and interactions (D-7)

- **KPIs (8 tiles):** the four targeted KPIs (wait, resolution, transfer, satisfaction), plus the three that actually broke and have no target (waits > 2 min, abandonment, same-reason repeat), plus volume for context. Escalation, AHT and any-reason repeat sit in the trend selector to keep page one focused.
- **Visual hierarchy:** headline sentence → KPI tiles (value, baseline, target, status shown as icon + label, sparkline) → trend vs target and attention list → driver and concentration views → limitations and definitions.
- **Color:** green and red are used only for target status, always with ✓/✕ text. Orange means "made it worse" and blue means "made it better" in driver views. Everything else is neutral.
- **Interactions:**
  - User-selectable baseline and compare periods (time).
  - Filters for channel, product, reason, team, segment and region.
  - Click a tile to change the trend and driver views.
  - Click a driver bar or heat-map cell to drill in, with drill-path chips and one-click removal.
  - Click an attention item to jump straight to the hot spot.
  - Hover tooltips with values, targets and n.
- **Investigation path (D-4):** Abandonment tile (worse) → "Biggest driver: Channel = Phone, 97%" → Product tab → Credit Card bar → filters now show Phone · Credit Card, wait 51s → 137s, missed target. See screenshots 1–3 in the PDF.
- **Data limitations (D-6):** satisfaction tile shows n, response rate and a caution flag; n is printed under monthly satisfaction points; the last 7 days are flagged on the repeat tile; small groups are marked; a limitations panel updates with the selection.

## 8. Power BI mapping (for a production build)

The same model works in Power BI: import `analysis_interactions` (DuckDB table, or CSV via `COPY analysis_interactions TO 'analysis.csv'`) plus Members and Targets, with a Date table. Core measures:

```
Interactions      = COUNTROWS(analysis)
Avg Wait (s)      = AVERAGE(analysis[wait_seconds])
Waits > 2 min %   = DIVIDE(CALCULATE([Interactions], analysis[wait_seconds] > 120), CALCULATE([Interactions], NOT ISBLANK(analysis[wait_seconds])))
Resolution %      = DIVIDE(CALCULATE([Interactions], analysis[outcome] = "Resolved"), [Interactions])
Abandonment %     = DIVIDE(CALCULATE([Interactions], analysis[outcome] = "Abandoned"), [Interactions])
Same-Reason Rpt % = DIVIDE(CALCULATE(SUM(analysis[is_same_reason_repeat_7d]), analysis[repeat_window_complete] = 1), CALCULATE([Interactions], analysis[repeat_window_complete] = 1))
Avg Satisfaction  = AVERAGE(analysis[satisfaction])
Survey n          = COUNT(analysis[satisfaction])
Target Resolution = CALCULATE(AVERAGE(Targets[Target]), Targets[KPI] = "Resolution_Rate")
Status Resolution = IF([Resolution %] >= [Target Resolution], "✓ On target", "✕ Missed")
```

Drill path: the Decomposition Tree visual (Abandonment % explained by Channel → Product → Reason) plus drill-through to a hot-spot page.

## 9. Limitations

- Synthetic data. Findings are associations, and causal statements are labelled as such.
- The *cause* of the May 1 step change is not in the data: staffing, routing, incident and policy logs are needed.
- Satisfaction has ~28% coverage, about ±0.2 margin of error per month, and is ~1.5 points below target in every month. Confirm the scale before using it.
- Only six months of data, so no seasonality can be assessed. The May–Jun comparison is 2 months.
- Wait on abandoned contacts may be time-to-hang-up (right-censored).
- Estimated cost is derived, not actual.
- The full list of unsupported conclusions and data requests is in the memo (I-4).

## 10. AI usage

AI assistance was used and is disclosed in `deliverables/AI_Usage_Log.xlsx`, including what it produced, how each result was validated, and what was changed or rejected.
