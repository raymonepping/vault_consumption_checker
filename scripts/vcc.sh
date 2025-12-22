#!/usr/bin/env bash
set -euo pipefail

# vcc.sh
# Instructor script for vault_consumption_checker:
# - analyze namespaces
# - count clients
# - diff clients
# - optional md -> docx conversion
# - profiles via config json
# - optional: shell completions installer (zsh, bash)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ANALYZE="${SCRIPT_DIR}/analyze_namespaces.sh"
COUNT="${SCRIPT_DIR}/count_clients.sh"
DIFF="${SCRIPT_DIR}/diff_clients.sh"
MD2DOCX="${SCRIPT_DIR}/md_to_docx.mjs"

DEFAULT_CONFIG="${ROOT_DIR}/config/vcc.config.json"

# Global default (can be overridden by profile or CLI)
ENTITLEMENT=""

# Completions sources
COMPLETIONS_DIR="${SCRIPT_DIR}/completions"
ZSH_COMPLETION_SRC="${COMPLETIONS_DIR}/_vcc"
BASH_COMPLETION_SRC="${COMPLETIONS_DIR}/vcc.bash"

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
  C_BOLD=$'\e[1m'
  C_DIM=$'\e[2m'
  C_HDR=$'\e[35m'
  C_INFO=$'\e[36m'
  C_OK=$'\e[32m'
  C_WARN=$'\e[33m'
  C_ERR=$'\e[31m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_HDR=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi

p() { printf "%s\n" "$*"; }
h() { printf "%s\n" "${C_HDR}${C_BOLD}$*${C_RESET}"; }
i() { printf "%s\n" "${C_INFO}${C_BOLD}$*${C_RESET}"; }
d() { printf "%s\n" "${C_DIM}$*${C_RESET}"; }
k() { printf "%s\n" "${C_OK}${C_BOLD}$*${C_RESET}"; }
w() { printf "%s\n" "${C_WARN}${C_BOLD}$*${C_RESET}"; }
e() { printf "%s\n" "${C_ERR}${C_BOLD}$*${C_RESET}"; }

