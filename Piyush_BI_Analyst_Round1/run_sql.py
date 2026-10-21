"""
Run the SQL scripts against a local DuckDB database file and save every
result tagged "-- @output: <name>" to outputs/sql/<script>__<name>.csv.

Usage (from the project folder):
    python run_sql.py                      # runs every sql/*.sql in order
    python run_sql.py 02_monthly_kpis.sql  # runs one script (00/01 must have run before)

The database file tcu_assessment.duckdb is created in the project folder.
You can open it afterwards in the DuckDB CLI, DBeaver, or Python to run
any query by hand:   duckdb tcu_assessment.duckdb
"""
import re
import sys
from pathlib import Path

import duckdb

HERE = Path(__file__).resolve().parent
SQL_DIR = HERE / "sql"
OUT_DIR = HERE / "outputs" / "sql"
DB_PATH = HERE / "tcu_assessment.duckdb"
TAG = re.compile(r"--\s*@output:\s*([A-Za-z0-9_]+)")


def run_script(con, path: Path):
    print(f"\n=== {path.name} ===")
    statements = duckdb.extract_statements(path.read_text(encoding="utf-8"))
    for stmt in statements:
        tag = TAG.search(stmt.query)
        rel = con.sql(stmt.query)
        if tag and rel is not None:
            name = tag.group(1)
            df = rel.df()
            out = OUT_DIR / f"{path.stem}__{name}.csv"
            df.to_csv(out, index=False)
            print(f"\n-- {name}  ({len(df)} rows -> {out.relative_to(HERE)})")
            with __import__("pandas").option_context(
                    "display.max_columns", 30, "display.width", 200,
                    "display.max_colwidth", 60):
                print(df.head(40).to_string(index=False))
        elif rel is not None:          # untagged SELECT, e.g. load check
            print(rel)


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    # Paths inside the SQL (data/...) are relative to the project folder.
    import os
    os.chdir(HERE)
    con = duckdb.connect(str(DB_PATH))
    scripts = ([SQL_DIR / a for a in sys.argv[1:]] if len(sys.argv) > 1
               else sorted(SQL_DIR.glob("*.sql")))
    for p in scripts:
        run_script(con, p)
    con.close()
    print(f"\nDone. Database: {DB_PATH.name}   Outputs: outputs/sql/")


if __name__ == "__main__":
    main()
