# SQL – Setup, Assumptions and Results

Engine: **DuckDB 1.x** (local, file-based, no server). All data stays on the local machine.

## 1. How to reproduce

From the project folder:

```
pip install -r requirements.txt
python export_raw_csv.py        # Excel -> data/*_raw.csv (no cleaning)
python run_sql.py               # runs sql/00..03 in order, saves outputs/sql/*.csv
```

`run_sql.py` creates `tcu_assessment.duckdb`. Every query tagged `-- @output:` is saved to
`outputs/sql/<script>__<name>.csv` and printed to the console (full log in `outputs/run_log.txt`).

Alternative without Python (DuckDB CLI, run from the project folder):

```
duckdb tcu_assessment.duckdb
.read sql/00_load_raw.sql
.read sql/01_profile_and_clean.sql
.read sql/02_monthly_kpis.sql
.read sql/03_period_drivers.sql
```

| Script | Task | Builds |
|---|---|---|
| `00_load_raw.sql` | Load | `raw_members`, `raw_interactions`, `raw_targets` (all VARCHAR, as delivered) |
| `01_profile_and_clean.sql` | SQL-1 | profiling queries, `stg_members`, `stg_interactions`, `analysis_interactions`, `dq_issue_log`, control tests |
| `02_monthly_kpis.sql` | SQL-2 | `metric_dictionary`, `v_kpi_monthly`, `v_kpi_vs_target` |
| `03_period_drivers.sql` | SQL-3 | `v_dim_long`, `driver_contributions`, drill-downs, weekly trend, new metric |

## 2. SQL-1 – Data model and data-quality decisions

**Layers:** raw (as delivered, all text) → stg (typed, standardized, de-duplicated) → analysis (joined, derived flags).

**Grain of `analysis_interactions`:** one row per unique interaction; `interaction_id` is the primary key (tested).

**Join:** `member_id`, many interactions to one member (N:1). LEFT JOIN so an unmatched interaction would be kept and caught by a control test rather than silently dropped. Result: 100% matched, no fan-out (row count unchanged).

**Source of truth:** Members table for member attributes (segment, region, tenure, digital score); Interactions table for contact events; Targets table for KPI targets. Interaction attributes (channel, product, reason, team) are taken as recorded on the interaction.

| # | Issue found | Rows | Why it matters | Decision |
|---|---|---|---|---|
| 1 | Exact duplicate interactions | 12 | Inflates volume; a duplicate looks like a same-day repeat contact | Verified all copies identical on all 12 columns; kept one per ID |
| 2 | Channel casing `phone` vs `Phone` | 8 | Splits Phone into two groups | Explicit mapping to a controlled list; unknown values → `UNMAPPED` and fail a test |
| 3 | Missing `Wait_Seconds` | 7 | Blank-as-zero would understate wait | Kept NULL; excluded from wait averages only |
| 4 | Satisfaction missing (survey non-response) | 2,890 (72%) | Average describes responders only; unresolved contacts score ~2.0 vs ~2.95 resolved | Never imputed; score always shown with response rate and n |
| 5 | Handle time recorded on Abandoned contacts (avg 439s) | 194 | Not plausible agent work time; field definition unclear | AHT excludes abandoned; flagged as question for data owner |
| 6 | `Estimated_Cost` is derived: Handle × $0.012 (+$3.00 if Transferred) | all | Not an observed cost; no channel cost difference | Directional use only |
| 7 | Repeat window right-censored (Jun 24–30) | 184 | Would understate June repeat rate | `repeat_window_complete` flag; excluded from repeat denominators |
| 8 | No targets for repeat, abandonment, escalation, AHT | – | Deterioration in these is invisible on the scorecard | Reported as trend-only; recommend targets |

Checked and clean: no orphan member IDs, no members without contacts, no cast failures, no negative values, satisfaction always 1–5, dates continuous Jan 1 – Jun 30 2026, categories otherwise consistent.

All 8 control tests in `01__e1_control_tests.csv` return PASS.

## 3. SQL-2 – Monthly KPIs (key results)

Definitions are stored in the database (`metric_dictionary`, output `02__k0`).
**7-day repeat-contact rate** = share of contacts followed by another contact from the same member within 7 calendar days (any channel/reason), using only contacts with a complete 7-day window.

