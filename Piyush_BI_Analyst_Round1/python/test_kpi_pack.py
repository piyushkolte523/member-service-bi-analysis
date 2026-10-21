"""
Validation for PY-3: reconciles the automated KPI pack against the SQL pipeline
and checks that the controls actually stop a bad file.

Run (from the project folder, after run_sql.py):
    python python/test_kpi_pack.py
"""
import sys
import tempfile
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tcu_common as tc          # noqa: E402
import monthly_kpi_pack as pack  # noqa: E402

ROOT = tc.PROJECT_ROOT
failures = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")
    if not ok:
        failures.append(name)


# 1. Pack KPIs reconcile with SQL KPIs (within SQL rounding)
raw = tc.load_raw()
a, dq = tc.clean(raw)
py = tc.kpis(a, "month").set_index("month")
sql = pd.read_csv(ROOT / "outputs" / "sql" / "02_monthly_kpis__k1_monthly_kpis.csv").set_index("month")
for col, tol in [("interactions", 0), ("avg_wait_s", 0.05), ("resolution_rate", 0.0005),
                 ("abandonment_rate", 0.0005), ("repeat_7d_rate", 0.0005), ("avg_satisfaction", 0.005)]:
    diff = (py[col] - sql[col]).abs().max()
    check(f"KPI reconciles with SQL: {col}", diff <= tol + 1e-9, f"max diff {diff:.4f}")

# 2. Target comparison reconciles with SQL scorecard
vt = tc.vs_target(py.reset_index(), raw["targets"])
sql_vt = pd.read_csv(ROOT / "outputs" / "sql" / "02_monthly_kpis__k2b_target_scorecard.csv").set_index("kpi")
on = vt.groupby("kpi").on_target.sum()
check("Months on target match SQL", (on == sql_vt.months_on_target).all(), on.to_dict())

# 3. Hot-spot detector finds the known May issue and nothing in a stable month
monthly = tc.kpis(a, "month")
may = pack.run_alerts(a, monthly, tc.vs_target(monthly, raw["targets"]), "2026-05")
check("Detector flags Phone | Credit Card in May",
      (may["where"] == "Phone | Credit Card").any())
mar = pack.run_alerts(a, monthly, tc.vs_target(monthly, raw["targets"]), "2026-03")
check("Detector raises no hot spot in stable March",
      not mar["type"].str.startswith("Hot spot").any())

# 4. Controls stop a corrupted file (conflicting duplicate + unknown channel)
bad = {k: v.copy() for k, v in raw.items()}
x = bad["interactions"]
dup = x.iloc[[0]].copy(); dup["Outcome"] = "Escalated"          # same ID, different content
x = pd.concat([x, dup], ignore_index=True)
x.loc[5, "Channel"] = "Fax"
bad["interactions"] = x
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "bad.xlsx"
    with pd.ExcelWriter(p) as xw:
        bad["members"].to_excel(xw, sheet_name="Members", index=False)
        bad["interactions"].to_excel(xw, sheet_name="Interactions", index=False)
        bad["targets"].to_excel(xw, sheet_name="Targets", index=False)
    code = pack.main(["--xlsx", str(p), "--out", str(Path(td) / "out")])
check("Pack refuses to publish a corrupted file (exit code 1)", code == 1)

print(f"\n{'ALL TESTS PASSED' if not failures else f'{len(failures)} FAILED: {failures}'}")
sys.exit(1 if failures else 0)
