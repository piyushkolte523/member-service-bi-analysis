"""
tcu_common.py - shared loading, cleaning and KPI logic for the Python work.

Deliberately independent of the SQL pipeline: it reads the ORIGINAL Excel
workbook with pandas and re-implements the cleaning rules, so results can be
used to validate the SQL outputs (PY-1) rather than just re-reading them.

Used by: notebooks/01_validation_and_rca.ipynb, notebooks/02_abandonment_model.ipynb,
         python/monthly_kpi_pack.py, python/build_dashboard.py
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_XLSX = PROJECT_ROOT / "data" / "BI_Analyst_Round_1_Technical_Assessment.xlsx"

CHANNEL_MAP = {"phone": "Phone", "digital": "Digital", "chat": "Chat", "branch": "Branch"}
REQUIRED_INTERACTION_COLS = [
    "Interaction_ID", "Interaction_Date", "Member_ID", "Channel", "Product", "Reason",
    "Team", "Wait_Seconds", "Handle_Seconds", "Outcome", "Satisfaction_1_5", "Estimated_Cost",
]
REQUIRED_MEMBER_COLS = ["Member_ID", "Segment", "Region", "Tenure_Years",
                        "Products_Held", "Digital_Adoption_Score"]
PERIOD_SPLIT = pd.Timestamp("2026-05-01")
REPEAT_WINDOW_DAYS = 7


# --------------------------------------------------------------------------- load
def load_raw(xlsx: str | Path = DEFAULT_XLSX) -> dict[str, pd.DataFrame]:
    """Read the three data sheets exactly as delivered."""
    xlsx = Path(xlsx)
    return {
        "members": pd.read_excel(xlsx, sheet_name="Members"),
        "interactions": pd.read_excel(xlsx, sheet_name="Interactions"),
        "targets": pd.read_excel(xlsx, sheet_name="Targets"),
    }


def check_schema(raw: dict[str, pd.DataFrame]) -> list[str]:
    """Return a list of schema problems (empty list = OK)."""
    problems = []
    for name, cols in (("interactions", REQUIRED_INTERACTION_COLS),
                       ("members", REQUIRED_MEMBER_COLS)):
        missing = set(cols) - set(raw[name].columns)
        if missing:
            problems.append(f"{name}: missing columns {sorted(missing)}")
    return problems


# --------------------------------------------------------------------------- clean
def clean(raw: dict[str, pd.DataFrame]) -> tuple[pd.DataFrame, dict]:
    """
    Apply the same business rules as sql/01 (re-implemented in pandas).
    Returns (analysis dataframe, data-quality counts).
    """
    m = raw["members"].copy()
    i = raw["interactions"].copy()
    dq: dict[str, int] = {"raw_interaction_rows": len(i), "raw_member_rows": len(m)}

    # text hygiene
    for df in (m, i):
        for c in df.select_dtypes(include=["object", "string"]).columns:
            df[c] = df[c].astype("string").str.strip()

    # duplicates - confirm exact before dropping
    dup_ids = i["Interaction_ID"].duplicated(keep=False)
    dq["duplicate_id_rows_extra"] = int(i["Interaction_ID"].duplicated().sum())
    dq["exact_duplicate_rows"] = int(i.duplicated().sum())
    dq["conflicting_duplicate_ids"] = int(
        i[dup_ids].drop_duplicates()["Interaction_ID"].duplicated().sum())
    i = i.drop_duplicates()                                   # exact copies only

    # channel standardization
    ch_norm = i["Channel"].str.lower()
    dq["channel_recoded_rows"] = int((i["Channel"] != ch_norm.map(CHANNEL_MAP)).sum())
    i["Channel"] = ch_norm.map(CHANNEL_MAP).fillna("UNMAPPED")
    dq["channel_unmapped_rows"] = int((i["Channel"] == "UNMAPPED").sum())

    # types
    i["Interaction_Date"] = pd.to_datetime(i["Interaction_Date"])
    for c in ("Wait_Seconds", "Handle_Seconds", "Satisfaction_1_5", "Estimated_Cost"):
        i[c] = pd.to_numeric(i[c], errors="coerce")
    dq["wait_missing_rows"] = int(i["Wait_Seconds"].isna().sum())
    dq["satisfaction_missing_rows"] = int(i["Satisfaction_1_5"].isna().sum())
    dq["abandoned_with_handle_time"] = int(((i["Outcome"] == "Abandoned")
                                            & (i["Handle_Seconds"] > 0)).sum())

    # tidy column names
    i = i.rename(columns={
        "Interaction_ID": "interaction_id", "Interaction_Date": "interaction_date",
        "Member_ID": "member_id", "Channel": "channel", "Product": "product",
        "Reason": "reason", "Team": "team", "Wait_Seconds": "wait_seconds",
        "Handle_Seconds": "handle_seconds", "Outcome": "outcome",
        "Satisfaction_1_5": "satisfaction", "Estimated_Cost": "estimated_cost"})
    m = m.rename(columns={
        "Member_ID": "member_id", "Segment": "segment", "Region": "region",
        "Tenure_Years": "tenure_years", "Products_Held": "products_held",
        "Digital_Adoption_Score": "digital_adoption_score"})
    m["tenure_band"] = pd.cut(m["tenure_years"], [-np.inf, 2, 5, 10, np.inf], right=False,
                              labels=["0-2 yrs", "2-5 yrs", "5-10 yrs", "10+ yrs"]).astype(str)
    m["digital_adoption_band"] = pd.cut(
        m["digital_adoption_score"], [-np.inf, 0.4, 0.7, np.inf], right=False,
        labels=["Low (<0.40)", "Medium (0.40-0.69)", "High (0.70+)"]).astype(str)

    # derived fields
    i["month"] = i["interaction_date"].dt.strftime("%Y-%m")
    i["period"] = np.where(i["interaction_date"] < PERIOD_SPLIT, "1) Jan-Apr", "2) May-Jun")
    for o in ("Resolved", "Transferred", "Escalated", "Abandoned"):
        i[f"is_{o.lower()}"] = (i["outcome"] == o).astype(int)
    i["has_survey"] = i["satisfaction"].notna().astype(int)
    i["is_satisfied_top2"] = np.where(i["satisfaction"].notna(),
                                      (i["satisfaction"] >= 4).astype(float), np.nan)

    # repeat-contact flags (same definitions as SQL)
    i = i.sort_values(["member_id", "interaction_date", "interaction_id"]).reset_index(drop=True)
    g = i.groupby("member_id")["interaction_date"]
    i["days_to_next_contact"] = (g.shift(-1) - i["interaction_date"]).dt.days
    i["is_repeat_7d"] = (i["days_to_next_contact"] <= REPEAT_WINDOW_DAYS).astype(int)
    nxt_same = i.groupby(["member_id", "reason"])["interaction_date"].shift(-1)
    i["is_same_reason_repeat_7d"] = ((nxt_same - i["interaction_date"]).dt.days
                                     <= REPEAT_WINDOW_DAYS).astype(int)
    prev = g.shift(1)
    i["is_return_contact_7d"] = ((i["interaction_date"] - prev).dt.days
                                 <= REPEAT_WINDOW_DAYS).astype(int)
    last_date = i["interaction_date"].max()
    i["repeat_window_complete"] = (i["interaction_date"]
                                   <= last_date - pd.Timedelta(days=REPEAT_WINDOW_DAYS)).astype(int)

    # join (N:1) and check
    before = len(i)
    a = i.merge(m, on="member_id", how="left", validate="many_to_one")
    assert len(a) == before, "join changed row count"
    dq["unmatched_member_rows"] = int(a["segment"].isna().sum())
    dq["analysis_rows"] = len(a)

    a["hotspot"] = ((a["channel"] == "Phone")
                    & ((a["product"] == "Credit Card") | (a["reason"] == "Payment"))).astype(int)
    return a.sort_values("interaction_id").reset_index(drop=True), dq


# --------------------------------------------------------------------------- KPIs
def kpis(df: pd.DataFrame, by: str | list[str] = "month") -> pd.DataFrame:
    """Core KPI table using the definitions in the metric dictionary (sql/02)."""
    def agg(g: pd.DataFrame) -> pd.Series:
        rep = g[g["repeat_window_complete"] == 1]
        waits = g["wait_seconds"].dropna()
        return pd.Series({
            "interactions": len(g),
            "unique_members": g["member_id"].nunique(),
            "contacts_per_member": len(g) / g["member_id"].nunique(),
            "avg_wait_s": waits.mean(),
            "p90_wait_s": waits.quantile(0.9),
            "pct_wait_over_120s": (waits > 120).mean(),
            "aht_s": g.loc[g["is_abandoned"] == 0, "handle_seconds"].mean(),
            "resolution_rate": g["is_resolved"].mean(),
            "transfer_rate": g["is_transferred"].mean(),
            "escalation_rate": g["is_escalated"].mean(),
            "abandonment_rate": g["is_abandoned"].mean(),
            "survey_responses": g["has_survey"].sum(),
            "survey_response_rate": g["has_survey"].mean(),
            "avg_satisfaction": g["satisfaction"].mean(),
            "pct_satisfied_top2": g["is_satisfied_top2"].mean(),
            "repeat_eligible_contacts": len(rep),
            "repeat_7d_rate": rep["is_repeat_7d"].mean() if len(rep) else np.nan,
            "same_reason_repeat_7d_rate": rep["is_same_reason_repeat_7d"].mean() if len(rep) else np.nan,
            "total_est_cost": g["estimated_cost"].sum(),
            "cost_per_resolved": g["estimated_cost"].sum() / max(g["is_resolved"].sum(), 1),
        })
    return df.groupby(by).apply(agg, include_groups=False).reset_index()


TARGET_DIRECTION = {"Resolution_Rate": "higher", "Satisfaction": "higher",
                    "Average_Wait_Seconds": "lower", "Transfer_Rate": "lower"}
KPI_TO_COLUMN = {"Resolution_Rate": "resolution_rate", "Satisfaction": "avg_satisfaction",
                 "Average_Wait_Seconds": "avg_wait_s", "Transfer_Rate": "transfer_rate"}


def vs_target(monthly: pd.DataFrame, targets: pd.DataFrame) -> pd.DataFrame:
    """Join monthly actuals to the long-format targets table."""
    t = targets.rename(columns={"Month": "month", "KPI": "kpi", "Target": "target"}).copy()
    t["month"] = t["month"].astype(str).str.strip()
    t["kpi"] = t["kpi"].astype(str).str.strip()
    rows = []
    for kpi, col in KPI_TO_COLUMN.items():
        part = monthly[["month", col]].rename(columns={col: "actual"})
        part["kpi"] = kpi
        rows.append(part)
    out = pd.concat(rows).merge(t, on=["month", "kpi"], how="left")
    out["variance"] = out["actual"] - out["target"]
    higher = out["kpi"].map(TARGET_DIRECTION).eq("higher")
    out["on_target"] = np.where(higher, out["actual"] >= out["target"],
                                out["actual"] <= out["target"])
    return out[["month", "kpi", "actual", "target", "variance", "on_target"]]


def contribution(df: pd.DataFrame, dim: str, metric_col: str,
                 p1: str = "1) Jan-Apr", p2: str = "2) May-Jun") -> pd.DataFrame:
    """Shift-share decomposition: contribution_i = w2*x2 - w1*x1 = rate + mix."""
    d = df.dropna(subset=[metric_col])
    c = d.groupby([dim, "period"])[metric_col].agg(["size", "mean"]).unstack("period")
    n1, n2 = c[("size", p1)].fillna(0), c[("size", p2)].fillna(0)
    x1, x2 = c[("mean", p1)], c[("mean", p2)]
    w1, w2 = n1 / n1.sum(), n2 / n2.sum()
    out = pd.DataFrame({"n1": n1, "n2": n2, "x1": x1, "x2": x2,
                        "contribution": w2 * x2 - w1 * x1,
                        "rate_effect": (w1 + w2) / 2 * (x2 - x1),
                        "mix_effect": (x1 + x2) / 2 * (w2 - w1)})
    out["share"] = out["contribution"] / out["contribution"].sum()
    return out.sort_values("contribution", ascending=False)
