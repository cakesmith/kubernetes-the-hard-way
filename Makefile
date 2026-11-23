.PHONY: help aws-profiles up start stop status destroy web-tunnel kube-tunnel argocd-ui validate validate-live validate-recovery

LAB := infrastructure/terraform
PROJECT_AWS_CONFIG := $(abspath $(LAB)/project.awsconfig)
ifeq ($(origin AWS_CONFIG_FILE),undefined)
ifneq ($(wildcard $(PROJECT_AWS_CONFIG)),)
export AWS_CONFIG_FILE := $(PROJECT_AWS_CONFIG)
endif
endif

export PROJECT_ACCOUNT_ID
export ADMIN_PROFILE ?= default
# Each web forward is a LOCAL_PORT:JUMPBOX_PORT pair.
export TUNNEL_PORTS ?= 80:80 443:443
.DEFAULT_GOAL := help

help:
	@printf '%s\n' \
		'Usage: make [target]' \
		'' \
		'  aws-profiles       Generate the local AWS role profiles' \
		'  help               Show this list' \
		'  up                 Provision or update and start the AWS lab' \
		'  start              Start the lab instances' \
		'  stop               Stop the lab instances' \
		'  status             Show the lab instance states and IP addresses' \
		'  destroy            Delete the lab infrastructure and root disks' \
		'  web-tunnel         Forward web ingress (default: 80:80 443:443)' \
		'  kube-tunnel        Set up kubeconfig and forward the Kubernetes API' \
		'  argocd-ui          Forward the Argo CD UI to localhost:8443 (requires kube-tunnel)' \
		'  validate           Run Terraform checks and mocked lifecycle tests' \
		'  validate-live      Check connectivity and ingress on the running lab' \
		'  validate-recovery  Stop and restart the lab to verify recovery'

aws-profiles:
	@bash $(LAB)/aws-profiles.sh "$$PROJECT_ACCOUNT_ID" "$$ADMIN_PROFILE"

# Delegate AWS lifecycle operations to the lab script.
up start stop status:
	$(LAB)/lab.sh $@

destroy:
	terraform -chdir=$(LAB) destroy

# Validate the port pairs with Bash before opening loopback-only forwards.
web-tunnel: SHELL := /bin/bash
web-tunnel:
	@set -f; set --; \
	for forward in $$TUNNEL_PORTS; do \
		if ! [[ $$forward =~ ^([1-9][0-9]{0,4}):([1-9][0-9]{0,4})$$ ]] || \
			(( BASH_REMATCH[1] > 65535 || BASH_REMATCH[2] > 65535 )); then \
			printf 'Invalid forward %s. Use LOCAL_PORT:JUMPBOX_PORT with ports from 1 to 65535.\n' "$$forward" >&2; \
			exit 2; \
		fi; \
		set -- "$$@" -L "127.0.0.1:$${BASH_REMATCH[1]}:127.0.0.1:$${BASH_REMATCH[2]}"; \
	done; \
	if (( $$# == 0 )); then \
		printf 'Set TUNNEL_PORTS to at least one LOCAL_PORT:JUMPBOX_PORT pair.\n' >&2; \
		exit 2; \
	fi; \
	exec ssh -a -N -o ExitOnForwardFailure=yes "$$@" jumpbox

# Keep workstation kubeconfig setup with the API tunnel it uses.
kube-tunnel:
	@bash $(LAB)/kube-tunnel.sh

argocd-ui:
	@printf '%s\n' 'Keep make kube-tunnel running in another terminal.' \
		'Once forwarding starts, open https://localhost:8443.'
	@kubectl --kubeconfig="$$HOME/.kube/kthw-aws.yaml" -n argocd port-forward svc/argocd-server 8443:443

# Start with local checks before running the tests that use AWS.
validate:
	terraform -chdir=$(LAB) fmt -check -recursive
	terraform -chdir=$(LAB) validate
	terraform -chdir=$(LAB) test
	python3 -B -m unittest discover -s $(LAB)/tests

validate-live:
	$(LAB)/tests/live.sh

validate-recovery:
	$(LAB)/tests/live.sh --recovery
