## `README.md`

````md
# Vault Consumption Checker

Small, jq-powered helper scripts to inspect HashiCorp Vault “activity counter” JSON exports (sometimes saved as `.txt`) and turn them into:
- Human-readable summaries in the terminal
- CSV files for Excel
- Markdown reports (diff script)

This repo is intentionally minimal and easy to run locally.

## Repository layout

```text
.
└── scripts/
    ├── count_clients.sh
    └── diff_clients.sh
````

## Requirements

* `bash`
* `jq`

Install `jq`:

* macOS: `brew install jq`
* Debian/Ubuntu: `sudo apt-get update && sudo apt-get install -y jq`

## Input format

Both scripts expect a file containing valid JSON with a structure similar to:

* `start_time` (string)
* `by_namespace[]` with:

  * `namespace_path`
  * `counts` (clients, entity_clients, non_entity_clients, acme_clients, secret_syncs)
  * `mounts[]` with `mount_path`, `mount_type`, `counts`
* `total` (reported totals)

The file extension does not matter. If it is JSON, it works.

Example input file names used in this repo:

* `./input/activity_counter_2023_2024.txt`
* `./input/activity_counter_2024_2025.txt`

## Script 1: Count and reconcile clients

### What it does

`./scripts/count_clients.sh`:

* Validates JSON
* Computes totals from namespaces
* Computes totals from mounts
* Compares computed totals to the file’s `.total`
* Highlights reconciliation gaps where a namespace’s `counts.clients` differs from the sum of its mounts
* Prints “top N” namespaces and mounts by clients
* Optionally exports CSV files (Excel-friendly)

### Usage

```bash
./scripts/count_clients.sh --file <path> [--top N] [--out-csv <dir>] [--out-md <path>]
```

### Example

```bash
./scripts/count_clients.sh --file ./input/activity_counter_2024_2025.txt --out-csv ./2024_2025
./scripts/count_clients.sh --file ./input/activity_counter_2023_2024.txt --out-csv ./2023_2024
```

### CSV output

When you use `--out-csv <dir>`, these files are generated:

* `namespaces.csv`
* `mounts.csv`
* `reconciliation.csv`
* `reconciliation_mounts.csv` (mount breakdown for namespaces with a delta)

## Script 2: Diff year-over-year client counts

### What it does

`./scripts/diff_clients.sh` compares two activity counter files and reports:

* Overall unique client delta (from `.total.clients`)
* Top namespaces increased and decreased
* A “concentration” metric: sum of the top 3 increases (shows how much growth is concentrated)
* Deleted namespaces net change (helps explain lifecycle churn)
* Optional CSV and Markdown exports

### Usage

```bash
./scripts/diff_clients.sh --old <file1> --new <file2> [--top N] [--out-csv <dir>] [--out-md <path>]
```

### Example

```bash
./scripts/diff_clients.sh \
  --old ./input/activity_counter_2023_2024.txt \
  --new ./input/activity_counter_2024_2025.txt \
  --out-csv ./diff \
  --out-md ./diff/2024_vs_2025.md
```

### Output files

When you use `--out-csv <dir>`:

* `namespace_diff.csv`
* `summary.csv` (single-row exec summary, easy for slides)

When you use `--out-md <path>`:

* A Markdown report with:

  * Overall delta
  * Key takeaway
  * Top increases and decreases
  * Full namespace delta table

## How to interpret totals and reconciliation

You will often see:

* Namespace totals (and `.total`) match perfectly
* Mount totals are higher than namespace totals

That is expected in many environments.

Why:

* The same client can authenticate via multiple auth mounts during the measurement window.
* Old or deleted mount accessors can show up (for example: “no mount accessor (pre-1.10 upgrade?)”).
* Mount-level sums are best treated as attribution, not a unique client count.

If you need a single number for “unique clients”, use:

* `.total.clients` (reported)
* Or “Totals (computed from namespaces)”

## Recommended .gitignore

If you do not want input files and generated outputs committed:

```gitignore
input/
2023_2024/
2024_2025/
diff/
```

Note: if files were already committed earlier, `.gitignore` will not remove them from Git history.
To stop tracking them:

```bash
git rm -r --cached input 2023_2024 2024_2025 diff
git commit -m "Stop tracking local input and output folders"
```

## Quick copy-paste runbook

```bash
# 1) Count a single report and export CSVs
./scripts/count_clients.sh --file ./input/activity_counter_2024_2025.txt --out-csv ./2024_2025

# 2) Count the previous year and export CSVs
./scripts/count_clients.sh --file ./input/activity_counter_2023_2024.txt --out-csv ./2023_2024

# 3) Diff year over year and export CSV + Markdown
./scripts/diff_clients.sh \
  --old ./input/activity_counter_2023_2024.txt \
  --new ./input/activity_counter_2024_2025.txt \
  --out-csv ./diff \
  --out-md ./diff/2024_vs_2025.md
```

## Troubleshooting

### “jq: error … cannot be sorted”

This usually indicates a jq expression is producing a string instead of an array.
These scripts use a safe key union pattern:

```jq
((a|keys) + (b|keys) | unique)
```

### Script “hangs” or “stalls”

If `jq` is invoked without an input file and without `-n`, it can wait for stdin forever.
These scripts use `jq -n` when slurping files.
