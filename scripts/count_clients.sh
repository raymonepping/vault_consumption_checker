#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./count_clients.sh --file <path> [--top N] [--out-csv <dir>] [--out-md <path>] [--filter <filter.json>] [--filter-mode exclude|highlight]

What it does:
  - Validates JSON
  - Sums totals across namespaces and mounts:
      clients, entity_clients, non_entity_clients, acme_clients, secret_syncs
  - Compares computed sums with .total in the file
  - Shows top namespaces and top mounts by clients
  - Reconciliation: flags namespaces where mounts_sum != namespace_total (and shows mount breakdown)
  - Optional monthly checks when .months[] exists:
      - clients per month
      - new_clients per month
  - Optional exports:
      --out-csv <dir> : writes CSV files (namespaces, mounts, reconciliation, reconciliation_mounts, months)
      --out-md  <path>: writes a Markdown report (tables)

Filter support:
  --filter <filter.json>      : apply exclude/highlight rules by namespace_path (root becomes "root")
  --filter-mode exclude|highlight :
      - exclude   : remove excluded namespaces from totals and outputs
      - highlight : keep them, but label as non-production in outputs

Requirements:
  - jq

Examples:
  ./count_clients.sh --file ./input/activity_counter_2024_2025.txt
  ./count_clients.sh --file ./input/activity_counter_2024_2025.txt --out-csv ./2024_2025
  ./count_clients.sh --file ./input/activity_counter_2024_2025.txt --out-md ./out/report.md
  ./count_clients.sh --file ./input/activity_counter_2024_2025.txt --filter ./filter.json --filter-mode exclude --out-csv ./2024_2025
USAGE
}

FILE=""
TOP=10
OUT_CSV_DIR=""
OUT_MD_PATH=""
FILTER=""
FILTER_MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  --file | -f)
    FILE="${2:-}"
    shift 2
    ;;
  --top)
    TOP="${2:-10}"
    shift 2
    ;;
  --out-csv)
    OUT_CSV_DIR="${2:-}"
    shift 2
    ;;
  --out-md)
    OUT_MD_PATH="${2:-}"
    shift 2
    ;;
  --filter)
    FILTER="${2:-}"
    shift 2
    ;;
  --filter-mode)
    FILTER_MODE="${2:-}"
    shift 2
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    echo "Unknown arg: $1"
    usage
    exit 2
    ;;
  esac
done

if [[ -z "${FILE}" ]]; then
  echo "Error: --file is required"
  usage
  exit 2
fi

if [[ ! -f "${FILE}" ]]; then
  echo "Error: file not found: ${FILE}"
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not found."
  echo "Install: macOS (brew install jq) | Debian/Ubuntu (apt-get install -y jq)"
  exit 2
fi

if ! jq -e . "${FILE}" >/dev/null 2>&1; then
  echo "Error: file is not valid JSON: ${FILE}"
  exit 2
fi

if [[ -n "${FILTER}" ]]; then
  if [[ ! -f "${FILTER}" ]]; then
    echo "Error: filter file not found: ${FILTER}"
    exit 2
  fi
  if ! jq -e . "${FILTER}" >/dev/null 2>&1; then
    echo "Error: filter file is not valid JSON: ${FILTER}"
    exit 2
  fi
fi

if [[ -n "${FILTER_MODE}" ]]; then
  case "${FILTER_MODE}" in
  exclude | highlight) ;;
  *)
    echo "Error: --filter-mode must be 'exclude' or 'highlight' (got: ${FILTER_MODE})"
    exit 2
    ;;
  esac
fi

if [[ -n "${OUT_CSV_DIR}" ]]; then
  mkdir -p "${OUT_CSV_DIR}"
fi

if [[ -n "${OUT_MD_PATH}" ]]; then
  mkdir -p "$(dirname "${OUT_MD_PATH}")"
fi

# Always define filter variables for jq (so jq compiles even when no filter is provided)
JQ_FILTER_ARGS=(--arg filter_mode "${FILTER_MODE:-}")
if [[ -n "${FILTER}" ]]; then
  JQ_FILTER_ARGS+=(--slurpfile filter_slurp "${FILTER}")
else
  JQ_FILTER_ARGS+=(--argjson filter_slurp '[]')
fi

# Shared jq program pieces are repeated across calls for portability

