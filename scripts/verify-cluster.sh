#!/usr/bin/env bash
# verify-cluster.sh — post-deploy smoke tests.
#
# Runs the checks a TA should always run before handing keys out:
#   1. Parent stack + budget stack in CREATE_COMPLETE / UPDATE_COMPLETE
#   2. `pcluster describe-cluster` reports CREATE_COMPLETE
#   3. `sinfo` on the head node shows the nki partition with expected node count
#   4. `neuron-ls` on a compute node shows 4 NeuronCores
#   5. The Slurm gres advertises `neuroncore:4` on each compute node
#
# Requires SSH access to the head node from the caller's IP (must be within
# the SshAllowedCidr passed at deploy time). Uses the admin ubuntu key.

set -euo pipefail

CLUSTER_NAME=""; REGION=""; ADMIN_KEY_PATH=""
while (( $# )); do
  case "$1" in
    --cluster-name)  CLUSTER_NAME="$2"; shift 2;;
    --region)        REGION="$2"; shift 2;;
    --admin-key-path) ADMIN_KEY_PATH="$2"; shift 2;;
    -h|--help) echo "usage: $0 --cluster-name NAME --region REGION [--admin-key-path FILE]"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "${CLUSTER_NAME}" && -n "${REGION}" ]] || { echo "cluster-name + region required" >&2; exit 2; }

PARENT_STACK="${CLUSTER_NAME}-parent"
BUDGET_STACK="${CLUSTER_NAME}-budget"

pass=0; fail=0
check() {
  local name="$1" out="$2" ok="$3"
  # Use `x=$((x + 1))` (assignment, always exit 0) rather than `((x++))`: under
  # `set -e`, `((pass++))` returns non-zero the first time pass goes 0 -> 1 (the
  # post-increment evaluates to the old value 0, and (( )) exits 1 on a zero
  # result), which would abort the whole script right after its first PASS.
  if [[ "${ok}" == "true" ]]; then
    echo "  [PASS] ${name}"; pass=$((pass + 1))
  else
    echo "  [FAIL] ${name}: ${out}"; fail=$((fail + 1))
  fi
}

