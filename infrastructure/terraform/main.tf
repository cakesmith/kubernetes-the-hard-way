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
    tags = { ManagedBy = "kubernetes-hard-way", Cost = "lab" }
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
  tags                    = { Name = "kubernetes-hard-way-public", ResourceType = "subnet" }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "172.16.1.0/24"
  availability_zone_id    = aws_subnet.lab.availability_zone_id
  map_public_ip_on_launch = false
  tags                    = { Name = "kubernetes-hard-way-private", ResourceType = "subnet" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "kubernetes-hard-way", ResourceType = "internet-gateway" }
}

resource "aws_route_table" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "kubernetes-hard-way-public", ResourceType = "route-table" }
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

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "kubernetes-hard-way-private", ResourceType = "route-table" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route" "private_internet" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.machine["jumpbox"].primary_network_interface_id
}

locals {
  machines = {
    jumpbox = { instance_type = "t3.micro", disk_size = 10, ip = "172.16.0.10", role = "jumpbox" }
    server  = { instance_type = "t3.small", disk_size = 20, ip = "172.16.1.11", role = "server" }
    node-0  = { instance_type = "t3.small", disk_size = 20, ip = "172.16.1.20", role = "worker" }
    node-1  = { instance_type = "t3.small", disk_size = 20, ip = "172.16.1.21", role = "worker" }
  }
  pod_networks = {
    node-0 = "10.200.0.0/24"
    node-1 = "10.200.1.0/24"
  }
  roles       = toset(["jumpbox", "server", "worker"])
  web_ports   = toset(["80", "443"])
  nodeport    = 30080
  nat_sources = concat([aws_subnet.private.cidr_block], values(local.pod_networks))
  host_rules = {
    server_ssh  = { target = "server", source = "jumpbox", port = 22 }
    worker_ssh  = { target = "worker", source = "jumpbox", port = 22 }
    api_jumpbox = { target = "server", source = "jumpbox", port = 6443 }
    api_worker  = { target = "server", source = "worker", port = 6443 }
    kubelet     = { target = "worker", source = "server", port = 10250 }
    nodeport    = { target = "worker", source = "jumpbox", port = local.nodeport }
  }

  jumpbox_config = templatefile("${path.module}/jumpbox/bootstrap.sh.tftpl", {
    vpc_cidr    = aws_vpc.lab.cidr_block
    nat_sources = join(", ", local.nat_sources)
    pod_cidrs   = join(", ", values(local.pod_networks))
    worker_0    = local.machines["node-0"].ip
    worker_1    = local.machines["node-1"].ip
    nodeport    = local.nodeport
  })
}

resource "aws_security_group" "role" {
  for_each    = local.roles
  name_prefix = "kubernetes-hard-way-${each.key}-"
  description = "Kubernetes lab ${each.key}"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "kubernetes-hard-way-${each.key}", ResourceType = "security-group" }
}

resource "aws_security_group_rule" "host" {
  for_each                 = local.host_rules
  type                     = "ingress"
  security_group_id        = aws_security_group.role[each.value.target].id
  source_security_group_id = aws_security_group.role[each.value.source].id
  protocol                 = "tcp"
  from_port                = each.value.port
  to_port                  = each.value.port
}

resource "aws_security_group_rule" "host_egress" {
  for_each                 = local.host_rules
  type                     = "egress"
  security_group_id        = aws_security_group.role[each.value.source].id
  source_security_group_id = aws_security_group.role[each.value.target].id
  protocol                 = "tcp"
  from_port                = each.value.port
  to_port                  = each.value.port
}

