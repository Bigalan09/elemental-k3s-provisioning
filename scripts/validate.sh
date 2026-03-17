#!/usr/bin/env bash
# validate.sh - Validate shell scripts, YAML files, and rendered artefacts.
#
# Usage:
#   bash scripts/validate.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

step() {
  echo ""
  echo "==> $*"
}

pass() {
  echo "    PASS: $*"
  PASS=$((PASS + 1))
}

fail() {
  echo "    FAIL: $*" >&2
  FAIL=$((FAIL + 1))
}

# Verify all required tools are available before starting
step "Checking required tools"
for tool in yq shellcheck yamllint kubeconform; do
  if command -v "${tool}" &>/dev/null; then
    pass "${tool} found: $(command -v "${tool}")"
  else
    echo "ERROR: Required tool '${tool}' is not installed." >&2
    exit 1
  fi
done

# Run shellcheck against all shell scripts
step "Running shellcheck on shell scripts"
while IFS= read -r -d '' script; do
  if shellcheck "${script}"; then
    pass "shellcheck: ${script}"
  else
    fail "shellcheck: ${script}"
  fi
done < <(find "${REPO_ROOT}/scripts" -name "*.sh" -print0)

# Collect YAML source directories that exist
yaml_dirs=()
for dir in "${REPO_ROOT}/templates" "${REPO_ROOT}/clusters" "${REPO_ROOT}/nodes"; do
  if [[ -d "${dir}" ]]; then
    yaml_dirs+=("${dir}")
  fi
done

# yamllint all YAML source files
step "Running yamllint on YAML source files"
if [[ ${#yaml_dirs[@]} -gt 0 ]]; then
  while IFS= read -r -d '' yaml_file; do
    if yamllint --strict "${yaml_file}"; then
      pass "yamllint: ${yaml_file}"
    else
      fail "yamllint: ${yaml_file}"
    fi
  done < <(find "${yaml_dirs[@]}" -name "*.yaml" -print0 2>/dev/null)
fi

# Render all example nodes into dist/ for validation
step "Rendering example nodes"
if bash "${REPO_ROOT}/scripts/render.sh" --all; then
  pass "render.sh --all"
else
  fail "render.sh --all"
fi

# yamllint rendered artefacts
step "Running yamllint on rendered artefacts"
if [[ -d "${REPO_ROOT}/dist" ]]; then
  while IFS= read -r -d '' yaml_file; do
    if yamllint --strict "${yaml_file}"; then
      pass "yamllint rendered: ${yaml_file}"
    else
      fail "yamllint rendered: ${yaml_file}"
    fi
  done < <(find "${REPO_ROOT}/dist" -name "*.yaml" -print0)
else
  fail "dist/ directory not found after rendering"
fi

# kubeconform on rendered Kubernetes-style manifests
step "Running kubeconform on rendered Kubernetes manifests"
if [[ -d "${REPO_ROOT}/dist" ]]; then
  while IFS= read -r -d '' yaml_file; do
    kind_value="$(yq '.kind // ""' "${yaml_file}")"
    if [[ -n "${kind_value}" && "${kind_value}" != "null" ]]; then
      if kubeconform \
          -strict \
          -ignore-missing-schemas \
          -summary \
          "${yaml_file}"; then
        pass "kubeconform: ${yaml_file}"
      else
        fail "kubeconform: ${yaml_file}"
      fi
    fi
  done < <(find "${REPO_ROOT}/dist" -name "*.yaml" -print0)
fi

# kubeconform on cluster-level manifests
step "Running kubeconform on cluster manifests"
while IFS= read -r -d '' yaml_file; do
  kind_value="$(yq '.kind // ""' "${yaml_file}")"
  if [[ -n "${kind_value}" && "${kind_value}" != "null" ]]; then
    if kubeconform \
        -strict \
        -ignore-missing-schemas \
        -summary \
        "${yaml_file}"; then
      pass "kubeconform cluster: ${yaml_file}"
    else
      fail "kubeconform cluster: ${yaml_file}"
    fi
  fi
done < <(find "${REPO_ROOT}/clusters" -name "*.yaml" -print0 2>/dev/null)

# Summary
echo ""
echo "=============================="
echo "Validation complete"
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo "=============================="

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
