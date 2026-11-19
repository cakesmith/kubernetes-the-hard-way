mock_provider "aws" {
  mock_resource "aws_instance" {
    defaults = { iam_instance_profile = "" }
  }

  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0" }
  }
}

variables {
  budget_alert_email    = "alerts@example.com"
  project_account_id    = "123456789012"
  aws_region            = "us-east-1"
  availability_zone_id  = "use1-az1"
  ssh_public_key        = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICpqBeJHf0VSfL9/MIrc69NqRWqGu4QxkwQukRsYCv03"
  ingress_allowed_cidrs = ["203.0.113.10/32"]
}

run "hybrid_network" {
  command = apply

  assert {
    condition = (
      aws_route.internet.gateway_id == aws_internet_gateway.lab.id &&
      aws_route.private_internet.network_interface_id == aws_instance.machine["jumpbox"].primary_network_interface_id &&
      aws_route.private_internet.route_table_id == aws_route_table.private.id &&
      aws_route_table_association.private.subnet_id == aws_subnet.private.id &&
      aws_subnet.private.availability_zone_id == aws_subnet.lab.availability_zone_id &&
      aws_subnet.lab.map_public_ip_on_launch &&
      !aws_subnet.private.map_public_ip_on_launch
    )
    error_message = "Public egress must use the IGW and private egress must use the jumpbox ENI."
  }

  assert {
    condition = tomap(output.private_ips) == tomap({
      jumpbox = "172.16.0.10"
      server  = "172.16.1.11"
      node-0  = "172.16.1.20"
      node-1  = "172.16.1.21"
    })
    error_message = "The fixed addresses must match the published machine layout."
  }

  assert {
    condition = alltrue([
      for name, instance in aws_instance.machine :
      instance.subnet_id == (name == "jumpbox" ? aws_subnet.lab.id : aws_subnet.private.id) &&
      instance.source_dest_check == (name == "server") &&
      (name == "jumpbox" ? instance.iam_instance_profile == "kubernetes-hard-way-jumpbox" : coalesce(instance.iam_instance_profile, "none") == "none") &&
      instance.root_block_device[0].encrypted &&
      instance.root_block_device[0].delete_on_termination &&
      instance.root_block_device[0].volume_type == "gp3"
    ])
    error_message = "Check instance subnet placement, forwarding, IAM and persistent encrypted root disks."
  }

  assert {
    condition = alltrue([
      for node, cidr in { node-0 = "10.200.0.0/24", node-1 = "10.200.1.0/24" } :
      aws_route.pod_networks[node].destination_cidr_block == cidr &&
      aws_route.private_pod_networks[node].destination_cidr_block == cidr &&
      aws_route.pod_networks[node].network_interface_id == aws_instance.machine[node].primary_network_interface_id &&
      aws_route.private_pod_networks[node].network_interface_id == aws_instance.machine[node].primary_network_interface_id
    ])
    error_message = "Each pod CIDR must target its worker ENI in both route tables."
  }

  assert {
    condition = (
      aws_security_group_rule.host["nodeport"].from_port == 30080 &&
      aws_security_group_rule.host["nodeport"].source_security_group_id == aws_security_group.role["jumpbox"].id &&
      toset(keys(aws_security_group_rule.public_web)) == toset(["80", "443"]) &&
      alltrue([for rule in aws_security_group_rule.public_web : rule.cidr_blocks == tolist(["203.0.113.10/32"])])
    )
    error_message = "Public ingress must stay on the allowlisted jumpbox web ports."
  }
}

run "reject_unrestricted_ingress" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.ingress_allowed_cidrs]
}
