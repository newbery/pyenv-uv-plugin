#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Test Harness Contract
#
# - Dependency-free: runs on macOS bash 3.2 and typical Linux distros.
# - Uses temp dirs only; does not require real `uv` or real `pyenv`.
# - PATH is prefixed with stubs for:
#     - uv
#     - pyenv-root
#     - pyenv-rehash
#     - pyenv-help
# -----------------------------------------------------------------------------

set -euo pipefail

failures=0
tests_run=0

assert_file_exists() {
  local p="$1"
  [[ -e "$p" || -L "$p" ]] || { echo "ASSERT FAILED: expected exists: $p" >&2; return 1; }
}

assert_not_exists() {
  local p="$1"
  if [[ -e "$p" || -L "$p" ]]; then
    echo "ASSERT FAILED: expected NOT exists: $p" >&2
    return 1
  fi
}

assert_symlink_to() {
  local link="$1" want="$2"
  [[ -L "$link" ]] || { echo "ASSERT FAILED: not a symlink: $link" >&2; return 1; }
  local got
  got="$(readlink "$link")"
  if [[ "$got" != "$want" ]]; then
    echo "ASSERT FAILED: $link points to '$got', expected '$want'" >&2
    return 1
  fi
}

assert_grep() {
  local pattern="$1" file="$2"
  grep -E -q "$pattern" "$file" || {
    echo "ASSERT FAILED: pattern not found: $pattern in $file" >&2
    echo "---- file contents ----" >&2
    cat "$file" >&2
    echo "-----------------------" >&2
    return 1
  }
}

refute_grep() {
  local pattern="$1" file="$2"
  if grep -E -q "$pattern" "$file"; then
    echo "ASSERT FAILED: unexpected pattern found: $pattern in $file" >&2
    echo "---- file contents ----" >&2
    cat "$file" >&2
    echo "-----------------------" >&2
    return 1
  fi
}

run_test() {
  local name="$1"
  tests_run=$((tests_run+1))
  echo "==> $name"
  if "$name"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name" >&2
    failures=$((failures+1))
  fi
  echo
}

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

setup_tmp() {
  mktemp -d -t pyenv-uv-test.XXXXXX
}

setup_stubs() {
  local tmp="$1"
  local stubs="$tmp/stubs"
  mkdir -p "$stubs"

  cp "$(repo_root)/tests/bin/"* "$stubs/"
  chmod +x "$stubs/"*

  export PATH="$stubs:$PATH"
  export TEST_TMP="$tmp"
}

make_fake_python() {
  # args: <path-to-exe> <version-x.y.z>
  local exe="$1" ver="$2"
  mkdir -p "$(dirname "$exe")"
  cat >"$exe" <<EOF
#!/bin/sh
# Fake python contract:
# - Supports only: python -c 'import sys; print("X.Y.Z")'
if [ "\$1" = "-c" ]; then
  echo "$ver"
  exit 0
fi
echo "fake-python: unsupported args: \$*" >&2
exit 2
EOF
  chmod +x "$exe"
}

# ----------------------------------------------------------------------
# TESTS
# ----------------------------------------------------------------------