echo "==> CFN stack states"
for stack in "${PARENT_STACK}" "${BUDGET_STACK}"; do
  status=$(aws cloudformation describe-stacks --stack-name "${stack}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NOT_FOUND)
  ok=false
  [[ "${status}" == "CREATE_COMPLETE" || "${status}" == "UPDATE_COMPLETE" ]] && ok=true
  check "${stack} = ${status}" "${status}" "${ok}"
done

echo "==> pcluster state"
pc_status=$(pcluster describe-cluster --cluster-name "${CLUSTER_NAME}" --region "${REGION}" 2>/dev/null | jq -r '.clusterStatus // "NOT_FOUND"' 2>/dev/null || echo NOT_FOUND)
ok=false; [[ "${pc_status}" == "CREATE_COMPLETE" ]] && ok=true
check "pcluster ${CLUSTER_NAME} = ${pc_status}" "${pc_status}" "${ok}"

# ---------------------------------------------------------------------------
# Head-node security group has NO open SSH ingress (Requirements 14.1 / 14.2;
# design Property 9). This validates Property 9: no public SSH exposure.
#
# Property 9: for the deployed head-node security group, NO ingress rule may
# source `CidrIp` 0.0.0.0/0 or `CidrIpv6` ::/0, and the ONLY ingress permitted
# is TCP/22 from the operator-supplied SshAllowedCidr range(s). The parent stack
# defines exactly that one rule (tcp 22-22 from SshAllowedCidr) and attaches
# this SG to the head node as an *additional* SG, so ParallelCluster layers its
# intra-cluster traffic onto its OWN managed SG and leaves this SG tcp/22-only.
# Verifying the LIVE SG catches drift -- a hand-edited rule, a widened CIDR, or
# the classic tcp/22-from-0.0.0.0/0 mistake -- that would expose the head node
# to the public internet, the exact exposure Req 14.2 forbids.
#
# This is an `aws ec2 describe-security-groups` check, NOT an SSH probe, so it
# is placed BEFORE the SSH-gated early exits below and runs on every invocation
# (it needs only AWS APIs -- no head-node public IP or admin key required). We
# resolve the SG id from the parent stack output `HeadNodeSecurityGroupId`
# (reusing the describe-stacks output idiom from the stack-state checks above),
# then read each ingress permission's IpProtocol/FromPort/ToPort via a plain
# multiselect and let a server-side JMESPath filter flag any rule sourcing
# 0.0.0.0/0 or ::/0 -- no jq dependency, no fragile empty-column text parsing.
# A rule sourcing 0.0.0.0/0 or ::/0 is a public-exposure FAIL (Req 14.2); a rule
# that is not tcp/22 is a "deny all other inbound" FAIL (Req 14.1). Offending
# rules are named (proto/from-to) so the operator sees exactly what diverged.
echo "==> head-node SG: no open SSH ingress (Property 9 / Req 14.1, 14.2)"
head_sg=$(aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='HeadNodeSecurityGroupId'].OutputValue | [0]" \
  --output text 2>/dev/null || echo "")

if [[ -z "${head_sg}" || "${head_sg}" == "None" ]]; then
  check "head-node SG resolves (${PARENT_STACK} output HeadNodeSecurityGroupId)" \
    "could not read HeadNodeSecurityGroupId from stack '${PARENT_STACK}' in ${REGION} -- cannot verify SSH ingress (Property 9)" false
else
  # All ingress rules as proto<TAB>from<TAB>to rows (multiselect: rows are
  # newline-separated, the three columns are never empty -- an all-traffic rule
  # renders its absent ports as 'None' -- so tab-parsing is unambiguous).
  sg_ingress=$(aws ec2 describe-security-groups --group-ids "${head_sg}" --region "${REGION}" \
    --query "SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort]" \
    --output text 2>/dev/null || echo "__ERR__")
  # Server-side filter: only the rules whose source is the whole internet
  # (IPv4 0.0.0.0/0 OR IPv6 ::/0). Empty result => no public exposure.
  sg_world=$(aws ec2 describe-security-groups --group-ids "${head_sg}" --region "${REGION}" \
    --query "SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp=='0.0.0.0/0'] || Ipv6Ranges[?CidrIpv6=='::/0']].[IpProtocol,FromPort,ToPort]" \
    --output text 2>/dev/null || echo "__ERR__")

  if [[ "${sg_ingress}" == "__ERR__" || "${sg_world}" == "__ERR__" ]]; then
    check "head-node SG ${head_sg} readable (describe-security-groups)" \
      "aws ec2 describe-security-groups failed for ${head_sg} in ${REGION} -- cannot verify SSH ingress (Property 9)" false
  else
    # (a) Req 14.2 / Property 9 core: no ingress rule open to the whole internet.
    world_desc=""
    while IFS=$'\t' read -r w_proto w_from w_to; do
      [[ -z "${w_proto}" ]] && continue
      world_desc="${world_desc:+${world_desc}; }${w_proto}/${w_from}-${w_to}"
    done <<< "${sg_world}"
    if [[ -n "${world_desc}" ]]; then
      check "head-node SG ${head_sg}: no public SSH ingress (0.0.0.0/0 or ::/0)" \
        "PUBLIC ingress rule(s) [${world_desc}] source 0.0.0.0/0 or ::/0 on ${head_sg} -- head node is exposed to the internet (Property 9, Req 14.2)" false
    else
      check "head-node SG ${head_sg}: no public SSH ingress (0.0.0.0/0 or ::/0)" "no world-open rule" true
    fi

    # (b) Req 14.1: the ONLY ingress is tcp/22; deny all other inbound.
    rule_count=0; proto_desc=""
    while IFS=$'\t' read -r i_proto i_from i_to; do
      [[ -z "${i_proto}" ]] && continue
      rule_count=$((rule_count + 1))
      if [[ "${i_proto}" != "tcp" || "${i_from}" != "22" || "${i_to}" != "22" ]]; then
        proto_desc="${proto_desc:+${proto_desc}; }${i_proto}/${i_from}-${i_to}"
      fi
    done <<< "${sg_ingress}"

    if [[ "${rule_count}" -eq 0 ]]; then
      check "head-node SG ${head_sg}: ingress is TCP/22 only" \
        "no ingress rules on ${head_sg} -- expected exactly TCP/22 from SshAllowedCidr (Property 9, Req 14.1)" false
    elif [[ -n "${proto_desc}" ]]; then
      check "head-node SG ${head_sg}: ingress is TCP/22 only" \
        "non-TCP/22 ingress rule(s) [${proto_desc}] on ${head_sg} -- Req 14.1 requires denying all inbound except TCP/22" false
    else
      # PASS path only: surface the allowed source CIDR(s) in the check name
      # (check() prints the name, not the detail, on PASS). All rules are tcp/22
      # here, so every IpRanges CIDR is an operator-supplied SSH source.
      allowed_v4=$(aws ec2 describe-security-groups --group-ids "${head_sg}" --region "${REGION}" \
        --query "SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp" \
        --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' | paste -sd, - || true)
      check "head-node SG ${head_sg}: ingress is TCP/22 only (from ${allowed_v4:-SshAllowedCidr})" \
        "${rule_count} rule(s), all tcp/22" true
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Compute isolation (Requirements 14.3 / 14.4; design Property 10). This
# validates Property 10: students can reach the compute fleet ONLY by
# submitting jobs to the Slurm scheduler on the head node (sbatch/srun) -- there
# is NO direct inbound network path from a student-originated source to a
# compute node. Two independent, AWS-only assertions (no SSH, no head-node
# public IP, no admin key), so this sits with the head-node SG check ABOVE the
# SSH-gated early exits and runs on every invocation:
#
#   (a) The compute security group (parent stack output ComputeSecurityGroupId)
#       grants NO student-reachable inbound access (Req 14.3). The parent stack
#       defines this SG with ZERO ingress -- ParallelCluster layers its intra-
#       cluster slurmd/munge rules onto its OWN managed SG -- so the expected
#       live state is: no rule sourcing 0.0.0.0/0 or ::/0 AND no IP-range (CIDR)
#       source at all; only SG-to-SG (UserIdGroupPairs) references are intra-
#       cluster and therefore student-unreachable. A world-open rule is public
#       exposure; any other CIDR source is a reachable IP path. Both FAIL and
#       name the offending rule. Inspecting the LIVE SG catches drift -- a
#       hand-added ingress rule that would breach Req 14.3.
#
#   (b) No compute node has a public IP (Req 14.3 "no public IP addresses
#       assigned to compute nodes"; Req 14.4 "no direct inbound path"). We list
#       the cluster's compute instances by the ParallelCluster-injected tags
#       (parallelcluster:cluster-name + parallelcluster:node-type=Compute -- NOT
#       the shared `Class` tag, which also matches the HEAD node, which
#       legitimately HAS a public IP) in the running state and assert
#       PublicIpAddress is absent for every one. A public IP on a compute node
#       is a direct student-reachable path -> FAIL naming the instance id(s).
#
# Reuses the describe-stacks output idiom and the JMESPath server-side world-
# open filter from the head-node SG check above; no jq, no SSH.
echo "==> compute isolation: no student-reachable ingress, no public IPs (Property 10 / Req 14.3, 14.4)"
compute_sg=$(aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='ComputeSecurityGroupId'].OutputValue | [0]" \
  --output text 2>/dev/null || echo "")

if [[ -z "${compute_sg}" || "${compute_sg}" == "None" ]]; then
  check "compute SG resolves (${PARENT_STACK} output ComputeSecurityGroupId)" \
    "could not read ComputeSecurityGroupId from stack '${PARENT_STACK}' in ${REGION} -- cannot verify compute ingress (Property 10)" false
else
  # All ingress rules as proto<TAB>from<TAB>to rows (same multiselect as the
  # head-node SG block: 'None' fills absent ports so tab-parsing is unambiguous).
  csg_ingress=$(aws ec2 describe-security-groups --group-ids "${compute_sg}" --region "${REGION}" \
    --query "SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort]" \
    --output text 2>/dev/null || echo "__ERR__")
  # Rules whose source is the whole internet (IPv4 0.0.0.0/0 OR IPv6 ::/0).
  csg_world=$(aws ec2 describe-security-groups --group-ids "${compute_sg}" --region "${REGION}" \
    --query "SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp=='0.0.0.0/0'] || Ipv6Ranges[?CidrIpv6=='::/0']].[IpProtocol,FromPort,ToPort]" \
    --output text 2>/dev/null || echo "__ERR__")
  # Rules carrying ANY IP-range (CIDR) source -- i.e. NOT an intra-cluster
  # SG-to-SG reference. On the compute SG these should not exist at all: compute
  # ingress must come only from the head/compute SGs (Req 14.3), never an IP.
  csg_cidr=$(aws ec2 describe-security-groups --group-ids "${compute_sg}" --region "${REGION}" \
    --query "SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp] || Ipv6Ranges[?CidrIpv6]].[IpProtocol,FromPort,ToPort]" \
    --output text 2>/dev/null || echo "__ERR__")

  if [[ "${csg_ingress}" == "__ERR__" || "${csg_world}" == "__ERR__" || "${csg_cidr}" == "__ERR__" ]]; then
    check "compute SG ${compute_sg} readable (describe-security-groups)" \
      "aws ec2 describe-security-groups failed for ${compute_sg} in ${REGION} -- cannot verify compute isolation (Property 10)" false
  else
    # (a-i) core: no ingress rule open to the whole internet (Req 14.3).
    cworld_desc=""
    while IFS=$'\t' read -r w_proto w_from w_to; do
      [[ -z "${w_proto}" ]] && continue
      cworld_desc="${cworld_desc:+${cworld_desc}; }${w_proto}/${w_from}-${w_to}"
    done <<< "${csg_world}"
    if [[ -n "${cworld_desc}" ]]; then
      check "compute SG ${compute_sg}: no public ingress (0.0.0.0/0 or ::/0)" \
        "PUBLIC ingress rule(s) [${cworld_desc}] source 0.0.0.0/0 or ::/0 on ${compute_sg} -- compute is exposed to the internet, students could reach it directly (Property 10, Req 14.3/14.4)" false
    else
      check "compute SG ${compute_sg}: no public ingress (0.0.0.0/0 or ::/0)" "no world-open rule" true
    fi

    # (a-ii) intra-cluster only: no IP-range (CIDR) source -- only SG-to-SG
    # references are student-unreachable. Count total ingress rules to
    # distinguish the expected "zero ingress" from an "SG-only" state.
    ccidr_desc=""
    while IFS=$'\t' read -r c_proto c_from c_to; do
      [[ -z "${c_proto}" ]] && continue
      ccidr_desc="${ccidr_desc:+${ccidr_desc}; }${c_proto}/${c_from}-${c_to}"
    done <<< "${csg_cidr}"
    cingress_count=0
    while IFS=$'\t' read -r i_proto i_from i_to; do
      [[ -z "${i_proto}" ]] && continue
      cingress_count=$((cingress_count + 1))
    done <<< "${csg_ingress}"
    if [[ -n "${ccidr_desc}" ]]; then
      check "compute SG ${compute_sg}: ingress is intra-cluster only (no IP-range source)" \
        "IP-range (CIDR) ingress rule(s) [${ccidr_desc}] on ${compute_sg} -- compute must accept traffic only from the head/compute SGs, not any IP range -- this is a student-reachable path (Property 10, Req 14.3/14.4)" false
    elif [[ "${cingress_count}" -eq 0 ]]; then
      check "compute SG ${compute_sg}: ingress is intra-cluster only (0 ingress rules)" "no ingress rules" true
    else
      check "compute SG ${compute_sg}: ingress is intra-cluster only (${cingress_count} SG-to-SG rule(s))" \
        "${cingress_count} rule(s), all SG-sourced" true
    fi
  fi
fi

# (b) No compute node carries a public IP. Filter by the ParallelCluster tags
# (parallelcluster:cluster-name + parallelcluster:node-type=Compute) so the head
# node -- which legitimately has a public IP -- is EXCLUDED (the shared `Class`
# tag would wrongly match it). Zero running compute instances is not a violation
# (nothing student-reachable exists, so isolation holds vacuously -- e.g. parent-
# only, pre-cluster, or after the block ended); a public IP on any is.
compute_pubips=$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:parallelcluster:cluster-name,Values=${CLUSTER_NAME}" \
            "Name=tag:parallelcluster:node-type,Values=Compute" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].[InstanceId,PublicIpAddress]" \
  --output text 2>/dev/null || echo "__ERR__")

if [[ "${compute_pubips}" == "__ERR__" ]]; then
  check "compute nodes have no public IP" \
    "aws ec2 describe-instances failed for cluster '${CLUSTER_NAME}' in ${REGION} -- cannot verify compute nodes lack public IPs (Property 10, Req 14.3)" false
else
  offending_pubips=""; compute_inst_count=0
  # text output renders an absent PublicIpAddress as the literal 'None'.
  while IFS=$'\t' read -r inst_id pub_ip; do
    [[ -z "${inst_id}" ]] && continue
    compute_inst_count=$((compute_inst_count + 1))
    if [[ -n "${pub_ip}" && "${pub_ip}" != "None" ]]; then
      offending_pubips="${offending_pubips:+${offending_pubips} }${inst_id}(${pub_ip})"
    fi
  done <<< "${compute_pubips}"

  if [[ -n "${offending_pubips}" ]]; then
    check "compute nodes have no public IP" \
      "compute instance(s) with a public IP: ${offending_pubips} -- a public IP is a direct student-reachable path to compute, which Req 14.4 forbids (students must go through the head-node Slurm scheduler) (Property 10)" false
  elif [[ "${compute_inst_count}" -eq 0 ]]; then
    check "compute nodes have no public IP (no running compute instances found)" \
      "0 running compute nodes tagged parallelcluster:node-type=Compute for '${CLUSTER_NAME}' -- isolation holds vacuously" true
  else
    check "all ${compute_inst_count} compute node(s) have no public IP" \
      "no PublicIpAddress on any compute node" true
  fi
fi

echo "==> head node reachable"
HEAD_IP=$(pcluster describe-cluster --cluster-name "${CLUSTER_NAME}" --region "${REGION}" 2>/dev/null | jq -r '.headNode.publicIpAddress // empty' 2>/dev/null || echo "")

if [[ -z "${HEAD_IP}" || "${HEAD_IP}" == "None" ]]; then
  check "head node has a public IP" "no IP" false
  echo ""
  echo "verify-cluster (${pass} passed, ${fail} failed)"
  (( fail == 0 )) && exit 0 || exit 1
fi

if [[ -z "${ADMIN_KEY_PATH}" ]]; then
  echo "  (skipping SSH-based checks; pass --admin-key-path to enable)"
  echo ""
  echo "verify-cluster (${pass} passed, ${fail} failed)"
  (( fail == 0 )) && exit 0 || exit 1
fi

ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i "${ADMIN_KEY_PATH}")

