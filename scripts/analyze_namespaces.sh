#!/usr/bin/env bash
set -euo pipefail

# analyze_namespaces.sh
# Summarize namespaces from a Vault activity counter export:
# - namespaces.csv (namespace, clients, mounts, share_of_total)  -> ; delimiter, decimal comma
# - prefixes.csv   (prefix rollup + share_of_total, deleted collapsed) -> ; delimiter, decimal comma
# - namespaces.md  (human readable)
# - optional filter starter JSON (exclude.json)

TOP=20
OUT_DIR=""
FILE=""
EMIT_FILTER="false"
FILTER_OUT=""
SUGGEST_THRESHOLD="5" # percent, used for "candidate prefixes"

# --- color helpers (auto-disable when not a TTY) ---
NO_COLOR="${NO_COLOR:-}"
COLOR="${COLOR:-auto}" # auto|always|never

is_tty() { [[ -t 1 ]]; }

color_enabled() {
  case "${COLOR}" in
    always) return 0 ;;
    never)  return 1 ;;
    auto)
      [[ -n "${NO_COLOR}" ]] && return 1
      is_tty
      return $?
      ;;
    *) is_tty ;;
  esac
}

if color_enabled; then
  C_RESET=$'\e[0m'
  C_DIM=$'\e[2m'
  C_BOLD=$'\e[1m'
  C_OK=$'\e[32m'
  C_WARN=$'\e[33m'
  C_ERR=$'\e[31m'
  C_INFO=$'\e[36m'
  C_HDR=$'\e[35m'

  C_SCOPE_PROD=$'\e[32m'
  C_SCOPE_NONPROD=$'\e[33m'
  C_SCOPE_SHARED=$'\e[36m'
  C_SCOPE_OTHER=$'\e[90m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""
  C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""; C_HDR=""
  C_SCOPE_PROD=""; C_SCOPE_NONPROD=""; C_SCOPE_SHARED=""; C_SCOPE_OTHER=""
fi

say() { printf "%s\n" "$*"; }
usage() {
  cat <<'EOF'
Usage:
  ./scripts/analyze_namespaces.sh --file <activity_counter.txt> [options]

Options:
  --out-dir <dir>             Output directory (default: ./out_namespaces)
  --top <n>                   Top N rows to show in markdown (default: 20)
  --emit-filter <bool>        true|false (default: false)
  --filter-out <path>         Where to write the filter json (default: <out-dir>/exclude.json)
  --suggest-threshold <pct>   Percent threshold for suggesting prefixes (default: 5)
  -h, --help                  Show help

Example:
  ./scripts/analyze_namespaces.sh \
    --file ./input/activity_counter_2024_2025.txt \
    --out-dir ./2024_2025 \
    --top 25 \
    --suggest-threshold 10 \
    --emit-filter true
EOF
}

bool_normalize() {
  case "${1:-}" in
    true|TRUE|1|yes|YES) echo "true" ;;
    false|FALSE|0|no|NO|"") echo "false" ;;
    *) echo "false" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --top) TOP="${2:-}"; shift 2 ;;
    --emit-filter) EMIT_FILTER="$(bool_normalize "${2:-}")"; shift 2 ;;
    --filter-out) FILTER_OUT="${2:-}"; shift 2 ;;
    --suggest-threshold) SUGGEST_THRESHOLD="${2:-5}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${FILE}" ]]; then
  echo "Missing --file" >&2
  usage
  exit 2
fi

if [[ ! -f "${FILE}" ]]; then
  echo "File not found: ${FILE}" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not found in PATH" >&2
  exit 2
fi

if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="./out_namespaces"
fi

