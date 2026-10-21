"""
PY-3 - Monthly Member-Service KPI Pack (automated)

Replaces the manual monthly routine of: pulling the extract, cleaning it in
Excel, rebuilding pivot tables, comparing to targets, eyeballing for problems
and pasting into a leadership deck.

What it does, in order
  1. Load the workbook (Members, Interactions, Targets)
  2. Run data controls  -> PASS / WARN / FAIL (FAIL stops the pack)
  3. Clean + build the analysis set (same rules as the SQL pipeline)
  4. Compute monthly KPIs, actual vs target, month-over-month change
  5. Raise alerts: missed targets, tail-wait / abandonment thresholds, and
     automatic hot-spot detection (any Channel x Product or Channel x Reason
     cell whose wait jumped vs its trailing 3-month average)
  6. Write: KPI_Pack_<month>.xlsx, a trend chart PNG and a JSON run log

Usage (from the project folder)
    python python/monthly_kpi_pack.py                       # latest month
    python python/monthly_kpi_pack.py --month 2026-05
    python python/monthly_kpi_pack.py --xlsx path/to/extract.xlsx --out outputs/kpi_pack

Exit code 0 = pack produced; 1 = a FAIL control stopped the run (nothing published).
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tcu_common as tc  # noqa: E402

# ----------------------------------------------------------------- thresholds
# Kept in one place so the business owner can change them without code changes elsewhere.
THRESHOLDS = {
    "max_wait_missing_pct": 0.02,       # WARN above
    "min_survey_response_rate": 0.20,   # WARN below
    "volume_change_warn_pct": 0.30,     # WARN if month volume differs > 30% from trailing 3-mo avg
    "alert_p90_wait_s": 120,            # tail-wait alert
    "alert_abandonment": 0.05,
    "alert_same_reason_repeat": 0.08,
    "hotspot_min_contacts": 30,
    "hotspot_wait_ratio": 1.5,          # cell wait >= 1.5x its trailing 3-month avg
}
KPI_COLUMNS = ["interactions", "unique_members", "contacts_per_member", "avg_wait_s", "p90_wait_s",
               "pct_wait_over_120s", "aht_s", "resolution_rate", "transfer_rate", "escalation_rate",
               "abandonment_rate", "survey_responses", "survey_response_rate", "avg_satisfaction",
               "repeat_7d_rate", "same_reason_repeat_7d_rate", "cost_per_resolved"]


# ----------------------------------------------------------------- controls
def run_controls(raw: dict, a: pd.DataFrame, dq: dict, month: str) -> pd.DataFrame:
    c = []
    add = lambda name, status, detail: c.append({"control": name, "status": status, "detail": detail})

    probs = tc.check_schema(raw)
    add("Schema: required columns present", "FAIL" if probs else "PASS", "; ".join(probs) or "all present")
    add("Duplicates: no conflicting records per Interaction_ID",
        "FAIL" if dq["conflicting_duplicate_ids"] else "PASS",
        f"{dq['conflicting_duplicate_ids']} conflicting IDs")
    add("Duplicates: exact copies removed", "WARN" if dq["exact_duplicate_rows"] else "PASS",
        f"{dq['exact_duplicate_rows']} exact duplicate rows removed")
    add("Reconciliation: analysis rows = raw rows - duplicates",
        "PASS" if dq["analysis_rows"] == dq["raw_interaction_rows"] - dq["exact_duplicate_rows"] else "FAIL",
        f"{dq['raw_interaction_rows']} - {dq['exact_duplicate_rows']} = {dq['analysis_rows']}")
    add("Categories: all channels mapped", "FAIL" if dq["channel_unmapped_rows"] else "PASS",
        f"{dq['channel_unmapped_rows']} unmapped; {dq['channel_recoded_rows']} recoded for casing")
    add("Referential integrity: every interaction has a member",
        "FAIL" if dq["unmatched_member_rows"] else "PASS", f"{dq['unmatched_member_rows']} unmatched")

    cur = a[a.month == month]
    if cur.empty:
        add("Report month present in data", "FAIL", f"no rows for {month}")
        return pd.DataFrame(c)
    wm = cur.wait_seconds.isna().mean()
    add("Completeness: wait recorded", "WARN" if wm > THRESHOLDS["max_wait_missing_pct"] else "PASS",
        f"{wm:.1%} missing in {month}")
    rr = cur.has_survey.mean()
    add("Coverage: survey response rate", "WARN" if rr < THRESHOLDS["min_survey_response_rate"] else "PASS",
        f"{rr:.1%} responded in {month} (satisfaction shown with n)")
    days = cur.interaction_date.dt.normalize().nunique()
    dim = pd.Period(month).days_in_month
    add("Completeness: every calendar day present", "PASS" if days == dim else "WARN", f"{days} of {dim} days")
    prior = sorted(m for m in a.month.unique() if m < month)[-3:]
    if prior:
        base = a[a.month.isin(prior)].groupby("month").size().mean()
        chg = len(cur) / base - 1
        add("Volume vs trailing 3-month average",
            "WARN" if abs(chg) > THRESHOLDS["volume_change_warn_pct"] else "PASS",
            f"{len(cur)} vs {base:.0f} ({chg:+.0%})")
    t = raw["targets"]
    has_t = (t["Month"].astype(str).str.strip() == month).any()
    add("Targets available for report month", "PASS" if has_t else "WARN",
        "found" if has_t else "no targets - actual-vs-target section will be blank")
    censored = (cur.repeat_window_complete == 0).mean()
    add("Repeat-contact window complete", "PASS" if censored == 0 else "WARN",
        "complete" if censored == 0 else f"{censored:.0%} of {month} contacts lack 7 days of follow-up; "
                                         "repeat rate uses complete-window contacts only (provisional)")
    return pd.DataFrame(c)


# ----------------------------------------------------------------- alerts
def run_alerts(a: pd.DataFrame, monthly: pd.DataFrame, vt: pd.DataFrame, month: str) -> pd.DataFrame:
    out = []
    row = monthly.set_index("month").loc[month]
    for _, r in vt[(vt.month == month) & (~vt.on_target)].iterrows():
        out.append({"severity": "High", "type": "Missed target", "where": "All contacts", "metric": r.kpi,
                    "value": round(r.actual, 3), "reference": r.target,
                    "note": f"variance {r.variance:+.3f}"})
    for metric, col, thr in [("P90 wait (s)", "p90_wait_s", THRESHOLDS["alert_p90_wait_s"]),
                             ("Abandonment rate", "abandonment_rate", THRESHOLDS["alert_abandonment"]),
                             ("Same-reason 7-day repeat", "same_reason_repeat_7d_rate",
                              THRESHOLDS["alert_same_reason_repeat"])]:
        if pd.notna(row[col]) and row[col] > thr:
            out.append({"severity": "High", "type": "Threshold breached (no formal target)",
                        "where": "All contacts", "metric": metric, "value": round(row[col], 3),
                        "reference": thr, "note": "recommend adding a formal target"})

    # automatic hot-spot detection
    prior = sorted(m for m in a.month.unique() if m < month)[-3:]
    if prior:
        for d1, d2 in [("channel", "product"), ("channel", "reason")]:
            cur = a[a.month == month].groupby([d1, d2]).wait_seconds.agg(["size", "mean"])
            base = a[a.month.isin(prior)].groupby([d1, d2]).wait_seconds.mean().rename("base")
            j = cur.join(base, how="inner")
            j = j[(j["size"] >= THRESHOLDS["hotspot_min_contacts"])
                  & (j["mean"] >= THRESHOLDS["hotspot_wait_ratio"] * j["base"])]
            for (v1, v2), r in j.sort_values("mean", ascending=False).iterrows():
                sub = a[(a.month == month) & (a[d1] == v1) & (a[d2] == v2)]
                out.append({"severity": "High", "type": "Hot spot: wait jump vs trailing 3 months",
                            "where": f"{v1} | {v2}", "metric": "Avg wait (s)", "value": round(r["mean"], 1),
                            "reference": round(r["base"], 1),
                            "note": f"{int(r['size'])} contacts; abandonment {sub.is_abandoned.mean():.0%}"})
    return pd.DataFrame(out, columns=["severity", "type", "where", "metric", "value", "reference", "note"])


# ----------------------------------------------------------------- outputs
def write_chart(monthly: pd.DataFrame, month: str, path: Path) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    m = monthly[monthly.month <= month]
    fig, axes = plt.subplots(1, 4, figsize=(13, 2.8))
    spec = [("avg_wait_s", "Avg wait (s)", 65, False), ("p90_wait_s", "P90 wait (s)", None, False),
            ("abandonment_rate", "Abandonment", None, True), ("resolution_rate", "Resolution", 0.82, True)]
    for ax, (col, title, tgt, pct) in zip(axes, spec):
        y = m[col] * (100 if pct else 1)
        ax.plot(m.month.str[5:], y, color="#2a78d6", marker="o", ms=4)
        if tgt is not None:
            ax.axhline(tgt * (100 if pct else 1), color="#52514e", ls=":", lw=1)
            ax.text(0, tgt * (100 if pct else 1), " target", color="#52514e", va="bottom", fontsize=8)
        ax.set_title(title + (" (%)" if pct else ""), fontsize=10, fontweight="bold")
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
        ax.grid(axis="y", color="#ecebe7"); ax.set_axisbelow(True)
    fig.suptitle(f"Member service KPIs through {month}", fontweight="bold")
    fig.tight_layout(); fig.savefig(path, dpi=150, metadata={"Software": None}); plt.close(fig)


def write_excel(path: Path, month: str, summary: pd.DataFrame, monthly: pd.DataFrame, vt: pd.DataFrame,
                alerts: pd.DataFrame, controls: pd.DataFrame, chart: Path) -> None:
    with pd.ExcelWriter(path, engine="xlsxwriter") as xw:
        wb = xw.book
        bold = wb.add_format({"bold": True, "font_size": 14})
        red = wb.add_format({"bg_color": "#f9d6d5"}); green = wb.add_format({"bg_color": "#d8efd8"})
        amber = wb.add_format({"bg_color": "#fdeccc"})

        summary.to_excel(xw, sheet_name="Summary", index=False, startrow=2)
        ws = xw.sheets["Summary"]; ws.write(0, 0, f"Member Service KPI Pack - {month}", bold)
        ws.set_column(0, 0, 34); ws.set_column(1, 4, 16)
        ws.insert_image(len(summary) + 5, 0, str(chart), {"x_scale": 0.62, "y_scale": 0.62})

        monthly.to_excel(xw, sheet_name="KPI_Trend", index=False); xw.sheets["KPI_Trend"].set_column(0, 30, 14)
        vt.to_excel(xw, sheet_name="Vs_Target", index=False)
        ws = xw.sheets["Vs_Target"]; ws.set_column(0, 5, 18)
        ws.conditional_format(1, 5, len(vt), 5, {"type": "cell", "criteria": "==", "value": "FALSE", "format": red})
        ws.conditional_format(1, 5, len(vt), 5, {"type": "cell", "criteria": "==", "value": "TRUE", "format": green})
        alerts.to_excel(xw, sheet_name="Alerts", index=False); xw.sheets["Alerts"].set_column(0, 6, 26)
        controls.to_excel(xw, sheet_name="Controls", index=False)
        ws = xw.sheets["Controls"]; ws.set_column(0, 0, 52); ws.set_column(1, 1, 8); ws.set_column(2, 2, 90)
        for word, fmt in (("FAIL", red), ("WARN", amber), ("PASS", green)):
            ws.conditional_format(1, 1, len(controls), 1,
                                  {"type": "text", "criteria": "containing", "value": word, "format": fmt})
        pd.DataFrame({"setting": list(THRESHOLDS), "value": list(THRESHOLDS.values())}).to_excel(
            xw, sheet_name="Thresholds", index=False)


def build_summary(monthly: pd.DataFrame, month: str) -> pd.DataFrame:
    m = monthly.set_index("month")
    prev = [x for x in m.index if x < month]
    labels = {"interactions": "Interactions", "avg_wait_s": "Avg wait (s)", "p90_wait_s": "P90 wait (s)",
              "pct_wait_over_120s": "% waits > 2 min", "resolution_rate": "Resolution rate",
              "transfer_rate": "Transfer rate", "abandonment_rate": "Abandonment rate",
              "same_reason_repeat_7d_rate": "Same-reason 7-day repeat", "avg_satisfaction": "Avg satisfaction",
              "survey_responses": "Survey responses (n)", "cost_per_resolved": "Cost per resolved ($)"}
    rows = []
    for col, lab in labels.items():
        cur = m.loc[month, col]
        p = m.loc[prev[-1], col] if prev else np.nan
        t3 = m.loc[prev[-3:], col].mean() if prev else np.nan
        rows.append({"KPI": lab, month: round(cur, 3), "Prior month": round(p, 3),
                     "Trailing 3-mo avg": round(t3, 3), "Change vs trailing": round(cur - t3, 3)})
    return pd.DataFrame(rows)


# ----------------------------------------------------------------- main
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--xlsx", default=str(tc.DEFAULT_XLSX))
    ap.add_argument("--month", help="YYYY-MM (default: latest month in data)")
    ap.add_argument("--out", default=str(tc.PROJECT_ROOT / "outputs" / "kpi_pack"))
    args = ap.parse_args(argv)

    started = datetime.now()
    out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
    raw = tc.load_raw(args.xlsx)
    if tc.check_schema(raw):
        print("FAIL: schema", tc.check_schema(raw)); return 1
    a, dq = tc.clean(raw)
    month = args.month or a.month.max()

    controls = run_controls(raw, a, dq, month)
    log = {"run_started": started.isoformat(timespec="seconds"), "source": Path(args.xlsx).name,
           "report_month": month, "rows_raw": dq["raw_interaction_rows"], "rows_analysis": dq["analysis_rows"],
           "controls": controls.to_dict("records")}
    print(controls.to_string(index=False))
    if (controls.status == "FAIL").any():
        log["result"] = "STOPPED - control failure"
        (out / f"run_log_{month}.json").write_text(json.dumps(log, indent=2, default=str))
        print("\nSTOPPED: at least one FAIL control. Nothing published."); return 1

    monthly = tc.kpis(a[a.month <= month], "month")[["month"] + KPI_COLUMNS]
    vt = tc.vs_target(monthly, raw["targets"])
    alerts = run_alerts(a, monthly, vt, month)
    summary = build_summary(monthly, month)

    chart = out / f"kpi_trend_{month}.png"
    write_chart(monthly, month, chart)
    xlsx = out / f"KPI_Pack_{month}.xlsx"
    write_excel(xlsx, month, summary, monthly.round(4), vt.round(4), alerts, controls, chart)

    log.update({"result": "PUBLISHED", "alerts": len(alerts), "outputs": [xlsx.name, chart.name],
                "run_seconds": round((datetime.now() - started).total_seconds(), 2)})
    (out / f"run_log_{month}.json").write_text(json.dumps(log, indent=2, default=str))
    print(f"\n{len(alerts)} alerts:\n" + (alerts.to_string(index=False) if len(alerts) else "none"))
    print(f"\nWrote {xlsx}\n      {chart}\n      run_log_{month}.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
