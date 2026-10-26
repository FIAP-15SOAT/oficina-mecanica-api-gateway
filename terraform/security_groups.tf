# Egress only to the service listeners of the internal NLB, never 0.0.0.0/0.
resource "aws_security_group" "secgrp_vpclink" {
  name        = local.secgrp_vpclink_name
  description = "Egress-only security group for the API Gateway VPC Link ENIs reaching the internal API NLB"
  vpc_id      = local.vpc_id

  tags = {
    Name = local.secgrp_vpclink_name
  }
}

resource "aws_vpc_security_group_egress_rule" "vpclink_to_service_listener" {
  for_each = local.service_listener_ports

  security_group_id = aws_security_group.secgrp_vpclink.id
  description       = "Allow the VPC Link ENIs to reach the ${each.key} listener of the internal NLB"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = local.vpc_cidr

  tags = {
    Name = "${local.secgrp_vpclink_name}-${each.key}"
  }
}
