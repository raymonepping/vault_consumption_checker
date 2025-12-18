#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./count_vault_clients.sh --file <path> [--top N] [--out-csv <dir>] [--out-md <path>]

What it does:
  - Validates JSON
  - Sums totals across namespaces and mounts:
      clients, entity_clients, non_entity_clients, acme_clients, secret_syncs
  - Compares computed sums with .total in the file
  - Shows top namespaces and top mounts by clients
  - Reconciliation: flags namespaces where mounts_sum != namespace_total (and shows mount breakdown)
  - Optional exports:
      --out-csv <dir> : writes CSV files (namespaces, mounts, reconciliation)
      --out-md  <path>: writes a Markdown report (tables)

Requirements:
  - jq

Examples:
  ./count_vault_clients.sh --file usage_report.txt
  ./count_vault_clients.sh --file usage_report.txt --top 15
  ./count_vault_clients.sh --file usage_report.txt --out-csv ./out
  ./count_vault_clients.sh --file usage_report.txt --out-md ./out/report.md
  ./count_vault_clients.sh --file usage_report.txt --out-csv ./out --out-md ./out/report.md
USAGE
}

FILE=""
TOP=10
OUT_CSV_DIR=""
OUT_MD_PATH=""

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

# Validate JSON
if ! jq -e . "${FILE}" >/dev/null 2>&1; then
  echo "Error: file is not valid JSON: ${FILE}"
  exit 2
fi

if [[ -n "${OUT_CSV_DIR}" ]]; then
  mkdir -p "${OUT_CSV_DIR}"
fi

if [[ -n "${OUT_MD_PATH}" ]]; then
  mkdir -p "$(dirname "${OUT_MD_PATH}")"
fi

