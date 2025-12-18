#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./diff_vault_clients.sh --old <file1> --new <file2> [--top N] [--out-csv <dir>] [--out-md <path>]

What it does:
  - Validates JSON inputs
  - Compares overall totals from .total (unique client counts)
  - Compares totals per namespace (.by_namespace[].counts)
  - Shows deltas (increased/decreased) and top movers
  - Adds "exec proof" stats:
      - top 3 increases total (shows how much growth is concentrated)
      - deleted namespaces net change (shows lifecycle churn impact)
  - Markdown report includes a Key takeaway block

Requirements:
  - jq

Examples:
  ./diff_vault_clients.sh --old activity_counter_2023_2024.txt --new activity_counter_2024_2025.txt
  ./diff_vault_clients.sh --old a.txt --new b.txt --top 20 --out-csv ./out --out-md ./out/diff.md
USAGE
}

OLD=""
NEW=""
TOP=15
OUT_CSV_DIR=""
OUT_MD_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  --old)
    OLD="${2:-}"
    shift 2
    ;;
  --new)
    NEW="${2:-}"
    shift 2
    ;;
  --top)
    TOP="${2:-15}"
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

if [[ -n "${OUT_CSV_DIR}" ]]; then
  mkdir -p "${OUT_CSV_DIR}"
fi

if [[ -n "${OUT_MD_PATH}" ]]; then
  mkdir -p "$(dirname "${OUT_MD_PATH}")"
fi