#
# Contract: 
#   `pyenv uv-install` creates a registration to the requested uv python and
#   then refreshes patch aliases to all pyenv-registered uv-* entries.
#
# Given:
#   - uv python dir contains an UNSYNCED entry reporting 3.13.2
#   - install request resolves to a DIFFERENT entry 3.12.7 and registers uv-<basename>
#
# When:
#   - Run: pyenv-uv-install 3.12
#
# Then:
#   - link to requested uv python (3.12.7) is created
#   - patch alias 3.12.7 is created
#   - patch alias 3.13.2 is NOT created
#
test_uv_install() {
  local root tmp
  root="$(repo_root)"
  tmp="$(setup_tmp)"
  setup_stubs "$tmp"

  export TEST_PYENV_ROOT="$tmp/pyenvroot"
  mkdir -p "$TEST_PYENV_ROOT/versions"

  export TEST_UV_PYTHON_DIR="$tmp/uvpy"
  mkdir -p "$TEST_UV_PYTHON_DIR"

  local unsynced="$TEST_UV_PYTHON_DIR/cpython-3.13.2-any"
  mkdir -p "$unsynced/bin"
  make_fake_python "$unsynced/bin/python3" "3.13.2"

  export TEST_UV_INSTALL_MAP="3.12=cpython-3.12.7-any:3.12.7"

  local err="$tmp/err.txt"
  "$root/bin/pyenv-uv-install" 3.12 2>"$err"

  local installed="$TEST_UV_PYTHON_DIR/cpython-3.12.7-any"
  assert_symlink_to "$TEST_PYENV_ROOT/versions/uv-cpython-3.12.7-any" "$installed"

  # Only the registered toolchain gets a patch alias after install refresh-from-pyenv
  assert_symlink_to "$TEST_PYENV_ROOT/versions/3.12.7" "$installed"
  assert_not_exists "$TEST_PYENV_ROOT/versions/3.13.2"

  rm -rf "$tmp"
}

#
# Contract:
#   `pyenv uv-sync` syncs from uv-managed pythons and creates
#   uv-<basename> registrations and X.Y.Z patch aliases
#
# Given:
#   - uv python dir has installs for python 3.13.2 and 3.13.11
#
# When:
#   - Run: pyenv-uv-sync
#
# Then:
#   - uv-* links to all uv pythons are created
#   - patch aliases to uv pythons are created
#
test_uv_sync() {
  local root tmp
  root="$(repo_root)"
  tmp="$(setup_tmp)"
  setup_stubs "$tmp"

  export TEST_PYENV_ROOT="$tmp/pyenvroot"
  mkdir -p "$TEST_PYENV_ROOT/versions"

  export TEST_UV_PYTHON_DIR="$tmp/uvpy"
  mkdir -p "$TEST_UV_PYTHON_DIR"

  local d1="$TEST_UV_PYTHON_DIR/cpython-3.13.2-any"
  local d2="$TEST_UV_PYTHON_DIR/cpython-3.13.11-any"
  mkdir -p "$d1/bin" "$d2/bin"
  make_fake_python "$d1/bin/python3" "3.13.2"
  make_fake_python "$d2/bin/python3" "3.13.11"

  local err="$tmp/err.txt"
  "$root/bin/pyenv-uv-sync" 2>"$err"

  assert_symlink_to "$TEST_PYENV_ROOT/versions/uv-cpython-3.13.2-any" "$d1"
  assert_symlink_to "$TEST_PYENV_ROOT/versions/uv-cpython-3.13.11-any" "$d2"

  assert_symlink_to "$TEST_PYENV_ROOT/versions/3.13.2" "$d1"
  assert_symlink_to "$TEST_PYENV_ROOT/versions/3.13.11" "$d2"

  rm -rf "$tmp"
}

