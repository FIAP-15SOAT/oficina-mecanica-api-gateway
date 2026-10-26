locals {
  api_name                      = "apigw-${var.project_name}"
  vpclink_name                  = "vpclink-${var.project_name}"
  secgrp_vpclink_name           = "secgrp-vpclink-${var.project_name}"
  cw_lg_api_access_name         = "/aws/apigateway/apigw-${var.project_name}/access-logs"
  cw_lg_api_access_tag_name     = "cw-lg-apigw-access-${var.project_name}"
  vpc_id                        = data.terraform_remote_state.aws_base.outputs.vpc_id
  vpc_cidr                      = data.terraform_remote_state.aws_base.outputs.vpc_cidr
  private_subnet_ids            = data.terraform_remote_state.aws_base.outputs.private_subnet_ids
  service_listener_arns         = data.terraform_remote_state.k8s.outputs.service_listener_arns
  service_listener_ports        = data.terraform_remote_state.k8s.outputs.service_listener_ports
  customer_auth_function_arn    = "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:${var.customer_auth_function_name}"
  customer_auth_integration_uri = "arn:aws:apigateway:${data.aws_region.current.region}:lambda:path/2015-03-31/functions/${local.customer_auth_function_arn}/invocations"

  # Owner service of each published route group. Each value must be a key of
  # `service_listener_arns`; changing one moves only that group's routes.
  route_owner = {
    "auth"               = "work-order"
    "users"              = "work-order"
    "users-customers"    = "work-order"
    "me"                 = "work-order"
    "me-password"        = "work-order"
    "me-area"            = "work-order"
    "customers"          = "work-order"
    "vehicles"           = "work-order"
    "work-orders"        = "work-order"
    "work-orders-quotes" = "work-order"
    "services"           = "work-order"
    "services-metrics"   = "work-order"
    "parts-supplies"     = "work-order"
    "stock"              = "work-order"
    "quotes"             = "work-order"
    "payments"           = "work-order"
  }
}
