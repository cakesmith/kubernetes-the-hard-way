#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
case "${1:-}" in
  up|start|stop|status|status-json) action=$1 ;;
  *) echo "Usage: $0 {up|start|stop|status}" >&2; exit 2 ;;
esac

if [[ "$action" == up ]]; then
  plan_dir=$(mktemp -d)
  trap 'rm -rf "$plan_dir"' EXIT
  terraform init -backend-config=lab.s3.tfbackend
  terraform plan -out="$plan_dir/tfplan"
  # EC2 replacement deletes its root disk. Require a deliberate Terraform
  # apply for instance or volume deletions while allowing network rule edits.
  terraform show -json "$plan_dir/tfplan" | python3 -c '
import json, sys
plan = json.load(sys.stdin)
deletions = [r["address"] for r in plan.get("resource_changes", [])
             if r["type"] in {"aws_instance", "aws_ebs_volume"}
             and "delete" in r["change"]["actions"]]
if deletions:
    sys.exit("Refusing make up: the plan deletes or replaces " + ", ".join(deletions))
'
  terraform apply "$plan_dir/tfplan"
  action=start
fi

outputs=$(terraform output -json)
id_list=$(python3 -c '
import json, re, sys
state = json.load(sys.stdin)
try:
    account = state["lab_account_id"]["value"]
    region = state["lab_region"]["value"]
    instances = state["instance_ids"]["value"]
    ids = [instances[name] for name in ("jumpbox", "server", "node-0", "node-1")]
    if (not re.fullmatch(r"[0-9]{12}", account) or
        not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)+-[0-9]+", region) or
        len(set(ids)) != 4 or not all(re.fullmatch(r"i-[0-9a-f]+", i) for i in ids)):
        raise ValueError()
except (KeyError, ValueError, TypeError):
    sys.exit("Terraform state has no complete lab outputs. Run make up for a new lab. "
             "For an existing lab, review the Terraform migration instructions.")
print(account, region, *ids, sep="\n")
' <<< "$outputs")
mapfile -t lab <<< "$id_list"
account=${lab[0]}
region=${lab[1]}
jumpbox=${lab[2]}
server=${lab[3]}
workers=("${lab[@]:4}")
ids=("${lab[@]:2}")

aws_lab() {
  aws --profile kthw-provisioner --region "$region" "$@"
}

actual=$(aws_lab sts get-caller-identity --query Account --output text)
if [[ "$account" != "$actual" ]]; then
  echo "Account mismatch. Terraform state expects $account, AWS profile is $actual." >&2
  exit 1
fi

set_power() {
  local target=$1 state id
  shift
  local -a pending=()
  for id in "$@"; do
    state=$(aws_lab ec2 describe-instances --instance-ids "$id" \
      --query 'Reservations[0].Instances[0].State.Name' --output text)
    case "$target:$state" in
      running:running|running:pending|stopped:stopped|stopped:stopping) ;;
      running:stopping)
        aws_lab ec2 wait instance-stopped --instance-ids "$id"
        pending+=("$id")
        ;;
      stopped:pending)
        aws_lab ec2 wait instance-running --instance-ids "$id"
        pending+=("$id")
        ;;
      running:stopped|stopped:running) pending+=("$id") ;;
      *) echo "Cannot move $id from $state to $target." >&2; return 1 ;;
    esac
  done
  if (( ${#pending[@]} )); then
    if [[ "$target" == running ]]; then
      aws_lab ec2 start-instances --instance-ids "${pending[@]}" >/dev/null
    else
      aws_lab ec2 stop-instances --instance-ids "${pending[@]}" >/dev/null
    fi
  fi
  aws_lab ec2 wait "instance-$target" --instance-ids "$@"
}

wait_for_health() {
  local attempt healthy
  echo "Waiting for EC2 status checks on all lab instances..." >&2
  for ((attempt = 1; attempt <= 40; attempt++)); do
    healthy=$(aws_lab ec2 describe-instance-status --instance-ids "$@" \
      --query "length(InstanceStatuses[?SystemStatus.Status == 'ok' && InstanceStatus.Status == 'ok' && (AttachedEbsStatus.Status == 'ok' || AttachedEbsStatus.Status == 'not-applicable')])" \
      --output json)
    if [[ "$healthy" == "$#" ]]; then
      return 0
    fi
    if (( attempt < 40 )); then
      sleep 15
    fi
  done
  echo "Timed out waiting for EC2 status checks ($healthy of $# instances passed)." >&2
  return 1
}

case "$action" in
  stop)
    set_power stopped "${workers[@]}"
    set_power stopped "$server"
    set_power stopped "$jumpbox"
    ;;
  start)
    set_power running "${ids[@]}"
    wait_for_health "${ids[@]}"
    ;;
  status-json)
    aws_lab ec2 describe-instances --instance-ids "${ids[@]}" \
      --query 'Reservations[].Instances[]' --output json
    exit
    ;;
esac
aws_lab ec2 describe-instances --instance-ids "${ids[@]}" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,State.Name,PrivateIpAddress,PublicIpAddress]' --output table
