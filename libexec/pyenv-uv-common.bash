#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# pyenv-uv common helpers
# -----------------------------------------------------------------------------

set -euo pipefail

pyenv_uv_prefix() { echo "${PYENV_UV_PREFIX:-uv-}"; }

pyenv_uv_plugin_root() {
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 1
  echo "$d"
}

pyenv_uv_versions_dir() {
  local pyenv_root
  pyenv_root="$(pyenv-root)"
  echo "${pyenv_root}/versions"
}

pyenv_uv_state_dir() {
  local pyenv_root
  pyenv_root="$(pyenv-root)"
  echo "${pyenv_root}/pyenv-uv"
}

pyenv_uv_overrides_file() {
  echo "$(pyenv_uv_state_dir)/alias-overrides.tsv"
}

pyenv_uv_require() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || {
      echo "pyenv-uv: required command not found: $c" >&2
      exit 127
    }
  done
}

pyenv_uv_clear_aliases() {
  pyenv_uv_require uv pyenv-root

  local versions_dir uv_dir p bn tgt removed
  versions_dir="$(pyenv_uv_versions_dir)"
  uv_dir="$(uv python dir)"
  removed=0

  [[ -d "$versions_dir" ]] || return 0

  for p in "$versions_dir"/*; do
    [[ -L "$p" ]] || continue
    bn="$(basename "$p")"
    [[ "$bn" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue

    tgt="$(readlink "$p")"
    if [[ "$tgt" == "$uv_dir"* ]]; then
      rm -f "$p"
      removed=$((removed+1))
    fi
  done

  [[ $removed -gt 0 ]] && echo "pyenv-uv: cleared $removed patch alias(es)" >&2
}

pyenv_uv_find_python_in_prefix() {
  local prefix_dir="$1"
  local pyexe=""

  for cand in "$prefix_dir/bin/python3" "$prefix_dir/bin/python"; do
    [[ -x "$cand" ]] && { pyexe="$cand"; break; }
  done
  if [[ -z "$pyexe" ]]; then
    cand="$(find "$prefix_dir/bin" -maxdepth 1 -type f -name 'python3.*' -print 2>/dev/null | head -n 1 || true)"
    [[ -n "$cand" && -x "$cand" ]] && pyexe="$cand"
  fi

  echo "$pyexe"
}

# ---- override store ---------------------------------------------------------

pyenv_uv_override_get() {
  local alias="$1"
  local f
  f="$(pyenv_uv_overrides_file)"
  [[ -f "$f" ]] || { echo ""; return 0; }
  awk -F'\t' -v k="$alias" '($1==k){print $2; exit 0}' "$f" 2>/dev/null || true
}

pyenv_uv_override_set() {
  local alias="$1" target="$2"
  local dir f tmp
  dir="$(pyenv_uv_state_dir)"
  f="$(pyenv_uv_overrides_file)"
  mkdir -p "$dir"
  tmp="$(mktemp -t pyenv-uv.overrides.XXXXXX)"
  trap 'rm -f "$tmp"' RETURN

  if [[ -f "$f" ]]; then
    awk -F'\t' -v k="$alias" '($1!=k){print $0}' "$f" >"$tmp" || true
  fi
  printf '%s\t%s\n' "$alias" "$target" >>"$tmp"
  mv "$tmp" "$f"
}

pyenv_uv_override_unset() {
  local alias="$1"
  local f tmp
  f="$(pyenv_uv_overrides_file)"
  [[ -f "$f" ]] || return 0
  tmp="$(mktemp -t pyenv-uv.overrides.XXXXXX)"
  trap 'rm -f "$tmp"' RETURN
  awk -F'\t' -v k="$alias" '($1!=k){print $0}' "$f" >"$tmp" || true
  mv "$tmp" "$f"
}

pyenv_uv_resolve_target_to_prefix() {
  local target="$1"
  local versions_dir p

  if [[ "$target" == /* ]]; then
    [[ -d "$target" ]] && { echo "$target"; return 0; }
    echo ""
    return 0
  fi

  versions_dir="$(pyenv_uv_versions_dir)"
  p="${versions_dir}/${target}"
  [[ -e "$p" || -L "$p" ]] || { echo ""; return 0; }

  if [[ -L "$p" ]]; then
    readlink "$p"
  else
    echo "$p"
  fi
}

# ---- linking rules ----------------------------------------------------------

pyenv_uv_alias_is_protected_non_uv() {
  local alias="$1"
  local versions_dir uv_dir p tgt
  versions_dir="$(pyenv_uv_versions_dir)"
  p="${versions_dir}/${alias}"

  [[ -e "$p" || -L "$p" ]] || return 1

  if [[ -L "$p" ]]; then
    tgt="$(readlink "$p")"
  else
    return 0
  fi

  pyenv_uv_require uv
  uv_dir="$(uv python dir)"

  [[ "$tgt" == "$uv_dir"* ]] && return 1
  return 0
}

pyenv_uv_link() {
  local name="$1" src="$2" mode="${3:-safe}"
  local versions_dir target
  versions_dir="$(pyenv_uv_versions_dir)"
  target="${versions_dir}/${name}"
  mkdir -p "$versions_dir"

  if [[ -e "$target" || -L "$target" ]]; then
    if [[ "$mode" == "force" ]]; then
      rm -rf "$target"
    else
      if [[ -L "$target" ]]; then
        local existing uv_dir
        existing="$(readlink "$target")"
        pyenv_uv_require uv
        uv_dir="$(uv python dir)"
        if [[ "$existing" == "$uv_dir"* ]]; then
          rm -rf "$target"
        else
          return 1
        fi
      else
        return 1
      fi
    fi
  fi

  ln -s "$src" "$target"
  return 0
}

# ---- record collection ------------------------------------------------------
# Records format for refresh-from-pyenv:
#   ver<TAB>prefix_dir<TAB>id
# where id is the pyenv link name (e.g. uv-cpython-...).
pyenv_uv_write_records() {
  local out="$1"
  : >"$out"

  local versions_dir uv_prefix
  versions_dir="$(pyenv_uv_versions_dir)"
  uv_prefix="$(pyenv_uv_prefix)"
  [[ -d "$versions_dir" ]] || return 0

  find "$versions_dir" -mindepth 1 -maxdepth 1 -type l -name "${uv_prefix}*" -print 2>/dev/null | sort | while IFS= read -r link; do
    local id prefix_dir pyexe ver
    id="$(basename "$link")"
    prefix_dir="$(readlink "$link")"
    [[ -n "$prefix_dir" && -d "$prefix_dir" ]] || continue

    pyexe="$(pyenv_uv_find_python_in_prefix "$prefix_dir")"
    [[ -n "$pyexe" ]] || continue

    ver="$("$pyexe" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null || true)"
    [[ -n "$ver" ]] || continue

    printf '%s\t%s\t%s\n' "$ver" "$prefix_dir" "$id" >>"$out"
  done
}

# ---- refresh implementation -------------------------------------------------

pyenv_uv_apply_refresh() {
  local records="$1"
  pyenv_uv_require pyenv-root pyenv-rehash

  [[ -s "$records" ]] || { pyenv-rehash; return 0; }

  local versions_dir uv_prefix
  versions_dir="$(pyenv_uv_versions_dir)"
  uv_prefix="$(pyenv_uv_prefix)"

  local tmp_sorted tmp_grouped
  tmp_sorted="$(mktemp -t pyenv-uv.sorted.XXXXXX)"
  tmp_grouped="$(mktemp -t pyenv-uv.grouped.XXXXXX)"
  trap 'rm -f "$tmp_sorted" "$tmp_grouped"' RETURN

  sort -t $'\t' -k1,1 -k3,3 "$records" >"$tmp_sorted"

  awk -F'\t' '
    BEGIN { cur=""; }
    {
      if (cur=="" ) { cur=$1; }
      if ($1!=cur) {
        print "";
        cur=$1;
      }
      print $0;
    }
  ' "$tmp_sorted" > "$tmp_grouped"

  local group=()
  local line

  # For nicer UX in warnings, show ids without uv- prefix when possible.
  # But keep the suggested command targets as full pyenv names (uv-...).
  strip_uv_prefix() {
    local s="$1"
    if [[ "$s" == "${uv_prefix}"* ]]; then
      echo "${s#"${uv_prefix}"}"
    else
      echo "$s"
    fi
  }

  finalize_group() {
    [[ ${#group[@]} -gt 0 ]] || return 0

    local ver="${group[0]%%$'\t'*}"
    local alias="$ver"

    if pyenv_uv_alias_is_protected_non_uv "$alias"; then
      echo "pyenv-uv: warning: alias '$alias' exists and points to a non-uv python; not overriding." >&2
      group=()
      return 0
    fi

    # Manual override (alias -> target)
    local ov target_prefix chosen_prefix chosen_id
    ov="$(pyenv_uv_override_get "$alias")"
    if [[ -n "$ov" ]]; then
      target_prefix="$(pyenv_uv_resolve_target_to_prefix "$ov")"
      if [[ -n "$target_prefix" ]]; then
        local i
        for i in "${group[@]}"; do
          local p id
          p="$(echo "$i" | awk -F'\t' '{print $2}')"
          id="$(echo "$i" | awk -F'\t' '{print $3}')"
          if [[ "$p" == "$target_prefix" ]]; then
            chosen_prefix="$p"
            chosen_id="$id"
            break
          fi
        done
        if [[ -n "${chosen_prefix:-}" ]]; then
          pyenv_uv_link "$alias" "$chosen_prefix" "safe" || true
          if [[ ${#group[@]} -gt 1 ]]; then
            echo "pyenv-uv: warning: multiple toolchains report $alias; using manual override '$ov' ($(strip_uv_prefix "$chosen_id"))." >&2
          fi
          group=()
          return 0
        else
          echo "pyenv-uv: warning: override for '$alias' points to '$ov' but it does not match any current uv candidate; ignoring override." >&2
        fi
      else
        echo "pyenv-uv: warning: override for '$alias' points to '$ov' but it could not be resolved; ignoring override." >&2
      fi
    fi

    # Stable canonical: lexicographically smallest candidate id.
    local first="${group[0]}"
    chosen_prefix="$(echo "$first" | awk -F'\t' '{print $2}')"
    chosen_id="$(echo "$first" | awk -F'\t' '{print $3}')"

    pyenv_uv_link "$alias" "$chosen_prefix" "safe" || true

    if [[ ${#group[@]} -gt 1 ]]; then
      echo "pyenv-uv: warning: multiple toolchains report $alias; chose '$(strip_uv_prefix "$chosen_id")' -> $chosen_prefix." >&2
      echo "pyenv-uv: to select a different one, run one of:" >&2
      local g
      for g in "${group[@]}"; do
        local id
        id="$(echo "$g" | awk -F'\t' '{print $3}')"
        echo "  pyenv uv-alias $alias $id" >&2
      done
    fi

    group=()
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then
      finalize_group
      continue
    fi
    group+=("$line")
  done < "$tmp_grouped"
  finalize_group

  pyenv-rehash
}

pyenv_uv_refresh_aliases() {
  pyenv_uv_require pyenv-root pyenv-rehash

  local tmp_records
  tmp_records="$(mktemp -t pyenv-uv.records.XXXXXX)"
  trap 'rm -f "$tmp_records"' RETURN

  pyenv_uv_write_records "$tmp_records"
  pyenv_uv_apply_refresh "$tmp_records"
}
