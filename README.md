````md
# Vault Consumption Checker

A tiny, auditable way to answer a deceptively hard question:

> “How many **unique Vault clients** did we actually have, and what changed year over year?”

This repo contains two Bash scripts:

- `scripts/count_clients.sh`  
  Creates a per-file report (totals, top namespaces, top mounts), reconciliation checks, and optional CSV/Markdown exports.
- `scripts/diff_clients.sh`  
  Compares two files (year over year), shows top movers, and optionally exports CSV/Markdown. Supports scope filtering and non-production highlighting.

## Requirements

- Bash
- `jq`

Install `jq`:
- macOS: `brew install jq`
- Debian/Ubuntu: `apt-get install -y jq`

## Repository layout

```text
./
├── input/
│   └── activity_counter_*.txt
├── filter/
│   └── exclude.json
└── scripts/
    ├── count_clients.sh
    └── diff_clients.sh
````

## Input format

The scripts expect a JSON file that looks like an **activity counter export**, with (at least) these keys:

* `start_time`
* `total.counts.clients` (or `total.clients` depending on your export)
* `by_namespace[]` where each entry contains:

  * `namespace_path`
  * `counts.clients`
  * `mounts[]` with per-mount `counts.clients`

If the file includes `.months[]`, `count_clients.sh` will also run monthly sanity checks and export `months.csv`.

## Quick start

### 1) Count a single report

```bash
./scripts/count_clients.sh \
  --file ./input/activity_counter_2024_2025.txt \
  --out-csv ./2024_2025 \
  --out-md  ./2024_2025/2025_report.md
```

This produces:

* `./2024_2025/namespaces.csv`
* `./2024_2025/mounts.csv`
* `./2024_2025/reconciliation.csv`
* `./2024_2025/reconciliation_mounts.csv`
* `./2024_2025/months.csv` (only if `.months[]` exists)
* `./2024_2025/2025_report.md`

### 2) Diff two reports (year over year)

```bash
./scripts/diff_clients.sh \
  --old ./input/activity_counter_2023_2024.txt \
  --new ./input/activity_counter_2024_2025.txt \
  --out-csv ./diff \
  --out-md  ./diff/2024_vs_2025.md
```

This produces:

* `./diff/namespace_diff.csv`
* `./diff/summary.csv` (single-row “exec proof” stats)
* `./diff/2024_vs_2025.md`

## Filtering and “production scope”

Both scripts support an optional filter file, so you can either:

* **exclude** namespaces from totals (production scope), or
* **highlight** namespaces as non-production while still counting everything.

### Filter JSON schema

`filter/exclude.json` example:

```json
{
  "mode": "exclude",
  "exclude_namespaces": [
    "^sand/",
    "^deleted",
    "^dr/",
    "^dev/",
    "^test/",
    "^sandbox/"
  ],
  "non_production_namespaces": [
    "^sand/",
    "^dr/",
    "^deleted",
    "^dev/",
    "^gitlab/",
    "^test/",
    "^sandbox/"
  ]
}
```

Notes:

* The values are **regex patterns** used with `jq` `test(...)`.
* JSON does not allow comments. Validate with:

  ```bash
  jq -e . ./filter/exclude.json >/dev/null && echo "valid" || echo "invalid"
  ```

### Mode: exclude (production-only counting)

```bash
./scripts/count_clients.sh \
  --file ./input/activity_counter_2024_2025.txt \
  --filter ./filter/exclude.json \
  --filter-mode exclude \
  --out-csv ./2024_2025_prod \
  --out-md  ./2024_2025_prod/2025_report_prod.md
```

In `exclude` mode:

* excluded namespaces are removed from computed totals and “top” lists
* the report still prints a “Excluded namespaces” section (so you can show what got removed)

### Mode: highlight (count all, tag non-production)

```bash
./scripts/diff_clients.sh \
  --old ./input/activity_counter_2023_2024.txt \
  --new ./input/activity_counter_2024_2025.txt \
  --filter ./filter/exclude.json \
  --filter-mode highlight
```

In `highlight` mode:

* everything is counted
* namespaces matching `non_production_namespaces` are tagged `[non-production]`
* the diff also prints a “Non-production movers” section (largest absolute movers)

## What the “reconciliation” section means

You may see a mismatch where:

* namespace total clients != sum of mount clients

This can happen when there are mounts without a current accessor, deleted mounts, or historical data. The scripts surface this explicitly, including a per-mount breakdown so you can explain the delta.

## Git hygiene

If your input and output files should never be committed, add patterns to `.gitignore`, for example:

```gitignore
input/*
2023_2024/*
2024_2025/*
diff/*
diff_prod/*
```

Important:

* `.gitignore` only prevents **new** files from being tracked.
* If something was already committed once, remove it from Git history tracking:

  ```bash
  git rm -r --cached input 2023_2024 2024_2025 diff diff_prod
  git commit -m "Stop tracking generated vault usage artifacts"
  ```

## Typical workflow

1. Put activity JSON exports in `./input/`
2. Run counts for each year (CSV + Markdown)
3. Run diff for the year-over-year view (CSV + Markdown)
4. Optionally run filtered “production scope” counts and diffs
5. Use `summary.csv` for slides, and the Markdown reports for audit trails

## License

MIT