# -------- Terminal summary (still the default) --------
jq -r --argjson top "$TOP" '
  def nz: . // 0;

  def totals_from_namespaces:
    {
      acme_clients:       (.by_namespace | map(.counts.acme_clients       | nz) | add // 0),
      clients:            (.by_namespace | map(.counts.clients            | nz) | add // 0),
      entity_clients:     (.by_namespace | map(.counts.entity_clients     | nz) | add // 0),
      non_entity_clients: (.by_namespace | map(.counts.non_entity_clients | nz) | add // 0),
      secret_syncs:       (.by_namespace | map(.counts.secret_syncs       | nz) | add // 0)
    };

  def totals_from_mounts:
    {
      acme_clients:       (.by_namespace | map(.mounts[]? | .counts.acme_clients       | nz) | add // 0),
      clients:            (.by_namespace | map(.mounts[]? | .counts.clients            | nz) | add // 0),
      entity_clients:     (.by_namespace | map(.mounts[]? | .counts.entity_clients     | nz) | add // 0),
      non_entity_clients: (.by_namespace | map(.mounts[]? | .counts.non_entity_clients | nz) | add // 0),
      secret_syncs:       (.by_namespace | map(.mounts[]? | .counts.secret_syncs       | nz) | add // 0)
    };

  def norm_ns:
    if (.namespace_path | nz) == "" then "root" else .namespace_path end;

  def ns_rows:
    (.by_namespace
      | map({
          namespace: (norm_ns),
          namespace_id: (.namespace_id | nz),
          mounts: (.mounts | length),
          clients: (.counts.clients | nz),
          entity_clients: (.counts.entity_clients | nz),
          non_entity_clients: (.counts.non_entity_clients | nz),
          acme_clients: (.counts.acme_clients | nz),
          secret_syncs: (.counts.secret_syncs | nz)
        })
      | sort_by(.clients) | reverse
    );

  def mount_rows:
    ([.by_namespace[] as $ns
      | ($ns | norm_ns) as $nspath
      | $ns.mounts[]?
      | {
          namespace: $nspath,
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

  def reconcile_rows:
    (.by_namespace
      | map(
          . as $ns
          | ($ns | norm_ns) as $name
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
      | ($ns.counts.clients // 0) as $ns_clients
      | (($ns.mounts | map(.counts.clients // 0) | add) // 0) as $m_clients
      | ($m_clients - $ns_clients) as $delta
      | select($delta != 0)
      | {
          namespace: $name,
          delta: $delta,
          namespace_clients: $ns_clients,
          mounts_clients_sum: $m_clients,
          mounts_breakdown: (
            $ns.mounts
            | sort_by(.counts.clients // 0) | reverse
            | map("    * " + (.mount_path | nz) + " (" + (.mount_type | nz) + ") clients=" + ((.counts.clients // 0)|tostring))
            | join("\n")
          )
        }
    ]);

  def diff(a; b):
    {
      acme_clients:       ((a.acme_clients       | nz) - (b.acme_clients       | nz)),
      clients:            ((a.clients            | nz) - (b.clients            | nz)),
      entity_clients:     ((a.entity_clients     | nz) - (b.entity_clients     | nz)),
      non_entity_clients: ((a.non_entity_clients | nz) - (b.non_entity_clients | nz)),
      secret_syncs:       ((a.secret_syncs       | nz) - (b.secret_syncs       | nz))
    };

  . as $doc
  | (totals_from_namespaces) as $ns_tot
  | (totals_from_mounts) as $m_tot
  | ($doc.total // {}) as $reported
  | ($doc.by_namespace | length) as $ns_count
  | ($doc.by_namespace | map(.mounts | length) | add // 0) as $mount_count
  | (ns_rows) as $ns_rows
  | (mount_rows) as $mount_rows
  | (reconcile_rows) as $recon
  | (reconcile_details) as $recon_details

  | (
      "File summary\n" +
      "  start_time:   " + ($doc.start_time | tostring) + "\n" +
      "  namespaces:   " + ($ns_count | tostring) + "\n" +
      "  mounts:       " + ($mount_count | tostring) + "\n\n" +

      "Totals (computed from namespaces)\n" +
      "  clients:            " + ($ns_tot.clients | tostring) + "\n" +
      "  entity_clients:     " + ($ns_tot.entity_clients | tostring) + "\n" +
      "  non_entity_clients: " + ($ns_tot.non_entity_clients | tostring) + "\n" +
      "  acme_clients:       " + ($ns_tot.acme_clients | tostring) + "\n" +
      "  secret_syncs:       " + ($ns_tot.secret_syncs | tostring) + "\n\n" +

      "Totals (computed from mounts)\n" +
      "  clients:            " + ($m_tot.clients | tostring) + "\n" +
      "  entity_clients:     " + ($m_tot.entity_clients | tostring) + "\n" +
      "  non_entity_clients: " + ($m_tot.non_entity_clients | tostring) + "\n" +
      "  acme_clients:       " + ($m_tot.acme_clients | tostring) + "\n" +
      "  secret_syncs:       " + ($m_tot.secret_syncs | tostring) + "\n\n" +

      "Totals (reported in file: .total)\n" +
      "  clients:            " + (($reported.clients | nz) | tostring) + "\n" +
      "  entity_clients:     " + (($reported.entity_clients | nz) | tostring) + "\n" +
      "  non_entity_clients: " + (($reported.non_entity_clients | nz) | tostring) + "\n" +
      "  acme_clients:       " + (($reported.acme_clients | nz) | tostring) + "\n" +
      "  secret_syncs:       " + (($reported.secret_syncs | nz) | tostring) + "\n\n" +

      "Validation (computed minus reported)\n" +
      "  namespaces - reported: " + (diff($ns_tot; $reported) | tostring) + "\n" +
      "  mounts     - reported: " + (diff($m_tot; $reported) | tostring) + "\n\n" +

      "Reconciliation (namespaces where mounts_sum != namespace_total)\n" +
      (if ($recon | length) == 0
       then "  - none\n\n"
       else (
          ($recon[0:$top]
           | map("  - " + .namespace
                 + "  namespace=" + (.namespace_clients|tostring)
                 + "  mounts_sum=" + (.mounts_clients_sum|tostring)
                 + "  delta=" + (.delta|tostring)
                 + "  mounts=" + (.mounts|tostring))
           | join("\n")
          ) + "\n\n" +
          "Reconciliation details\n" +
          (
            $recon_details[0:$top]
            | map(
                "  - " + .namespace
                + "  delta=" + (.delta|tostring)
                + " (namespace=" + (.namespace_clients|tostring)
                + ", mounts_sum=" + (.mounts_clients_sum|tostring) + ")\n"
                + .mounts_breakdown
              )
            | join("\n\n")
          ) + "\n\n"
        )
      end) +

      ("Top namespaces by clients (top " + ($top|tostring) + ")\n") +
      (
        $ns_rows[0:$top]
        | map("  - " + .namespace + "  clients=" + (.clients|tostring) + "  mounts=" + (.mounts|tostring))
        | join("\n")
      ) + "\n\n" +

      ("Top mounts by clients (top " + ($top|tostring) + ")\n") +
      (
        $mount_rows[0:$top]
        | map("  - " + .namespace + "  " + .mount_path + " (" + .mount_type + ")" + "  clients=" + (.clients|tostring))
        | join("\n")
      ) + "\n"
    )
' "$FILE"

# -------- CSV exports --------
if [[ -n "${OUT_CSV_DIR}" ]]; then
  # Namespaces CSV
  jq -r '
    def nz: . // 0;
    def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;
    (["namespace","namespace_id","mounts","clients","entity_clients","non_entity_clients","acme_clients","secret_syncs"] | @csv),
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
        }
      | [.namespace,.namespace_id,.mounts,.clients,.entity_clients,.non_entity_clients,.acme_clients,.secret_syncs] | @csv
    )
  ' "$FILE" >"${OUT_CSV_DIR}/namespaces.csv"

  # Mounts CSV
  jq -r '
    def nz: . // 0;
    def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;
    (["namespace","mount_path","mount_type","clients","entity_clients","non_entity_clients","acme_clients","secret_syncs"] | @csv),
    (.by_namespace[] as $ns
      | ($ns | norm_ns) as $nspath
      | $ns.mounts[]?
      | {
          namespace: $nspath,
          mount_path: (.mount_path | nz),
          mount_type: (.mount_type | nz),
          clients: (.counts.clients | nz),
          entity_clients: (.counts.entity_clients | nz),
          non_entity_clients: (.counts.non_entity_clients | nz),
          acme_clients: (.counts.acme_clients | nz),
          secret_syncs: (.counts.secret_syncs | nz)
        }
      | [.namespace,.mount_path,.mount_type,.clients,.entity_clients,.non_entity_clients,.acme_clients,.secret_syncs] | @csv
    )
  ' "$FILE" >"${OUT_CSV_DIR}/mounts.csv"

  # Reconciliation CSV
  jq -r '
    def nz: . // 0;
    def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;
    (["namespace","namespace_clients","mounts_clients_sum","delta","mounts"] | @csv),
    (.by_namespace[]
      | . as $ns
      | ($ns | norm_ns) as $name
      | ($ns.counts.clients // 0) as $ns_clients
      | (($ns.mounts | map(.counts.clients // 0) | add) // 0) as $m_clients
      | {
          namespace: $name,
          namespace_clients: $ns_clients,
          mounts_clients_sum: $m_clients,
          delta: ($m_clients - $ns_clients),
          mounts: ($ns.mounts | length)
        }
      | select(.delta != 0)
      | [.namespace,.namespace_clients,.mounts_clients_sum,.delta,.mounts] | @csv
    )
  ' "$FILE" >"${OUT_CSV_DIR}/reconciliation.csv"

  # Reconciliation mount breakdown CSV (only namespaces where delta != 0)
  jq -r '
    def nz: . // 0;
    def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

    (["namespace","namespace_clients","mounts_clients_sum","delta","mount_path","mount_type","clients","entity_clients","non_entity_clients","acme_clients","secret_syncs"] | @csv),
    (
      .by_namespace[] as $ns
      | ($ns | norm_ns) as $name
      | ($ns.counts.clients // 0) as $ns_clients
      | (($ns.mounts | map(.counts.clients // 0) | add) // 0) as $m_clients
      | ($m_clients - $ns_clients) as $delta
      | select($delta != 0)
      | $ns.mounts[]? as $m
      | [
          $name,
          $ns_clients,
          $m_clients,
          $delta,
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

  echo "  - ${OUT_CSV_DIR}/reconciliation_mounts.csv"

  echo "✅ Wrote CSV:"
  echo "  - ${OUT_CSV_DIR}/namespaces.csv"
  echo "  - ${OUT_CSV_DIR}/mounts.csv"
  echo "  - ${OUT_CSV_DIR}/reconciliation.csv"
fi

# -------- Markdown export --------
if [[ -n "${OUT_MD_PATH}" ]]; then
  jq -r --argjson top "$TOP" '
    def nz: . // 0;
    def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

    def ns_rows:
      (.by_namespace
        | map({
            namespace: (norm_ns),
            mounts: (.mounts | length),
            clients: (.counts.clients | nz)
          })
        | sort_by(.clients) | reverse
      );

    def mount_rows:
      ([.by_namespace[] as $ns
        | ($ns | norm_ns) as $nspath
        | $ns.mounts[]?
        | {
            namespace: $nspath,
            mount_path: (.mount_path | nz),
            mount_type: (.mount_type | nz),
            clients: (.counts.clients | nz)
          }]
        | sort_by(.clients) | reverse
      );

    def reconcile_rows:
      (.by_namespace
        | map(
            . as $ns
            | ($ns | norm_ns) as $name
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

    . as $doc
    | (ns_rows) as $ns
    | (mount_rows) as $m
    | (reconcile_rows) as $r

    | (
      "# Vault client count report\n\n" +
      "- File: `" + ($doc | tostring | .? ) + "`\n"
    )
  ' "$FILE" >/dev/null 2>&1 || true

  # Build MD with a separate jq call (avoid weird quoting + keep it clean)
  jq -r --argjson top "$TOP" '
    def nz: . // 0;
    def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

    def totals_from_namespaces:
      {
        clients:            (.by_namespace | map(.counts.clients            | nz) | add // 0),
        entity_clients:     (.by_namespace | map(.counts.entity_clients     | nz) | add // 0),
        non_entity_clients: (.by_namespace | map(.counts.non_entity_clients | nz) | add // 0),
        acme_clients:       (.by_namespace | map(.counts.acme_clients       | nz) | add // 0),
        secret_syncs:       (.by_namespace | map(.counts.secret_syncs       | nz) | add // 0)
      };

    def totals_from_mounts:
      {
        clients:            (.by_namespace | map(.mounts[]? | .counts.clients            | nz) | add // 0),
        entity_clients:     (.by_namespace | map(.mounts[]? | .counts.entity_clients     | nz) | add // 0),
        non_entity_clients: (.by_namespace | map(.mounts[]? | .counts.non_entity_clients | nz) | add // 0),
        acme_clients:       (.by_namespace | map(.mounts[]? | .counts.acme_clients       | nz) | add // 0),
        secret_syncs:       (.by_namespace | map(.mounts[]? | .counts.secret_syncs       | nz) | add // 0)
      };

    def ns_rows:
      (.by_namespace
        | map({
            namespace: (norm_ns),
            mounts: (.mounts | length),
            clients: (.counts.clients | nz)
          })
        | sort_by(.clients) | reverse
      );

    def mount_rows:
      ([.by_namespace[] as $ns
        | ($ns | norm_ns) as $nspath
        | $ns.mounts[]?
        | {
            namespace: $nspath,
            mount_path: (.mount_path | nz),
            mount_type: (.mount_type | nz),
            clients: (.counts.clients | nz)
          }]
        | sort_by(.clients) | reverse
      );

    def reconcile_rows:
      (.by_namespace
        | map(
            . as $ns
            | ($ns | norm_ns) as $name
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

      "## Summary\n\n" +
      "- start_time: `" + ($doc.start_time | tostring) + "`\n" +
      "- namespaces: `" + ($ns_count | tostring) + "`\n" +
      "- mounts: `" + ($mount_count | tostring) + "`\n\n" +

      "## Totals\n\n" +
      "| Source | clients | entity_clients | non_entity_clients | acme_clients | secret_syncs |\n" +
      "|---|---:|---:|---:|---:|---:|\n" +
      "| Namespaces (computed) | " + ($ns_tot.clients|tostring) + " | " + ($ns_tot.entity_clients|tostring) + " | " + ($ns_tot.non_entity_clients|tostring) + " | " + ($ns_tot.acme_clients|tostring) + " | " + ($ns_tot.secret_syncs|tostring) + " |\n" +
      "| Mounts (computed) | " + ($m_tot.clients|tostring) + " | " + ($m_tot.entity_clients|tostring) + " | " + ($m_tot.non_entity_clients|tostring) + " | " + ($m_tot.acme_clients|tostring) + " | " + ($m_tot.secret_syncs|tostring) + " |\n" +
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
        | map("| " + .namespace + " | " + (.clients|tostring) + " | " + (.mounts|tostring) + " |")
        | join("\n")
      ) + "\n\n" +

      "## Top mounts by clients\n\n" +
      "| namespace | mount_path | mount_type | clients |\n" +
      "|---|---|---|---:|\n" +
      (
        $m[0:$top]
        | map("| " + .namespace + " | " + .mount_path + " | " + .mount_type + " | " + (.clients|tostring) + " |")
        | join("\n")
      ) + "\n"
    )
  ' "$FILE" >"${OUT_MD_PATH}"

  echo "✅ Wrote Markdown: ${OUT_MD_PATH}"
fi