#
# Contract:
#   `pyenv uv-sync --no-refresh-aliases` creates uv-<basename> registrations
#   as usual but also clears all existing patch aliases to uv pythons.
#
# Given:
#   - First run of uv-sync creates patch aliases and uv-* links.
#
# When:
#   - Run: pyenv-uv-sync --no-aliases
#
# Then:
#   - uv-* links remain
#   - patch aliases (X.Y.Z) that point into uv python dir are removed
#
test_uv_sync_no_aliases() {
  local root tmp
  root="$(repo_root)"
  tmp="$(setup_tmp)"
  setup_stubs "$tmp"

  export TEST_PYENV_ROOT="$tmp/pyenvroot"
  mkdir -p "$TEST_PYENV_ROOT/versions"

  export TEST_UV_PYTHON_DIR="$tmp/uvpy"
  mkdir -p "$TEST_UV_PYTHON_DIR"

  local d1="$TEST_UV_PYTHON_DIR/cpython-3.13.2-any"
  local d2="$TEST_UV_PYTHON_DIR/cpython-3.13.11-any"
  mkdir -p "$d1/bin" "$d2/bin"
  make_fake_python "$d1/bin/python3" "3.13.2"
  make_fake_python "$d2/bin/python3" "3.13.11"

  "$root/bin/pyenv-uv-sync" >/dev/null 2>&1

  assert_symlink_to "$TEST_PYENV_ROOT/versions/uv-cpython-3.13.2-any" "$d1"
  assert_symlink_to "$TEST_PYENV_ROOT/versions/3.13.2" "$d1"

  "$root/bin/pyenv-uv-sync" --no-refresh-aliases >/dev/null 2>&1

  assert_symlink_to "$TEST_PYENV_ROOT/versions/uv-cpython-3.13.2-any" "$d1"
  assert_symlink_to "$TEST_PYENV_ROOT/versions/uv-cpython-3.13.11-any" "$d2"

  assert_not_exists "$TEST_PYENV_ROOT/versions/3.13.2"
  assert_not_exists "$TEST_PYENV_ROOT/versions/3.13.11"

  rm -rf "$tmp"
}

#
# Contract:
#   During refresh of patch aliases, if multiple uv-managed pythons report the
#   same patch version alias (X.Y.Z), the refresh chooses a stable canonical
#   candidate and warns with `pyenv uv-alias` suggestions.
#
# Policy under test:
#   - choose lexicographically smallest candidate id (from basename) as canonical
#   - warning contains lines: "pyenv uv-alias <alias> <candidate>"
#
# Given:
#   - two uv-managed pythons both report 3.12.2:
#       cpython-3.12.2-a
#       cpython-3.12.2-b
#
# When:
#   - Run: pyenv-uv-sync
#
# Then:
#   - versions/3.12.2 points to the canonical (a)
#   - stderr includes conflict warning
#   - stderr includes uv-alias suggestions for both candidates
#
test_uv_sync_conflict() {
  local root tmp
  root="$(repo_root)"
  tmp="$(setup_tmp)"
  setup_stubs "$tmp"

  export TEST_PYENV_ROOT="$tmp/pyenvroot"
  mkdir -p "$TEST_PYENV_ROOT/versions"

  export TEST_UV_PYTHON_DIR="$tmp/uvpy"
  mkdir -p "$TEST_UV_PYTHON_DIR"

  local a="$TEST_UV_PYTHON_DIR/cpython-3.12.2-a"
  local b="$TEST_UV_PYTHON_DIR/cpython-3.12.2-b"
  mkdir -p "$a/bin" "$b/bin"
  make_fake_python "$a/bin/python3" "3.12.2"
  make_fake_python "$b/bin/python3" "3.12.2"

  local err="$tmp/err.txt"
  "$root/bin/pyenv-uv-sync" 2>"$err"

  assert_symlink_to "$TEST_PYENV_ROOT/versions/3.12.2" "$a"

  assert_grep "warning: multiple toolchains report 3\\.12\\.2" "$err"
  assert_grep "to select a different one, run one of" "$err"
  assert_grep "pyenv uv-alias 3\\.12\\.2 uv-cpython-3\\.12\\.2-a" "$err"
  assert_grep "pyenv uv-alias 3\\.12\\.2 uv-cpython-3\\.12\\.2-b" "$err"

  rm -rf "$tmp"
}

