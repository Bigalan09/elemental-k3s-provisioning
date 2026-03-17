#!/usr/bin/env bash
# render.sh - Render Elemental node configuration artefacts from templates and node definition files.
#
# Usage:
#   bash scripts/render.sh nodes/examples/server-01.yaml        # render a single node
#   bash scripts/render.sh --env lab                             # render all nodes in nodes/lab/
#   bash scripts/render.sh --env production                      # render all nodes in nodes/production/
#   bash scripts/render.sh --all                                 # render all nodes across all environments

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_DIR="${REPO_ROOT}/templates"
DIST_DIR="${REPO_ROOT}/dist"

VALID_ENVS=("lab" "staging" "production" "examples")

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required but not found in PATH. Install yq v4 before running this script." >&2
  exit 1
fi

# resolve_ssh_secret_ref returns the SSH key secret reference for a given node.
# Priority: per-node sshKeySecretRef > environment cluster-config sshKeySecretRef > empty string.
resolve_ssh_secret_ref() {
  local node_file="$1"
  local env_name="$2"

  local node_ref
  node_ref="$(yq '.sshKeySecretRef.name // ""' "${node_file}")"
  if [[ -n "${node_ref}" ]]; then
    local node_ns
    node_ns="$(yq '.sshKeySecretRef.namespace // "fleet-default"' "${node_file}")"
    echo "${node_ref}/${node_ns}"
    return
  fi

  local cluster_config="${REPO_ROOT}/clusters/${env_name}/cluster-config.yaml"
  if [[ -f "${cluster_config}" ]]; then
    local env_ref
    env_ref="$(yq '.sshKeySecretRef.name // ""' "${cluster_config}")"
    if [[ -n "${env_ref}" ]]; then
      local env_ns
      env_ns="$(yq '.sshKeySecretRef.namespace // "fleet-default"' "${cluster_config}")"
      echo "${env_ref}/${env_ns}"
      return
    fi
  fi

  echo ""
}

# resolve_environment returns the environment name for a given node file based on
# its path or the explicit environment field in the node definition.
resolve_environment() {
  local node_file="$1"

  # Try the explicit environment field first.
  local env_field
  env_field="$(yq '.environment // ""' "${node_file}")"
  if [[ -n "${env_field}" ]]; then
    echo "${env_field}"
    return
  fi

  # Fall back to the directory name containing the node file.
  local dir_name
  dir_name="$(basename "$(dirname "${node_file}")")"
  echo "${dir_name}"
}

