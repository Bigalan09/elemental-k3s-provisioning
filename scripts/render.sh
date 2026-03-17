#!/usr/bin/env bash
# render.sh - Render Elemental node configuration artefacts from templates and node definition files.
#
# Usage:
#   bash scripts/render.sh nodes/examples/server-01.yaml   # render a single node
#   bash scripts/render.sh --all                           # render all nodes under nodes/examples/

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_DIR="${REPO_ROOT}/templates"
NODES_DIR="${REPO_ROOT}/nodes/examples"
DIST_DIR="${REPO_ROOT}/dist"

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required but not found in PATH. Install yq v4 before running this script." >&2
  exit 1
fi

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

  # Export environment variables for use by yq strenv() and env()
  # Structured fields (arrays and maps) are exported as compact JSON
  # so that yq can parse them back with from_json.
  export NODE_HOSTNAME="${hostname}"
  export NODE_ROLE="${role}"
  export NODE_INSTALL_DEVICE="${install_device}"

  NODE_SSH_KEYS_JSON="$(yq -o=json -I0 '.sshAuthorizedKeys // []' "${node_file}")"
  export NODE_SSH_KEYS_JSON

  NODE_LABELS_JSON="$(yq -o=json -I0 '.labels // {}' "${node_file}")"
  export NODE_LABELS_JSON

  NODE_TAINTS_JSON="$(yq -o=json -I0 '.taints // []' "${node_file}")"
  export NODE_TAINTS_JSON

  local out_dir="${DIST_DIR}/${hostname}"
  mkdir -p "${out_dir}"

  echo "Rendering node: ${hostname} (role=${role})"

  # Render machine-registration
  yq --prettyPrint '
    .metadata.name = strenv(NODE_HOSTNAME) |
    .metadata.labels["elemental.cattle.io/hostname"] = strenv(NODE_HOSTNAME) |
    .spec.machineInventoryLabels = (.spec.machineInventoryLabels * (strenv(NODE_LABELS_JSON) | from_json)) |
    .spec.machineInventoryLabels["elemental.cattle.io/hostname"] = strenv(NODE_HOSTNAME) |
    .spec.machineInventoryLabels["elemental.cattle.io/role"] = strenv(NODE_ROLE) |
    .spec.config["cloud-init"].users[0].ssh_authorized_keys = (strenv(NODE_SSH_KEYS_JSON) | from_json) |
    .spec.config.elemental.install.device = strenv(NODE_INSTALL_DEVICE) |
    .spec.machineInventorySelectorTemplate.spec.selector.matchLabels["elemental.cattle.io/hostname"] = strenv(NODE_HOSTNAME)
  ' "${TEMPLATES_DIR}/machine-registration.tpl.yaml" > "${out_dir}/machine-registration.yaml"

  # Render cloud-config (pure cloud-init format, not a Kubernetes resource)
  yq --prettyPrint '
    .hostname = strenv(NODE_HOSTNAME) |
    .users[0].ssh_authorized_keys = (strenv(NODE_SSH_KEYS_JSON) | from_json)
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
    .spec.role = strenv(NODE_ROLE)
  ' "${TEMPLATES_DIR}/cluster-node.tpl.yaml" > "${out_dir}/cluster-node.yaml"

  echo "  Output written to ${out_dir}/"
}

main() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <node-file.yaml>" >&2
    echo "       $0 --all" >&2
    exit 1
  fi

  if [[ "$1" == "--all" ]]; then
    local count=0
    for node_file in "${NODES_DIR}"/*.yaml; do
      if [[ ! -f "${node_file}" ]]; then
        echo "WARNING: No node definition files found in ${NODES_DIR}/" >&2
        break
      fi
      render_node "${node_file}"
      count=$((count + 1))
    done
    echo "Rendered ${count} node(s)."
  else
    render_node "$1"
  fi
}

main "$@"