#
# Contract:
#   During refresh of patch aliases, if a patch alias already exists and
#   points to a non-uv python, it's not overwritten and a warning is emitted.
#
# Given:
#   - versions/3.12.2 is a symlink to a non-uv prefix (outside uv python dir)
#   - uv python dir contains an item reporting 3.12.2
#
# When:
#   - Run: pyenv-uv-sync
#
# Then:
#   - versions/3.12.2 remains pointing to the non-uv target
#   - stderr includes the "not overriding" warning
#
test_uv_sync_protects_non_uv_alias() {
  local root tmp
  root="$(repo_root)"
  tmp="$(setup_tmp)"
  setup_stubs "$tmp"

  export TEST_PYENV_ROOT="$tmp/pyenvroot"
  mkdir -p "$TEST_PYENV_ROOT/versions"

  export TEST_UV_PYTHON_DIR="$tmp/uvpy"
  mkdir -p "$TEST_UV_PYTHON_DIR"

  local nonuv="$tmp/nonuv-python"
  mkdir -p "$nonuv"
  ln -s "$nonuv" "$TEST_PYENV_ROOT/versions/3.12.2"

  local u="$TEST_UV_PYTHON_DIR/cpython-3.12.2-any"
  mkdir -p "$u/bin"
  make_fake_python "$u/bin/python3" "3.12.2"

  local err="$tmp/err.txt"
  "$root/bin/pyenv-uv-sync" 2>"$err"

  assert_symlink_to "$TEST_PYENV_ROOT/versions/3.12.2" "$nonuv"
  assert_grep "pyenv-uv: warning: alias '3\\.12\\.2' exists and points to a non-uv python; not overriding\\." "$err"

  rm -rf "$tmp"
}

#
# Contract:
#   `pyenv uv-alias` sets a persistent override so later refreshes use the
#   selected candidate when multiple uv pythons report the same patch version.
#
# Given:
#   - two uv pythons both report 3.12.2:
#       cpython-3.12.2-a
#       cpython-3.12.2-b
#   - initial uv-sync chooses canonical (a)
#
# When:
#   - Run: pyenv uv-alias 3.12.2 uv-cpython-3.12.2-b
#   - Run: pyenv-uv-sync again
#
# Then:
#   - versions/3.12.2 points to (b)
#   - overrides file contains: 3.12.2 <tab> uv-cpython-3.12.2-b
#
test_uv_alias_persists() {
  local root tmp
  root="$(repo_root)"
  tmp="$(setup_tmp)"
  setup_stubs "$tmp"

  export TEST_PYENV_ROOT="$tmp/pyenvroot"
  mkdir -p "$TEST_PYENV_ROOT/versions"

  export TEST_UV_PYTHON_DIR="$tmp/uvpy"
  mkdir -p "$TEST_UV_PYTHON_DIR"

  local a="$TEST_UV_PYTHON_DIR/cpython-3.12.2-a"
  local b="$TEST_UV_PYTHON_DIR/cpython-3.12.2-b"
  mkdir -p "$a/bin" "$b/bin"
  make_fake_python "$a/bin/python3" "3.12.2"
  make_fake_python "$b/bin/python3" "3.12.2"

  local err1="$tmp/err1.txt"
  "$root/bin/pyenv-uv-sync" 2>"$err1"
  assert_symlink_to "$TEST_PYENV_ROOT/versions/3.12.2" "$a"

  local err2="$tmp/err2.txt"
  "$root/bin/pyenv-uv-alias" 3.12.2 uv-cpython-3.12.2-b 2>"$err2"

  local err3="$tmp/err3.txt"
  "$root/bin/pyenv-uv-sync" 2>"$err3"
  assert_symlink_to "$TEST_PYENV_ROOT/versions/3.12.2" "$b"

  local overrides="$TEST_PYENV_ROOT/pyenv-uv/alias-overrides.tsv"
  assert_file_exists "$overrides"
  assert_grep '^3\.12\.2\tuv-cpython-3\.12\.2-b$' "$overrides"

  rm -rf "$tmp"
}

