#!/bin/bash
# generate_machineconfigs.sh - Compile MachineConfig manifests from
# butane sources (openperouter-master/worker, dns, registry), and render the
# CSR auto-approver manifest from the installation's agent-config.yaml.
#
# Usage: generate_machineconfigs.sh <output_dir>
#
#   output_dir  Directory where the MachineConfig YAML files are written
#
# Requires: butane

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRASDIR="$(cd "${SCRIPTDIR}/../extras" && pwd)"

output_dir="$1"
mkdir -p "${output_dir}"

if ! command -v butane &>/dev/null; then
    echo "ERROR: butane is required but not found. Install with: sudo dnf install butane"
    exit 1
fi

if ! command -v yq &>/dev/null; then
    echo "ERROR: yq is required to render the CSR auto-approver manifest. Install with: pip install yq"
    exit 1
fi

echo "==> Generating MachineConfig manifests into ${output_dir}..."

if [[ -f "${SCRIPTDIR}/openperouter-master.bu" ]]; then
    echo "  openperouter-master.bu -> 99-master-openperouter.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/openperouter-master.bu" \
        -o "${output_dir}/99-master-openperouter.yaml"
fi

if [[ -f "${SCRIPTDIR}/openperouter-worker.bu" ]]; then
    echo "  openperouter-worker.bu -> 99-worker-openperouter.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/openperouter-worker.bu" \
        -o "${output_dir}/99-worker-openperouter.yaml"
fi

if [[ -f "${SCRIPTDIR}/registry.bu" ]]; then
    echo "  registry.bu -> 01-master-registry.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/registry.bu" \
        -o "${output_dir}/01-master-registry.yaml"
fi

if [[ -f "${SCRIPTDIR}/registry-worker.bu" ]]; then
    echo "  registry-worker.bu -> 01-worker-registry.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/registry-worker.bu" \
        -o "${output_dir}/01-worker-registry.yaml"
fi

if [[ -f "${SCRIPTDIR}/if-mtu.bu" ]]; then
    echo "  if-mtu.bu -> 01-master-if-mtu.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/if-mtu.bu" \
        -o "${output_dir}/99-master-if-mtu.yaml"
fi

if [[ -f "${SCRIPTDIR}/if-mtu-worker.bu" ]]; then
    echo "  if-mtu-worker.bu -> 01-worker-if-mtu.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/if-mtu-worker.bu" \
        -o "${output_dir}/99-worker-if-mtu.yaml"
fi

echo "  set-cluster-mtu.yaml"
cp "${EXTRASDIR}/config/set-cluster-mtu.yaml" "${output_dir}/set-cluster-mtu.yaml"

# Render a CSR approver whose allow-list follows the declared Agent hosts.
# This prevents it from approving CSRs for arbitrary node names.
csr_template="${EXTRASDIR}/config/99-csr-auto-approver.yaml.in"
agent_config="${SCRIPTDIR}/agent-config.yaml"
if [[ ! -f "${csr_template}" || ! -f "${agent_config}" ]]; then
    echo "ERROR: CSR auto-approver template or agent-config.yaml is missing" >&2
    exit 1
fi

mapfile -t approved_nodes < <(yq -r '.hosts[].hostname' "${agent_config}")
if [[ "${#approved_nodes[@]}" -eq 0 ]]; then
    echo "ERROR: No hostnames found in ${agent_config}" >&2
    exit 1
fi
for node in "${approved_nodes[@]}"; do
    # Kubernetes node names may be FQDNs. Permit DNS labels separated by dots,
    # while enforcing the 63-character per-label and 253-character total limits.
    if [[ "${#node}" -gt 253 ]] || \
       [[ ! "${node}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        echo "ERROR: Invalid hostname in ${agent_config}: ${node}" >&2
        exit 1
    fi
done
allowed_nodes="${approved_nodes[*]}"
echo "  99-csr-auto-approver.yaml (nodes: ${allowed_nodes})"
sed "s|__ALLOWED_NODE_NAMES__|${allowed_nodes}|g" "${csr_template}" \
    > "${output_dir}/99-csr-auto-approver.yaml"

echo "==> MachineConfig manifests generated."
