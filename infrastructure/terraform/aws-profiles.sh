#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
account=${1:-}
admin_profile=${2:-default}
config=project.awsconfig

if [[ -z "$account" ]]; then
  if ! account=$(terraform -chdir=project-account output -raw project_account_id); then
    echo "Set PROJECT_ACCOUNT_ID to the existing AWS member account ID." >&2
    exit 1
  fi
fi
if [[ ! "$account" =~ ^[0-9]{12}$ ]]; then
  echo "PROJECT_ACCOUNT_ID must be a 12-digit AWS member account ID." >&2
  exit 2
fi
# The profile name is embedded in the credential_process command.
if [[ ! "$admin_profile" =~ ^[a-zA-Z0-9_+=,.@-]+$ || "$admin_profile" == kthw-management ]]; then
  echo "Set ADMIN_PROFILE to a base profile in the normal AWS config, such as default." >&2
  exit 2
fi

staged_config=$(mktemp "${config}.XXXXXX")
trap 'rm -f -- "$staged_config"' EXIT
cat > "$staged_config" <<EOF
[profile kthw-management]
credential_process = env -u AWS_CONFIG_FILE aws --profile $admin_profile configure export-credentials --format process

[profile kthw-bootstrap]
role_arn = arn:aws:iam::$account:role/OrganizationAccountAccessRole
source_profile = kthw-management

[profile kthw-provisioner]
role_arn = arn:aws:iam::$account:role/kubernetes-hard-way-provisioner
source_profile = kthw-management

[profile kthw-instance-access]
role_arn = arn:aws:iam::$account:role/kubernetes-hard-way-instance-access
source_profile = kthw-management
EOF

# Publish the complete file without overwriting an existing configuration.
if ln -T -- "$staged_config" "$config" 2>/dev/null; then
  printf 'Created %s/%s\n' "$PWD" "$config"
elif cmp -s -- "$staged_config" "$config"; then
  printf 'Profiles already configured in %s/%s\n' "$PWD" "$config"
else
  printf 'Could not create %s/%s. If it already exists, review it or move it before regenerating.\n' \
    "$PWD" "$config" >&2
  exit 1
fi
