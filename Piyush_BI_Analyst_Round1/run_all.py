"""
Run the whole assessment end to end, in order, from the original Excel file.

    python run_all.py

Steps
  1. export_raw_csv.py            Excel -> data/*_raw.csv (no cleaning)
  2. run_sql.py                   SQL-1..3 in DuckDB -> outputs/sql/*.csv
  3. notebooks (executed in place) PY-1 validation & RCA, PY-2 model -> outputs/python/
  4. monthly_kpi_pack.py          PY-3 automated pack -> outputs/kpi_pack/
  5. test_kpi_pack.py             PY-3 validation tests
  6. build_dashboard.py           dashboard/Member_Service_Dashboard.html

Takes about 1-2 minutes. Stops at the first failing step.
"""
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PY = sys.executable


def step(title, cmd):
    print(f"\n{'=' * 70}\n{title}\n{'=' * 70}", flush=True)
    t = time.time()
    r = subprocess.run(cmd, cwd=ROOT)
    if r.returncode != 0:
        print(f"\nFAILED at: {title}  (exit code {r.returncode})")
        sys.exit(r.returncode)
    print(f"-- done in {time.time() - t:.1f}s")


def run_notebooks():
    import nbformat
    from nbclient import NotebookClient
    for nb_path in sorted((ROOT / "notebooks").glob("*.ipynb")):
        print(f"executing {nb_path.name} ...", flush=True)
        nb = nbformat.read(nb_path, as_version=4)
        NotebookClient(nb, timeout=900, kernel_name="python3",
                       resources={"metadata": {"path": str(nb_path.parent)}}).execute()
        nbformat.write(nb, nb_path)
        print(f"   saved with outputs: notebooks/{nb_path.name}")


if __name__ == "__main__":
    start = time.time()
    step("1/6  Export raw CSVs from Excel", [PY, "export_raw_csv.py"])
    step("2/6  SQL pipeline (DuckDB)", [PY, "run_sql.py"])
    print(f"\n{'=' * 70}\n3/6  Python notebooks (PY-1, PY-2)\n{'=' * 70}")
    run_notebooks()
    step("4/6  Automated monthly KPI pack (PY-3)", [PY, "python/monthly_kpi_pack.py"])
    step("5/6  KPI pack validation tests", [PY, "python/test_kpi_pack.py"])
    step("6/6  Build interactive dashboard", [PY, "python/build_dashboard.py"])
    print(f"\nALL STEPS COMPLETE in {time.time() - start:.0f}s")
    print("Open dashboard/Member_Service_Dashboard.html in your browser.")