# Print terminal report
jq -n -r --argjson top "$TOP" --slurpfile old "${OLD}" --slurpfile new "${NEW}" '
  def nz: . // 0;
  def norm_ns(p): if (p|nz) == "" then "root" else p end;

  def totals(d):
    {
      start_time: (d.start_time | tostring),
      clients: ((d.total.clients // 0) | nz)
    };

  def ns_map(d):
    (d.by_namespace
      | map({
          namespace: norm_ns(.namespace_path),
          clients: (.counts.clients | nz),
          mounts: (.mounts | length)
        })
      | reduce .[] as $r ({}; .[$r.namespace] = $r)
    );

  def keys_union(a; b):
    ((a|keys) + (b|keys) | unique);

  def ns_deltas(oldm; newm):
    (keys_union(oldm; newm)
      | map(
          . as $k
          | (oldm[$k] // {clients:0,mounts:0}) as $o
          | (newm[$k] // {clients:0,mounts:0}) as $n
          | {
              namespace: $k,
              old_clients: ($o.clients|nz),
              new_clients: ($n.clients|nz),
              delta_clients: (($n.clients|nz) - ($o.clients|nz)),
              old_mounts: ($o.mounts|nz),
              new_mounts: ($n.mounts|nz),
              delta_mounts: (($n.mounts|nz) - ($o.mounts|nz))
            }
        )
      | sort_by(.delta_clients) | reverse
    );

  ($old[0]) as $o
  | ($new[0]) as $n
  | (totals($o)) as $ot
  | (totals($n)) as $nt
  | ($nt.clients - $ot.clients) as $delta_total
  | (ns_map($o)) as $oldm
  | (ns_map($n)) as $newm
  | (ns_deltas($oldm; $newm)) as $rows
  | ($rows | map(select(.delta_clients > 0))) as $added
  | ($rows | map(select(.delta_clients < 0))) as $removed
  | (($added | sort_by(.delta_clients) | reverse)[0:3] | map(.delta_clients) | add // 0) as $top3_inc
  | (($removed | map(select(.namespace | startswith("deleted namespace"))) | map(.delta_clients) | add) // 0) as $deleted_delta

  | (
    "Overall (from .total)\n" +
    "  old start_time: " + ($ot.start_time) + "\n" +
    "  new start_time: " + ($nt.start_time) + "\n" +
    "  old clients:    " + ($ot.clients|tostring) + "\n" +
    "  new clients:    " + ($nt.clients|tostring) + "\n" +
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
        else (map("  - " + .namespace + "  " + (.old_clients|tostring) + " -> " + (.new_clients|tostring) + " (+" + (.delta_clients|tostring) + ")") | join("\n")) + "\n"
        end
    ) + "\n" +

    ("Top namespaces decreased (top " + ($top|tostring) + ")\n") +
    (
      ($removed | sort_by(.delta_clients))[0:$top]
      | if length == 0 then "  - none\n"
        else (map("  - " + .namespace + "  " + (.old_clients|tostring) + " -> " + (.new_clients|tostring) + " (" + (.delta_clients|tostring) + ")") | join("\n")) + "\n"
        end
    ) + "\n"
  )
'

# CSV export
if [[ -n "${OUT_CSV_DIR}" ]]; then
  jq -n -r --slurpfile old "${OLD}" --slurpfile new "${NEW}" '
    def nz: . // 0;
    def norm_ns(p): if (p|nz) == "" then "root" else p end;

    def ns_map(d):
      (d.by_namespace
        | map({
            namespace: norm_ns(.namespace_path),
            clients: (.counts.clients | nz),
            mounts: (.mounts | length)
          })
        | reduce .[] as $r ({}; .[$r.namespace] = $r)
      );

    def keys_union(a; b):
      ((a|keys) + (b|keys) | unique);

    ($old[0]) as $o
    | ($new[0]) as $n
    | (ns_map($o)) as $oldm
    | (ns_map($n)) as $newm
    | (["namespace","old_clients","new_clients","delta_clients","old_mounts","new_mounts","delta_mounts"] | @csv),
      (keys_union($oldm; $newm)[]
        as $k
        | ($oldm[$k] // {clients:0,mounts:0}) as $ov
        | ($newm[$k] // {clients:0,mounts:0}) as $nv
        | [
            $k,
            ($ov.clients|nz),
            ($nv.clients|nz),
            (($nv.clients|nz) - ($ov.clients|nz)),
            ($ov.mounts|nz),
            ($nv.mounts|nz),
            (($nv.mounts|nz) - ($ov.mounts|nz))
          ]
        | @csv
      )
  ' >"${OUT_CSV_DIR}/namespace_diff.csv"

  # Exec summary CSV (single row) for easy copy/paste into slides
  jq -n -r --slurpfile old "${OLD}" --slurpfile new "${NEW}" '
    def nz: . // 0;
    def norm_ns(p): if (p|nz) == "" then "root" else p end;

    def totals(d):
      { start_time: (d.start_time|tostring), clients: ((d.total.clients // 0) | nz) };

    def ns_map(d):
      (d.by_namespace
        | map({ namespace: norm_ns(.namespace_path), clients: (.counts.clients|nz) })
        | reduce .[] as $r ({}; .[$r.namespace] = $r)
      );

    def keys_union(a; b):
      ((a|keys) + (b|keys) | unique);

    def rows(oldm; newm):
      (keys_union(oldm; newm)
        | map(
            . as $k
            | (oldm[$k] // {clients:0}) as $o
            | (newm[$k] // {clients:0}) as $n
            | { namespace:$k, delta_clients: (($n.clients|nz) - ($o.clients|nz)) }
          )
      );

    ($old[0]) as $o
    | ($new[0]) as $n
    | (totals($o)) as $ot
    | (totals($n)) as $nt
    | ($nt.clients - $ot.clients) as $delta_total
    | (ns_map($o)) as $oldm
    | (ns_map($n)) as $newm
    | (rows($oldm; $newm)) as $all
    | ($all | map(select(.delta_clients > 0))) as $added
    | ($all | map(select(.delta_clients < 0))) as $removed
    | (($added | sort_by(.delta_clients) | reverse)[0:3] | map(.delta_clients) | add // 0) as $top3_inc
    | (($removed | map(select(.namespace | startswith("deleted namespace"))) | map(.delta_clients) | add) // 0) as $deleted_delta
    | (["old_start_time","new_start_time","old_clients","new_clients","delta_clients","top3_increases_total","deleted_namespaces_net_change"] | @csv),
      ([
        $ot.start_time,
        $nt.start_time,
        $ot.clients,
        $nt.clients,
        $delta_total,
        $top3_inc,
        $deleted_delta
      ] | @csv)
  ' >"${OUT_CSV_DIR}/summary.csv"

  echo "✅ Wrote CSV:"
  echo "  - ${OUT_CSV_DIR}/namespace_diff.csv"
  echo "  - ${OUT_CSV_DIR}/summary.csv"
fi

# Markdown export
if [[ -n "${OUT_MD_PATH}" ]]; then
  jq -n -r --argjson top "$TOP" --slurpfile old "${OLD}" --slurpfile new "${NEW}" '
    def nz: . // 0;
    def norm_ns(p): if (p|nz) == "" then "root" else p end;

    def totals(d):
      {
        start_time: (d.start_time | tostring),
        clients: ((d.total.clients // 0) | nz)
      };

    def ns_map(d):
      (d.by_namespace
        | map({
            namespace: norm_ns(.namespace_path),
            clients: (.counts.clients | nz),
            mounts: (.mounts | length)
          })
        | reduce .[] as $r ({}; .[$r.namespace] = $r)
      );

    def keys_union(a; b):
      ((a|keys) + (b|keys) | unique);

    def rows(oldm; newm):
      (keys_union(oldm; newm)
        | map(
            . as $k
            | (oldm[$k] // {clients:0,mounts:0}) as $o
            | (newm[$k] // {clients:0,mounts:0}) as $n
            | {
                namespace: $k,
                old_clients: ($o.clients|nz),
                new_clients: ($n.clients|nz),
                delta_clients: (($n.clients|nz) - ($o.clients|nz)),
                old_mounts: ($o.mounts|nz),
                new_mounts: ($n.mounts|nz),
                delta_mounts: (($n.mounts|nz) - ($o.mounts|nz))
              }
          )
        | sort_by(.delta_clients) | reverse
      );

    ($old[0]) as $o
    | ($new[0]) as $n
    | (totals($o)) as $ot
    | (totals($n)) as $nt
    | ($nt.clients - $ot.clients) as $delta_total
    | (ns_map($o)) as $oldm
    | (ns_map($n)) as $newm
    | (rows($oldm; $newm)) as $all
    | ($all | map(select(.delta_clients > 0))) as $added
    | ($all | map(select(.delta_clients < 0))) as $removed
    | (($added | sort_by(.delta_clients) | reverse)[0:3] | map(.delta_clients) | add // 0) as $top3_inc
    | (($removed | map(select(.namespace | startswith("deleted namespace"))) | map(.delta_clients) | add) // 0) as $deleted_delta

    | (
      "# Vault client diff report\n\n" +

      "## Overall\n\n" +
      "- old start_time: `" + ($ot.start_time) + "`\n" +
      "- new start_time: `" + ($nt.start_time) + "`\n" +
      "- old clients: `" + ($ot.clients|tostring) + "`\n" +
      "- new clients: `" + ($nt.clients|tostring) + "`\n" +
      "- delta clients: `" + ($delta_total|tostring) + "`\n" +
      "- top 3 increases total: `" + ($top3_inc|tostring) + "` (offset by decreases)\n" +
      "- deleted namespaces net change: `" + ($deleted_delta|tostring) + "`\n\n" +

      "## Key takeaway\n\n" +
      "Unique clients changed by **" + ($delta_total|tostring) + "** year over year (**" +
      ($ot.clients|tostring) + " → " + ($nt.clients|tostring) +
      "**). Most of the movement is concentrated in the largest few namespaces.\n\n" +

      "## Top increases\n\n" +
      "| namespace | old | new | delta |\n" +
      "|---|---:|---:|---:|\n" +
      (
        (($added | sort_by(.delta_clients) | reverse)[0:$top])
        | if length == 0 then "| _none_ |  |  |  |\n"
          else (map("| " + .namespace + " | " + (.old_clients|tostring) + " | " + (.new_clients|tostring) + " | +" + (.delta_clients|tostring) + " |") | join("\n")) + "\n"
          end
      ) + "\n" +

      "## Top decreases\n\n" +
      "| namespace | old | new | delta |\n" +
      "|---|---:|---:|---:|\n" +
      (
        (($removed | sort_by(.delta_clients))[0:$top])
        | if length == 0 then "| _none_ |  |  |  |\n"
          else (map("| " + .namespace + " | " + (.old_clients|tostring) + " | " + (.new_clients|tostring) + " | " + (.delta_clients|tostring) + " |") | join("\n")) + "\n"
          end
      ) + "\n" +

      "## Full namespace delta (top " + ($top|tostring) + " by change)\n\n" +
      "| namespace | old_clients | new_clients | delta_clients | old_mounts | new_mounts | delta_mounts |\n" +
      "|---|---:|---:|---:|---:|---:|---:|\n" +
      (
        $all[0:$top]
        | map("| " + .namespace
              + " | " + (.old_clients|tostring)
              + " | " + (.new_clients|tostring)
              + " | " + (.delta_clients|tostring)
              + " | " + (.old_mounts|tostring)
              + " | " + (.new_mounts|tostring)
              + " | " + (.delta_mounts|tostring)
              + " |")
        | join("\n")
      ) + "\n"
    )
  ' >"${OUT_MD_PATH}"

  echo "✅ Wrote Markdown: ${OUT_MD_PATH}"
fi
# End of script