usage() {
  # Lightweight palette for help text (works even when colors are disabled)
  local H="${C_HDR}${C_BOLD}"    # headers
  local L="${C_INFO}${C_BOLD}"   # labels
  local CMD="${C_OK}${C_BOLD}"   # commands
  local OPT="${C_INFO}${C_BOLD}" # flags
  local PH="${C_DIM}"            # placeholders
  local R="${C_RESET}"

  printf "%b\n" "${H}Usage:${R}"
  printf "%b\n\n" "  ./scripts/vcc.sh ${PH}<command>${R} [options]"

  printf "%b\n" "${L}Common workflows:${R}"
  printf "%b\n" "  ./scripts/vcc.sh ${CMD}all${R} ${OPT}--profile${R} prod ${OPT}--docx${R} true"
  printf "%b\n" "  ./scripts/vcc.sh ${CMD}count${R} ${OPT}--file${R} ${PH}<file>${R} ${OPT}--out-csv${R} ${PH}<dir>${R} ${OPT}--out-md${R} ${PH}<file>${R}"
  printf "%b\n\n" "  ./scripts/vcc.sh ${CMD}completions${R} ${OPT}--install${R} true ${OPT}--shell${R} zsh"

  printf "%b\n" "${L}Commands:${R}"
  printf "%b\n" "  ${CMD}analyze${R}       Run analyze_namespaces.sh (args passed through)"
  printf "%b\n" "  ${CMD}count${R}         Run count_clients.sh (args passed through)"
  printf "%b\n" "  ${CMD}diff${R}          Run diff_clients.sh (args passed through)"
  printf "%b\n" "  ${CMD}all${R}           Run: analyze(new) + count(old) + count(new) + diff(old,new)"
  printf "%b\n" "  ${CMD}completions${R}   Show or install shell completions"
  printf "%b\n\n" "  ${CMD}help${R}          Show help"

  printf "%b\n" "${L}'all' options:${R}"
  printf "%b\n" "  ${OPT}--old${R} ${PH}<file>${R}                 Old activity counter export"
  printf "%b\n" "  ${OPT}--new${R} ${PH}<file>${R}                 New activity counter export"
  printf "%b\n" "  ${OPT}--out-dir${R} ${PH}<dir>${R}              Output root folder (default from profile or ./out)"
  printf "%b\n" "  ${OPT}--filter${R} ${PH}<path>${R}              Filter file for count/diff (default from profile)"
  printf "%b\n\n" "  ${OPT}--filter-mode${R} ${PH}<mode>${R}         exclude|highlight (default from profile)"

  printf "%b\n" "  ${OPT}--top${R} ${PH}<n>${R}                    Passed to analyze (default from profile)"
  printf "%b\n" "  ${OPT}--suggest-threshold${R} ${PH}<pct>${R}    Passed to analyze (default from profile)"
  printf "%b\n\n" "  ${OPT}--emit-filter${R} ${PH}<bool>${R}         Passed to analyze (default from profile)"

  printf "%b\n" "  ${OPT}--entitlement${R} ${PH}<n>${R}            Passed to count_clients.sh (default from profile)"
  printf "%b\n" "  ${OPT}--docx${R} ${PH}<bool>${R}                true|false (default from profile) If true, creates a meeting pack"
  printf "%b\n" "  ${OPT}--profile${R} ${PH}<name>${R}             Profile name (default: default)"
  printf "%b\n\n" "  ${OPT}--config${R} ${PH}<path>${R}              Config json path (default: ./config/vcc.config.json)"

  printf "%b\n" "${L}Completions options:${R}"
  printf "%b\n" "  ${OPT}--install${R} ${PH}<bool>${R}             true|false (default: false)"
  printf "%b\n" "  ${OPT}--shell${R} ${PH}<name>${R}               zsh|bash (default: zsh)"
  printf "%b\n" "  ${OPT}--dest${R} ${PH}<dir>${R}                 Destination directory (optional)"
  printf "%b\n" "  ${OPT}--rc${R} ${PH}<file>${R}                  Shell rc file (optional, default: ~/.zshrc or ~/.bashrc)"
  printf "%b\n\n" "  ${PH}Color control:${R} set NO_COLOR=1 to disable, or COLOR=never|auto|always"
}

need_file() { [[ -f "$1" ]] || { e "File not found: $1" >&2; exit 2; }; }
need_exec() { [[ -x "$1" ]] || { e "Missing or not executable: $1" >&2; exit 2; }; }

bool_norm() {
  case "${1:-}" in
    true|TRUE|1|yes|YES) echo "true" ;;
    false|FALSE|0|no|NO|"") echo "false" ;;
    *) echo "false" ;;
  esac
}

json_get() {
  # json_get <config> <profile> <jq_path> <fallback>
  local cfg="$1"
  local prof="$2"
  local path="$3"
  local fallback="${4:-}"

  if [[ -z "${cfg}" || ! -f "${cfg}" ]]; then
    echo "${fallback}"
    return 0
  fi

  local v
  v="$(jq -r --arg p "${prof}" "${path}" "${cfg}" 2>/dev/null || true)"
  if [[ -z "${v}" || "${v}" == "null" ]]; then
    echo "${fallback}"
  else
    echo "${v}"
  fi
}

convert_md_to_docx() {
  local md_path="$1"
  local docx_path="$2"

  [[ -f "${md_path}" ]] || return 0

  if ! command -v node >/dev/null 2>&1; then
    p "ℹ️  node not found, skipping docx conversion for: ${md_path}"
    return 0
  fi

  if [[ ! -f "${MD2DOCX}" ]]; then
    p "ℹ️  md_to_docx.mjs not found, skipping docx conversion for: ${md_path}"
    return 0
  fi

  p "📝 DOCX: ${md_path} -> ${docx_path}"
  node "${MD2DOCX}" "${md_path}" "${docx_path}" >/dev/null
}

copy_if_exists() {
  local src="$1"
  local dst_dir="$2"
  [[ -e "${src}" ]] || return 0
  mkdir -p "${dst_dir}"
  if [[ -d "${src}" ]]; then
    local base
    base="$(basename "${src}")"
    rm -rf "${dst_dir:?}/${base}"
    cp -R "${src}" "${dst_dir}/"
  else
    cp -f "${src}" "${dst_dir}/"
  fi
}

