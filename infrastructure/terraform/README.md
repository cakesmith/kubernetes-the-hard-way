# Kubernetes The Hard Way on AWS

Terraform provisions the AWS infrastructure for the tutorial. The project account, state bucket, and IAM roles stay in place between lab runs. The lab itself is disposable.

## What exists today

| Setting | Value |
| --- | --- |
| Organizations management account | `637423194439` (`cakesmith`) |
| Project member account | `476564946996` (`Kubernetes The Hard Way`) |
| AWS Region | `us-east-1` |
| Bootstrap caller | `arn:aws:iam::637423194439:user/nick-admin` via AWS CLI profile `default` |
| State bucket | `kubernetes-hard-way-476564946996-tfstate` |
| State object | `kubernetes-hard-way/terraform.tfstate` |
| S3 lock object | `kubernetes-hard-way/terraform.tfstate.tflock` |

The account and bootstrap were applied on November 19, 2026, using Terraform 1.10.5 and AWS provider 5.100.0. Both project roles were assumed successfully. Terraform initialized the S3 backend and produced a 14-resource lab plan using a temporary test public key. S3 rejected the SSH role's attempt to list the state bucket. The lab plan was never applied, so there are no lab EC2 instances and the SSH tunnel has yet to be tested against a running jumpbox.

## How the account was bootstrapped

