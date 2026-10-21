"""
Build the interactive executive dashboard as ONE self-contained, offline HTML file.

- No external libraries, fonts, CDNs or URLs: everything (code + data) is inlined,
  so the file opens by double-click in any modern browser with no internet and
  nothing is uploaded anywhere.
- Data comes from the same cleaning logic as the Python analysis (tcu_common.py).

Usage (from the project folder):
    python python/build_dashboard.py
Output:
    dashboard/Member_Service_Dashboard.html
"""
import json
import sys
from datetime import date
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tcu_common as tc  # noqa: E402

ROOT = tc.PROJECT_ROOT
TEMPLATE = ROOT / "dashboard" / "dashboard_template.html"
OUT = ROOT / "dashboard" / "Member_Service_Dashboard.html"

DIMS = {"ch": "channel", "pr": "product", "rs": "reason", "tm": "team", "seg": "segment", "rg": "region"}
OUTCOMES = ["Resolved", "Transferred", "Escalated", "Abandoned"]


def main():
    raw = tc.load_raw()
    a, dq = tc.clean(raw)
    months = sorted(a.month.unique())
    cats = {k: sorted(a[c].dropna().unique().tolist()) for k, c in DIMS.items()}
    idx = {k: {v: i for i, v in enumerate(vals)} for k, vals in cats.items()}

    rows = []
    for r in a.itertuples(index=False):
        rows.append([
            months.index(r.month),
            idx["ch"][r.channel], idx["pr"][r.product], idx["rs"][r.reason],
            idx["tm"][r.team], idx["seg"][r.segment], idx["rg"][r.region],
            None if pd.isna(r.wait_seconds) else int(r.wait_seconds),
            int(r.handle_seconds),
            OUTCOMES.index(r.outcome),
            None if pd.isna(r.satisfaction) else int(r.satisfaction),
            int(r.is_repeat_7d), int(r.is_same_reason_repeat_7d), int(r.repeat_window_complete),
            round(float(r.estimated_cost), 2),
        ])

    t = raw["targets"].copy()
    targets = {}
    for rr in t.itertuples(index=False):
        targets.setdefault(str(rr.KPI).strip(), {})[str(rr.Month).strip()] = float(rr.Target)

    payload = {
        "months": months, "cats": cats, "outcomes": OUTCOMES, "rows": rows, "targets": targets,
        "meta": {"built": date.today().isoformat(), "raw_rows": dq["raw_interaction_rows"],
                 "dup_removed": dq["exact_duplicate_rows"], "channel_recoded": dq["channel_recoded_rows"],
                 "wait_missing": dq["wait_missing_rows"], "analysis_rows": dq["analysis_rows"],
                 "last_complete_repeat_date": str((a.interaction_date.max() - pd.Timedelta(days=7)).date())},
    }
    html = TEMPLATE.read_text(encoding="utf-8").replace(
        "/*__DATA__*/null", json.dumps(payload, separators=(",", ":")))
    OUT.write_text(html, encoding="utf-8")
    print(f"Wrote {OUT.relative_to(ROOT)}  ({OUT.stat().st_size / 1024:.0f} KB, {len(rows)} rows embedded)")


if __name__ == "__main__":
    main()