echo "==> Slurm view of the cluster"
sinfo_out=$(ssh "${ssh_opts[@]}" "ubuntu@${HEAD_IP}" 'sinfo -h -o "%P %D %t"' 2>&1 || echo ERROR)
if echo "${sinfo_out}" | grep -q '^nki '; then
  check "nki partition present" "${sinfo_out}" true
else
  check "nki partition present" "${sinfo_out}" false
fi

echo "==> Neuron gres advertised"
gres_out=$(ssh "${ssh_opts[@]}" "ubuntu@${HEAD_IP}" \
  'scontrol -o show nodes 2>/dev/null | grep -oE "Gres=[^ ]*neuroncore[^ ]*"' 2>&1 || echo ERROR)
if echo "${gres_out}" | grep -q 'neuroncore'; then
  check "neuroncore gres advertised" "${gres_out}" true
else
  check "neuroncore gres advertised" "${gres_out}" false
fi

# ---------------------------------------------------------------------------
# gres NodeName pattern vs. live node names (Requirement 11.5 / design Property 8
# registration precondition; divergence D6).
#
# ParallelCluster appends the rendered `neuroncore-gres.conf` to slurm.conf via
# `SlurmSettings.CustomSlurmSettingsIncludeFile`. That include carries:
#     GresTypes=neuroncore
#     NodeName=<pattern> Gres=neuroncore:<n>
# The <pattern> (rendered by deploy.sh as `<queue>-st-<resource>-[1-N]`, e.g.
# `nki-st-trn2-[1-4]`) MUST expand to the real PC static compute node names. If
# it drifts from the live names, slurmctld never attaches the neuroncore gres to
# those nodes, so EVERY `sbatch --gres=neuroncore:...` job sits PENDING FOREVER
# with no node able to satisfy the request. That silent, hard-to-diagnose hang
# is exactly the D6 symptom this check guards against.
#
# One SSH round-trip gathers: the configured NodeName pattern + gres count read
# back out of slurm.conf, the pattern expanded with `scontrol show hostnames`,
# the live node names, and each node's advertised Gres. We then assert (a) the
# include pattern matches every live compute node, and (b) every live compute
# node actually advertises the neuroncore gres at the configured count.
echo "==> gres NodeName pattern matches live nodes (D6 registration precondition)"
# NOTE: single-quoted remote command (double quotes only inside) so nothing is
# expanded locally; all $vars/$(...) are evaluated by the head node's shell.
gres_probe_cmd='conf=$(scontrol show config 2>/dev/null | sed -n "s/^SLURM_CONF[[:space:]]*=[[:space:]]*//p" | head -n1); [ -n "$conf" ] || conf=/opt/slurm/etc/slurm.conf; etc=$(dirname "$conf"); gline=$(grep -rhoE "^[[:space:]]*NodeName=[^[:space:]]+[[:space:]]+.*Gres=[^[:space:]]*neuroncore[^[:space:]]*" "$etc" 2>/dev/null | head -n1); pat=$(printf "%s" "$gline" | grep -oE "NodeName=[^[:space:]]+" | head -n1 | cut -d= -f2); cnt=$(printf "%s" "$gline" | grep -oE "neuroncore:[0-9]+" | head -n1 | cut -d: -f2); echo "PATTERN=${pat:-<none>}"; echo "CONFCOUNT=${cnt:-<none>}"; if [ -n "$pat" ]; then echo "EXPANDED=$(scontrol show hostnames "$pat" 2>/dev/null | sort | paste -sd, -)"; else echo "EXPANDED="; fi; echo "ACTUAL=$(scontrol -o show nodes 2>/dev/null | grep -oE "NodeName=[^[:space:]]+" | cut -d= -f2 | sort | paste -sd, -)"; scontrol -o show nodes 2>/dev/null | while read -r nl; do nn=$(printf "%s" "$nl" | grep -oE "NodeName=[^[:space:]]+" | cut -d= -f2); gg=$(printf "%s" "$nl" | grep -oE "Gres=[^[:space:]]+" | cut -d= -f2-); echo "NODEGRES ${nn:-?} ${gg:-<none>}"; done'
gres_probe=$(ssh "${ssh_opts[@]}" "ubuntu@${HEAD_IP}" "${gres_probe_cmd}" 2>&1 || echo "ERROR")

