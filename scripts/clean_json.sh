#!/usr/bin/env bash
set -euo pipefail

# json_cleaning.sh
# Cleans Vault-ish exports that contain non-JSON marker lines like:
#   ### NAMESPACE: xyz ###
# Produces ONE JSON object output:
# - If input contains multiple JSON docs (stream/NDJSON-ish), it slurps and collapses to the best object.
# - If input is a JSON array, it collapses the array to the best object.
# - If input is a single object, it writes it as-is.

usage() {
  cat <<'EOF'
Usage:
  ./scripts/json_cleaning.sh --in <path> [--out <path>] [--mode strip|ndjson-auto] [--force true|false]

Options:
  --in <path>           Input file (required)
  --out <path>          Output file (default: <in>.clean.json)
  --mode <mode>         strip       : remove marker lines only, keep structure (may still be invalid JSON)
                        ndjson-auto  : strip markers, then collapse multi-doc/array to ONE object (default)
  --force <bool>        Overwrite output if exists (default: false)
  --help                Show help
EOF
}

IN=""
OUT=""
MODE="ndjson-auto"
FORCE="false"

bool_norm() {
  case "${1:-}" in
    true|TRUE|1|yes|YES) echo "true" ;;
    false|FALSE|0|no|NO|"") echo "false" ;;
    *) echo "false" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) IN="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-ndjson-auto}"; shift 2 ;;
    --force) FORCE="$(bool_norm "${2:-false}")"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "${IN}" ]] || { echo "Error: --in is required" >&2; exit 2; }
[[ -f "${IN}" ]] || { echo "Error: input not found: ${IN}" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required (brew install jq)" >&2; exit 2; }

if [[ -z "${OUT}" ]]; then
  OUT="${IN}.clean.json"
fi

if [[ -e "${OUT}" && "${FORCE}" != "true" ]]; then
  echo "Error: output exists: ${OUT} (use --force true)" >&2
  exit 2
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.stripped" "$tmp.slurped" "$tmp.one"' EXIT

# 1) Strip obvious marker lines
awk '
  /^[[:space:]]*###([[:space:]]+NAMESPACE:.*)?###?[[:space:]]*$/ { next }
  { print }
' "${IN}" > "${tmp}.stripped"

removed_count="$(
  awk '
    /^[[:space:]]*###([[:space:]]+NAMESPACE:.*)?###?[[:space:]]*$/ { c++ }
    END { print c+0 }
  ' "${IN}"
)"
[[ -n "${removed_count}" ]] || removed_count="0"

# If mode is strip only, just output stripped and exit (may still be invalid JSON).
# ---- strip mode ----
if [[ "${MODE}" == "strip" ]]; then
  mv "${tmp}.stripped" "${OUT}"

  valid_json="false"
  output_type="n/a"
  if jq -e . "${OUT}" >/dev/null 2>&1; then
    valid_json="true"
    output_type="$(jq -r 'type' "${OUT}")"
  fi

  echo "✅ Stripped markers only: ${OUT}"
  echo "   - removed namespace markers: ${removed_count}"
  echo "   - output_type: ${output_type}"
  echo "   - valid_json: ${valid_json}"
  if [[ "${valid_json}" != "true" ]]; then
    echo "   - note: output may still not be valid JSON (stream/NDJSON/etc.)"
  fi
  exit 0
fi

# 2) Try to parse as a stream of JSON values. jq -s will:
# - read 1 object -> [ {..} ]
# - read 1 array  -> [ [..] ]
# - read many objs-> [ {..}, {..}, ... ]
if ! jq -s '.' "${tmp}.stripped" > "${tmp}.slurped" 2>/dev/null; then
  echo "❌ Could not parse JSON even after stripping markers."
  echo "   - removed namespace markers: ${removed_count}"
  echo "   Inspect:"
  echo "   nl -ba '${tmp}.stripped' | sed -n '1,80p'"
  exit 2
fi

# 3) Collapse to ONE object
# Scoring prefers the report with the highest total.clients (fallbacks included).
jq '
  def score:
    ( .total.clients? // .total.distinct_entities? // .total.non_entity_tokens? // 0 );

  def to_obj:
    if type == "object" then .
    elif type == "array" then
      (map(select(type=="object")) | if length==0 then {} else max_by(score) end)
    else {} end;

  if type != "array" then
    {}
  else
    if length == 0 then
      {}
    elif length == 1 then
      (.[0] | to_obj)
    else
      (map(to_obj) | map(select(type=="object")) | if length==0 then {} else max_by(score) end)
    end
  end
' "${tmp}.slurped" > "${tmp}.one"

# Sanity: ensure we wrote exactly one JSON object with expected-ish shape
if ! jq -e 'type=="object"' "${tmp}.one" >/dev/null 2>&1; then
  echo "❌ Cleaner produced non-object output unexpectedly."
  exit 2
fi

mv "${tmp}.one" "${OUT}"

# Output validation (should always be valid here)
if ! jq -e . "${OUT}" >/dev/null 2>&1; then
  echo "❌ Output file failed JSON validation unexpectedly: ${OUT}"
  exit 2
fi

echo "✅ Clean JSON written (collapsed to one object): ${OUT}"
echo "   - removed namespace markers: ${removed_count}"
echo "   - input docs detected: $(jq -r 'length' "${tmp}.slurped")"
echo "   - output_type: $(jq -r 'type' "${OUT}")"
echo "   - valid_json: true"