| Month | Volume | Avg wait (s) | P90 wait (s) | % wait > 2 min | Resolution | Transfer | Abandon | Avg CSAT (n) | 7-day repeat |
|---|---|---|---|---|---|---|---|---|---|
| Jan | 604 | 36.2 | 73 | 0.2% | 79.5% | 7.5% | 5.1% | 2.69 (160) | 31.1% |
| Feb | 591 | 36.1 | 73 | 0.2% | 80.2% | 10.7% | 2.5% | 2.96 (159) | 34.2% |
| Mar | 605 | 38.2 | 76 | 0.0% | 82.0% | 8.1% | 3.6% | 2.90 (179) | 30.4% |
| Apr | 637 | 38.0 | 73 | 0.0% | 80.1% | 10.8% | 3.0% | 2.67 (161) | 34.5% |
| May | 790 | 54.1 | 141 | 14.2% | 78.2% | 8.6% | 7.6% | 2.62 (219) | 39.2% |
| Jun | 765 | 53.1 | 130 | 11.5% | 77.3% | 10.2% | 6.1% | 2.70 (224) | 39.6% |

**Against target:** average wait is "green" in all 6 months (target 65s), which is probably why service is
believed to be fine. Resolution missed in all 6 months (worst in June), transfer missed in 5 of 6, and satisfaction
(about 2.7 vs 4.2) missed in every month. The satisfaction gap is too large and too constant to read without first
confirming the survey scale and method.

## 4. SQL-3 – What drove the Jan–Apr vs May–Jun change

Method: contribution decomposition (each value's contribution = w₂x₂ − w₁x₁, which sums exactly to the total
change, split into rate and mix effects), ranked with `RANK()` / `SUM() OVER` window functions across 8 dimensions,
followed by intersection drill-downs.

1. **One hot spot explains the service deterioration.** Phone contacts about **Credit Card or Payment**: average
   wait 51s → 137s, 68% now wait more than 2 minutes, abandonment 2.9% → 21.2%, resolution 80.5% → 67.1%,
   CSAT 2.71 → 1.97. All other Phone contacts (50s → 50s) and the other channels are flat.
2. **Phone accounts for 96% of the overall wait increase** and 97% of the abandonment increase. Phone × Credit Card
   alone accounts for 60% of the wait change, and Phone × Payment for 49%.
3. **It was a step change, not a drift.** Hot-spot wait jumped in the week of Apr 27 (+30s) and again the week of
   May 4 (+54s), then held at about 136–141s through June. That points to a specific event (staffing, routing, a system
   or policy change) rather than a gradual decline. The data cannot say which.
4. **Volume grew +28% per month** (609 → 778) across every channel, product and segment. The largest growth was in
   Payment (+47%) and Transfer (+42%) reasons and Digital Banking (+36%).
5. **Repeat contacts rose everywhere** (32.6% → 39.4%), including in groups whose wait did not change. The repeat
   problem is broader than the phone queue and is not explained by the hot spot alone.

**New metric: "Resolved-and-stayed-resolved" rate** (resolved AND no same-reason contact within 7 days). Reported
resolution fell only 1.9 points (80.4% → 78.5%), but resolved-and-stayed-resolved fell 3.8 points (75.7% → 71.9%).
Contacts coded *Resolved* came back about the same reason almost as often as *unresolved* ones (8.4% vs 8.8% in
May–Jun). The outcome code is therefore a weak signal of whether the member's issue was actually fixed, and the
reported resolution rate overstates performance.

## 5. Assumptions and limitations

- Jan–Apr vs May–Jun compares 4 months with 2. Volumes are normalized per month, and rates are period averages.
- The 7-day repeat rate counts any next contact. It cannot distinguish a new, unrelated issue from a failed fix, so a
  same-reason version is also reported.
- Cells with fewer than 30 contacts in either period are flagged `low_volume_flag` and should not be over-read.
- Weeks at the start and end of the range are partial (`partial_week` flag).
- All data is synthetic. Findings describe association; the cause of the May step change needs operational data
  (staffing, schedule adherence, routing or IVR changes, system incidents).
