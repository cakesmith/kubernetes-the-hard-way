# Cleaning Up

In this lab you will delete the compute resources created during this tutorial.

## AWS infrastructure add-on: Stop or destroy the lab

Run `make stop` from the repository root to suspend the lab and keep Kubernetes data on EBS. Use `make start` to resume it. Run `make destroy` only if you intend to delete the lab and its attached root volumes. The bootstrap account, state bucket and IAM roles remain. See the [AWS lifecycle guide](../infrastructure/terraform/README.md#run-stop-and-destroy-the-lab).

## Compute Instances

Previous versions of this guide made use of GCP resources for various aspects of compute and networking. The current version is agnostic, and all configuration is performed on the `jumpbox`, `server`, or nodes.

Clean up is as simple as deleting all virtual machines you created for this exercise.

Next: [Start Over](../README.md)