add_line_if_missing() {
  # add_line_if_missing <file> <literal_line>
  local file="$1"
  local line="$2"
  mkdir -p "$(dirname "${file}")"
  touch "${file}"
  if ! grep -Fq "${line}" "${file}"; then
    printf "\n%s\n" "${line}" >> "${file}"
  fi
}

cmd_analyze() { need_exec "${ANALYZE}"; "${ANALYZE}" "$@"; }
cmd_count()   { need_exec "${COUNT}";   "${COUNT}"   "$@"; }
cmd_diff()    { need_exec "${DIFF}";    "${DIFF}"    "$@"; }

cmd_completions() {
  local shell="zsh"
  local install="false"
  local dest=""
  local rc=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --shell) shell="${2:-zsh}"; shift 2 ;;
      --install) install="$(bool_norm "${2:-}")"; shift 2 ;;
      --dest) dest="${2:-}"; shift 2 ;;
      --rc) rc="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) e "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

  if [[ "${shell}" != "zsh" && "${shell}" != "bash" ]]; then
    e "Unsupported shell: ${shell} (use: zsh or bash)" >&2
    exit 2
  fi

  h "🧩 Shell completions"
  p ""

  if [[ "${shell}" == "zsh" ]]; then
    [[ -n "${dest}" ]] || dest="${HOME}/.zsh/completions"
    [[ -n "${rc}" ]] || rc="${HOME}/.zshrc"

    if [[ ! -f "${ZSH_COMPLETION_SRC}" ]]; then
      e "Missing zsh completion source: ${ZSH_COMPLETION_SRC}" >&2
      exit 2
    fi

    p "Shell : zsh"
    p "Src   : ${ZSH_COMPLETION_SRC}"
    p "Dest  : ${dest}"
    p "RC    : ${rc}"
    p ""

    if [[ "${install}" != "true" ]]; then
      i "What this will do (dry info)"
      p "  1) Copy _vcc into: ${dest}"
      p "  2) Ensure your ~/.zshrc enables that folder and runs compinit"
      p "  3) You reload your shell"
      p ""
      p "Run:"
      p "  ./scripts/vcc.sh completions --install true --shell zsh"
      return 0
    fi

    mkdir -p "${dest}"
    cp -f "${ZSH_COMPLETION_SRC}" "${dest}/_vcc"

    add_line_if_missing "${rc}" 'fpath=("$HOME/.zsh/completions" $fpath)'
    add_line_if_missing "${rc}" 'autoload -U compinit && compinit'

    k "✅ Installed zsh completion\n"
    p "Next:"
    p "  source ${rc}"
    p "  or restart your terminal"
    return 0
  fi

  # bash
  [[ -n "${dest}" ]] || dest="${HOME}/.bash_completion.d"
  [[ -n "${rc}" ]] || rc="${HOME}/.bashrc"

  if [[ ! -f "${BASH_COMPLETION_SRC}" ]]; then
    e "Missing bash completion source: ${BASH_COMPLETION_SRC}" >&2
    exit 2
  fi

  p "Shell : bash"
  p "Src   : ${BASH_COMPLETION_SRC}"
  p "Dest  : ${dest}"
  p "RC    : ${rc}"
  p ""

  if [[ "${install}" != "true" ]]; then
    i "What this will do (dry info)"
    p "  1) Copy vcc.bash into: ${dest}"
    p "  2) Ensure your ~/.bashrc sources it"
    p "  3) You reload your shell"
    p ""
    p "Run:"
    p "  ./scripts/vcc.sh completions --install true --shell bash"
    return 0
  fi

  mkdir -p "${dest}"
  cp -f "${BASH_COMPLETION_SRC}" "${dest}/vcc.bash"
  add_line_if_missing "${rc}" '[ -f "$HOME/.bash_completion_d/vcc.bash" ] && source "$HOME/.bash_completion_d/vcc.bash"'
  # Note: keep the line above literal. If you prefer, point it to ${dest} manually.

  k "✅ Installed bash completion\n"
  p "Next:"
  p "  source ${rc}"
  p "  or restart your terminal"
}

