#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./count_clients.sh --file <path> [--top N] [--out-csv <dir>] [--out-md <path>] [--filter <filter.json>] [--filter-mode exclude|highlight] [--entitlement N] [--color auto|always|never] [--no-color]

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
  ./count_clients.sh --file ./input/activity_counter_2024_2025.txt --filter ./filter/exclude.json --filter-mode exclude --out-csv ./2024_2025
USAGE
}

FILE=""
TOP=10
OUT_CSV_DIR=""
OUT_MD_PATH=""
FILTER=""
FILTER_MODE=""
ENTITLEMENT=""
COLOR_MODE="auto" # auto|always|never

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file|-f) FILE="${2:-}"; shift 2 ;;
    --top) TOP="${2:-10}"; shift 2 ;;
    --out-csv) OUT_CSV_DIR="${2:-}"; shift 2 ;;
    --out-md) OUT_MD_PATH="${2:-}"; shift 2 ;;
    --filter) FILTER="${2:-}"; shift 2 ;;
    --filter-mode) FILTER_MODE="${2:-}"; shift 2 ;;
    --entitlement) ENTITLEMENT="${2:-}"; shift 2 ;;
    --color) COLOR_MODE="${2:-auto}"; shift 2 ;;
    --no-color) COLOR_MODE="never"; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown arg: $1"
      usage
      exit 2
      ;;
  esac
done

# Pass entitlement as JSON (number or null). Avoids jq tonumber crashes.
JQ_ENT_ARGS=()
if [[ -n "${ENTITLEMENT}" ]]; then
  JQ_ENT_ARGS=(--argjson entitlement "${ENTITLEMENT}")
else
  JQ_ENT_ARGS=(--argjson entitlement null)
fi

# NO_COLOR convention
if [[ -n "${NO_COLOR:-}" ]]; then
  COLOR_MODE="never"
fi

C_RESET=""
C_BOLD=""
C_DIM=""
C_RED=""
C_GREEN=""
C_YELLOW=""
C_CYAN=""

init_colors() {
  local enable="false"
  case "${COLOR_MODE}" in
    auto) [[ -t 1 ]] && enable="true" ;;
    always) enable="true" ;;
    never) enable="false" ;;
    *)
      echo "Error: --color must be auto|always|never (got: ${COLOR_MODE})"
      exit 2
      ;;
  esac

  if [[ "${enable}" == "true" ]]; then
    C_RESET=$'\e[0m'
    C_BOLD=$'\e[1m'
    C_DIM=$'\e[2m'
    C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'
    C_CYAN=$'\e[36m'
  fi
}

init_colors
JQ_COLOR_ARGS=(
  --arg C_RESET "${C_RESET}"
  --arg C_H1 "${C_BOLD}${C_CYAN}"
  --arg C_KEY "${C_DIM}"
  --arg C_GOOD "${C_GREEN}"
  --arg C_WARN "${C_YELLOW}"
  --arg C_BAD "${C_RED}"
)

# --- validate inputs ---
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

if [[ -n "${ENTITLEMENT}" ]]; then
  if ! [[ "${ENTITLEMENT}" =~ ^[0-9]+$ ]]; then
    echo "Error: --entitlement must be an integer, got: ${ENTITLEMENT}"
    exit 2
  fi
fi

if [[ -n "${FILTER_MODE}" ]]; then
  case "${FILTER_MODE}" in
    exclude|highlight) ;;
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

# Always define filter variables for jq
JQ_FILTER_ARGS=(--arg filter_mode "${FILTER_MODE:-}")
if [[ -n "${FILTER}" ]]; then
  JQ_FILTER_ARGS+=(--slurpfile filter_slurp "${FILTER}")
else
  JQ_FILTER_ARGS+=(--argjson filter_slurp '[]')
fi

