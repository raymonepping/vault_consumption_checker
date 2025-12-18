#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./diff_clients.sh --old <file1> --new <file2> [--top N] [--out-csv <dir>] [--out-md <path>] [--filter <path>] [--filter-mode exclude|highlight]

What it does:
  - Validates JSON inputs
  - Compares overall totals (unique client counts) for the selected scope
  - Compares totals per namespace
  - Shows deltas (increased/decreased) and top movers
  - Adds "exec proof" stats:
      - top 3 increases total
      - deleted namespaces net change
  - Optional filter file:
      - exclude: removes matching namespaces from the analysis
      - highlight: includes everything but labels non-production namespaces

Requirements:
  - jq

Examples:
  ./diff_clients.sh --old a.json --new b.json
  ./diff_clients.sh --old a.json --new b.json --top 20 --out-csv ./out --out-md ./out/diff.md
  ./diff_clients.sh --old a.json --new b.json --filter ./filter/exclude.json --filter-mode exclude
USAGE
}

OLD=""
NEW=""
TOP=15
OUT_CSV_DIR=""
OUT_MD_PATH=""
FILTER=""
FILTER_MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --old) OLD="${2:-}"; shift 2 ;;
    --new) NEW="${2:-}"; shift 2 ;;
    --top) TOP="${2:-15}"; shift 2 ;;
    --out-csv) OUT_CSV_DIR="${2:-}"; shift 2 ;;
    --out-md) OUT_MD_PATH="${2:-}"; shift 2 ;;
    --filter) FILTER="${2:-}"; shift 2 ;;
    --filter-mode) FILTER_MODE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

if [[ -z "${OLD}" || -z "${NEW}" ]]; then
  echo "Error: --old and --new are required"
  usage
  exit 2
fi

for f in "${OLD}" "${NEW}"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: file not found: $f"
    exit 2
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not found."
  echo "Install: macOS (brew install jq) | Debian/Ubuntu (apt-get install -y jq)"
  exit 2
fi

if ! jq -e . "${OLD}" >/dev/null 2>&1; then
  echo "Error: --old is not valid JSON: ${OLD}"
  exit 2
fi

if ! jq -e . "${NEW}" >/dev/null 2>&1; then
  echo "Error: --new is not valid JSON: ${NEW}"
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

if [[ -n "${OUT_CSV_DIR}" ]]; then
  mkdir -p "${OUT_CSV_DIR}"
fi

if [[ -n "${OUT_MD_PATH}" ]]; then
  mkdir -p "$(dirname "${OUT_MD_PATH}")"
fi

JQ_FILTER_ARGS=()
if [[ -n "${FILTER}" ]]; then
  JQ_FILTER_ARGS+=(--slurpfile filter "${FILTER}")
fi
if [[ -n "${FILTER_MODE}" ]]; then
  JQ_FILTER_ARGS+=(--arg filter_mode "${FILTER_MODE}")
fi

