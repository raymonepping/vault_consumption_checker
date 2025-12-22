# bash completion for vcc
# Usage (one-off):
#   source completions/vcc.bash

_vcc_profiles() {
  local cfg="${1:-./config/vcc.config.json}"
  command -v jq >/dev/null 2>&1 || return 0
  [[ -f "$cfg" ]] || return 0
  jq -r '.profiles | keys[]' "$cfg" 2>/dev/null | tr '\n' ' '
}

_vcc_comp_files() {
  # basic file completion without requiring bash-completion's _filedir
  local cur="$1"
  COMPREPLY=( $(compgen -f -- "$cur") )
}

_vcc_comp_dirs() {
  local cur="$1"
  COMPREPLY=( $(compgen -d -- "$cur") )
}

_vcc() {
  local cur prev cmd
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  cmd="${COMP_WORDS[1]:-}"

  local cmds="analyze count diff all help --help -h"

  # If completing the command position
  if [[ $COMP_CWORD -le 1 ]]; then
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return 0
  fi

  # Detect --config value if present in the command line
  local cfg="./config/vcc.config.json"
  local i
  for (( i=1; i<${#COMP_WORDS[@]}; i++ )); do
    if [[ "${COMP_WORDS[$i]}" == "--config" && -n "${COMP_WORDS[$((i+1))]:-}" ]]; then
      cfg="${COMP_WORDS[$((i+1))]}"
      break
    fi
  done

  # Shared option lists (only flags we know exist from your scripts)
  local bools="true false"
  local filter_modes="exclude highlight"

  local opts_analyze="--file --out-dir --top --suggest-threshold --emit-filter --filter-out --help -h"
  local opts_count="--file --entitlement --out-csv --out-md --filter --filter-mode --help -h"
  local opts_diff="--old --new --out-csv --out-md --filter --filter-mode --help -h"
  local opts_all="--old --new --out-dir --filter --filter-mode --top --suggest-threshold --emit-filter --entitlement --docx --profile --config --help -h"

  case "$prev" in
    --emit-filter|--docx)
      COMPREPLY=( $(compgen -W "$bools" -- "$cur") )
      return 0
      ;;
    --filter-mode)
      COMPREPLY=( $(compgen -W "$filter_modes" -- "$cur") )
      return 0
      ;;
    --profile)
      COMPREPLY=( $(compgen -W "$(_vcc_profiles "$cfg")" -- "$cur") )
      return 0
      ;;
    --file|--old|--new|--filter|--filter-out|--config|--out-md)
      _vcc_comp_files "$cur"
      return 0
      ;;
    --out-dir|--out-csv)
      _vcc_comp_dirs "$cur"
      return 0
      ;;
  esac

  case "$cmd" in
    analyze) COMPREPLY=( $(compgen -W "$opts_analyze" -- "$cur") ) ;;
    count)   COMPREPLY=( $(compgen -W "$opts_count"   -- "$cur") ) ;;
    diff)    COMPREPLY=( $(compgen -W "$opts_diff"    -- "$cur") ) ;;
    all)     COMPREPLY=( $(compgen -W "$opts_all"     -- "$cur") ) ;;
    help|--help|-h) COMPREPLY=() ;;
    *) COMPREPLY=( $(compgen -W "$cmds" -- "$cur") ) ;;
  esac
}

complete -F _vcc vcc