render_node() {
  local node_file="$1"

  if [[ ! -f "${node_file}" ]]; then
    echo "ERROR: Node definition file not found: ${node_file}" >&2
    exit 1
  fi

  # Read and validate required fields
  local hostname role install_device
  hostname="$(yq '.hostname' "${node_file}")"
  role="$(yq '.role' "${node_file}")"
  install_device="$(yq '.installDevice' "${node_file}")"

  if [[ -z "${hostname}" || "${hostname}" == "null" ]]; then
    echo "ERROR: Missing required field 'hostname' in ${node_file}" >&2
    exit 1
  fi

  if [[ -z "${role}" || "${role}" == "null" ]]; then
    echo "ERROR: Missing required field 'role' in ${node_file}" >&2
    exit 1
  fi

  if [[ "${role}" != "server" && "${role}" != "agent" ]]; then
    echo "ERROR: Invalid role '${role}' in ${node_file}. Must be 'server' or 'agent'." >&2
    exit 1
  fi

  if [[ -z "${install_device}" || "${install_device}" == "null" ]]; then
    echo "ERROR: Missing required field 'installDevice' in ${node_file}" >&2
    exit 1
  fi

  local env_name
  env_name="$(resolve_environment "${node_file}")"

  # Export environment variables for use by yq strenv() and env()
  # Structured fields (arrays and maps) are exported as compact JSON
  # so that yq can parse them back with from_json.
  export NODE_HOSTNAME="${hostname}"
  export NODE_ROLE="${role}"
  export NODE_INSTALL_DEVICE="${install_device}"
  export NODE_ENVIRONMENT="${env_name}"

  NODE_LABELS_JSON="$(yq -o=json -I0 '.labels // {}' "${node_file}")"
  export NODE_LABELS_JSON

  NODE_TAINTS_JSON="$(yq -o=json -I0 '.taints // []' "${node_file}")"
  export NODE_TAINTS_JSON

  local ssh_secret_ref
  ssh_secret_ref="$(resolve_ssh_secret_ref "${node_file}" "${env_name}")"
  export NODE_SSH_SECRET_REF="${ssh_secret_ref}"

  local registration_group
  registration_group="$(yq '.registrationGroup // ""' "${node_file}")"
  export NODE_REGISTRATION_GROUP="${registration_group}"

  local tailscale_enabled
  tailscale_enabled="$(yq '.tailscale.enabled // false' "${node_file}")"
  export NODE_TAILSCALE_ENABLED="${tailscale_enabled}"

  local tailscale_auth_secret
  tailscale_auth_secret="$(yq '.tailscale.authKeySecretName // ""' "${node_file}")"
  export NODE_TAILSCALE_AUTH_SECRET="${tailscale_auth_secret}"

  local out_dir="${DIST_DIR}/${env_name}/${hostname}"
  mkdir -p "${out_dir}"

  echo "Rendering node: ${hostname} (role=${role}, env=${env_name})"

  # Render machine-registration
  yq --prettyPrint '
    .metadata.name = strenv(NODE_HOSTNAME) |
    .metadata.labels["elemental.cattle.io/hostname"] = strenv(NODE_HOSTNAME) |
    .metadata.annotations["elemental.cattle.io/ssh-key-secret"] = strenv(NODE_SSH_SECRET_REF) |
    .spec.machineInventoryLabels = (.spec.machineInventoryLabels * (strenv(NODE_LABELS_JSON) | from_json)) |
    .spec.machineInventoryLabels["elemental.cattle.io/hostname"] = strenv(NODE_HOSTNAME) |
    .spec.machineInventoryLabels["elemental.cattle.io/role"] = strenv(NODE_ROLE) |
    .spec.config.elemental.install.device = strenv(NODE_INSTALL_DEVICE) |
    .spec.machineInventorySelectorTemplate.spec.selector.matchLabels["elemental.cattle.io/hostname"] = strenv(NODE_HOSTNAME)
  ' "${TEMPLATES_DIR}/machine-registration.tpl.yaml" > "${out_dir}/machine-registration.yaml"

  # Render cloud-config (pure cloud-init format, not a Kubernetes resource)
  yq --prettyPrint '
    .hostname = strenv(NODE_HOSTNAME)
  ' "${TEMPLATES_DIR}/cloud-config.tpl.yaml" > "${out_dir}/cloud-config.yaml"

  # Render node-role
  yq --prettyPrint '
    .metadata.name = (strenv(NODE_HOSTNAME) + "-role") |
    .metadata.labels["elemental.cattle.io/hostname"] = strenv(NODE_HOSTNAME) |
    .metadata.labels["elemental.cattle.io/role"] = strenv(NODE_ROLE) |
    .metadata.labels = (.metadata.labels * (strenv(NODE_LABELS_JSON) | from_json)) |
    .spec.role = strenv(NODE_ROLE) |
    .spec.hostname = strenv(NODE_HOSTNAME) |
    .spec.nodeLabels = (strenv(NODE_LABELS_JSON) | from_json) |
    .spec.nodeTaints = (strenv(NODE_TAINTS_JSON) | from_json)
  ' "${TEMPLATES_DIR}/node-role.tpl.yaml" > "${out_dir}/node-role.yaml"

  # Render cluster-node
  yq --prettyPrint '
    .metadata.name = strenv(NODE_HOSTNAME) |
    .metadata.labels["elemental.cattle.io/hostname"] = strenv(NODE_HOSTNAME) |
    .metadata.labels["elemental.cattle.io/role"] = strenv(NODE_ROLE) |
    .metadata.labels = (.metadata.labels * (strenv(NODE_LABELS_JSON) | from_json)) |
    .spec.hostname = strenv(NODE_HOSTNAME) |
    .spec.role = strenv(NODE_ROLE) |
    .spec.cluster = strenv(NODE_ENVIRONMENT)
  ' "${TEMPLATES_DIR}/cluster-node.tpl.yaml" > "${out_dir}/cluster-node.yaml"

  # Render seed-image config
  local cluster_name="${env_name}"
  local reg_name="${registration_group:-${env_name}-registration}"
  export NODE_CLUSTER_NAME="${cluster_name}"
  export NODE_REG_NAME="${reg_name}"

  yq --prettyPrint '
    .metadata.name = (strenv(NODE_HOSTNAME) + "-seed") |
    .metadata.labels["elemental.cattle.io/cluster"] = strenv(NODE_CLUSTER_NAME) |
    .spec.registrationRef.name = strenv(NODE_REG_NAME) |
    .spec.registrationRef.namespace = "fleet-default"
  ' "${TEMPLATES_DIR}/seed-image.tpl.yaml" > "${out_dir}/seed-image.yaml"

  echo "  Output written to ${out_dir}/"
}

render_environment() {
  local env_name="$1"
  local nodes_dir="${REPO_ROOT}/nodes/${env_name}"

  if [[ ! -d "${nodes_dir}" ]]; then
    echo "ERROR: Node directory not found: ${nodes_dir}" >&2
    exit 1
  fi

  local count=0
  for node_file in "${nodes_dir}"/*.yaml; do
    if [[ ! -f "${node_file}" ]]; then
      echo "WARNING: No node definition files found in ${nodes_dir}/" >&2
      break
    fi
    render_node "${node_file}"
    count=$((count + 1))
  done
  echo "Rendered ${count} node(s) for environment: ${env_name}"
}

usage() {
  echo "Usage: $0 <node-file.yaml>" >&2
  echo "       $0 --env <environment>   (lab|staging|production|examples)" >&2
  echo "       $0 --all                 (render all environments)" >&2
  exit 1
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
  fi

  case "$1" in
    --all)
      local total=0
      for env_name in "${VALID_ENVS[@]}"; do
        local nodes_dir="${REPO_ROOT}/nodes/${env_name}"
        if [[ ! -d "${nodes_dir}" ]]; then
          continue
        fi
        for node_file in "${nodes_dir}"/*.yaml; do
          if [[ ! -f "${node_file}" ]]; then
            continue
          fi
          render_node "${node_file}"
          total=$((total + 1))
        done
      done
      echo "Rendered ${total} node(s) across all environments."
      ;;
    --env)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --env requires an environment name." >&2
        usage
      fi
      render_environment "$2"
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      usage
      ;;
    *)
      render_node "$1"
      ;;
  esac
}

main "$@"