cfg_pattern=$(printf '%s\n' "${gres_probe}" | sed -n 's/^PATTERN=//p')
conf_count=$(printf '%s\n' "${gres_probe}" | sed -n 's/^CONFCOUNT=//p')
expanded_csv=$(printf '%s\n' "${gres_probe}" | sed -n 's/^EXPANDED=//p')
actual_csv=$(printf '%s\n' "${gres_probe}" | sed -n 's/^ACTUAL=//p')

# (a) every live compute node name must be covered by the include NodeName pattern
missing_nodes=""
if [[ -n "${actual_csv}" ]]; then
  for n in ${actual_csv//,/ }; do
    case ",${expanded_csv}," in
      *",${n},"*) : ;;
      *) missing_nodes="${missing_nodes:+${missing_nodes} }${n}" ;;
    esac
  done
fi

if [[ -z "${cfg_pattern}" || "${cfg_pattern}" == "<none>" ]]; then
  check "gres NodeName line present in slurm.conf" \
    "no 'NodeName=... Gres=...neuroncore' line found under the slurm config dir; probe: ${gres_probe}" false
elif [[ -z "${actual_csv}" ]]; then
  check "gres NodeName pattern matches live nodes" \
    "scontrol reported no compute nodes; probe: ${gres_probe}" false
