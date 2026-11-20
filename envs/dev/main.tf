locals {
  name = "${var.project}-${var.environment}"
}

# Everything tagged Project=<project> shows up in one console view.
resource "aws_resourcegroups_group" "project" {
  name = local.name

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]
      TagFilters = [
        { Key = "Project", Values = [var.project] },
        { Key = "Environment", Values = [var.environment] },
      ]
    })
  }
}

module "network" {
  source = "../../modules/network"

  name     = local.name
  vpc_cidr = var.vpc_cidr
}

module "endpoints" {
  source = "../../modules/endpoints"

  name            = local.name
  vpc_id          = module.network.vpc_id
  vpc_cidr        = module.network.vpc_cidr
  subnet_ids      = module.network.isolated_subnet_ids
  route_table_ids = [module.network.egress_route_table_id, module.network.isolated_route_table_id]
}

module "dev_env" {
  source = "../../modules/dev_env"

  name              = local.name
  vpc_id            = module.network.vpc_id
  subnet_id         = module.network.egress_subnet_ids[0]
  availability_zone = module.network.azs[0]
  instance_type     = var.dev_instance_type

  # cloud-init installs packages from the internet, so the NAT route must exist.
  egress_ready = module.network.nat_gateway_id
}

module "app_build" {
  source = "../../modules/app_build"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.egress_subnet_ids
  source_dir = "${path.root}/../../app"

  # The build pulls its base image through the NAT.
  egress_ready = module.network.nat_gateway_id
}

module "app_service" {
  source = "../../modules/app_service"

  name       = local.name
  vpc_id     = module.network.vpc_id
  vpc_cidr   = module.network.vpc_cidr
  subnet_ids = module.network.isolated_subnet_ids
  image_uri  = module.app_build.image_uri

  # Tasks in the isolated tier can only pull the image through the endpoints.
  endpoints_ready = module.endpoints.ready
}

module "monitoring" {
  source = "../../modules/monitoring"

  name                    = local.name
  alert_email             = var.alert_email
  alb_arn_suffix          = module.app_service.alb_arn_suffix
  target_group_arn_suffix = module.app_service.target_group_arn_suffix
  ecs_cluster_name        = module.app_service.cluster_name
  ecs_service_name        = module.app_service.service_name
  ecs_desired_count       = module.app_service.desired_count
  dev_instance_id         = module.dev_env.instance_id
  nat_gateway_id          = module.network.nat_gateway_id
  codebuild_project_name  = module.app_build.codebuild_project_name
}
