# Member Service BI Analysis

## Project Overview

This project analyzes synthetic member-service interaction data to evaluate operational performance, member experience, repeat-contact behavior, and the factors driving changes in key performance indicators.

The project combines SQL, Python, statistical modeling, workflow automation, an interactive dashboard, and business recommendations.

All data used in this project is synthetic. The repository must remain private.

## Business Objective

The analysis addresses three main questions:

1. Is member-service performance improving?
2. Which channels, products, reasons, teams, or member groups are driving performance changes?
3. What actions should leadership prioritize?

## Key Findings

- Average wait time met the overall target, but this masked a significant service problem in specific phone queues.
- Phone interactions involving Credit Card and Payment contacts experienced a major wait-time increase beginning in May.
- The affected queues explained most of the overall increase in wait time and decline in resolution performance.
- Higher wait times were associated with increased abandonment risk.
- Satisfaction results should be interpreted carefully because survey response coverage was limited.
- Same-reason repeat contact was more useful than the broader repeat-contact measure for identifying possible service failures.

Detailed findings and recommendations are provided in:

`deliverables/Insights_and_Recommendations_Memo.docx`

## Repository Structure

```text
member-service-bi-analysis/
│
├── data/
│   ├── BI_Analyst_Round_1_Technical_Assessment.xlsx
│   ├── interactions_raw.csv
│   ├── members_raw.csv
│   └── targets_raw.csv
│
├── sql/
│   ├── 00_load_raw.sql
│   ├── 01_profile_and_clean.sql
│   ├── 02_monthly_kpis.sql
│   └── 03_period_drivers.sql
│
├── notebooks/
│   ├── 01_validation_and_rca.ipynb
│   └── 02_abandonment_model.ipynb
│
├── python/
│   ├── build_dashboard.py
│   ├── monthly_kpi_pack.py
│   ├── tcu_common.py
│   └── test_kpi_pack.py
│
├── dashboard/
│   ├── Member_Service_Dashboard.html
│   ├── Dashboard_Screenshots.pdf
│   └── screenshots/
│
├── deliverables/
│   ├── Insights_and_Recommendations_Memo.docx
│   ├── PM_and_Stakeholder_Plan.docx
│   └── AI_Usage_Log.xlsx
│
├── outputs/
│   ├── sql/
│   ├── python/
│   └── kpi_pack/
│
├── export_raw_csv.py
├── run_sql.py
├── run_all.py
├── SQL_NOTES.md
├── requirements.txt
└── README.md
```

## Tools Used

- SQL with DuckDB
- Python 3.10 or later
- pandas
- NumPy
- scikit-learn
- statsmodels
- matplotlib
- Jupyter Notebook
- HTML, JavaScript, and SVG
- Microsoft Excel and Word

## How to Run the Project

### 1. Install the required Python packages

From the main project folder, run:

```bash
python -m pip install -r requirements.txt
```

### 2. Run the complete workflow

```bash
python run_all.py
```

The workflow:

1. Extracts the source data into CSV files.
2. Loads and cleans the data using SQL.
3. Calculates monthly KPIs and driver analysis.
4. Executes the Python validation and modeling notebooks.
5. Generates the automated monthly KPI pack.
6. Runs data-quality and reconciliation tests.
7. Rebuilds the interactive dashboard.

## SQL Analysis

The SQL workflow covers:

- Data profiling and quality validation
- Duplicate handling
- Missing-value analysis
- Category standardization
- Member and interaction joins
- Monthly KPI calculations
- Actual-versus-target comparisons
- Seven-day repeat-contact analysis
- January–April versus May–June driver analysis
- Window-function ranking of contributors
- Hot-spot and intersection analysis

SQL outputs are stored in:

`outputs/sql/`

Additional assumptions and data-quality decisions are documented in:

`SQL_NOTES.md`

## Python Analysis

### Validation and Root-Cause Analysis

`notebooks/01_validation_and_rca.ipynb`

This notebook independently rebuilds important calculations and validates the SQL results. It also tests possible explanations for the changes in wait time, resolution, abandonment, repeat contact, and satisfaction.

### Abandonment-Risk Model

`notebooks/02_abandonment_model.ipynb`

This notebook evaluates how waiting time is associated with abandonment risk. It includes:

- Logistic regression
- Nonlinear wait-time effects
- Cross-validation
- Calibration analysis
- Out-of-time validation
- Business-impact estimation

The model supports service-level decisions. It is not intended to predict the behavior of individual members.

### KPI Automation

`python/monthly_kpi_pack.py`

The automation produces:

- Monthly KPI summary
- KPI trend table
- Actual-versus-target scorecard
- Exception alerts
- Data-quality controls
- Trend chart
- Execution log

Tests are available in:

`python/test_kpi_pack.py`

## Interactive Dashboard

Open the following file in a browser:

`dashboard/Member_Service_Dashboard.html`

The dashboard runs locally and does not require an internet connection.

It includes:

- KPI summary cards
- Performance trends
- Actual-versus-target comparisons
- Time and business-dimension filters
- Driver analysis
- Drill-down paths
- Data-quality and coverage warnings
- KPI definitions and tooltips

A PDF and screenshots are included so the dashboard can be reviewed without opening the interactive file.

## Important Metric Definitions

- **Resolution rate:** Resolved interactions divided by total interactions.
- **Transfer rate:** Transferred interactions divided by total interactions.
- **Abandonment rate:** Abandoned interactions divided by total interactions.
- **Average wait:** Mean wait time for interactions with recorded wait values.
- **Average handle time:** Mean handle time for non-abandoned interactions.
- **Seven-day repeat contact:** An interaction