# -------- Terminal summary --------
jq -r --argjson top "$TOP" "${JQ_FILTER_ARGS[@]}" '
  def nz: . // 0;
  def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

  # filter config (always defined)
  def f: (if ($filter_slurp|type) == "array" and ($filter_slurp|length) > 0 then $filter_slurp[0] else {} end);
  def mode_from_file: (f.mode // "exclude");
  def mode: if ($filter_mode // "") != "" then $filter_mode else mode_from_file end;
  def excl: (f.exclude_namespaces // []);
  def nonprod: (f.non_production_namespaces // []);

def matches_any($patterns; $ns):
  ($patterns | type) == "array"
  and ($patterns | length) > 0
  and ($patterns | any(.[]; . as $re | ($ns | test($re))));

  def is_excluded($ns): matches_any(excl; $ns);
  def is_nonprod($ns): matches_any(nonprod; $ns);

  def filter_enabled:
    ($filter_slurp|type) == "array" and ($filter_slurp|length) > 0;

  def keep_ns($ns):
    if filter_enabled and mode == "exclude" then (is_excluded($ns) | not) else true end;

  def ns_rows_all:
    (.by_namespace
      | map(
          . as $ns
          | ($ns | norm_ns) as $name
          | {
              namespace: $name,
              namespace_id: ($ns.namespace_id | nz),
              mounts: ($ns.mounts | length),
              clients: ($ns.counts.clients | nz),
              entity_clients: ($ns.counts.entity_clients | nz),
              non_entity_clients: ($ns.counts.non_entity_clients | nz),
              acme_clients: ($ns.counts.acme_clients | nz),
              secret_syncs: ($ns.counts.secret_syncs | nz),
              excluded: is_excluded($name),
              non_production: is_nonprod($name)
            }
        )
    );

  def ns_rows_filtered:
    (ns_rows_all
      | map(select(keep_ns(.namespace)))
      | sort_by(.clients) | reverse
    );

  def mount_rows_filtered:
    ([.by_namespace[] as $ns
      | ($ns | norm_ns) as $nspath
      | select(keep_ns($nspath))
      | $ns.mounts[]?
      | {
          namespace: $nspath,
          namespace_non_production: is_nonprod($nspath),
          mount_path: (.mount_path | nz),
          mount_type: (.mount_type | nz),
          clients: (.counts.clients | nz),
          entity_clients: (.counts.entity_clients | nz),
          non_entity_clients: (.counts.non_entity_clients | nz),
          acme_clients: (.counts.acme_clients | nz),
          secret_syncs: (.counts.secret_syncs | nz)
        }]
      | sort_by(.clients) | reverse
    );

  def sum_field($rows; $field):
    ($rows | map(.[$field] | nz) | add // 0);

  def totals_from_ns($rows):
    {
      acme_clients:       sum_field($rows; "acme_clients"),
      clients:            sum_field($rows; "clients"),
      entity_clients:     sum_field($rows; "entity_clients"),
      non_entity_clients: sum_field($rows; "non_entity_clients"),
      secret_syncs:       sum_field($rows; "secret_syncs")
    };

  def totals_from_mounts($rows):
    {
      acme_clients:       ($rows | map(.acme_clients|nz) | add // 0),
      clients:            ($rows | map(.clients|nz) | add // 0),
      entity_clients:     ($rows | map(.entity_clients|nz) | add // 0),
      non_entity_clients: ($rows | map(.non_entity_clients|nz) | add // 0),
      secret_syncs:       ($rows | map(.secret_syncs|nz) | add // 0)
    };

  def diff(a; b):
    {
      acme_clients:       ((a.acme_clients       | nz) - (b.acme_clients       | nz)),
      clients:            ((a.clients            | nz) - (b.clients            | nz)),
      entity_clients:     ((a.entity_clients     | nz) - (b.entity_clients     | nz)),
      non_entity_clients: ((a.non_entity_clients | nz) - (b.non_entity_clients | nz)),
      secret_syncs:       ((a.secret_syncs       | nz) - (b.secret_syncs       | nz))
    };

  def reconcile_rows:
    ([.by_namespace[] as $ns
      | ($ns | norm_ns) as $name
      | select(keep_ns($name))
      | ($ns.counts.clients // 0) as $ns_clients
      | (($ns.mounts | map(.counts.clients // 0) | add) // 0) as $m_clients
      | {
          namespace: $name,
          namespace_clients: ($ns_clients | nz),
          mounts_clients_sum: ($m_clients | nz),
          delta: (($m_clients|nz) - ($ns_clients|nz)),
          mounts: ($ns.mounts | length)
        }
      | select(.delta != 0)
    ]);

  def reconcile_mounts_for($doc; $ns_name):
    ([$doc.by_namespace[]
      | ($ns_name) as $want
      | select((norm_ns) == $want)
      | .mounts[]?
      | {
          mount_path: (.mount_path | nz),
          mount_type: (.mount_type | nz),
          clients: (.counts.clients | nz)
        }
    ]
      | sort_by(.clients) | reverse
    );

  def has_months:
    (.months? != null) and ((.months | type) == "array") and ((.months | length) > 0);

  def months_rows:
    (.months // [])
    | map({
        time: (.timestamp | tostring),
        clients: (.counts.clients | nz),
        new_clients: (.new_clients.counts.clients | nz)
      });

  . as $doc
  | (ns_rows_all) as $ns_all
  | (ns_rows_filtered) as $ns_rows
  | (mount_rows_filtered) as $mount_rows
  | (totals_from_ns($ns_rows)) as $ns_tot
  | (totals_from_mounts($mount_rows)) as $m_tot
  | ($doc.total // {}) as $reported
  | (totals_from_ns($ns_all)) as $ns_tot_unfiltered
  | ($doc.by_namespace | length) as $ns_count
  | ($doc.by_namespace | map(.mounts | length) | add // 0) as $mount_count
  | ($ns_all | map(select(.excluded)) ) as $excluded_rows
  | (reconcile_rows) as $recon

  | (
      (if filter_enabled then
        "Filter\n"
        + "  mode: " + (mode|tostring) + "\n"
        + "  exclude_namespaces: " + (excl|tostring) + "\n"
        + "  non_production_namespaces: " + (nonprod|tostring) + "\n\n"
      else "" end) +

      "File summary\n"
      + "  start_time:   " + ($doc.start_time | tostring) + "\n"
      + "  namespaces:   " + ($ns_count | tostring) + "\n"
      + "  mounts:       " + ($mount_count | tostring) + "\n\n"

      + "Totals (computed from namespaces" + (if filter_enabled and mode=="exclude" then ", filtered" else "" end) + ")\n"
      + "  clients:            " + ($ns_tot.clients | tostring) + "\n"
      + "  entity_clients:     " + ($ns_tot.entity_clients | tostring) + "\n"
      + "  non_entity_clients: " + ($ns_tot.non_entity_clients | tostring) + "\n"
      + "  acme_clients:       " + ($ns_tot.acme_clients | tostring) + "\n"
      + "  secret_syncs:       " + ($ns_tot.secret_syncs | tostring) + "\n\n"

      + "Totals (computed from mounts" + (if filter_enabled and mode=="exclude" then ", filtered" else "" end) + ")\n"
      + "  clients:            " + ($m_tot.clients | tostring) + "\n"
      + "  entity_clients:     " + ($m_tot.entity_clients | tostring) + "\n"
      + "  non_entity_clients: " + ($m_tot.non_entity_clients | tostring) + "\n"
      + "  acme_clients:       " + ($m_tot.acme_clients | tostring) + "\n"
      + "  secret_syncs:       " + ($m_tot.secret_syncs | tostring) + "\n\n"

      + "Totals (reported in file: .total)\n"
      + "  clients:            " + (($reported.clients | nz) | tostring) + "\n"
      + "  entity_clients:     " + (($reported.entity_clients | nz) | tostring) + "\n"
      + "  non_entity_clients: " + (($reported.non_entity_clients | nz) | tostring) + "\n"
      + "  acme_clients:       " + (($reported.acme_clients | nz) | tostring) + "\n"
      + "  secret_syncs:       " + (($reported.secret_syncs | nz) | tostring) + "\n\n"

      + "Validation (computed minus reported)\n"
      + "  namespaces - reported: " + (diff($ns_tot_unfiltered; $reported) | tostring) + "\n"
      + "  mounts     - reported: " + (diff($m_tot; $reported) | tostring) + "\n\n"

      + (if filter_enabled and mode=="exclude" and ($excluded_rows|length)>0 then
          "Excluded namespaces (top " + ($top|tostring) + " by clients)\n"
          + (
            ($excluded_rows | sort_by(.clients) | reverse)[0:$top]
            | map("  - " + .namespace + "  clients=" + (.clients|tostring))
            | join("\n")
          ) + "\n\n"
        else "" end)

      + "Reconciliation (namespaces where mounts_sum != namespace_total)\n"
      + (
          if ($recon|length) == 0 then "  - none\n\n"
          else (
            ($recon | sort_by(.delta) | reverse)[0:$top]
            | map("  - " + .namespace
                  + "  namespace=" + (.namespace_clients|tostring)
                  + "  mounts_sum=" + (.mounts_clients_sum|tostring)
                  + "  delta=" + (.delta|tostring)
                  + "  mounts=" + (.mounts|tostring))
            | join("\n")
          ) + "\n\n"
        end

      + (if ($recon|length) > 0 then
          "Reconciliation details\n"
          + (
            ($recon | sort_by(.delta) | reverse)[0:$top]
            | map(
                "  - " + .namespace + "  delta=" + (.delta|tostring)
                + " (namespace=" + (.namespace_clients|tostring)
                + ", mounts_sum=" + (.mounts_clients_sum|tostring) + ")\n"
                + (
                  (reconcile_mounts_for($doc; .namespace))
                  | map("    * " + .mount_path + " (" + .mount_type + ") clients=" + (.clients|tostring))
                  | join("\n")
                )
              )
            | join("\n")
          ) + "\n\n"
        else "" end)

      + ("Top namespaces by clients (top " + ($top|tostring) + ")\n")
      + (
        $ns_rows[0:$top]
        | map(
            "  - " + .namespace
            + (if filter_enabled and mode=="highlight" and .non_production then "  [non-production]" else "" end)
            + "  clients=" + (.clients|tostring)
            + "  mounts=" + (.mounts|tostring)
          )
        | join("\n")
      ) + "\n\n"

      + ("Top mounts by clients (top " + ($top|tostring) + ")\n")
      + (
        $mount_rows[0:$top]
        | map(
            "  - " + .namespace
            + (if filter_enabled and mode=="highlight" and .namespace_non_production then "  [non-production]" else "" end)
            + "  " + .mount_path + " (" + .mount_type + ")"
            + "  clients=" + (.clients|tostring)
          )
        | join("\n")
      ) + "\n\n"

      + (if has_months then
          "Monthly checks (from .months)\n"
          + "  clients:\n"
          + (months_rows | map("    - " + .time + "  clients=" + (.clients|tostring)) | join("\n")) + "\n\n"
          + "  new_clients:\n"
          + (months_rows | map("    - " + .time + "  new_clients=" + (.new_clients|tostring)) | join("\n")) + "\n\n"
        else "" end)
    )
  )
' "$FILE"

# -------- CSV exports --------
if [[ -n "${OUT_CSV_DIR}" ]]; then
  # Namespaces CSV (filtered if filter-mode=exclude)
  jq -r "${JQ_FILTER_ARGS[@]}" '
    def nz: . // 0;
    def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

    def f: (if ($filter_slurp|type) == "array" and ($filter_slurp|length) > 0 then $filter_slurp[0] else {} end);
    def mode_from_file: (f.mode // "exclude");
    def mode: if ($filter_mode // "") != "" then $filter_mode else mode_from_file end;
    def excl: (f.exclude_namespaces // []);
    def nonprod: (f.non_production_namespaces // []);

    def matches_any($patterns; $ns):
  ($patterns | type) == "array"
  and ($patterns | length) > 0
  and ($patterns | any(.[]; . as $re | ($ns | test($re))));


    def is_excluded($ns): matches_any(excl; $ns);
    def is_nonprod($ns): matches_any(nonprod; $ns);

    def filter_enabled:
      ($filter_slurp|type) == "array" and ($filter_slurp|length) > 0;

    def keep_ns($ns):
      if filter_enabled and mode == "exclude" then (is_excluded($ns) | not) else true end;

    (["namespace","namespace_id","mounts","clients","entity_clients","non_entity_clients","acme_clients","secret_syncs","non_production","excluded"] | @csv),
    (.by_namespace[]
      | {
          namespace: (norm_ns),
          namespace_id: (.namespace_id | nz),
          mounts: (.mounts | length),
          clients: (.counts.clients | nz),
          entity_clients: (.counts.entity_clients | nz),
          non_entity_clients: (.counts.non_entity_clients | nz),
          acme_clients: (.counts.acme_clients | nz),
          secret_syncs: (.counts.secret_syncs | nz)
        } as $r
      | ($r.namespace) as $ns
      | select(keep_ns($ns))
      | ($r + {
          non_production: is_nonprod($ns),
          excluded: is_excluded($ns)
        })
      | [.namespace,.namespace_id,.mounts,.clients,.entity_clients,.non_entity_clients,.acme_clients,.secret_syncs,(.non_production|tostring),(.excluded|tostring)] | @csv
    )
  ' "$FILE" >"${OUT_CSV_DIR}/namespaces.csv"

  # Mounts CSV (filtered if filter-mode=exclude)
  jq -r "${JQ_FILTER_ARGS[@]}" '
    def nz: . // 0;
    def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

    def f: (if ($filter_slurp|type) == "array" and ($filter_slurp|length) > 0 then $filter_slurp[0] else {} end);
    def mode_from_file: (f.mode // "exclude");
    def mode: if ($filter_mode // "") != "" then $filter_mode else mode_from_file end;
    def excl: (f.exclude_namespaces // []);
    def nonprod: (f.non_production_namespaces // []);

    def matches_any($patterns; $ns):
  ($patterns | type) == "array"
  and ($patterns | length) > 0
  and ($patterns | any(.[]; . as $re | ($ns | test($re))));


    def is_excluded($ns): matches_any(excl; $ns);
    def is_nonprod($ns): matches_any(nonprod; $ns);

    def filter_enabled:
      ($filter_slurp|type) == "array" and ($filter_slurp|length) > 0;

    def keep_ns($ns):
      if filter_enabled and mode == "exclude" then (is_excluded($ns) | not) else true end;

    (["namespace","mount_path","mount_type","clients","entity_clients","non_entity_clients","acme_clients","secret_syncs","namespace_non_production","namespace_excluded"] | @csv),
    (.by_namespace[] as $ns
      | ($ns | norm_ns) as $nspath
      | select(keep_ns($nspath))
      | $ns.mounts[]?
      | [
          $nspath,
          (.mount_path | nz),
          (.mount_type | nz),
          (.counts.clients | nz),
          (.counts.entity_clients | nz),
          (.counts.non_entity_clients | nz),
          (.counts.acme_clients | nz),
          (.counts.secret_syncs | nz),
          (is_nonprod($nspath)|tostring),
          (is_excluded($nspath)|tostring)
        ]
      | @csv
    )
  ' "$FILE" >"${OUT_CSV_DIR}/mounts.csv"

  # Months CSV (no filtering applied, months are global in the report)
  if jq -e '.months? and (.months|type=="array") and (.months|length>0)' "$FILE" >/dev/null 2>&1; then
    jq -r '
      def nz: . // 0;
      (["timestamp","clients","new_clients"] | @csv),
      (.months[]
        | [
            (.timestamp | tostring),
            (.counts.clients | nz),
            (.new_clients.counts.clients | nz)
          ]
        | @csv
      )
    ' "$FILE" >"${OUT_CSV_DIR}/months.csv"
  fi

  # Reconciliation CSV (filtered if filter-mode=exclude)
  jq -r "${JQ_FILTER_ARGS[@]}" '
    def nz: . // 0;
    def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

    def f: (if ($filter_slurp|type) == "array" and ($filter_slurp|length) > 0 then $filter_slurp[0] else {} end);
    def mode_from_file: (f.mode // "exclude");
    def mode: if ($filter_mode // "") != "" then $filter_mode else mode_from_file end;
    def excl: (f.exclude_namespaces // []);

    def matches_any($patterns; $ns):
  ($patterns | type) == "array"
  and ($patterns | length) > 0
  and ($patterns | any(.[]; . as $re | ($ns | test($re))));


    def is_excluded($ns): matches_any(excl; $ns);

    def filter_enabled:
      ($filter_slurp|type) == "array" and ($filter_slurp|length) > 0;

    def keep_ns($ns):
      if filter_enabled and mode == "exclude" then (is_excluded($ns) | not) else true end;

    (["namespace","namespace_clients","mounts_clients_sum","delta","mounts"] | @csv),
    (.by_namespace[]
      | . as $ns
      | ($ns | norm_ns) as $name
      | select(keep_ns($name))
      | ($ns.counts.clients // 0) as $ns_clients
      | (($ns.mounts | map(.counts.clients // 0) | add) // 0) as $m_clients
      | {
          namespace: $name,
          namespace_clients: ($ns_clients | nz),
          mounts_clients_sum: ($m_clients | nz),
          delta: (($m_clients|nz) - ($ns_clients|nz)),
          mounts: ($ns.mounts | length)
        }
      | select(.delta != 0)
      | [.namespace,.namespace_clients,.mounts_clients_sum,.delta,.mounts] | @csv
    )
  ' "$FILE" >"${OUT_CSV_DIR}/reconciliation.csv"

  # Reconciliation mounts breakdown CSV (filtered if filter-mode=exclude)
  jq -r "${JQ_FILTER_ARGS[@]}" '
    def nz: . // 0;
    def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

    def f: (if ($filter_slurp|type) == "array" and ($filter_slurp|length) > 0 then $filter_slurp[0] else {} end);
    def mode_from_file: (f.mode // "exclude");
    def mode: if ($filter_mode // "") != "" then $filter_mode else mode_from_file end;
    def excl: (f.exclude_namespaces // []);

    def matches_any($patterns; $ns):
  ($patterns | type) == "array"
  and ($patterns | length) > 0
  and ($patterns | any(.[]; . as $re | ($ns | test($re))));


    def is_excluded($ns): matches_any(excl; $ns);

    def filter_enabled:
      ($filter_slurp|type) == "array" and ($filter_slurp|length) > 0;

    def keep_ns($ns):
      if filter_enabled and mode == "exclude" then (is_excluded($ns) | not) else true end;

    (["namespace","namespace_clients","mounts_clients_sum","delta","mount_path","mount_type","clients","entity_clients","non_entity_clients","acme_clients","secret_syncs"] | @csv),
    (
      .by_namespace[] as $ns
      | ($ns | norm_ns) as $name
      | select(keep_ns($name))
      | ($ns.counts.clients // 0) as $ns_clients
      | (($ns.mounts | map(.counts.clients // 0) | add) // 0) as $m_clients
      | ($m_clients - $ns_clients) as $delta
      | select($delta != 0)
      | $ns.mounts[]? as $m
      | [
          $name,
          ($ns_clients | nz),
          ($m_clients | nz),
          ($delta | nz),
          ($m.mount_path | nz),
          ($m.mount_type | nz),
          ($m.counts.clients | nz),
          ($m.counts.entity_clients | nz),
          ($m.counts.non_entity_clients | nz),
          ($m.counts.acme_clients | nz),
          ($m.counts.secret_syncs | nz)
        ]
      | @csv
    )
  ' "$FILE" >"${OUT_CSV_DIR}/reconciliation_mounts.csv"

  echo "✅ Wrote CSV:"
  echo "  - ${OUT_CSV_DIR}/namespaces.csv"
  echo "  - ${OUT_CSV_DIR}/mounts.csv"
  echo "  - ${OUT_CSV_DIR}/reconciliation.csv"
  echo "  - ${OUT_CSV_DIR}/reconciliation_mounts.csv"
  if [[ -f "${OUT_CSV_DIR}/months.csv" ]]; then
    echo "  - ${OUT_CSV_DIR}/months.csv"
  fi
fi

# -------- Markdown export (filtered if filter-mode=exclude, highlights if highlight) --------
if [[ -n "${OUT_MD_PATH}" ]]; then
  jq -r --argjson top "$TOP" "${JQ_FILTER_ARGS[@]}" '
    def nz: . // 0;
    def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

    def f: (if ($filter_slurp|type) == "array" and ($filter_slurp|length) > 0 then $filter_slurp[0] else {} end);
    def mode_from_file: (f.mode // "exclude");
    def mode: if ($filter_mode // "") != "" then $filter_mode else mode_from_file end;
    def excl: (f.exclude_namespaces // []);
    def nonprod: (f.non_production_namespaces // []);

    def matches_any($patterns; $ns):
  ($patterns | type) == "array"
  and ($patterns | length) > 0
  and ($patterns | any(.[]; . as $re | ($ns | test($re))));


    def is_excluded($ns): matches_any(excl; $ns);
    def is_nonprod($ns): matches_any(nonprod; $ns);

    def filter_enabled:
      ($filter_slurp|type) == "array" and ($filter_slurp|length) > 0;

    def keep_ns($ns):
      if filter_enabled and mode == "exclude" then (is_excluded($ns) | not) else true end;

    def totals_from_namespaces:
      {
        clients:            (.by_namespace | map((norm_ns) as $n | select(keep_ns($n)) | (.counts.clients            | nz)) | add // 0),
        entity_clients:     (.by_namespace | map((norm_ns) as $n | select(keep_ns($n)) | (.counts.entity_clients     | nz)) | add // 0),
        non_entity_clients: (.by_namespace | map((norm_ns) as $n | select(keep_ns($n)) | (.counts.non_entity_clients | nz)) | add // 0),
        acme_clients:       (.by_namespace | map((norm_ns) as $n | select(keep_ns($n)) | (.counts.acme_clients       | nz)) | add // 0),
        secret_syncs:       (.by_namespace | map((norm_ns) as $n | select(keep_ns($n)) | (.counts.secret_syncs       | nz)) | add // 0)
      };

    def totals_from_mounts:
      {
        clients:            (.by_namespace | map((norm_ns) as $n | select(keep_ns($n)) | (.mounts[]? | .counts.clients            | nz)) | add // 0),
        entity_clients:     (.by_namespace | map((norm_ns) as $n | select(keep_ns($n)) | (.mounts[]? | .counts.entity_clients     | nz)) | add // 0),
        non_entity_clients: (.by_namespace | map((norm_ns) as $n | select(keep_ns($n)) | (.mounts[]? | .counts.non_entity_clients | nz)) | add // 0),
        acme_clients:       (.by_namespace | map((norm_ns) as $n | select(keep_ns($n)) | (.mounts[]? | .counts.acme_clients       | nz)) | add // 0),
        secret_syncs:       (.by_namespace | map((norm_ns) as $n | select(keep_ns($n)) | (.mounts[]? | .counts.secret_syncs       | nz)) | add // 0)
      };

    def ns_rows:
      (.by_namespace
        | map({
            namespace: (norm_ns),
            mounts: (.mounts | length),
            clients: (.counts.clients | nz),
            non_production: is_nonprod((norm_ns)),
            excluded: is_excluded((norm_ns))
          })
        | map(select(keep_ns(.namespace)))
        | sort_by(.clients) | reverse
      );

    def mount_rows:
      ([.by_namespace[] as $ns
        | ($ns | norm_ns) as $nspath
        | select(keep_ns($nspath))
        | $ns.mounts[]?
        | {
            namespace: $nspath,
            mount_path: (.mount_path | nz),
            mount_type: (.mount_type | nz),
            clients: (.counts.clients | nz),
            namespace_non_production: is_nonprod($nspath)
          }]
        | sort_by(.clients) | reverse
      );

    def reconcile_rows:
      (.by_namespace
        | map(
            . as $ns
            | ($ns | norm_ns) as $name
            | select(keep_ns($name))
            | ($ns.counts.clients // 0) as $ns_clients
            | (($ns.mounts | map(.counts.clients // 0) | add) // 0) as $m_clients
            | {
                namespace: $name,
                namespace_clients: $ns_clients,
                mounts_clients_sum: $m_clients,
                delta: ($m_clients - $ns_clients),
                mounts: ($ns.mounts | length)
              }
          )
        | map(select(.delta != 0))
        | sort_by(.delta) | reverse
      );

    def reconcile_details:
      ([.by_namespace[] as $ns
        | ($ns | norm_ns) as $name
        | select(keep_ns($name))
        | ($ns.counts.clients // 0) as $ns_clients
        | (($ns.mounts | map(.counts.clients // 0) | add) // 0) as $m_clients
        | ($m_clients - $ns_clients) as $delta
        | select($delta != 0)
        | {
            namespace: $name,
            delta: $delta,
            namespace_clients: $ns_clients,
            mounts_clients_sum: $m_clients,
            mounts_table: (
              "| mount_path | mount_type | clients |\n"
              + "|---|---|---:|\n"
              + (
                $ns.mounts
                | sort_by(.counts.clients // 0) | reverse
                | map("| " + (.mount_path | nz) + " | " + (.mount_type | nz) + " | " + ((.counts.clients // 0)|tostring) + " |")
                | join("\n")
              )
            )
          }
      ]);

    . as $doc
    | (totals_from_namespaces) as $ns_tot
    | (totals_from_mounts) as $m_tot
    | ($doc.total // {}) as $reported
    | ($doc.by_namespace | length) as $ns_count
    | ($doc.by_namespace | map(.mounts | length) | add // 0) as $mount_count
    | (ns_rows) as $ns
    | (mount_rows) as $m
    | (reconcile_rows) as $r
    | (reconcile_details) as $rd

    | (
      "# Vault client count report\n\n" +

      (if filter_enabled then
        "## Filter\n\n"
        + "- mode: `" + (mode|tostring) + "`\n"
        + "- exclude_namespaces: `" + (excl|tostring) + "`\n"
        + "- non_production_namespaces: `" + (nonprod|tostring) + "`\n\n"
      else "" end) +

      "## Summary\n\n" +
      "- start_time: `" + ($doc.start_time | tostring) + "`\n" +
      "- namespaces: `" + ($ns_count | tostring) + "`\n" +
      "- mounts: `" + ($mount_count | tostring) + "`\n\n" +

      "## Totals\n\n" +
      "| Source | clients | entity_clients | non_entity_clients | acme_clients | secret_syncs |\n" +
      "|---|---:|---:|---:|---:|---:|\n" +
      "| Namespaces (computed" + (if filter_enabled and mode=="exclude" then ", filtered" else "" end) + ") | " + ($ns_tot.clients|tostring) + " | " + ($ns_tot.entity_clients|tostring) + " | " + ($ns_tot.non_entity_clients|tostring) + " | " + ($ns_tot.acme_clients|tostring) + " | " + ($ns_tot.secret_syncs|tostring) + " |\n" +
      "| Mounts (computed" + (if filter_enabled and mode=="exclude" then ", filtered" else "" end) + ") | " + ($m_tot.clients|tostring) + " | " + ($m_tot.entity_clients|tostring) + " | " + ($m_tot.non_entity_clients|tostring) + " | " + ($m_tot.acme_clients|tostring) + " | " + ($m_tot.secret_syncs|tostring) + " |\n" +
      "| Reported (.total) | " + (($reported.clients // 0)|tostring) + " | " + (($reported.entity_clients // 0)|tostring) + " | " + (($reported.non_entity_clients // 0)|tostring) + " | " + (($reported.acme_clients // 0)|tostring) + " | " + (($reported.secret_syncs // 0)|tostring) + " |\n\n" +

      "## Reconciliation (mounts_sum vs namespace_total)\n\n" +
      (if ($r|length) == 0
       then "_No differences found._\n\n"
       else (
         "| namespace | namespace_clients | mounts_clients_sum | delta | mounts |\n" +
         "|---|---:|---:|---:|---:|\n" +
         (
           $r[0:$top]
           | map("| " + .namespace + " | " + (.namespace_clients|tostring) + " | " + (.mounts_clients_sum|tostring) + " | " + (.delta|tostring) + " | " + (.mounts|tostring) + " |")
           | join("\n")
         ) + "\n\n"
       )
      end) +

      "## Reconciliation details\n\n" +
      (if ($rd|length) == 0
       then "_No differences found._\n\n"
       else (
         $rd[0:$top]
         | map(
             "### " + .namespace + " (delta=" + (.delta|tostring) + ")\n\n" +
             "- namespace_clients: `" + (.namespace_clients|tostring) + "`\n" +
             "- mounts_clients_sum: `" + (.mounts_clients_sum|tostring) + "`\n\n" +
             .mounts_table + "\n\n"
           )
         | join("\n")
       )
      end) +

      "## Top namespaces by clients\n\n" +
      "| namespace | clients | mounts |\n" +
      "|---|---:|---:|\n" +
      (
        $ns[0:$top]
        | map("| " + .namespace
              + (if filter_enabled and mode=="highlight" and .non_production then " *(non-production)*" else "" end)
              + " | " + (.clients|tostring) + " | " + (.mounts|tostring) + " |")
        | join("\n")
      ) + "\n\n" +

      "## Top mounts by clients\n\n" +
      "| namespace | mount_path | mount_type | clients |\n" +
      "|---|---|---|---:|\n" +
      (
        $m[0:$top]
        | map("| " + .namespace
              + (if filter_enabled and mode=="highlight" and .namespace_non_production then " *(non-production)*" else "" end)
              + " | " + .mount_path + " | " + .mount_type + " | " + (.clients|tostring) + " |")
        | join("\n")
      ) + "\n"
    )
  ' "$FILE" >"${OUT_MD_PATH}"

  echo "✅ Wrote Markdown: ${OUT_MD_PATH}"
fi
# -------- Text summary --------