elif [[ -n "${missing_nodes}" ]]; then
  # divergence: name the offending pattern so the operator can see the drift.
  check "gres NodeName pattern matches live nodes" \
    "include NodeName pattern '${cfg_pattern}' (expands to [${expanded_csv}]) does not match live compute node(s): ${missing_nodes} -- neuroncore gres will not register on those nodes and --gres jobs will hang pending (D6)" false
else
  check "gres NodeName pattern '${cfg_pattern}' matches live nodes" "${actual_csv}" true
fi

# (b) every live compute node must advertise the neuroncore gres at the
# configured count (Gres=...neuroncore:4 on a trn2.3xl, or the node's core count
# on other instance types). A node with a missing/(null) or wrong-count gres is
# a node whose --gres=neuroncore jobs can never be scheduled -> pending forever.
bad_gres_nodes=""
node_total=0
while read -r tag nn gval; do
  [[ "${tag}" == "NODEGRES" ]] || continue
  node_total=$((node_total + 1))
  if [[ "${gval}" =~ neuroncore:([0-9]+) ]]; then
    core="${BASH_REMATCH[1]}"
  else
    core=""
  fi
  if [[ -z "${core}" ]]; then
    bad_gres_nodes="${bad_gres_nodes:+${bad_gres_nodes} }${nn}(gres=${gval})"
  elif [[ "${conf_count}" =~ ^[0-9]+$ && "${core}" != "${conf_count}" ]]; then
    bad_gres_nodes="${bad_gres_nodes:+${bad_gres_nodes} }${nn}(neuroncore:${core}!=${conf_count})"
  fi
done <<< "${gres_probe}"

if [[ "${conf_count}" =~ ^[0-9]+$ ]]; then
  exp_desc="neuroncore:${conf_count}"
else
  exp_desc="a neuroncore:<count> gres"
fi
if [[ "${node_total}" -eq 0 ]]; then
  check "every compute node advertises ${exp_desc}" \
    "no compute nodes reported by scontrol; probe: ${gres_probe}" false
elif [[ -n "${bad_gres_nodes}" ]]; then
  check "every compute node advertises ${exp_desc}" \
    "node(s) not advertising the expected neuroncore gres: ${bad_gres_nodes} -- these nodes' --gres=neuroncore jobs stay pending forever (D6)" false
else
  check "all ${node_total} compute node(s) advertise ${exp_desc}" "${actual_csv}" true
fi

# ---------------------------------------------------------------------------
# Per-student Slurm limits are ACTUALLY wired on the QoS/associations
# (Requirements 18.1 / 18.2 / 18.3, plus optional 18.5; design divergence D5).
#
# D5's whole point: the PRD promised per-student caps (MaxWallTime,
# MaxConcurrentJobs, MaxCores, and a core-hours budget) but the original
# implementation created a bare account+users with NO limits, so nothing was
# enforced -- the only wall-time bound was a self-imposed `#SBATCH --time` a
# student could simply override. bootstrap/head-node-setup.sh (task 3.2) now
# creates a `student-qos` QoS carrying the naturally-per-user caps and pins
# every student's association (under account `trn-course`) to it, plus a
# per-student `GrpTRESMins` core-hours budget on each association when one is
# configured. This check confirms those limits are present on the LIVE cluster
# -- i.e. enforcement is genuinely wired, not merely advisory. A missing cap is
# a FAIL that names the offending limit so the operator sees exactly what did
# not stick.
#
# We query with `-P format=...` (parsable2, no trailing '|') instead of parsing
# sacctmgr's width-truncated default table: with `-n` (no header) the explicit
# format list fixes the column order, so each field maps positionally.
#   QoS   : Name | MaxWall | MaxJobsPU (MaxJobsPerUser) | MaxTRESPU (MaxTRESPerUser)
#   Assoc : Account | User | QOS | GrpTRESMins
# One SSH round-trip emits KEY=value lines parsed locally (same style as the D6
# gres probe above). Single-quoted remote command so $()/${} evaluate on the
# head node; double quotes only inside.
echo "==> per-student Slurm limits wired (D5 enforcement)"
limits_probe_cmd='if ! command -v sacctmgr >/dev/null 2>&1; then echo "SACCTMGR=missing"; exit 0; fi; echo "SACCTMGR=present"; echo "QOSLINE=$(sacctmgr -n -P show qos student-qos format=Name,MaxWall,MaxJobsPU,MaxTRESPU 2>/dev/null | head -n1)"; sacctmgr -n -P show assoc format=Account,User,QOS,GrpTRESMins 2>/dev/null | while IFS= read -r __l; do echo "ASSOC=${__l}"; done'
limits_probe=$(ssh "${ssh_opts[@]}" "ubuntu@${HEAD_IP}" "${limits_probe_cmd}" 2>&1 || echo "SACCTMGR=error")

sacctmgr_state=$(printf '%s\n' "${limits_probe}" | sed -n 's/^SACCTMGR=//p')
qos_line=$(printf '%s\n' "${limits_probe}" | sed -n 's/^QOSLINE=//p')

# (a) student-qos carries the three naturally-per-user caps (18.1 / 18.2 / 18.3).
if [[ "${sacctmgr_state}" != "present" ]]; then
  check "student-qos carries per-student limits" \
    "sacctmgr unavailable/unreadable on the head node (state='${sacctmgr_state:-<none>}') -- Slurm accounting/enforcement is not active, so per-student limits are NOT wired (D5); probe: ${limits_probe}" false