if ! [[ "${SUGGEST_THRESHOLD}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Error: --suggest-threshold must be a number (percent), got: ${SUGGEST_THRESHOLD}" >&2
  exit 2
fi

mkdir -p "${OUT_DIR}"

NAMESPACES_CSV="${OUT_DIR}/namespaces.csv"
PREFIXES_CSV="${OUT_DIR}/prefixes.csv"
OUT_MD="${OUT_DIR}/namespaces.md"

if [[ -z "${FILTER_OUT}" ]]; then
  FILTER_OUT="${OUT_DIR}/exclude.json"
fi

# ---------------------------
# 1) namespaces.csv (share_of_total, EU decimal comma, semicolon delimiter)
jq -r '
  def nz: . // 0;
  def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

  def share($v; $t):
    if ($t|tonumber) == 0 then 0
    else (((($v|tonumber) * 10000) / ($t|tonumber)) | floor) / 10000
    end;

  def fmt4($x):
    ($x|tostring) as $s
    | if ($s|test("\\.")) then
        ($s|split(".")) as $p
        | ($p[0] + "." + (($p[1] + "0000")[0:4]))
      else
        ($s + ".0000")
      end;

  def dec_comma($s): ($s|gsub("\\."; ","));
  def q($s): "\"" + ($s|tostring|gsub("\""; "\"\"")) + "\"";

  (.by_namespace // []) as $arr
  | ($arr | map(.counts.clients|nz) | add // 0) as $total
  | ($arr
      | map({
          namespace: (norm_ns),
          clients: (.counts.clients|nz),
          mounts: ((.mounts // [])|length),
          share_of_total: dec_comma(fmt4(share((.counts.clients|nz); $total)))
        })
      | sort_by(.clients) | reverse
    ) as $rows
  | ("namespace;clients;mounts;share_of_total"),
    ($rows[] | [ q(.namespace), (.clients|tostring), (.mounts|tostring), .share_of_total ] | join(";"))
' "${FILE}" > "${NAMESPACES_CSV}"

# ---------------------------
# 2) prefixes.csv (share_of_total, EU decimal comma, semicolon delimiter)
jq -r '
  def nz: . // 0;
  def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

  def prefix($ns):
    if $ns == "root" then "root"
    elif ($ns | startswith("deleted")) then "deleted"
    else ($ns | split("/")[0] + "/")
    end;

  def share($v; $t):
    if ($t|tonumber) == 0 then 0
    else (((($v|tonumber) * 10000) / ($t|tonumber)) | floor) / 10000
    end;

  def fmt4($x):
    ($x|tostring) as $s
    | if ($s|test("\\.")) then
        ($s|split(".")) as $p
        | ($p[0] + "." + (($p[1] + "0000")[0:4]))
      else
        ($s + ".0000")
      end;

  def dec_comma($s): ($s|gsub("\\."; ","));
  def q($s): "\"" + ($s|tostring|gsub("\""; "\"\"")) + "\"";

  (.by_namespace // []) as $arr
  | ($arr | map(.counts.clients|nz) | add // 0) as $total
  | ($arr
      | map({ namespace: (norm_ns), clients: (.counts.clients|nz) })
      | map({ prefix: prefix(.namespace), clients: .clients })
      | sort_by(.prefix)
      | group_by(.prefix)
      | map({
          prefix: .[0].prefix,
          namespaces_count: length,
          clients_sum: (map(.clients) | add // 0)
        })
      | map(. + { share_of_total: dec_comma(fmt4(share(.clients_sum; $total))) })
      | sort_by(.clients_sum) | reverse
    ) as $rows
  | ("prefix;namespaces_count;clients_sum;share_of_total"),
    ($rows[] | [ q(.prefix), (.namespaces_count|tostring), (.clients_sum|tostring), .share_of_total ] | join(";"))
' "${FILE}" > "${PREFIXES_CSV}"

# ---------------------------
# 3) namespaces.md (human readable, share_of_total with decimal comma)
jq -r --argjson top "${TOP}" '
  def nz: . // 0;
  def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

  def prefix($ns):
    if $ns == "root" then "root"
    elif ($ns | startswith("deleted")) then "deleted"
    else ($ns | split("/")[0] + "/")
    end;

  def share($v; $t):
    if ($t|tonumber) == 0 then 0
    else (((($v|tonumber) * 10000) / ($t|tonumber)) | floor) / 10000
    end;

  def fmt4($x):
    ($x|tostring) as $s
    | if ($s|test("\\.")) then
        ($s|split(".")) as $p
        | ($p[0] + "." + (($p[1] + "0000")[0:4]))
      else
        ($s + ".0000")
      end;

  def dec_comma($s): ($s|gsub("\\."; ","));

  (.by_namespace // []) as $arr
  | ($arr | map(.counts.clients|nz) | add // 0) as $total
  | ($arr | length) as $ns_count
  | ($arr | map(.mounts|length) | add // 0) as $mount_count

  | ($arr
      | map({
          namespace: (norm_ns),
          clients: (.counts.clients|nz),
          mounts: ((.mounts // [])|length),
          share_of_total: dec_comma(fmt4(share((.counts.clients|nz); $total)))
        })
      | sort_by(.clients) | reverse
    ) as $rows

  | ($arr
      | map({ namespace: (norm_ns), clients: (.counts.clients|nz) })
      | map({ prefix: prefix(.namespace), clients: .clients })
      | sort_by(.prefix)
      | group_by(.prefix)
      | map({
          prefix: .[0].prefix,
          namespaces_count: length,
          clients_sum: (map(.clients) | add // 0),
          share_of_total: dec_comma(fmt4(share((map(.clients)|add//0); $total)))
        })
      | sort_by(.clients_sum) | reverse
    ) as $pref

  | (
      "# Detected namespaces\n\n"
      + "## Summary\n\n"
      + "- namespaces: `" + ($ns_count|tostring) + "`\n"
      + "- mounts: `" + ($mount_count|tostring) + "`\n"
      + "- total_clients (sum of namespace clients): `" + ($total|tostring) + "`\n\n"

      + "## Top prefixes by clients\n\n"
      + "| prefix | namespaces | clients_sum | share_of_total |\n"
      + "|---|---:|---:|---:|\n"
      + (
          $pref[0:$top]
          | map("| " + .prefix + " | " + (.namespaces_count|tostring) + " | " + (.clients_sum|tostring) + " | " + .share_of_total + " |")
          | join("\n")
        ) + "\n\n"

      + "## Top namespaces by clients\n\n"
      + "| namespace | clients | mounts | share_of_total |\n"
      + "|---|---:|---:|---:|\n"
      + (
          $rows[0:$top]
          | map("| " + .namespace + " | " + (.clients|tostring) + " | " + (.mounts|tostring) + " | " + .share_of_total + " |")
          | join("\n")
        ) + "\n"
    )
' "${FILE}" > "${OUT_MD}"

# ---------------------------
# 4) Optional: emit a starter + suggested exclude filter JSON
# - Always includes starter non-prod prefixes
# - Adds suggested prefixes above threshold EXCEPT: root, prod/
# - Collapses deleted variants to ^deleted
if [[ "${EMIT_FILTER}" == "true" ]]; then
  jq --argjson suggest_threshold "${SUGGEST_THRESHOLD}" '
    def nz: . // 0;
    def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

    def prefix($ns):
      if $ns == "root" then "root"
      elif ($ns | startswith("deleted")) then "deleted"
      else ($ns | split("/")[0] + "/")
      end;

    def pct($v; $t):
      if ($t|tonumber) == 0 then 0
      else (((($v|tonumber) * 10000) / ($t|tonumber)) | floor) / 100
      end;

    (.by_namespace // []) as $arr
    | ($arr | map(.counts.clients|nz) | add // 0) as $total

    | ($arr
        | map({ ns: (norm_ns), clients: (.counts.clients|nz) })
        | map({ p: (prefix(.ns)), clients: .clients })
        | sort_by(.p)
        | group_by(.p)
        | map({ prefix: .[0].p, clients: (map(.clients)|add//0) })
        | map(. + { pct: pct(.clients; $total) })
        | sort_by(.clients) | reverse
      ) as $p_rows

    | ([
        "^deleted",
        "^dev/",
        "^dr/",
        "^sand/",
        "^sandbox/",
        "^test/"
      ]) as $starter

    | ($p_rows
        | map(select(.prefix != "root" and .prefix != "prod/" and .pct >= $suggest_threshold))
        | map(
            if .prefix == "deleted" then "^deleted"
            else "^" + .prefix
            end
          )
      ) as $suggested

    | ($starter + $suggested | unique) as $patterns

    | {
        mode: "exclude",
        exclude_namespaces: $patterns,
        non_production_namespaces: $patterns
      }
  ' "${FILE}" > "${FILTER_OUT}"
fi

# ---------------------------
# Terminal summary (human output)
summary="$(
  jq -r --argjson top "${TOP}" --argjson suggest_threshold "${SUGGEST_THRESHOLD}" '
    def nz: . // 0;
    def norm_ns: if (.namespace_path | nz) == "" then "root" else .namespace_path end;

    def is_deleted($ns): ($ns | test("^deleted"));
    def is_prod($ns): ($ns | test("^prod/"));
    def is_nonprod($ns):
      ($ns | test("^(sand/|dev/|test/|dr/|sandbox/)")) or is_deleted($ns);
    def is_shared($ns):
      ($ns == "root") or ($ns | test("^okta/")) or ($ns | test("^gitlab/"));
    def scope($ns):
      if is_prod($ns) then "prod"
      elif is_nonprod($ns) then "non-prod"
      elif is_shared($ns) then "shared"
      else "other"
      end;

    def prefix($ns):
      if $ns == "root" then "root"
      elif ($ns | startswith("deleted")) then "deleted"
      else ($ns | split("/")[0] + "/")
      end;

    def pct($v; $t):
      if ($t|tonumber) == 0 then 0
      else (((($v|tonumber) * 10000) / ($t|tonumber)) | floor) / 100
      end;

    (.by_namespace // []) as $arr
    | ($arr | map(.counts.clients|nz) | add // 0) as $total
    | ($arr | length) as $ns_count
    | ($arr | map(.mounts|length) | add // 0) as $mount_count

    | ($arr
        | map(
            (norm_ns) as $ns
            | {
                namespace: $ns,
                scope: scope($ns),
                clients: (.counts.clients|nz),
                mounts: ((.mounts // [])|length),
                pct: pct((.counts.clients|nz); $total)
              }
          )
        | sort_by(.clients) | reverse
      ) as $ns_rows

    | ($ns_rows
        | sort_by(.scope)
        | group_by(.scope)
        | map({
            scope: .[0].scope,
            namespaces: length,
            clients: (map(.clients)|add // 0),
            pct: pct((map(.clients)|add // 0); $total)
          })
        | sort_by(.clients) | reverse
      ) as $scope_rows

    | ($arr
        | map({ ns: (norm_ns), clients: (.counts.clients|nz) })
        | map({ p: (prefix(.ns)), clients: .clients })
        | sort_by(.p)
        | group_by(.p)
        | map({
            prefix: .[0].p,
            namespaces: length,
            clients: (map(.clients) | add // 0)
          })
        | map(. + { pct: pct(.clients; $total) })
        | sort_by(.clients) | reverse
      ) as $p_rows

    | ($p_rows
        | map(select(.prefix != "root" and .prefix != "prod/" and .pct >= $suggest_threshold))
      ) as $candidates

    | (
        "File summary\n"
        + "  start_time: " + ((.start_time // "")|tostring) + "\n"
        + "  namespaces: " + ($ns_count|tostring) + "\n"
        + "  mounts: " + ($mount_count|tostring) + "\n"
        + "  total_clients: " + ($total|tostring) + "\n\n"

        + "Scope totals\n"
        + (
            $scope_rows
            | map("  - " + .scope
                  + "  clients=" + (.clients|tostring)
                  + "  pct=" + (.pct|tostring) + "%"
                  + "  namespaces=" + (.namespaces|tostring))
            | join("\n")
          ) + "\n\n"

        + "Top prefixes by clients (top " + ($top|tostring) + ")\n"
        + (
            ($p_rows[0:$top]
              | map("  - " + .prefix
                    + "  clients=" + (.clients|tostring)
                    + "  pct=" + (.pct|tostring) + "%"
                    + "  namespaces=" + (.namespaces|tostring))
              | join("\n")
            ) + "\n\n"
          )

        + "Top namespaces by clients (top " + ($top|tostring) + ")\n"
        + (
            ($ns_rows[0:$top]
              | map("  - " + .namespace
                    + "  scope=" + .scope
                    + "  clients=" + (.clients|tostring)
                    + "  mounts=" + (.mounts|tostring)
                    + "  pct=" + (.pct|tostring) + "%")
              | join("\n")
            ) + "\n\n"
          )

        + "Candidate prefixes over threshold (for filter review)\n"
        + (
            if ($candidates|length) == 0 then
              "  - none\n"
            else
              ($candidates
                | map("  - " + .prefix
                      + "  clients=" + (.clients|tostring)
                      + "  pct=" + (.pct|tostring) + "%"
                      + "  namespaces=" + (.namespaces|tostring))
                | join("\n")) + "\n"
            end
          )
      )
  ' "${FILE}"
)"

print_intro() {
  printf "%b\n" "${C_HDR}${C_BOLD}🔎 Namespace analysis${C_RESET}"
  printf "%b\n" "${C_DIM}  file: ${FILE}${C_RESET}"
  printf "%b\n" "${C_DIM}  out : ${OUT_DIR}${C_RESET}"
  printf "\n"
}

colorize_summary() {
  # macOS/BSD awk safe: no match(..., ..., array)
  awk \
    -v reset="${C_RESET}" \
    -v bold="${C_BOLD}" \
    -v dim="${C_DIM}" \
    -v info="${C_INFO}" \
    -v hdr="${C_HDR}" \
    -v prod="${C_SCOPE_PROD}" \
    -v nonprod="${C_SCOPE_NONPROD}" \
    -v shared="${C_SCOPE_SHARED}" \
    -v other="${C_SCOPE_OTHER}" \
    '{
      line=$0

      # Section headers
      if (line ~ /^File summary$/ ||
          line ~ /^Scope totals$/ ||
          line ~ /^Top prefixes by clients/ ||
          line ~ /^Top namespaces by clients/ ||
          line ~ /^Candidate prefixes over threshold/) {
        line = info bold line reset
      }

      # Color scope totals lines (the token after "- ")
      if (line ~ /^[[:space:]]*-[[:space:]]+prod[[:space:]]/) {
        sub(/- prod /, "- " prod "prod" reset " ", line)
      } else if (line ~ /^[[:space:]]*-[[:space:]]+non-prod[[:space:]]/) {
        sub(/- non-prod /, "- " nonprod "non-prod" reset " ", line)
      } else if (line ~ /^[[:space:]]*-[[:space:]]+shared[[:space:]]/) {
        sub(/- shared /, "- " shared "shared" reset " ", line)
      } else if (line ~ /^[[:space:]]*-[[:space:]]+other[[:space:]]/) {
        sub(/- other /, "- " other "other" reset " ", line)
      }

      # Color scope= tokens in the namespace list
      gsub(/scope=prod/, "scope=" prod "prod" reset, line)
      gsub(/scope=non-prod/, "scope=" nonprod "non-prod" reset, line)
      gsub(/scope=shared/, "scope=" shared "shared" reset, line)
      gsub(/scope=other/, "scope=" other "other" reset, line)

      print line
    }'
}

print_intro
if color_enabled; then
  printf "%s\n" "${summary}" | colorize_summary
else
  printf "%s\n" "${summary}"
fi

printf "\n"
printf "%b\n" "${C_OK}${C_BOLD}✅ Wrote:${C_RESET}"
printf "  - %s\n" "${NAMESPACES_CSV}"
printf "  - %s\n" "${PREFIXES_CSV}"
printf "  - %s\n" "${OUT_MD}"
if [[ "${EMIT_FILTER}" == "true" ]]; then
  printf "  - %s\n" "${FILTER_OUT}"
fi
