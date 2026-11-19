.PHONY: up start stop status destroy validate validate-live validate-recovery

LAB := infrastructure/terraform
.DEFAULT_GOAL := status

up start stop status:
	$(LAB)/lab.sh $@

destroy:
	terraform -chdir=$(LAB) destroy

validate:
	terraform -chdir=$(LAB) fmt -check -recursive
	terraform -chdir=$(LAB) validate
	terraform -chdir=$(LAB) test
	python3 -B -m unittest discover -s $(LAB)/tests

validate-live:
	$(LAB)/tests/live.sh

validate-recovery:
	$(LAB)/tests/live.sh --recovery