cmd_all() {
  local old="" new=""
  local out_dir=""
  local top="" suggest="" emit_filter=""
  local filter="" filter_mode=""
  local profile="default"
  local config="${DEFAULT_CONFIG}"
  local docx=""
  local entitlement="${ENTITLEMENT}"

  local args=("$@")
  local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --old) old="${args[$((i+1))]:-}"; i=$((i+2)) ;;
      --new) new="${args[$((i+1))]:-}"; i=$((i+2)) ;;
      --out-dir) out_dir="${args[$((i+1))]:-}"; i=$((i+2)) ;;
      --top) top="${args[$((i+1))]:-}"; i=$((i+2)) ;;
      --suggest-threshold) suggest="${args[$((i+1))]:-}"; i=$((i+2)) ;;
      --emit-filter) emit_filter="$(bool_norm "${args[$((i+1))]:-}")"; i=$((i+2)) ;;
      --filter) filter="${args[$((i+1))]:-}"; i=$((i+2)) ;;
      --filter-mode) filter_mode="${args[$((i+1))]:-}"; i=$((i+2)) ;;
      --profile) profile="${args[$((i+1))]:-default}"; i=$((i+2)) ;;
      --config) config="${args[$((i+1))]:-}"; i=$((i+2)) ;;
      --docx) docx="$(bool_norm "${args[$((i+1))]:-}")"; i=$((i+2)) ;;
      --entitlement) entitlement="${args[$((i+1))]:-}"; i=$((i+2)) ;;
      *) i=$((i+1)) ;;
    esac
  done

  if [[ -z "${old}" ]]; then old="$(json_get "${config}" "${profile}" '.profiles[$p].old // empty' '')"; fi
  if [[ -z "${new}" ]]; then new="$(json_get "${config}" "${profile}" '.profiles[$p].new // empty' '')"; fi

  [[ -n "${old}" && -n "${new}" ]] || { e "all requires: --old <file> --new <file> (or set them in profile)" >&2; exit 2; }
  need_file "${old}"
  need_file "${new}"

  if [[ -z "${out_dir}" ]]; then
    out_dir="$(json_get "${config}" "${profile}" '.profiles[$p].out_dir // empty' '')"
    [[ -n "${out_dir}" ]] || out_dir="./out"
  fi

  if [[ -z "${top}" ]]; then top="$(json_get "${config}" "${profile}" '.profiles[$p].top // empty' '')"; fi
  if [[ -z "${suggest}" ]]; then suggest="$(json_get "${config}" "${profile}" '.profiles[$p].suggest_threshold // empty' '')"; fi
  if [[ -z "${emit_filter}" ]]; then emit_filter="$(bool_norm "$(json_get "${config}" "${profile}" '.profiles[$p].emit_filter // empty' 'false')")"; fi

  if [[ -z "${filter}" ]]; then filter="$(json_get "${config}" "${profile}" '.profiles[$p].filter // empty' '')"; fi
  if [[ -z "${filter_mode}" ]]; then filter_mode="$(json_get "${config}" "${profile}" '.profiles[$p].filter_mode // empty' '')"; fi

  if [[ -z "${docx}" ]]; then docx="$(bool_norm "$(json_get "${config}" "${profile}" '.profiles[$p].docx // empty' 'false')")"; fi
  if [[ -z "${entitlement}" ]]; then entitlement="$(json_get "${config}" "${profile}" '.profiles[$p].entitlement // empty' '')"; fi

  mkdir -p "${out_dir}"

  local ns_dir="${out_dir}/namespaces"
  local old_dir="${out_dir}/old"
  local new_dir="${out_dir}/new"
  local diff_dir="${out_dir}/diff"
  mkdir -p "${ns_dir}" "${old_dir}" "${new_dir}" "${diff_dir}"

  p "🚦 Workflow: all"
  p "  profile: ${profile}"
  p "  config : ${config}"
  p "  old    : ${old}"
  p "  new    : ${new}"
  p "  out    : ${out_dir}"
  p "  docx   : ${docx}"
  [[ -n "${entitlement}" ]] && p "  entitlement: ${entitlement}"
  p ""

  {
    local a=(--file "${new}" --out-dir "${ns_dir}")
    [[ -n "${top}" ]] && a+=(--top "${top}")
    [[ -n "${suggest}" ]] && a+=(--suggest-threshold "${suggest}")
    [[ -n "${emit_filter}" ]] && a+=(--emit-filter "${emit_filter}")
    cmd_analyze "${a[@]}"
  }

  {
    local c=(--file "${old}" --out-csv "${old_dir}" --out-md "${old_dir}/report.md")
    [[ -n "${entitlement}" ]] && c+=(--entitlement "${entitlement}")
    [[ -n "${filter}" ]] && c+=(--filter "${filter}")
    [[ -n "${filter_mode}" ]] && c+=(--filter-mode "${filter_mode}")
    cmd_count "${c[@]}"
  }

  {
    local c=(--file "${new}" --out-csv "${new_dir}" --out-md "${new_dir}/report.md")
    [[ -n "${entitlement}" ]] && c+=(--entitlement "${entitlement}")
    [[ -n "${filter}" ]] && c+=(--filter "${filter}")
    [[ -n "${filter_mode}" ]] && c+=(--filter-mode "${filter_mode}")
    cmd_count "${c[@]}"
  }

  {
    local d=(--old "${old}" --new "${new}" --out-csv "${diff_dir}" --out-md "${diff_dir}/diff.md")
    [[ -n "${filter}" ]] && d+=(--filter "${filter}")
    [[ -n "${filter_mode}" ]] && d+=(--filter-mode "${filter_mode}")
    cmd_diff "${d[@]}"
  }

  for f in "${old_dir}/report.md" "${new_dir}/report.md" "${diff_dir}/diff.md" "${ns_dir}/namespaces.md"; do
    if [[ -f "${f}" ]] && [[ ! -s "${f}" ]]; then
      w "⚠️  Warning: report is empty: ${f}\n"
    fi
  done

  if [[ "${docx}" == "true" ]]; then
    local run_id
    run_id="$(date +"%Y%m%d_%H%M%S")"
    local pack="${out_dir}/meeting_pack_${profile}_${run_id}"
    local pack_reports="${pack}/reports"
    local pack_data="${pack}/data"
    mkdir -p "${pack_reports}" "${pack_data}"

    p ""
    p "📦 Meeting pack: ${pack}"

    copy_if_exists "${ns_dir}/namespaces.csv" "${pack_data}"
    copy_if_exists "${ns_dir}/prefixes.csv" "${pack_data}"
    copy_if_exists "${ns_dir}/exclude.json" "${pack_data}"

    copy_if_exists "${old_dir}" "${pack_data}"
    copy_if_exists "${new_dir}" "${pack_data}"
    copy_if_exists "${diff_dir}" "${pack_data}"

    copy_if_exists "${ns_dir}/namespaces.md" "${pack_reports}"
    copy_if_exists "${old_dir}/report.md" "${pack_reports}"
    copy_if_exists "${new_dir}/report.md" "${pack_reports}"
    copy_if_exists "${diff_dir}/diff.md" "${pack_reports}"

    convert_md_to_docx "${ns_dir}/namespaces.md" "${pack_reports}/namespaces.docx"
    convert_md_to_docx "${old_dir}/report.md" "${pack_reports}/old_report.docx"
    convert_md_to_docx "${new_dir}/report.md" "${pack_reports}/new_report.docx"
    convert_md_to_docx "${diff_dir}/diff.md" "${pack_reports}/diff.docx"

    p "✅ Meeting pack ready"
  fi

  p ""
  p "✅ Done. Outputs:"
  p "  - ${ns_dir}"
  p "  - ${old_dir}"
  p "  - ${new_dir}"
  p "  - ${diff_dir}"
}

cmd="${1:-help}"
shift || true

case "${cmd}" in
  help|-h|--help) usage ;;
  analyze) cmd_analyze "$@" ;;
  count)   cmd_count "$@" ;;
  diff)    cmd_diff "$@" ;;
  all)     cmd_all "$@" ;;
  completions) cmd_completions "$@" ;;
  *) e "Unknown command: ${cmd}" >&2; usage; exit 2 ;;
esac
