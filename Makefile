.PHONY: help up start stop status destroy web-tunnel kube-tunnel validate validate-live validate-recovery

LAB := infrastructure/terraform
# Each web forward is a LOCAL_PORT:JUMPBOX_PORT pair.
export TUNNEL_PORTS ?= 80:80 443:443
.DEFAULT_GOAL := help

help:
	@printf '%s\n' \
		'Usage: make [target]' \
		'' \
		'  help               Show this list' \
		'  up                 Provision or update and start the AWS lab' \
		'  start              Start the lab instances' \
		'  stop               Stop the lab instances' \
		'  status             Show the lab instance states and IP addresses' \
		'  destroy            Delete the lab infrastructure and root disks' \
		'  web-tunnel         Forward web ingress (default: 80:80 443:443)' \
		'  kube-tunnel        Set up kubeconfig and forward the Kubernetes API' \
		'  validate           Run Terraform checks and mocked lifecycle tests' \
		'  validate-live      Check connectivity and ingress on the running lab' \
		'  validate-recovery  Stop and restart the lab to verify recovery'

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