resource "aws_security_group_rule" "web_egress" {
  for_each = {
    for pair in setproduct(local.roles, local.web_ports) :
    "${pair[0]}-${pair[1]}" => { role = pair[0], port = tonumber(pair[1]) }
  }
  type              = "egress"
  security_group_id = aws_security_group.role[each.value.role].id
  protocol          = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "nat" {
  for_each          = local.web_ports
  type              = "ingress"
  security_group_id = aws_security_group.role["jumpbox"].id
  protocol          = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  cidr_blocks       = local.nat_sources
}

resource "aws_security_group_rule" "public_web" {
  for_each          = length(var.ingress_allowed_cidrs) == 0 ? toset([]) : local.web_ports
  type              = "ingress"
  security_group_id = aws_security_group.role["jumpbox"].id
  protocol          = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  cidr_blocks       = sort(tolist(var.ingress_allowed_cidrs))
}

resource "aws_security_group_rule" "pod_api" {
  type              = "ingress"
  security_group_id = aws_security_group.role["server"].id
  protocol          = "tcp"
  from_port         = 6443
  to_port           = 6443
  cidr_blocks       = values(local.pod_networks)
}

# Pod-to-pod traffic supports arbitrary workload ports. Host-to-host rules
# use security group references and apply only to the ports above.
resource "aws_security_group_rule" "pod_ingress" {
  type              = "ingress"
  security_group_id = aws_security_group.role["worker"].id
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = values(local.pod_networks)
}

resource "aws_security_group_rule" "pod_egress" {
  type              = "egress"
  security_group_id = aws_security_group.role["worker"].id
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = values(local.pod_networks)
}

resource "aws_instance" "machine" {
  for_each = local.machines
  depends_on = [
    aws_route.internet,
    aws_route_table_association.lab,
    aws_route_table_association.private,
    aws_security_group_rule.web_egress,
  ]

  ami           = data.aws_ami.debian.id
  instance_type = each.value.instance_type
  # Inherit public IPv4 assignment from the subnet. The provider reads the
  # current association, which disappears while the jumpbox is stopped.
  subnet_id              = each.key == "jumpbox" ? aws_subnet.lab.id : aws_subnet.private.id
  key_name               = aws_key_pair.lab.key_name
  private_ip             = each.value.ip
  source_dest_check      = each.key == "server"
  vpc_security_group_ids = [aws_security_group.role[each.value.role].id]
  iam_instance_profile   = each.key == "jumpbox" ? "kubernetes-hard-way-jumpbox" : null
  user_data              = each.key == "jumpbox" ? local.jumpbox_config : null

  lifecycle {
    # Keep the launch image and first-boot data stable on existing instances.
    # Reapply changed guest configuration using the jumpbox_config output.
    ignore_changes = [ami, user_data]
  }

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
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
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
  description = "Private route table to use for cluster peering"
  value       = aws_route_table.private.id
}

output "public_route_table_id" {
  value = aws_route_table.lab.id
}

output "subnet_ids" {
  value = { public = aws_subnet.lab.id, private = aws_subnet.private.id }
}

output "jumpbox_config" {
  description = "Rendered first-boot script. Run as root on the jumpbox to reapply guest configuration."
  value       = local.jumpbox_config
}

output "ingress_nodeport" {
  value = local.nodeport
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
    "${aws_instance.machine["node-0"].private_ip} node-0.kubernetes.local node-0 ${local.pod_networks["node-0"]}",
    "${aws_instance.machine["node-1"].private_ip} node-1.kubernetes.local node-1 ${local.pod_networks["node-1"]}",
    "",
  ])
}

# Both route tables need pod routes: private workers send directly to the
# peer ENI, and the jumpbox sends de-NATed responses back to the correct pod.
resource "aws_route" "pod_networks" {
  for_each               = local.pod_networks
  route_table_id         = aws_route_table.lab.id
  destination_cidr_block = each.value
  network_interface_id   = aws_instance.machine[each.key].primary_network_interface_id
}

resource "aws_route" "private_pod_networks" {
  for_each               = local.pod_networks
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = each.value
  network_interface_id   = aws_instance.machine[each.key].primary_network_interface_id
}

output "instance_ids" {
  description = "Instance IDs for lifecycle operations"
  value       = { for name, instance in aws_instance.machine : name => instance.id }
}

output "lab_region" {
  value = var.aws_region
}

output "lab_account_id" {
  value = var.project_account_id
}
