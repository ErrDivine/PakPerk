"""Export locally collected product feedback to an Excel-friendly UTF-8 CSV.

Run from the repository: python scripts/export_product_surveys.py output.csv
Docker Compose's postgres service must be running. No public read API is exposed.
"""

import argparse
import csv
import io
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("The output already exists; please choose a new filename.")
    root = Path(__file__).resolve().parents[1]
    query = """COPY (
        SELECT response_id, submitted_at, locale,
          ratings->>'overall' AS overall, ratings->>'discovery' AS discovery,
          ratings->>'reading' AS reading, ratings->>'figures' AS figures,
          ratings->>'translation' AS translation, ratings->>'notes' AS notes,
          ratings->>'navigation' AS navigation, ratings->>'speed' AS speed,
          suggestions
        FROM product_surveys ORDER BY submitted_at
    ) TO STDOUT WITH CSV HEADER"""
    result = subprocess.run(
        ["docker", "compose", "exec", "-T", "postgres", "psql", "-X", "-q",
         "-v", "ON_ERROR_STOP=1", "-U", "pakperk", "-d", "pakperk", "-c", query],
        cwd=root, capture_output=True, check=True,
    )
    rows = csv.reader(io.StringIO(result.stdout.decode("utf-8")))
    with args.output.open("x", encoding="utf-8-sig", newline="") as output:
        writer = csv.writer(output)
        for row in rows:
            # Suggestions are untrusted spreadsheet input, not formulas.
            if row and row[-1].lstrip().startswith(("=", "+", "-", "@")):
                row[-1] = "'" + row[-1]
            writer.writerow(row)
    print(f"Saved: {args.output.resolve()}")


if __name__ == "__main__":
    main()
