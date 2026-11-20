data "aws_region" "current" {}

resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alb_dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  ecs_dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  # One entry per alarm. Symptom alarms (users affected) come first.
  alarms = {
    app-unhealthy-targets = {
      description = "The ALB sees unhealthy app targets"
      namespace   = "AWS/ApplicationELB"
      metric      = "UnHealthyHostCount"
      statistic   = "Maximum"
      comparison  = "GreaterThanThreshold"
      threshold   = 0
      periods     = 2
      missing     = "notBreaching"
      dimensions  = local.alb_dimensions
    }
    app-5xx = {
      description = "The app is returning 5xx responses"
      namespace   = "AWS/ApplicationELB"
      metric      = "HTTPCode_Target_5XX_Count"
      statistic   = "Sum"
      comparison  = "GreaterThanThreshold"
      threshold   = 5
      periods     = 2
      missing     = "notBreaching"
      dimensions  = local.alb_dimensions
    }
    app-running-tasks-low = {
      description = "Fewer app tasks running than desired"
      namespace   = "ECS/ContainerInsights"
      metric      = "RunningTaskCount"
      statistic   = "Minimum"
      comparison  = "LessThanThreshold"
      threshold   = var.ecs_desired_count
      periods     = 3
      missing     = "breaching"
      dimensions  = local.ecs_dimensions
    }
    app-cpu-high = {
      description = "App CPU above 80%"
      namespace   = "AWS/ECS"
      metric      = "CPUUtilization"
      statistic   = "Average"
      comparison  = "GreaterThanThreshold"
      threshold   = 80
      periods     = 5
      missing     = "notBreaching"
      dimensions  = local.ecs_dimensions
    }
    app-memory-high = {
      description = "App memory above 80%"
      namespace   = "AWS/ECS"
      metric      = "MemoryUtilization"
      statistic   = "Average"
      comparison  = "GreaterThanThreshold"
      threshold   = 80
      periods     = 5
      missing     = "notBreaching"
      dimensions  = local.ecs_dimensions
    }
    dev-instance-status-check = {
      description = "Dev box failed an EC2 status check"
      namespace   = "AWS/EC2"
      metric      = "StatusCheckFailed"
      statistic   = "Maximum"
      comparison  = "GreaterThanThreshold"
      threshold   = 0
      periods     = 2
      missing     = "notBreaching" # a stopped dev box is not an incident
      dimensions  = { InstanceId = var.dev_instance_id }
    }
    nat-port-allocation-errors = {
      description = "NAT gateway cannot allocate source ports (egress is failing)"
      namespace   = "AWS/NATGateway"
      metric      = "ErrorPortAllocation"
      statistic   = "Sum"
      comparison  = "GreaterThanThreshold"
      threshold   = 0
      periods     = 1
      missing     = "notBreaching"
      dimensions  = { NatGatewayId = var.nat_gateway_id }
    }
    build-failed = {
      description = "An image build failed"
      namespace   = "AWS/CodeBuild"
      metric      = "FailedBuilds"
      statistic   = "Sum"
      comparison  = "GreaterThanThreshold"
      threshold   = 0
      periods     = 1
      missing     = "notBreaching"
      dimensions  = { ProjectName = var.codebuild_project_name }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  comparison_operator = each.value.comparison
  threshold           = each.value.threshold
  period              = 60
  evaluation_periods  = each.value.periods
  treat_missing_data  = each.value.missing
  dimensions          = each.value.dimensions

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "App requests and errors"
          region = data.aws_region.current.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "App latency (p95)"
          region = data.aws_region.current.region
          stat   = "p95"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "App CPU and memory"
          region = data.aws_region.current.region
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "NAT gateway traffic"
          region = data.aws_region.current.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/NATGateway", "BytesOutToDestination", "NatGatewayId", var.nat_gateway_id],
            ["AWS/NATGateway", "ErrorPortAllocation", "NatGatewayId", var.nat_gateway_id],
          ]
        }
      },
      {
        type = "alarm", x = 0, y = 12, width = 24, height = 4
        properties = {
          title  = "Alarms"
          alarms = [for a in aws_cloudwatch_metric_alarm.this : a.arn]
        }
      },
    ]
  })
}