Run commands from `infrastructure/terraform`. The commands in this section document the one-time setup. For the existing project, use the saved local state and continue to [Deploy the lab](#deploy-the-lab).

### 1. Verify the management login and create the account

The `default` AWS CLI profile authenticated as `nick-admin`. Terraform could not use its credentials directly, so the bootstrap used the CLI's `export-credentials` command to supply temporary credentials to Terraform. The helper passes credentials to the caller without storing them in Terraform variables.

```sh
aws --profile default sts get-caller-identity
aws --profile default organizations describe-organization \
  --query 'Organization.{ManagementAccountId:MasterAccountId,FeatureSet:FeatureSet}'
```

Use this entry in your normal AWS config to reproduce the helper used at bootstrap.

```ini
[profile kthw-management]
credential_process = aws --profile default configure export-credentials --format process
```

The member account was created by the [account configuration](project-account/main.tf). Set `PROJECT_ACCOUNT_EMAIL` to an unused email you control when reproducing this for a new member account. This project's email is recorded in the local, ignored `project-account/account.auto.tfvars`. AWS rejected the first attempt with `EMAIL_ALREADY_EXISTS` because that email belonged to the management account. The retry with the unused address succeeded.

```sh
AWS_PROFILE=kthw-management terraform -chdir=project-account init
AWS_PROFILE=kthw-management terraform -chdir=project-account plan -out=tfplan \
  -var='management_account_id=637423194439' \
  -var="project_account_email=${PROJECT_ACCOUNT_EMAIL:?Set an unused AWS account email}"
AWS_PROFILE=kthw-management terraform -chdir=project-account apply tfplan
terraform -chdir=project-account output -raw project_account_id
```

AWS Organizations created `OrganizationAccountAccessRole` in the member account. The account resource has `prevent_destroy` enabled.

### 2. Configure the project role profiles

The deployed checkout has a local, ignored `project.awsconfig` with the following profiles. It uses `env -u AWS_CONFIG_FILE` in the credential helper to resolve `default` from your normal AWS config. Use the first helper example above if you put these profiles directly in your normal config instead. For a new project account, replace the role ARNs' account ID with the output from step 1.

```ini
[profile kthw-management]
credential_process = env -u AWS_CONFIG_FILE aws --profile default configure export-credentials --format process

[profile kthw-bootstrap]
role_arn = arn:aws:iam::476564946996:role/OrganizationAccountAccessRole
source_profile = kthw-management

[profile kthw-provisioner]
role_arn = arn:aws:iam::476564946996:role/kubernetes-hard-way-provisioner
source_profile = kthw-management

[profile kthw-instance-access]
role_arn = arn:aws:iam::476564946996:role/kubernetes-hard-way-instance-access
source_profile = kthw-management
```

```sh
export AWS_CONFIG_FILE="$PWD/project.awsconfig"
aws --profile kthw-bootstrap sts get-caller-identity
```

### 3. Create the state bucket and roles

The [bootstrap configuration](state-bucket/main.tf) runs as `kthw-bootstrap` in the member account. It creates the S3 bucket with versioning, SSE-S3 encryption, and public access blocking. The provisioner and SSH roles both trust `nick-admin`. The management caller also needs IAM permission to assume those cross-account roles. The jumpbox has a separate EC2 instance profile with `AmazonSSMManagedInstanceCore` so its agent can register with Systems Manager.

```sh
AWS_PROFILE=kthw-bootstrap terraform -chdir=state-bucket init
AWS_PROFILE=kthw-bootstrap terraform -chdir=state-bucket plan -out=tfplan \
  -var='project_account_id=476564946996' \
  -var='bucket_name=kubernetes-hard-way-476564946996-tfstate'
AWS_PROFILE=kthw-bootstrap terraform -chdir=state-bucket apply tfplan
terraform -chdir=state-bucket output -raw backend_config > lab.s3.tfbackend
```

After applying the bootstrap, these commands verified the two role sessions and initialized the live backend. The read-only S3 check returned `AccessDenied`, as expected.

```sh
aws --profile kthw-provisioner sts get-caller-identity
aws --profile kthw-instance-access sts get-caller-identity
terraform init -backend-config=lab.s3.tfbackend
aws --profile kthw-instance-access --region us-east-1 s3api list-objects-v2 \
  --bucket kubernetes-hard-way-476564946996-tfstate --max-keys 1
```

Both the S3 backend and the AWS provider use `kthw-provisioner`. The [bucket and IAM policies](state-bucket/access.tf) deny direct S3 object access to other principals. The provisioner can read and write the state, remove the lock, and manage the lab's EC2 and VPC resources in `us-east-1`. Its EC2 permissions are scoped by region and API action. The dedicated account keeps unrelated resources and routine administrators outside that boundary. The bootstrap administrator retains emergency access and can edit the bucket policy for recovery.

Back up `project-account/terraform.tfstate` and `state-bucket/terraform.tfstate` securely. These are separate local states. The lab state lives in S3. Terraform state, plans, local variables, and the generated backend configuration are ignored by Git.

## Deploy the lab

Use Terraform 1.10 or later and an OpenSSH public key. Keep the matching private key on your workstation. Terraform creates one Debian 12 `t3.micro` jumpbox and three `t3.small` nodes, with 70 GiB of encrypted EBS storage and four public IPv4 addresses for outbound connectivity. Check your account's EC2, storage, and IPv4 charges before deploying. The jumpbox accepts workstation SSH through Session Manager without an internet-facing SSH rule.

Run from `infrastructure/terraform`. The existing local `account.auto.tfvars` sets `project_account_id = "476564946996"`. Use your own public key path below. If you previously deployed this lab in another account, keep that backend separate and use empty lab state in the new account.

```sh
export AWS_CONFIG_FILE="$PWD/project.awsconfig"
export TF_VAR_ssh_public_key="$(cat "$HOME/.ssh/id_ed25519.pub")"
terraform init -backend-config=lab.s3.tfbackend
terraform plan -out=tfplan
terraform apply tfplan
```

For a fresh checkout of this project, restore the local profile and account variables above, and regenerate `lab.s3.tfbackend` from the bootstrap state. If you change the lab's `aws_region`, set `lab_region` to match in the bootstrap.

## Connect and continue the tutorial

Install the AWS CLI Session Manager plugin and wait for cloud-init to install and start SSM Agent. The tunnel requires the `kthw-instance-access` role. SSH then authenticates Debian's `admin` user with your private key.

```sh
ssh -i "$HOME/.ssh/id_ed25519" \
  -o 'ProxyCommand=aws --profile kthw-instance-access --region us-east-1 ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p' \
  "admin@$(terraform output -raw jumpbox_instance_id)"
```

On your workstation, run `terraform output -raw machines_txt` and copy its contents into `machines.txt` on the jumpbox. For initial access to the nodes, use SSH agent forwarding from your workstation with `ssh -A` and log in to each node as `admin`. Follow the tutorial's [SSH setup](../../docs/03-compute-resources.md#configuring-ssh-access) to enable root access with a separate jumpbox key.

Run `terraform destroy` from the lab directory with the same variables and provisioner profile when finished. The member account, bucket, and bootstrap roles remain available for the next run.

## Connect another project

When a second project needs a private network path, use the `vpc_id`, `vpc_cidr`, `route_table_id`, and `availability_zone_id` outputs to configure cross-account VPC peering. Choose a peer CIDR that avoids the lab VPC (`172.16.0.0/16`) and its pod networks (`10.200.0.0/24` and `10.200.1.0/24`). Add routes on both sides and allow the required application ports. To align physical zones across accounts, set `availability_zone_id` before deploying. Same-AZ peering traffic is free. Cross-AZ and cross-region transfer rates apply. [AWS VPC peering setup](https://docs.aws.amazon.com/vpc/latest/peering/create-vpc-peering-connection.html) · [AWS VPC pricing](https://aws.amazon.com/vpc/pricing/)

Use the `ResourceType` tag as a cost allocation tag in AWS Billing to distinguish supported resource types in cost reports.
