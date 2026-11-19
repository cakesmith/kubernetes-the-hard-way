#!/bin/sh
set -eu

agent_dir=$(mktemp -d)
trap 'rm -rf "$agent_dir"' EXIT
wget -q --tries=5 -O "$agent_dir/amazon-ssm-agent.deb" \
  https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
dpkg -i "$agent_dir/amazon-ssm-agent.deb"
systemctl enable --now amazon-ssm-agent