# -------- Terminal summary --------
jq -r --argjson top "$TOP" "${JQ_ENT_ARGS[@]}" "${JQ_FILTER_ARGS[@]}" "${JQ_COLOR_ARGS[@]}" '
  # ---------- defaults ----------
  def n0:
    if . == null then 0
    elif (type == "number") then .
    else (tonumber? // 0)
    end;

  def s0: if . == null then "" else tostring end;

  def norm_ns:
    ((.namespace_path // "") as $p
     | if $p == "" then "root" else $p end);

  # mounts may be missing in old exports
  def mounts0: (.mounts // []);

  # normalize counts across schemas
  def c_clients:            (.counts.clients | n0);
  def c_entity_clients:     ((.counts.entity_clients // .counts.distinct_entities) | n0);
  def c_non_entity_clients: ((.counts.non_entity_clients // .counts.non_entity_tokens) | n0);
  def c_acme_clients:       (.counts.acme_clients | n0);
  def c_secret_syncs:       (.counts.secret_syncs | n0);

  # ---------- formatting ----------
  def h1($s): ($C_H1 + $s + $C_RESET + "\n");
  def key($s): ($C_KEY + $s + $C_RESET);
  def round2: ((. * 100) | round) / 100;

  # ---------- entitlement ----------
  def ent: $entitlement;
  def has_ent: (ent != null);

  def ent_status($value):
    if (has_ent | not) then ""
    else
      (($value - ent) as $d
      | if $d < 0 then "under by " + ((-$d)|tostring)
        elif $d > 0 then "over by " + ($d|tostring)
        else "exact match"
        end)
    end;

  def ent_color($value):
    if (has_ent | not) then ""
    else
      (($value - ent) as $d
      | if $d < 0 then $C_GOOD
        elif $d > 0 then $C_BAD
        else $C_GOOD
        end)
    end;

  def ent_block($label; $value):
    if (has_ent | not) then ""
    else
      h1("Entitlement")
      + "  " + key("entitlement:") + " " + (ent|tostring) + "\n"
      + "  " + key($label + ":") + " " + ($value|tostring)
      + " (" + (ent_color($value)) + (ent_status($value)) + $C_RESET + ")\n\n"
    end;

  # ---------- filter config ----------
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

  # ---------- rows ----------
  def ns_rows_all:
    ((.by_namespace // [])
      | map(
          . as $ns
          | ($ns | norm_ns) as $name
          | {
              namespace: $name,
              namespace_id: ($ns.namespace_id // "" | tostring),
              mounts: (($ns | mounts0) | length),
              clients: ($ns | c_clients),
              entity_clients: ($ns | c_entity_clients),
              non_entity_clients: ($ns | c_non_entity_clients),
              acme_clients: ($ns | c_acme_clients),
              secret_syncs: ($ns | c_secret_syncs),
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
    ([.by_namespace[]? as $ns
      | ($ns | norm_ns) as $nspath
      | select(keep_ns($nspath))
      | (($ns | mounts0)[]?) as $m
      | {
          namespace: $nspath,
          namespace_non_production: is_nonprod($nspath),
          mount_path: ($m.mount_path | s0),
          mount_type: ($m.mount_type | s0),
          clients: ($m.counts.clients | n0),
          entity_clients: (($m.counts.entity_clients // $m.counts.distinct_entities) | n0),
          non_entity_clients: (($m.counts.non_entity_clients // $m.counts.non_entity_tokens) | n0),
          acme_clients: ($m.counts.acme_clients | n0),
          secret_syncs: ($m.counts.secret_syncs | n0)
        }]
      | sort_by(.clients) | reverse
    );

  # ---------- totals ----------
  def sum_field($rows; $field):
    ($rows | map(.[$field] | n0) | add // 0);

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
      acme_clients:       ($rows | map(.acme_clients|n0) | add // 0),
      clients:            ($rows | map(.clients|n0) | add // 0),
      entity_clients:     ($rows | map(.entity_clients|n0) | add // 0),
      non_entity_clients: ($rows | map(.non_entity_clients|n0) | add // 0),
      secret_syncs:       ($rows | map(.secret_syncs|n0) | add // 0)
    };

  def diff(a; b):
    {
      acme_clients:       ((a.acme_clients       | n0) - (b.acme_clients       | n0)),
      clients:            ((a.clients            | n0) - (b.clients            | n0)),
      entity_clients:     ((a.entity_clients     | n0) - (b.entity_clients     | n0)),
      non_entity_clients: ((a.non_entity_clients | n0) - (b.non_entity_clients | n0)),
      secret_syncs:       ((a.secret_syncs       | n0) - (b.secret_syncs       | n0))
    };

  # ---------- reconciliation ----------
  def reconcile_rows:
    ([.by_namespace[]? as $ns
      | ($ns | norm_ns) as $name
      | select(keep_ns($name))
      | ($ns | c_clients) as $ns_clients
      | (((($ns | mounts0) | map((.counts.clients | n0)) | add) // 0)) as $m_clients
      | {
          namespace: $name,
          namespace_clients: ($ns_clients | n0),
          mounts_clients_sum: ($m_clients | n0),
          delta: (($m_clients|n0) - ($ns_clients|n0)),
          mounts: (($ns | mounts0) | length)
        }
      | select(.delta != 0)
    ]);

  def delta_color($d):
    (($d|abs) as $a
      | if $a == 0 then $C_GOOD
        elif $a <= 5 then $C_WARN
        else $C_BAD
        end);

  def reconcile_mounts_for($doc; $ns_name):
    ([$doc.by_namespace[]? as $ns
      | select(($ns | norm_ns) == $ns_name)
      | (($ns | mounts0)[]?) as $m
      | {
          mount_path: ($m.mount_path | s0),
          mount_type: ($m.mount_type | s0),
          clients: ($m.counts.clients | n0)
        }
    ]
      | sort_by(.clients) | reverse
    );

  # ---------- months ----------
  def has_months:
    (.months? != null) and ((.months | type) == "array") and ((.months | length) > 0);

  def months_rows:
    (.months // [])
    | map({
        time: (.timestamp | tostring),
        clients: (.counts.clients | n0),
        new_clients: (.new_clients.counts.clients | n0)
      });

  # ---------- build doc ----------
  . as $doc
  | (ns_rows_all) as $ns_all
  | (ns_rows_filtered) as $ns_rows
  | (mount_rows_filtered) as $mount_rows
  | (totals_from_ns($ns_rows)) as $ns_tot
  | (totals_from_mounts($mount_rows)) as $m_tot
  | ($doc.total // {}) as $reported
  | ({
      clients: ($reported.clients // 0),
      entity_clients: (($reported.entity_clients // $reported.distinct_entities) // 0),
      non_entity_clients: (($reported.non_entity_clients // $reported.non_entity_tokens) // 0),
      acme_clients: ($reported.acme_clients // 0),
      secret_syncs: ($reported.secret_syncs // 0)
    } | with_entries(.value |= (n0))) as $reported_norm

  # reported total normalization (old + new)
  | ( ($reported.clients | n0) ) as $rep_clients
  | ( (($reported.entity_clients // $reported.distinct_entities) | n0) ) as $rep_entity
  | ( (($reported.non_entity_clients // $reported.non_entity_tokens) | n0) ) as $rep_non_entity
  | ( ($reported.acme_clients | n0) ) as $rep_acme
  | ( ($reported.secret_syncs | n0) ) as $rep_secret_syncs

  | (totals_from_ns($ns_all)) as $ns_tot_unfiltered
  | (($doc.by_namespace // []) | length) as $ns_count
  | (($doc.by_namespace // []) | map(((.mounts // [])|length)) | add // 0) as $mount_count
  | ($ns_all | map(select(.excluded)) ) as $excluded_rows
  | (reconcile_rows) as $recon

  | (if has_months then (months_rows | map(.clients) | max // 0) else 0 end) as $monthly_peak
  | (if has_months then (months_rows | map(.clients) | min // 0) else 0 end) as $monthly_min
  | (if has_months then (months_rows | map(.clients) | add // 0) else 0 end) as $monthly_sum
  | (if has_months then (months_rows | length) else 0 end) as $monthly_n
  | (if has_months and $monthly_n > 0 then ($monthly_sum / $monthly_n) else 0 end) as $monthly_avg

  | (
      (if filter_enabled then
        h1("Filter")
        + "  " + key("mode:") + " " + (mode|tostring) + "\n"
        + "  " + key("exclude_namespaces:") + " " + (excl|tostring) + "\n"
        + "  " + key("non_production_namespaces:") + " " + (nonprod|tostring) + "\n\n"
      else "" end)

      + h1("File summary")
      + "  " + key("start_time:") + " " + ($doc.start_time | tostring) + "\n"
      + "  " + key("namespaces:") + " " + ($ns_count | tostring) + "\n"
      + "  " + key("mounts:") + " " + ($mount_count | tostring) + "\n\n"

      + (ent_block("selected_scope_clients"; ($ns_tot.clients | n0)))

      + h1("Totals (computed from namespaces" + (if filter_enabled and mode=="exclude" then ", filtered" else "" end) + ")")
      + "  " + key("clients:") + " " + ($ns_tot.clients | tostring) + "\n"
      + "  " + key("entity_clients:") + " " + ($ns_tot.entity_clients | tostring) + "\n"
      + "  " + key("non_entity_clients:") + " " + ($ns_tot.non_entity_clients | tostring) + "\n"
      + "  " + key("acme_clients:") + " " + ($ns_tot.acme_clients | tostring) + "\n"
      + "  " + key("secret_syncs:") + " " + ($ns_tot.secret_syncs | tostring) + "\n\n"

      + h1("Totals (computed from mounts" + (if filter_enabled and mode=="exclude" then ", filtered" else "" end) + ")")
      + "  " + key("clients:") + " " + ($m_tot.clients | tostring) + "\n"
      + "  " + key("entity_clients:") + " " + ($m_tot.entity_clients | tostring) + "\n"
      + "  " + key("non_entity_clients:") + " " + ($m_tot.non_entity_clients | tostring) + "\n"
      + "  " + key("acme_clients:") + " " + ($m_tot.acme_clients | tostring) + "\n"
      + "  " + key("secret_syncs:") + " " + ($m_tot.secret_syncs | tostring) + "\n\n"

      + h1("Totals (reported in file: .total)")
      + "  " + key("clients:") + " " + ($rep_clients|tostring) + "\n"
      + "  " + key("entity_clients:") + " " + ($rep_entity|tostring) + "\n"
      + "  " + key("non_entity_clients:") + " " + ($rep_non_entity|tostring) + "\n"
      + "  " + key("acme_clients:") + " " + ($rep_acme|tostring) + "\n"
      + "  " + key("secret_syncs:") + " " + ($rep_secret_syncs|tostring) + "\n\n"

      + h1("Validation (computed minus reported)")
      + "  " + key("namespaces - reported:") + " " + (diff($ns_tot_unfiltered; $reported_norm) | tostring) + "\n"
      + "  " + key("mounts     - reported:") + " " + (diff($m_tot; $reported_norm) | tostring) + "\n\n"

      + h1("Top namespaces by clients (top " + ($top|tostring) + ")")
      + (
        $ns_rows[0:$top]
        | map(
            "  - " + .namespace
            + "  " + key("clients=") + (.clients|tostring)
            + "  " + key("mounts=") + (.mounts|tostring)
          )
        | join("\n")
      ) + "\n\n"

      + h1("Top mounts by clients (top " + ($top|tostring) + ")")
      + (
        if ($mount_rows|length) == 0 then "  - none (this export has no mounts breakdown)\n\n"
        else (
          $mount_rows[0:$top]
          | map("  - " + .namespace + "  " + .mount_path + " (" + .mount_type + ") " + key("clients=") + (.clients|tostring))
          | join("\n")
        ) + "\n\n"
        end
    )
  )
' "$FILE"

# -------- CSV exports --------
if [[ -n "${OUT_CSV_DIR}" ]]; then
  # Namespaces CSV (filtered if filter-mode=exclude)
  jq -r "${JQ_FILTER_ARGS[@]}" '
    def n0: if . == null then 0 elif (type=="number") then . else (tonumber? // 0) end;
    def norm_ns: ((.namespace_path // "") as $p | if $p == "" then "root" else $p end);

    def mounts0: (.mounts // []);

    # normalize counts across schemas
    def c_clients:            (.counts.clients | n0);
    def c_entity_clients:     ((.counts.entity_clients // .counts.distinct_entities) | n0);
    def c_non_entity_clients: ((.counts.non_entity_clients // .counts.non_entity_tokens) | n0);
    def c_acme_clients:       (.counts.acme_clients | n0);
    def c_secret_syncs:       (.counts.secret_syncs | n0);

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
    ((.by_namespace // [])[]
      | . as $ns
      | (norm_ns) as $name
      | select(keep_ns($name))
      | [
          $name,
          ($ns.namespace_id // "" | tostring),
          (($ns | mounts0) | length),
          ($ns | c_clients),
          ($ns | c_entity_clients),
          ($ns | c_non_entity_clients),
          ($ns | c_acme_clients),
          ($ns | c_secret_syncs),
          (is_nonprod($name)|tostring),
          (is_excluded($name)|tostring)
        ]
      | @csv
    )
  ' "$FILE" > "${OUT_CSV_DIR}/namespaces.csv"

  # Mounts CSV (safe even when no mounts exist)
  jq -r "${JQ_FILTER_ARGS[@]}" '
    def n0: if . == null then 0 elif (type=="number") then . else (tonumber? // 0) end;
    def s0: if . == null then "" else tostring end;
    def norm_ns: ((.namespace_path // "") as $p | if $p == "" then "root" else $p end);

    def mounts0: (.mounts // []);

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
    ([ (.by_namespace // [])[] as $ns
        | ($ns | norm_ns) as $nspath
        | select(keep_ns($nspath))
        | (($ns | mounts0)[]?) as $m
        | [
            $nspath,
            ($m.mount_path | s0),
            ($m.mount_type | s0),
            ($m.counts.clients | n0),
            (($m.counts.entity_clients // $m.counts.distinct_entities) | n0),
            (($m.counts.non_entity_clients // $m.counts.non_entity_tokens) | n0),
            ($m.counts.acme_clients | n0),
            ($m.counts.secret_syncs | n0),
            (is_nonprod($nspath)|tostring),
            (is_excluded($nspath)|tostring)
          ]
        | @csv
      ] | .[])
  ' "$FILE" > "${OUT_CSV_DIR}/mounts.csv"

  # Months CSV (no filtering)
  if jq -e '.months? and (.months|type=="array") and (.months|length>0)' "$FILE" >/dev/null 2>&1; then
    jq -r '
      def n0: if . == null then 0 elif (type=="number") then . else (tonumber? // 0) end;
      (["timestamp","clients","new_clients"] | @csv),
      (.months[]
        | [
            (.timestamp | tostring),
            (.counts.clients | n0),
            (.new_clients.counts.clients | n0)
          ]
        | @csv
      )
    ' "$FILE" > "${OUT_CSV_DIR}/months.csv"
  fi

  # Reconciliation CSV (safe; treats missing mounts as [])
  jq -r "${JQ_FILTER_ARGS[@]}" '
    def n0: if . == null then 0 elif (type=="number") then . else (tonumber? // 0) end;
    def norm_ns: ((.namespace_path // "") as $p | if $p == "" then "root" else $p end);
    def mounts0: (.mounts // []);

    def c_clients: (.counts.clients | n0);

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
    ((.by_namespace // [])[]
      | . as $ns
      | ($ns | norm_ns) as $name
      | select(keep_ns($name))
      | ($ns | c_clients) as $ns_clients
      | (((($ns | mounts0) | map((.counts.clients | n0)) | add) // 0)) as $m_clients
      | {
          namespace: $name,
          namespace_clients: $ns_clients,
          mounts_clients_sum: $m_clients,
          delta: ($m_clients - $ns_clients),
          mounts: (($ns | mounts0) | length)
        }
      | select(.delta != 0)
      | [.namespace,.namespace_clients,.mounts_clients_sum,.delta,.mounts] | @csv
    )
  ' "$FILE" > "${OUT_CSV_DIR}/reconciliation.csv"

  # Reconciliation mounts breakdown CSV (safe, but will be empty for old schema)
  jq -r "${JQ_FILTER_ARGS[@]}" '
    def n0: if . == null then 0 elif (type=="number") then . else (tonumber? // 0) end;
    def s0: if . == null then "" else tostring end;
    def norm_ns: ((.namespace_path // "") as $p | if $p == "" then "root" else $p end);
    def mounts0: (.mounts // []);

    def c_clients: (.counts.clients | n0);

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
    ([ (.by_namespace // [])[] as $ns
        | ($ns | norm_ns) as $name
        | select(keep_ns($name))
        | ($ns | c_clients) as $ns_clients
        | (((($ns | mounts0) | map((.counts.clients | n0)) | add) // 0)) as $m_clients
        | ($m_clients - $ns_clients) as $delta
        | select($delta != 0)
        | (($ns | mounts0)[]?) as $m
        | [
            $name,
            $ns_clients,
            $m_clients,
            $delta,
            ($m.mount_path | s0),
            ($m.mount_type | s0),
            ($m.counts.clients | n0),
            (($m.counts.entity_clients // $m.counts.distinct_entities) | n0),
            (($m.counts.non_entity_clients // $m.counts.non_entity_tokens) | n0),
            ($m.counts.acme_clients | n0),
            ($m.counts.secret_syncs | n0)
          ]
        | @csv
      ] | .[])
  ' "$FILE" > "${OUT_CSV_DIR}/reconciliation_mounts.csv"

  echo "✅ Wrote CSV:"
  echo "  - ${OUT_CSV_DIR}/namespaces.csv"
  echo "  - ${OUT_CSV_DIR}/mounts.csv"
  echo "  - ${OUT_CSV_DIR}/reconciliation.csv"
  echo "  - ${OUT_CSV_DIR}/reconciliation_mounts.csv"
  if [[ -f "${OUT_CSV_DIR}/months.csv" ]]; then
    echo "  - ${OUT_CSV_DIR}/months.csv"
  fi
fi

# -------- Markdown export --------
if [[ -n "${OUT_MD_PATH}" ]]; then
  jq -r --argjson top "$TOP" "${JQ_ENT_ARGS[@]}" "${JQ_FILTER_ARGS[@]}" '
    # ---------- primitives ----------
    def n0: if . == null then 0 elif (type=="number") then . else (tonumber? // 0) end;
    def s0: if . == null then "" else tostring end;
    def norm_ns: ((.namespace_path // "") as $p | if $p == "" then "root" else $p end);
    def mounts0: (.mounts // []);

    # normalize counts across schemas (namespace or mount object passed in as ".")
    def c_clients:            (.counts.clients | n0);
    def c_entity_clients:     ((.counts.entity_clients // .counts.distinct_entities) | n0);
    def c_non_entity_clients: ((.counts.non_entity_clients // .counts.non_entity_tokens) | n0);
    def c_acme_clients:       (.counts.acme_clients | n0);
    def c_secret_syncs:       (.counts.secret_syncs | n0);

    # normalize .total across schemas
    def total_norm:
      (.total // {}) as $t
      | {
          clients: ($t.clients | n0),
          entity_clients: (($t.entity_clients // $t.distinct_entities) | n0),
          non_entity_clients: (($t.non_entity_clients // $t.non_entity_tokens) | n0),
          acme_clients: ($t.acme_clients | n0),
          secret_syncs: ($t.secret_syncs | n0)
        };

    # ---------- entitlement ----------
    def ent: $entitlement;
    def has_ent: (ent != null);

    def ent_status($value):
      if (has_ent | not) then ""
      else
        (($value - ent) as $d
        | if $d < 0 then "under by " + ((-$d)|tostring)
          elif $d > 0 then "over by " + ($d|tostring)
          else "exact match"
          end)
      end;

    # ---------- filter config ----------
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

    # ---------- totals ----------
    def totals_from_namespaces:
      {
        clients:            ((.by_namespace // []) | map((norm_ns) as $n | select(keep_ns($n)) | (c_clients)) | add // 0),
        entity_clients:     ((.by_namespace // []) | map((norm_ns) as $n | select(keep_ns($n)) | (c_entity_clients)) | add // 0),
        non_entity_clients: ((.by_namespace // []) | map((norm_ns) as $n | select(keep_ns($n)) | (c_non_entity_clients)) | add // 0),
        acme_clients:       ((.by_namespace // []) | map((norm_ns) as $n | select(keep_ns($n)) | (c_acme_clients)) | add // 0),
        secret_syncs:       ((.by_namespace // []) | map((norm_ns) as $n | select(keep_ns($n)) | (c_secret_syncs)) | add // 0)
      };

    def totals_from_mounts:
      {
        clients:            ((.by_namespace // []) | map((norm_ns) as $n | select(keep_ns($n)) | ((mounts0)[]? | (c_clients))) | add // 0),
        entity_clients:     ((.by_namespace // []) | map((norm_ns) as $n | select(keep_ns($n)) | ((mounts0)[]? | (c_entity_clients))) | add // 0),
        non_entity_clients: ((.by_namespace // []) | map((norm_ns) as $n | select(keep_ns($n)) | ((mounts0)[]? | (c_non_entity_clients))) | add // 0),
        acme_clients:       ((.by_namespace // []) | map((norm_ns) as $n | select(keep_ns($n)) | ((mounts0)[]? | (c_acme_clients))) | add // 0),
        secret_syncs:       ((.by_namespace // []) | map((norm_ns) as $n | select(keep_ns($n)) | ((mounts0)[]? | (c_secret_syncs))) | add // 0)
      };

    # ---------- rows ----------
    def ns_rows:
      ((.by_namespace // [])
        | map({
            namespace: (norm_ns),
            mounts: ((mounts0) | length),
            clients: (c_clients),
            non_production: is_nonprod((norm_ns)),
            excluded: is_excluded((norm_ns))
          })
        | map(select(keep_ns(.namespace)))
        | sort_by(.clients) | reverse
      );

    def mount_rows:
      ([ (.by_namespace // [])[] as $ns
        | ($ns | norm_ns) as $nspath
        | select(keep_ns($nspath))
        | (($ns | mounts0)[]?) as $m
        | {
            namespace: $nspath,
            mount_path: ($m.mount_path | s0),
            mount_type: ($m.mount_type | s0),
            clients: ($m | c_clients),
            namespace_non_production: is_nonprod($nspath)
          }]
        | sort_by(.clients) | reverse
      );

    # ---------- reconciliation ----------
    def reconcile_rows:
      ((.by_namespace // [])
        | map(
            . as $ns
            | ($ns | norm_ns) as $name
            | select(keep_ns($name))
            | ($ns | c_clients) as $ns_clients
            | (((($ns | mounts0) | map((. | c_clients)) | add) // 0)) as $m_clients
            | {
                namespace: $name,
                namespace_clients: $ns_clients,
                mounts_clients_sum: $m_clients,
                delta: ($m_clients - $ns_clients),
                mounts: (($ns | mounts0) | length)
              }
          )
        | map(select(.delta != 0))
        | sort_by(.delta) | reverse
      );

    def reconcile_details:
      ([ (.by_namespace // [])[] as $ns
        | ($ns | norm_ns) as $name
        | select(keep_ns($name))
        | ($ns | c_clients) as $ns_clients
        | (((($ns | mounts0) | map((. | c_clients)) | add) // 0)) as $m_clients
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
                ($ns | mounts0)
                | sort_by((. | c_clients)) | reverse
                | map("| " + (.mount_path | s0) + " | " + (.mount_type | s0) + " | " + ((. | c_clients)|tostring) + " |")
                | join("\n")
              )
            )
          }
      ]);

    # ---------- months ----------
    def has_months:
      (.months? != null) and ((.months | type) == "array") and ((.months | length) > 0);

    def months_rows:
      (.months // [])
      | map({
          time: (.timestamp | tostring),
          clients: (.counts.clients | n0),
          new_clients: (.new_clients.counts.clients | n0)
        });

    def monthly_peak($rows): ($rows | map(.clients) | max // 0);
    def monthly_min($rows):  ($rows | map(.clients) | min // 0);
    def monthly_avg($rows):
      ( ($rows | length) as $n
        | if $n == 0 then 0
          else ((($rows | map(.clients) | add // 0) / $n) * 100 | round) / 100
          end );

    # ---------- build doc ----------
    . as $doc
    | (totals_from_namespaces) as $ns_tot
    | (totals_from_mounts) as $m_tot
    | (total_norm) as $reported
    | ($doc.by_namespace // [] | length) as $ns_count
    | ($doc.by_namespace // [] | map((.mounts // []) | length) | add // 0) as $mount_count
    | (ns_rows) as $ns
    | (mount_rows) as $m
    | (reconcile_rows) as $r
    | (reconcile_details) as $rd
    | (months_rows) as $mo
    | ($ns_tot.clients | n0) as $selected
    | ($mount_count > 0) as $has_mounts

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
      "- mounts: `" + ($mount_count | tostring) + "`\n" +
      (if has_ent then
        "- entitlement: `" + (ent|tostring) + "`\n"
        + "- selected_scope_clients: `" + ($selected|tostring) + "` (" + (ent_status($selected)) + ")\n"
      else "" end) +
      "\n" +

      "## Totals\n\n" +
      "| Source | clients | entity_clients | non_entity_clients | acme_clients | secret_syncs |\n" +
      "|---|---:|---:|---:|---:|---:|\n" +
      "| Namespaces (computed" + (if filter_enabled and mode=="exclude" then ", filtered" else "" end) + ") | "
        + ($ns_tot.clients|tostring) + " | " + ($ns_tot.entity_clients|tostring) + " | " + ($ns_tot.non_entity_clients|tostring) + " | " + ($ns_tot.acme_clients|tostring) + " | " + ($ns_tot.secret_syncs|tostring) + " |\n" +
      "| Mounts (computed" + (if filter_enabled and mode=="exclude" then ", filtered" else "" end) + ") | "
        + (if $has_mounts then ($m_tot.clients|tostring) else "n/a" end) + " | "
        + (if $has_mounts then ($m_tot.entity_clients|tostring) else "n/a" end) + " | "
        + (if $has_mounts then ($m_tot.non_entity_clients|tostring) else "n/a" end) + " | "
        + (if $has_mounts then ($m_tot.acme_clients|tostring) else "n/a" end) + " | "
        + (if $has_mounts then ($m_tot.secret_syncs|tostring) else "n/a" end) + " |\n" +
      "| Reported (.total) | "
        + ($reported.clients|tostring) + " | " + ($reported.entity_clients|tostring) + " | " + ($reported.non_entity_clients|tostring) + " | " + ($reported.acme_clients|tostring) + " | " + ($reported.secret_syncs|tostring) + " |\n\n" +

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
      (if $has_mounts then
        "| namespace | mount_path | mount_type | clients |\n"
        + "|---|---|---|---:|\n"
        + (
          $m[0:$top]
          | map("| " + .namespace
                + (if filter_enabled and mode=="highlight" and .namespace_non_production then " *(non-production)*" else "" end)
                + " | " + .mount_path + " | " + .mount_type + " | " + (.clients|tostring) + " |")
          | join("\n")
        ) + "\n\n"
      else
        "_No mounts breakdown in this export._\n\n"
      end) +

      (if has_months then
        "## Monthly checks\n\n"
        + "_Interpretation:_\n"
        + "- **Clients** is the monthly active unique client count.\n"
        + "- **annual_unique_clients** is the unique count across the full reporting window.\n\n"
        + "### Clients\n\n"
        + "| month | clients |\n"
        + "|---|---:|\n"
        + (
          $mo
          | map("| " + .time + " | " + (.clients|tostring) + " |")
          | join("\n")
        ) + "\n\n"
        + "### Client stats\n\n"
        + "- monthly_peak_clients: `" + (monthly_peak($mo)|tostring) + "`\n"
        + "- monthly_min_clients: `" + (monthly_min($mo)|tostring) + "`\n"
        + "- monthly_avg_clients: `" + (monthly_avg($mo)|tostring) + "`\n\n"
        + "### New clients\n\n"
        + "- total_new_clients: `" + (($mo | map(.new_clients) | add // 0) | tostring) + "`\n"
        + "- annual_unique_clients: `" + ($reported.clients|tostring) + "`\n\n"
      else "" end)
    )
  ' "$FILE" > "${OUT_MD_PATH}"

  echo "✅ Wrote Markdown: ${OUT_MD_PATH}"
fi