elif [[ -z "${qos_line}" ]]; then
  check "student-qos carries per-student limits" \
    "the 'student-qos' QoS does not exist -- head-node-setup.sh did not create it or accounting is off; per-student limits are NOT enforced (D5)" false
else
  IFS='|' read -r q_name q_maxwall q_maxjobs q_maxtres <<< "${qos_line}" || true
  missing_limits=""
  [[ -n "${q_maxwall}" ]] \
    || missing_limits="${missing_limits:+${missing_limits}, }MaxWall (18.1)"
  [[ "${q_maxjobs}" =~ ^[0-9]+$ ]] \
    || missing_limits="${missing_limits:+${missing_limits}, }MaxJobsPerUser (18.2)"
  [[ "${q_maxtres}" == *neuroncore* ]] \
    || missing_limits="${missing_limits:+${missing_limits}, }MaxTRESPerUser=gres/neuroncore (18.3)"
  if [[ -n "${missing_limits}" ]]; then
    check "student-qos carries per-student limits" \
      "student-qos exists but is missing/unset: ${missing_limits} [MaxWall='${q_maxwall}' MaxJobsPerUser='${q_maxjobs}' MaxTRESPerUser='${q_maxtres}'] -- these caps are not enforced (D5)" false
  else
    check "student-qos limits set (MaxWall=${q_maxwall}, MaxJobsPerUser=${q_maxjobs}, MaxTRESPerUser=${q_maxtres})" \
      "${qos_line}" true
  fi
fi

# (b) per-student core-hours budget on each student association, but only WHERE
# a budget is configured -- Requirement 18.5 is optional. head-node-setup.sh
# clears GrpTRESMins to unlimited (-1) when no positive CORE_HOURS_BUDGET is
# given, so verify-cluster.sh has no deploy-time knowledge of whether a budget
# was set. We therefore infer it from the associations themselves: if ANY
# student association carries a gres/neuroncore GrpTRESMins, a budget is in
# effect and EVERY student association must carry one (a partial apply is a
# bug -> FAIL naming the students missing it). If NONE carry one, the optional
# budget simply was not configured for this deploy -> PASS.
if [[ "${sacctmgr_state}" == "present" ]]; then
  budget_present=false
  assoc_total=0
  assoc_missing_budget=""
  while IFS= read -r aline; do
    IFS='|' read -r a_acct a_user a_qos a_grptresmins <<< "${aline}" || true
    [[ "${a_acct}" == "trn-course" && -n "${a_user}" ]] || continue
    assoc_total=$((assoc_total + 1))
    if [[ "${a_grptresmins}" == *neuroncore=* ]]; then
      budget_present=true
    else
      assoc_missing_budget="${assoc_missing_budget:+${assoc_missing_budget} }${a_user}"
    fi
  done < <(printf '%s\n' "${limits_probe}" | sed -n 's/^ASSOC=//p')

  if [[ "${budget_present}" == "true" && -n "${assoc_missing_budget}" ]]; then
    check "per-student core-hours budget (GrpTRESMins=gres/neuroncore)" \
      "a core-hours budget is configured but these student association(s) lack a gres/neuroncore GrpTRESMins: ${assoc_missing_budget} -- their core-hours cap is NOT enforced (D5, Req 18.5)" false
  elif [[ "${budget_present}" == "true" ]]; then
    check "per-student core-hours budget wired on all ${assoc_total} student association(s)" \
      "GrpTRESMins=gres/neuroncore set" true
  else
    # No student association carries a budget: the optional core-hours cap
    # (18.5) is not configured for this deploy. Not a failure.
    check "per-student core-hours budget (optional 18.5): not configured" \
      "no student association carries a gres/neuroncore GrpTRESMins (${assoc_total} student assoc(s) checked)" true
  fi
fi

# ---------------------------------------------------------------------------
# Head/compute UID agreement for a sample student (Requirement 6.4 / design
# Property 3). Optional identity check.
#
# Property 3 (consistent UID across nodes) & divergence-free identity: every
# student account is created from the ONE shared roster. head-node-setup.sh
# useradd's each student on the head node, and compute-node-setup.sh's
# sync_users_from_roster (plus its 5-min cron) useradd's the SAME {username,uid}
# on every compute node out of /shared/etc/passwd.roster. Because both derive
# from that single roster, a given student's UID MUST be identical on the head
# node and on every compute node: uid_head(user) == uid_compute_i(user).
#
# Why it matters: all student home/work dirs live on the shared EFS mount and
# POSIX ownership is purely numeric. If the head and a compute node disagreed on
# a student's UID, files that student wrote from a compute job would resolve to
# the WRONG (or no) account on the head node -- silent cross-account permission
# leakage on a shared filesystem. This samples the FIRST student in the roster,
# reads its head-node UID, then reads the SAME user's UID on a compute node (its
# passwd db was synced from the same roster) and asserts the two are equal.
#
# One SSH round-trip resolves the sample student from the roster (jq, with a
# grep/sed fallback so the check still works if jq is absent), emits its head
# UID, and emits the compute UID obtained by running `id -u <student>` inside a
# 1-node `srun` (same mechanism the neuron-ls check uses to reach a compute
# node). Single-quoted remote command (double quotes only inside) so $()/${}
# evaluate on the head node; results return as KEY=value lines parsed locally.
echo "==> head/compute UID agreement for a sample student (Property 3 / D-identity)"
uid_probe_cmd='ROSTER=/shared/etc/passwd.roster; student=""; if command -v jq >/dev/null 2>&1 && [ -s "$ROSTER" ]; then student=$(jq -r ".[0].username // empty" "$ROSTER" 2>/dev/null); fi; if [ -z "$student" ] && [ -s "$ROSTER" ]; then student=$(grep -oE "\"username\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$ROSTER" | head -n1 | sed -E "s/.*\"([^\"]+)\"[[:space:]]*$/\1/"); fi; echo "STUDENT=${student:-<none>}"; if [ -n "$student" ]; then echo "HEADUID=$(id -u "$student" 2>/dev/null)"; craw=$(srun -N1 -t 1 id -u "$student" 2>&1); echo "COMPUTEUID=$(printf "%s" "$craw" | grep -oE "^[0-9]+$" | tail -n1)"; echo "COMPUTEMSG=$(printf "%s" "$craw" | tr "\n" " " | tr -d "\r" | cut -c1-200)"; fi'
uid_probe=$(ssh "${ssh_opts[@]}" "ubuntu@${HEAD_IP}" "${uid_probe_cmd}" 2>&1 || echo "ERROR")