#
# Contract:
#   `pyenv uv-uninstall <name>` removes the requested name and other plugin
#   names (patch alias X.Y.Z and uv-* prefix) pointing to same prefix.
#   It does NOT remove arbitrary custom names pointing to the same item.
#
# Given:
#   - versions/uv-cpython-3.13.2-any exists
#   - versions/3.13.2 exists
#   - versions/work-compat exists
#   - all of the above linked to the same uv python
#
# When:
#   - Run: pyenv-uv-uninstall 3.13.2
#
# Then:
#   - 3.13.2 and uv-* are removed
#   - work-compat remains
#   - underlying uv python remains
#
test_uv_uninstall() {
  local root tmp
  root="$(repo_root)"
  tmp="$(setup_tmp)"
  setup_stubs "$tmp"

  export TEST_PYENV_ROOT="$tmp/pyenvroot"
  mkdir -p "$TEST_PYENV_ROOT/versions"

  export TEST_UV_PYTHON_DIR="$tmp/uvpy"
  mkdir -p "$TEST_UV_PYTHON_DIR"

  local prefix="$TEST_UV_PYTHON_DIR/some-prefix"
  mkdir -p "$prefix/bin"
  make_fake_python "$prefix/bin/python3" "3.13.2"

  ln -s "$prefix" "$TEST_PYENV_ROOT/versions/3.13.2"
  ln -s "$prefix" "$TEST_PYENV_ROOT/versions/uv-cpython-3.13.2-any"
  ln -s "$prefix" "$TEST_PYENV_ROOT/versions/work-compat"

  "$root/bin/pyenv-uv-uninstall" "3.13.2" >/dev/null 2>&1

  assert_not_exists "$TEST_PYENV_ROOT/versions/3.13.2"
  assert_not_exists "$TEST_PYENV_ROOT/versions/uv-cpython-3.13.2-any"
  assert_file_exists "$TEST_PYENV_ROOT/versions/work-compat"
  assert_file_exists "$prefix"

  rm -rf "$tmp"
}

#
# Contract:
#   `pyenv uv-uninstall --all-links` removes every symlink pointing
#   to the same prefix, including custom names.
#
# Given:
#   - versions/3.13.2 exists
#   - versions/work-compat exists
#   - all of the above linked to the same uv python
#
# When:
#   - Run: pyenv-uv-uninstall --all-links 3.13.2
#
# Then:
#   - both links are removed
#   - underlying uv python remains
#
test_uv_uninstall_all_links() {
  local root tmp
  root="$(repo_root)"
  tmp="$(setup_tmp)"
  setup_stubs "$tmp"

  export TEST_PYENV_ROOT="$tmp/pyenvroot"
  mkdir -p "$TEST_PYENV_ROOT/versions"

  export TEST_UV_PYTHON_DIR="$tmp/uvpy"
  mkdir -p "$TEST_UV_PYTHON_DIR"

  local prefix="$TEST_UV_PYTHON_DIR/some-prefix"
  mkdir -p "$prefix/bin"
  make_fake_python "$prefix/bin/python3" "3.13.2"

  ln -s "$prefix" "$TEST_PYENV_ROOT/versions/3.13.2"
  ln -s "$prefix" "$TEST_PYENV_ROOT/versions/work-compat"

  "$root/bin/pyenv-uv-uninstall" --all-links "3.13.2" >/dev/null 2>&1

  assert_not_exists "$TEST_PYENV_ROOT/versions/3.13.2"
  assert_not_exists "$TEST_PYENV_ROOT/versions/work-compat"
  assert_file_exists "$prefix"

  rm -rf "$tmp"
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------

run_test test_uv_install
run_test test_uv_sync
run_test test_uv_sync_no_aliases
run_test test_uv_sync_conflict
run_test test_uv_sync_protects_non_uv_alias
run_test test_uv_alias_persists
run_test test_uv_uninstall
run_test test_uv_uninstall_all_links

echo "Tests run: $tests_run"
if [[ $failures -ne 0 ]]; then
  echo "Failures: $failures" >&2
  exit 1
fi
echo "All tests passed."
