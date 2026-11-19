terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    key          = "kubernetes-hard-way/terraform.tfstate"
    profile      = "kthw-provisioner"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  profile             = "kthw-provisioner"
  allowed_account_ids = [var.project_account_id]

  default_tags {
    tags = { ManagedBy = "kubernetes-hard-way" }
  }
}

data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"] # Debian cloud team

  filter {
    name   = "name"
    values = ["debian-12-amd64-*"]
  }
  filter {
    name   = "free-tier-eligible"
    values = ["true"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_vpc" "lab" {
  cidr_block           = "172.16.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "kubernetes-hard-way", ResourceType = "vpc" }
}

resource "aws_subnet" "lab" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "172.16.0.0/24"
  availability_zone_id    = var.availability_zone_id
  map_public_ip_on_launch = true
  tags                    = { Name = "kubernetes-hard-way", ResourceType = "subnet" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "kubernetes-hard-way", ResourceType = "internet-gateway" }
}

resource "aws_route_table" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "kubernetes-hard-way", ResourceType = "route-table" }
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.lab.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.lab.id
}

resource "aws_route_table_association" "lab" {
  subnet_id      = aws_subnet.lab.id
  route_table_id = aws_route_table.lab.id
}

resource "aws_security_group" "lab" {
  name_prefix = "kubernetes-hard-way-"
  description = "Traffic between lab instances"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "kubernetes-hard-way-lab", ResourceType = "security-group" }

  ingress {
    description = "Traffic between lab instances"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }
  ingress {
    description = "Pod subnet traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.200.0.0/24", "10.200.1.0/24"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

locals {
  machines = {
    jumpbox = { instance_type = "t3.micro", disk_size = 10 }
    server  = { instance_type = "t3.small", disk_size = 20 }
    node-0  = { instance_type = "t3.small", disk_size = 20 }
    node-1  = { instance_type = "t3.small", disk_size = 20 }
  }
}

resource "aws_instance" "machine" {
  for_each   = local.machines
  depends_on = [aws_route.internet, aws_route_table_association.lab]

  ami                         = data.aws_ami.debian.id
  instance_type               = each.value.instance_type
  subnet_id                   = aws_subnet.lab.id
  associate_public_ip_address = true
  key_name                    = aws_key_pair.lab.key_name
  source_dest_check           = false
  vpc_security_group_ids      = [aws_security_group.lab.id]
  iam_instance_profile        = each.key == "jumpbox" ? "kubernetes-hard-way-jumpbox" : null
  user_data                   = each.key == "jumpbox" ? file("${path.module}/install-ssm.sh") : null
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = each.value.disk_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens = "required"
  }

  tags        = { Name = each.key, ResourceType = "ec2-instance" }
  volume_tags = { Name = "${each.key}-root", ResourceType = "ebs-volume" }
}

resource "aws_key_pair" "lab" {
  key_name   = "kubernetes-hard-way"
  public_key = var.ssh_public_key
  tags       = { Name = "kubernetes-hard-way", ResourceType = "ec2-key-pair" }
}

output "jumpbox_instance_id" {
  description = "Jumpbox ID for Session Manager SSH"
  value       = aws_instance.machine["jumpbox"].id
}

output "vpc_id" {
  value = aws_vpc.lab.id
}

output "vpc_cidr" {
  value = aws_vpc.lab.cidr_block
}

output "route_table_id" {
  value = aws_route_table.lab.id
}

output "availability_zone_id" {
  value = aws_subnet.lab.availability_zone_id
}

output "private_ips" {
  description = "Private IP addresses for the lab machines"
  value       = { for name, instance in aws_instance.machine : name => instance.private_ip }
}

output "machines_txt" {
  description = "Machine database for docs/03-compute-resources.md"
  value = join("\n", [
    "${aws_instance.machine["server"].private_ip} server.kubernetes.local server",
    "${aws_instance.machine["node-0"].private_ip} node-0.kubernetes.local node-0 10.200.0.0/24",
    "${aws_instance.machine["node-1"].private_ip} node-1.kubernetes.local node-1 10.200.1.0/24",
  ])
}

# AWS must route pod CIDRs to the workers as well as the guest OS routes in the lab.
resource "aws_route" "pod_networks" {
  for_each = {
    node-0 = "10.200.0.0/24"
    node-1 = "10.200.1.0/24"
  }

  route_table_id         = aws_route_table.lab.id
  destination_cidr_block = each.value
  network_interface_id   = aws_instance.machine[each.key].primary_network_interface_id
}