sample_student=$(printf '%s\n' "${uid_probe}" | sed -n 's/^STUDENT=//p')
head_uid=$(printf '%s\n' "${uid_probe}" | sed -n 's/^HEADUID=//p')
compute_uid=$(printf '%s\n' "${uid_probe}" | sed -n 's/^COMPUTEUID=//p')
compute_msg=$(printf '%s\n' "${uid_probe}" | sed -n 's/^COMPUTEMSG=//p')

if [[ -z "${sample_student}" || "${sample_student}" == "<none>" ]]; then
  check "head/compute UID agreement" \
    "no student account found in /shared/etc/passwd.roster to sample -- roster is empty/missing (or the head node was unreachable), so identity cannot be verified; probe: ${uid_probe}" false
elif [[ ! "${head_uid}" =~ ^[0-9]+$ ]]; then
  check "head/compute UID agreement" \
    "could not read head-node UID for sample student '${sample_student}' (id -u returned '${head_uid:-<empty>}'); probe: ${uid_probe}" false
elif [[ ! "${compute_uid}" =~ ^[0-9]+$ ]]; then
  check "head/compute UID agreement" \
    "sample student '${sample_student}' has no UID on the compute node (srun 'id -u' -> '${compute_msg:-<empty>}') -- the roster user-sync has not created this account on compute, so its UID cannot agree with the head node (Property 3, Req 6.4)" false
elif [[ "${head_uid}" != "${compute_uid}" ]]; then
  check "head/compute UID agreement" \
    "sample student '${sample_student}' UID mismatch: head=${head_uid} vs compute=${compute_uid} -- divergent identity across nodes breaks shared-EFS file ownership (Property 3, Req 6.4)" false
else
  check "head/compute UID agreement for '${sample_student}' (uid=${head_uid})" "${head_uid}" true
fi

echo "==> neuron-ls on one compute node"
neuron_out=$(ssh "${ssh_opts[@]}" "ubuntu@${HEAD_IP}" \
  'srun -N1 --gres=neuroncore:1 -t 2 bash -c "neuron-ls || true"' 2>&1 || echo ERROR)
if echo "${neuron_out}" | grep -qE 'neuron|trn2|NeuronCore'; then
  check "compute-node neuron-ls" "$(echo "${neuron_out}" | head -3 | tr -d '\r' | paste -sd'|' -)" true
else
  check "compute-node neuron-ls" "${neuron_out}" false
fi

# ---------------------------------------------------------------------------
# gres core pinning: a `--gres=neuroncore:k` job is allocated EXACTLY k
# NeuronCores, and the sum of concurrently allocated cores on a node never
# exceeds that node's core count (Requirements 11.2 / 11.3; design Property 8).
#
# Property 8: for all node,time the sum of allocated cores <= the node core
# count, and a job asking for neuroncore:k on a trn2.3xlarge (4 cores) gets
# exactly k. This is the runtime companion to the D6 registration precondition
# checked above: D6 proves the gres is *advertised* on the right nodes; this
# proves the scheduler actually *hands out* the right number of cores and *pins*
# the job to them.
#
# We probe the LIVE scheduler with three short jobs in one SSH round-trip:
#   * neuroncore:1 and neuroncore:<ceil> (ceil = the configured per-node count,
#     4 on a trn2.3xlarge) each run `env` on a compute node via srun. srun rc==0
#     means Slurm granted the request, and since Slurm never grants more, nor
#     runs with fewer, gres than asked, rc==0 => exactly k cores were allocated
#     (Req 11.2). When the runtime also exports NEURON_RT_VISIBLE_CORES (the core
#     mask that implements the Req 11.6 pinning), we additionally assert it
#     expands to exactly k cores -- a present-but-wrong mask (e.g. all 4 cores
#     visible to a 1-core job) is the core-pinning regression this guards.
#   * a neuroncore:<ceil+1> request via `srun --test-only` MUST be rejected
#     (non-zero): a count above the node core count is unschedulable, so the
#     per-node concurrent sum can never exceed <ceil> (Req 11.3 / 11.7). If it
#     were accepted, the <=<ceil> ceiling would not be enforced -> FAIL.
#
# `--immediate=90` (plus an outer `timeout`) keeps a busy/misconfigured cluster
# from hanging verify: an allocation that cannot be granted promptly aborts and
# is reported rather than blocking forever (PC static `-st-` nodes are always
# powered on, so a healthy idle cluster allocates immediately). Every job uses a
# 1-minute `-t` cap and runs only `env`/`true`. FAIL messages name the observed
# vs expected core count so the operator sees exactly what diverged.
echo "==> gres core pinning (Property 8 / Req 11.2, 11.3)"

# Reuse conf_count (the per-node neuroncore gres count) discovered by the D6
# probe above as the node core count / ceiling. Default to the trn2.3xlarge
# value (4) when that probe could not read it, so k=1 and k=4 are still tested.
if [[ "${conf_count}" =~ ^[0-9]+$ && "${conf_count}" -ge 1 ]]; then
  k_hi="${conf_count}"; over=$((conf_count + 1)); ceil_desc="${conf_count}"
else
  k_hi=4; over=5; ceil_desc="the node core count (4 on a trn2.3xlarge)"
fi
k_lo=1