# ---------------- Terminal report ----------------
jq -n -r --argjson top "${TOP}" "${JQ_FILTER_ARGS[@]}" --slurpfile old "${OLD}" --slurpfile new "${NEW}" '
  def nz: . // 0;
  def norm_ns(p): if (p|nz) == "" then "root" else p end;

  # Filter config (same structure as count_clients.sh)
  def f: (if ($filter|type) == "array" and ($filter|length) > 0 then $filter[0] else {} end);
  def mode_from_file: (f.mode // "exclude");
  def mode:
    if ($filter_mode? // "") != "" then $filter_mode else mode_from_file end;

  def excl: (f.exclude_namespaces // []);
  def nonprod: (f.non_production_namespaces // []);

  # Robust matcher: avoid any(.[]; ...) edge cases
  def matches_any($patterns; $s):
    reduce ($patterns[]? ) as $p (false; . or (try ($s | test($p)) catch false));

  def is_excluded($ns): matches_any(excl; $ns);
  def is_nonprod($ns): matches_any(nonprod; $ns);

  def ns_map(d):
    (d.by_namespace
      | map(
          . as $ns
          | norm_ns($ns.namespace_path) as $name
          | {
              namespace: $name,
              clients: ($ns.counts.clients | nz),
              mounts: ($ns.mounts | length),
              excluded: is_excluded($name),
              non_production: is_nonprod($name)
            }
        )
      | if mode == "exclude" then map(select(.excluded | not)) else . end
      | reduce .[] as $r ({}; .[$r.namespace] = $r)
    );

  def keys_union(a; b):
    ((a|keys) + (b|keys) | unique);

  def ns_deltas(oldm; newm):
    (keys_union(oldm; newm)
      | map(
          . as $k
          | (oldm[$k] // {clients:0,mounts:0,non_production:false}) as $o
          | (newm[$k] // {clients:0,mounts:0,non_production:false}) as $n
          | {
              namespace: $k,
              old_clients: ($o.clients|nz),
              new_clients: ($n.clients|nz),
              delta_clients: (($n.clients|nz) - ($o.clients|nz)),
              old_mounts: ($o.mounts|nz),
              new_mounts: ($n.mounts|nz),
              delta_mounts: (($n.mounts|nz) - ($o.mounts|nz)),
              non_production: ($n.non_production // $o.non_production // false)
            }
        )
      | sort_by(.delta_clients) | reverse
    );

  def total_clients_from_map(m): (m | to_entries | map(.value.clients|nz) | add // 0);

  ($old[0]) as $o
  | ($new[0]) as $n
  | (ns_map($o)) as $oldm
  | (ns_map($n)) as $newm
  | (total_clients_from_map($oldm)) as $old_total
  | (total_clients_from_map($newm)) as $new_total
  | ($new_total - $old_total) as $delta_total
  | (ns_deltas($oldm; $newm)) as $rows
  | ($rows | map(select(.delta_clients > 0))) as $added
  | ($rows | map(select(.delta_clients < 0))) as $removed
  | (($added | sort_by(.delta_clients) | reverse)[0:3] | map(.delta_clients) | add // 0) as $top3_inc
  | (($removed | map(select(.namespace | startswith("deleted namespace"))) | map(.delta_clients) | add) // 0) as $deleted_delta
  | ($rows | map(select(.non_production == true))) as $nonprod_rows

  | (
    (if ($filter|type) == "array" and ($filter|length) > 0 then
      "Filter\n" +
      "  mode: " + (mode|tostring) + "\n" +
      "  exclude_namespaces: " + (excl|tostring) + "\n" +
      "  non_production_namespaces: " + (nonprod|tostring) + "\n\n"
    else "" end) +

    "Overall (selected scope)\n" +
    "  old start_time: " + ($o.start_time|tostring) + "\n" +
    "  new start_time: " + ($n.start_time|tostring) + "\n" +
    "  old clients:    " + ($old_total|tostring) + "\n" +
    "  new clients:    " + ($new_total|tostring) + "\n" +
    "  delta clients:  " + ($delta_total|tostring) + "\n" +
    "  top 3 increases total: " + ($top3_inc|tostring) + " (offset by decreases)\n" +
    "  deleted namespaces net change: " + ($deleted_delta|tostring) + "\n" +
    (if $delta_total > 0 then "  trend:          increased\n\n"
     elif $delta_total < 0 then "  trend:          decreased\n\n"
     else "  trend:          unchanged\n\n"
     end) +

    ("Top namespaces increased (top " + ($top|tostring) + ")\n") +
    (
      ($added | sort_by(.delta_clients) | reverse)[0:$top]
      | if length == 0 then "  - none\n"
        else (map(
              "  - " + .namespace
              + (if mode=="highlight" and .non_production then "  [non-production]" else "" end)
              + "  " + (.old_clients|tostring) + " -> " + (.new_clients|tostring) + " (+" + (.delta_clients|tostring) + ")"
            ) | join("\n")) + "\n"
        end
    ) + "\n" +

    ("Top namespaces decreased (top " + ($top|tostring) + ")\n") +
    (
      ($removed | sort_by(.delta_clients))[0:$top]
      | if length == 0 then "  - none\n"
        else (map(
              "  - " + .namespace
              + (if mode=="highlight" and .non_production then "  [non-production]" else "" end)
              + "  " + (.old_clients|tostring) + " -> " + (.new_clients|tostring) + " (" + (.delta_clients|tostring) + ")"
            ) | join("\n")) + "\n"
        end
    ) + "\n" +

    (if mode=="highlight" and ($nonprod_rows|length) > 0 then
      ("Non-production movers (top " + ($top|tostring) + " by absolute change)\n") +
      (
        ($nonprod_rows
          | map(. + {abs_delta: (.delta_clients|abs)})
          | sort_by(.abs_delta) | reverse
        )[0:$top]
        | map("  - " + .namespace + "  " + (.old_clients|tostring) + " -> " + (.new_clients|tostring) + " (" + (.delta_clients|tostring) + ")")
        | join("\n")
      ) + "\n\n"
    else "" end)
  )
'

# ---------------- CSV export ----------------
if [[ -n "${OUT_CSV_DIR}" ]]; then
  jq -n -r "${JQ_FILTER_ARGS[@]}" --slurpfile old "${OLD}" --slurpfile new "${NEW}" '
    def nz: . // 0;
    def norm_ns(p): if (p|nz) == "" then "root" else p end;

    def f: (if ($filter|type) == "array" and ($filter|length) > 0 then $filter[0] else {} end);
    def mode_from_file: (f.mode // "exclude");
    def mode:
      if ($filter_mode? // "") != "" then $filter_mode else mode_from_file end;
    def excl: (f.exclude_namespaces // []);
    def nonprod: (f.non_production_namespaces // []);

    def matches_any($patterns; $s):
      reduce ($patterns[]? ) as $p (false; . or (try ($s | test($p)) catch false));

    def is_excluded($ns): matches_any(excl; $ns);
    def is_nonprod($ns): matches_any(nonprod; $ns);

    def ns_map(d):
      (d.by_namespace
        | map(
            . as $ns
            | norm_ns($ns.namespace_path) as $name
            | {
                namespace: $name,
                clients: ($ns.counts.clients | nz),
                mounts: ($ns.mounts | length),
                excluded: is_excluded($name),
                non_production: is_nonprod($name)
              }
          )
        | if mode == "exclude" then map(select(.excluded | not)) else . end
        | reduce .[] as $r ({}; .[$r.namespace] = $r)
      );

    def keys_union(a; b):
      ((a|keys) + (b|keys) | unique);

    ($old[0]) as $o
    | ($new[0]) as $n
    | (ns_map($o)) as $oldm
    | (ns_map($n)) as $newm
    | (["namespace","old_clients","new_clients","delta_clients","old_mounts","new_mounts","delta_mounts","non_production"] | @csv),
      (keys_union($oldm; $newm)[]
        as $k
        | ($oldm[$k] // {clients:0,mounts:0,non_production:false}) as $ov
        | ($newm[$k] // {clients:0,mounts:0,non_production:false}) as $nv
        | [
            $k,
            ($ov.clients|nz),
            ($nv.clients|nz),
            (($nv.clients|nz) - ($ov.clients|nz)),
            ($ov.mounts|nz),
            ($nv.mounts|nz),
            (($nv.mounts|nz) - ($ov.mounts|nz)),
            ($nv.non_production // $ov.non_production // false)
          ]
        | @csv
      )
  ' >"${OUT_CSV_DIR}/namespace_diff.csv"

  jq -n -r "${JQ_FILTER_ARGS[@]}" --slurpfile old "${OLD}" --slurpfile new "${NEW}" '
    def nz: . // 0;
    def norm_ns(p): if (p|nz) == "" then "root" else p end;

    def f: (if ($filter|type) == "array" and ($filter|length) > 0 then $filter[0] else {} end);
    def mode_from_file: (f.mode // "exclude");
    def mode:
      if ($filter_mode? // "") != "" then $filter_mode else mode_from_file end;
    def excl: (f.exclude_namespaces // []);
    def nonprod: (f.non_production_namespaces // []);

    def matches_any($patterns; $s):
      reduce ($patterns[]? ) as $p (false; . or (try ($s | test($p)) catch false));

    def is_excluded($ns): matches_any(excl; $ns);
    def is_nonprod($ns): matches_any(nonprod; $ns);

    def ns_map(d):
      (d.by_namespace
        | map(
            . as $ns
            | norm_ns($ns.namespace_path) as $name
            | {
                namespace: $name,
                clients: ($ns.counts.clients | nz),
                excluded: is_excluded($name),
                non_production: is_nonprod($name)
              }
          )
        | if mode == "exclude" then map(select(.excluded | not)) else . end
        | reduce .[] as $r ({}; .[$r.namespace] = $r)
      );

    def keys_union(a; b):
      ((a|keys) + (b|keys) | unique);

    def rows(oldm; newm):
      (keys_union(oldm; newm)
        | map(
            . as $k
            | (oldm[$k] // {clients:0,non_production:false}) as $o
            | (newm[$k] // {clients:0,non_production:false}) as $n
            | { namespace:$k, delta_clients: (($n.clients|nz) - ($o.clients|nz)) , non_production: ($n.non_production // $o.non_production // false) }
          )
      );

    def total_clients_from_map(m): (m | to_entries | map(.value.clients|nz) | add // 0);

    ($old[0]) as $o
    | ($new[0]) as $n
    | (ns_map($o)) as $oldm
    | (ns_map($n)) as $newm
    | (total_clients_from_map($oldm)) as $old_total
    | (total_clients_from_map($newm)) as $new_total
    | ($new_total - $old_total) as $delta_total
    | (rows($oldm; $newm)) as $all
    | ($all | map(select(.delta_clients > 0))) as $added
    | ($all | map(select(.delta_clients < 0))) as $removed
    | (($added | sort_by(.delta_clients) | reverse)[0:3] | map(.delta_clients) | add // 0) as $top3_inc
    | (($removed | map(select(.namespace | startswith("deleted namespace"))) | map(.delta_clients) | add) // 0) as $deleted_delta
    | (["filter_mode","old_start_time","new_start_time","old_clients","new_clients","delta_clients","top3_increases_total","deleted_namespaces_net_change"] | @csv),
      ([
        (mode|tostring),
        ($o.start_time|tostring),
        ($n.start_time|tostring),
        $old_total,
        $new_total,
        $delta_total,
        $top3_inc,
        $deleted_delta
      ] | @csv)
  ' >"${OUT_CSV_DIR}/summary.csv"

  echo "✅ Wrote CSV:"
  echo "  - ${OUT_CSV_DIR}/namespace_diff.csv"
  echo "  - ${OUT_CSV_DIR}/summary.csv"
fi

# ---------------- Markdown export ----------------
if [[ -n "${OUT_MD_PATH}" ]]; then
  jq -n -r --argjson top "${TOP}" "${JQ_FILTER_ARGS[@]}" --slurpfile old "${OLD}" --slurpfile new "${NEW}" '
    def nz: . // 0;
    def norm_ns(p): if (p|nz) == "" then "root" else p end;

    def f: (if ($filter|type) == "array" and ($filter|length) > 0 then $filter[0] else {} end);
    def mode_from_file: (f.mode // "exclude");
    def mode:
      if ($filter_mode? // "") != "" then $filter_mode else mode_from_file end;
    def excl: (f.exclude_namespaces // []);
    def nonprod: (f.non_production_namespaces // []);

    def matches_any($patterns; $s):
      reduce ($patterns[]? ) as $p (false; . or (try ($s | test($p)) catch false));

    def is_excluded($ns): matches_any(excl; $ns);
    def is_nonprod($ns): matches_any(nonprod; $ns);

    def ns_map(d):
      (d.by_namespace
        | map(
            . as $ns
            | norm_ns($ns.namespace_path) as $name
            | {
                namespace: $name,
                clients: ($ns.counts.clients | nz),
                mounts: ($ns.mounts | length),
                excluded: is_excluded($name),
                non_production: is_nonprod($name)
              }
          )
        | if mode == "exclude" then map(select(.excluded | not)) else . end
        | reduce .[] as $r ({}; .[$r.namespace] = $r)
      );

    def keys_union(a; b):
      ((a|keys) + (b|keys) | unique);

    def rows(oldm; newm):
      (keys_union(oldm; newm)
        | map(
            . as $k
            | (oldm[$k] // {clients:0,mounts:0,non_production:false}) as $o
            | (newm[$k] // {clients:0,mounts:0,non_production:false}) as $n
            | {
                namespace: $k,
                old_clients: ($o.clients|nz),
                new_clients: ($n.clients|nz),
                delta_clients: (($n.clients|nz) - ($o.clients|nz)),
                old_mounts: ($o.mounts|nz),
                new_mounts: ($n.mounts|nz),
                delta_mounts: (($n.mounts|nz) - ($o.mounts|nz)),
                non_production: ($n.non_production // $o.non_production // false)
              }
          )
        | sort_by(.delta_clients) | reverse
      );

    def total_clients_from_map(m): (m | to_entries | map(.value.clients|nz) | add // 0);

    ($old[0]) as $o
    | ($new[0]) as $n
    | (ns_map($o)) as $oldm
    | (ns_map($n)) as $newm
    | (total_clients_from_map($oldm)) as $old_total
    | (total_clients_from_map($newm)) as $new_total
    | ($new_total - $old_total) as $delta_total
    | (rows($oldm; $newm)) as $all
    | ($all | map(select(.delta_clients > 0))) as $added
    | ($all | map(select(.delta_clients < 0))) as $removed
    | (($added | sort_by(.delta_clients) | reverse)[0:3] | map(.delta_clients) | add // 0) as $top3_inc
    | (($removed | map(select(.namespace | startswith("deleted namespace"))) | map(.delta_clients) | add) // 0) as $deleted_delta

    | (
      "# Vault client diff report\n\n" +
      (if ($filter|type) == "array" and ($filter|length) > 0 then
        "## Filter\n\n" +
        "- mode: `" + (mode|tostring) + "`\n" +
        "- exclude_namespaces: `" + (excl|tostring) + "`\n" +
        "- non_production_namespaces: `" + (nonprod|tostring) + "`\n\n"
      else "" end) +

      "## Overall (selected scope)\n\n" +
      "- old start_time: `" + ($o.start_time|tostring) + "`\n" +
      "- new start_time: `" + ($n.start_time|tostring) + "`\n" +
      "- old clients: `" + ($old_total|tostring) + "`\n" +
      "- new clients: `" + ($new_total|tostring) + "`\n" +
      "- delta clients: `" + ($delta_total|tostring) + "`\n" +
      "- top 3 increases total: `" + ($top3_inc|tostring) + "`\n" +
      "- deleted namespaces net change: `" + ($deleted_delta|tostring) + "`\n\n" +

      "## Top increases\n\n" +
      "| namespace | old | new | delta | non_production |\n" +
      "|---|---:|---:|---:|---|\n" +
      (
        (($added | sort_by(.delta_clients) | reverse)[0:$top])
        | if length == 0 then "| _none_ |  |  |  |  |\n"
          else (map("| " + .namespace + " | " + (.old_clients|tostring) + " | " + (.new_clients|tostring) + " | +" + (.delta_clients|tostring) + " | " + (.non_production|tostring) + " |") | join("\n")) + "\n"
          end
      ) + "\n" +

      "## Top decreases\n\n" +
      "| namespace | old | new | delta | non_production |\n" +
      "|---|---:|---:|---:|---|\n" +
      (
        (($removed | sort_by(.delta_clients))[0:$top])
        | if length == 0 then "| _none_ |  |  |  |  |\n"
          else (map("| " + .namespace + " | " + (.old_clients|tostring) + " | " + (.new_clients|tostring) + " | " + (.delta_clients|tostring) + " | " + (.non_production|tostring) + " |") | join("\n")) + "\n"
          end
      ) + "\n" +

      "## Full namespace delta (top " + ($top|tostring) + " by change)\n\n" +
      "| namespace | old_clients | new_clients | delta_clients | old_mounts | new_mounts | delta_mounts | non_production |\n" +
      "|---|---:|---:|---:|---:|---:|---:|---|\n" +
      (
        $all[0:$top]
        | map("| " + .namespace
              + " | " + (.old_clients|tostring)
              + " | " + (.new_clients|tostring)
              + " | " + (.delta_clients|tostring)
              + " | " + (.old_mounts|tostring)
              + " | " + (.new_mounts|tostring)
              + " | " + (.delta_mounts|tostring)
              + " | " + (.non_production|tostring)
              + " |")
        | join("\n")
      ) + "\n"
    )
  ' >"${OUT_MD_PATH}"

  echo "✅ Wrote Markdown: ${OUT_MD_PATH}"
fi
# End of script