# Count NeuronCores described by a NEURON_RT_VISIBLE_CORES value, which may be a
# comma/space list and/or hyphenated ranges (e.g. "0-3" or "0,1,2,3" -> 4).
expand_core_count() {
  awk 'BEGIN{c=0}
       {n=split($0,p,/[, \t]+/);
        for(i=1;i<=n;i++){t=p[i];
          if(t=="") continue;
          if(t ~ /^[0-9]+-[0-9]+$/){split(t,r,"-"); if(r[2]>=r[1]) c+=r[2]-r[1]+1}
          else if(t ~ /^[0-9]+$/){c++}}}
       END{print c+0}' <<< "$1"
}

# Classify one `--gres=neuroncore:k` result (allocation rc + visible-core mask).
check_pin_k() {
  local k="$1" arc="$2" vis="$3" msg="$4" cnt
  if [[ ! "${arc}" =~ ^0$ ]]; then
    check "neuroncore:${k} job allocated exactly ${k} core(s)" \
      "srun could not obtain a --gres=neuroncore:${k} allocation (rc='${arc:-<none>}'): ${msg:-no srun detail captured} -- cannot confirm exactly ${k} core(s) were allocated (Property 8, Req 11.2)" false
  elif [[ -n "${vis}" ]]; then
    cnt=$(expand_core_count "${vis}")
    if [[ "${cnt}" == "${k}" ]]; then
      check "neuroncore:${k} job sees exactly ${k} core(s) (NEURON_RT_VISIBLE_CORES=${vis})" "${vis}" true
    else
      check "neuroncore:${k} job sees exactly ${k} core(s)" \
        "job granted neuroncore:${k} but NEURON_RT_VISIBLE_CORES='${vis}' exposes ${cnt} core(s), expected ${k} -- core-pinning mismatch (Property 8, Req 11.2/11.6)" false
    fi
  else
    check "neuroncore:${k} allocation granted (runtime core-mask unconfirmed)" \
      "Slurm granted --gres=neuroncore:${k} (srun rc=0 => exactly ${k} gres allocated, Req 11.2); NEURON_RT_VISIBLE_CORES was empty so per-core runtime pinning (Req 11.6) could not be confirmed" true
  fi
}

# One SSH round-trip: two allocations (k=1, k=<ceil>) that print their env, plus
# a <ceil+1> --test-only feasibility probe. Numbers are spliced in locally via
# '"${var}"'; every $var/$(...) stays single-quoted so it runs on the head node.
pin_probe_cmd='o1=$(timeout 150 srun -N1 --gres=neuroncore:'"${k_lo}"' -t 1 --immediate=90 env 2>&1); r1=$?; echo "ALLOCRC_LO=$r1"; echo "VIS_LO=$(printf %s "$o1" | sed -n s/^NEURON_RT_VISIBLE_CORES=//p | head -n1)"; echo "MSG_LO=$(printf %s "$o1" | tr "\n" " " | cut -c1-160)"; '\
'o4=$(timeout 150 srun -N1 --gres=neuroncore:'"${k_hi}"' -t 1 --immediate=90 env 2>&1); r4=$?; echo "ALLOCRC_HI=$r4"; echo "VIS_HI=$(printf %s "$o4" | sed -n s/^NEURON_RT_VISIBLE_CORES=//p | head -n1)"; echo "MSG_HI=$(printf %s "$o4" | tr "\n" " " | cut -c1-160)"; '\
'fo=$(timeout 60 srun -N1 --gres=neuroncore:'"${over}"' -t 1 --test-only true 2>&1); fr=$?; echo "FIVERC=$fr"; echo "FIVEMSG=$(printf %s "$fo" | tr "\n" " " | cut -c1-200)"'
pin_probe=$(ssh "${ssh_opts[@]}" "ubuntu@${HEAD_IP}" "${pin_probe_cmd}" 2>&1 || echo "ERROR")

alloc_lo=$(printf '%s\n' "${pin_probe}" | sed -n 's/^ALLOCRC_LO=//p')
vis_lo=$(printf '%s\n' "${pin_probe}" | sed -n 's/^VIS_LO=//p')
msg_lo=$(printf '%s\n' "${pin_probe}" | sed -n 's/^MSG_LO=//p')
alloc_hi=$(printf '%s\n' "${pin_probe}" | sed -n 's/^ALLOCRC_HI=//p')
vis_hi=$(printf '%s\n' "${pin_probe}" | sed -n 's/^VIS_HI=//p')
msg_hi=$(printf '%s\n' "${pin_probe}" | sed -n 's/^MSG_HI=//p')
five_rc=$(printf '%s\n' "${pin_probe}" | sed -n 's/^FIVERC=//p')
five_msg=$(printf '%s\n' "${pin_probe}" | sed -n 's/^FIVEMSG=//p')

# Req 11.2: neuroncore:1 and neuroncore:<ceil> each get exactly that many cores.
check_pin_k "${k_lo}" "${alloc_lo}" "${vis_lo}" "${msg_lo}"
check_pin_k "${k_hi}" "${alloc_hi}" "${vis_hi}" "${msg_hi}"

# Req 11.3 / 11.7: a request above the per-node core count must be rejected
# (never allocated, never pending), so the sum of concurrently allocated cores
# on a node can never exceed <ceil>.
if [[ "${five_rc}" =~ ^[0-9]+$ && "${five_rc}" -ne 0 ]]; then
  check "over-count neuroncore:${over} request rejected (ceiling ${ceil_desc} enforced)" \
    "srun --test-only rc=${five_rc}: ${five_msg:-request refused}" true
elif [[ "${five_rc}" == "0" ]]; then
  check "over-count neuroncore:${over} request rejected" \
    "a --gres=neuroncore:${over} request (exceeds the ${ceil_desc} per-node ceiling) was accepted by srun --test-only -- the <=${ceil_desc} core ceiling is NOT enforced and concurrent allocations could exceed it (Property 8, Req 11.3)" false
else
  check "over-count neuroncore:${over} request rejected" \
    "could not evaluate the over-count request (rc='${five_rc:-<none>}', msg='${five_msg:-<none>}'; probe: ${pin_probe}) (Property 8, Req 11.3)" false
fi

echo ""
echo "verify-cluster (${pass} passed, ${fail} failed)"
(( fail == 0 )) && exit 0 || exit 1
