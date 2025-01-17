locals {
  service_names = { for service in var.services : service.name => service }
}

# Create ECS Service for each service
resource "aws_ecs_service" "services" {
  for_each = local.service_names

  name                               = "${var.project}_service_${each.key}_${var.env}"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.services[each.key].arn
  desired_count                      = each.value.desired_count
  deployment_minimum_healthy_percent = 50
  launch_type                        = "FARGATE"
  scheduling_strategy                = "REPLICA"
  enable_ecs_managed_tags           = each.value.remote_access


  network_configuration {
    security_groups  = [aws_security_group.services[each.key].id]
    subnets          = var.subnet_ids
    assign_public_ip = true
  }

  dynamic "load_balancer" {
    for_each = var.enable_alb ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.services[each.key].arn
      container_name   = "${var.project}_service_${each.key}_${var.env}"
      container_port   = each.value.container_port
    }
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_private_dns_namespace.local.name

    service {
      port_name      = "${var.project}_service_${each.key}_${var.env}"
      discovery_name = "${var.project}_service_${each.key}_${var.env}"
      client_alias {
        port     = each.value.hots_port
        dns_name = "${var.project}_service_${each.key}_${var.env}"
      }
    }
  }

  tags = {
    terraform = "true"
    env       = var.env
  }
}

# Create Task Definition for each service
resource "aws_ecs_task_definition" "services" {
  for_each = local.service_names

  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  family                   = "${var.project}_service_${each.key}_${var.env}"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.services_task_execution[each.key].arn
  task_role_arn           = aws_iam_role.services_task[each.key].arn

  container_definitions = jsonencode(concat(
    each.value.xray_enabled ? local.xray_enabled_container : [],
    [{
      name        = "${var.project}_service_${each.key}_${var.env}"
      cpu         = each.value.cpu
      memory      = each.value.memory
      image       = "${each.value.docker_image != "" ? each.value.docker_image : (var.env == "dev" ? join("", aws_ecr_repository.services[each.key].*.repository_url) : var.ecr_url)}:latest"

      // we support three types of env variables:
      // 1. from SSM
      // 2. from env_files_s3
      // 3. from env_vars variable
      secrets     = local.services_env_ssm[each.key]
      environment = concat(local.services_env, each.value.env_vars)
      environmentFiles = [
        for file in local.services_env_files_s3[each.key] : {
          value = "arn:aws:s3:::${file.bucket}/${file.key}"
          type  = "s3"
        }
      ]
      essential   = each.value.essential

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.services[each.key].name
          awslogs-stream-prefix = "ecs"
          awslogs-region        = data.aws_region.current.name
        }
      }

      portMappings = [{
        protocol      = "tcp"
        containerPort = each.value.container_port
        hostPort      = each.value.hots_port
        name          = "${var.project}_service_${each.key}_${var.env}"
      }]
    }]
  ))

  tags = {
    terraform = "true"
    env       = var.env
  }
}

# Create Security Group for each service
resource "aws_security_group" "services" {
  for_each = local.service_names

  name   = "${var.project}_service_${each.key}_${var.env}"
  vpc_id = var.vpc_id

  ingress {
    protocol         = "tcp"
    from_port        = each.value.container_port
    to_port          = each.value.container_port
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    terraform = "true"
    env       = var.env
  }
}

# Create CloudWatch Log Group for each service
resource "aws_cloudwatch_log_group" "services" {
  for_each = local.service_names

  name              = "${var.project}_service_${each.key}_${var.env}"
  retention_in_days = 7

  tags = {
    terraform = "true"
    env       = var.env
  }
}

# Create IAM roles for each service
resource "aws_iam_role" "services_task" {
  for_each = local.service_names

  name               = "${var.project}_${each.key}_task_${var.env}"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role" "services_task_execution" {
  for_each = local.service_names

  name               = "${var.project}_${each.key}_task_execution_${var.env}"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

# Attach policies to service roles
resource "aws_iam_role_policy_attachment" "services_task_execution" {
  for_each = local.service_names

  role       = aws_iam_role.services_task_execution[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "services_task_cloudwatch" {
  for_each = local.service_names

  role       = aws_iam_role.services_task[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
}

# S3 bucket access
resource "aws_iam_role_policy_attachment" "backend_task_backend_bucket" {
  for_each = local.service_names

  role       = aws_iam_role.services_task_execution[each.key].name
  policy_arn = aws_iam_policy.full_access_to_backend_bucket.arn
}

# SES access
resource "aws_iam_role_policy_attachment" "backend_task_ses" {
  for_each = local.service_names

  role       = aws_iam_role.services_task_execution[each.key].name
  policy_arn = aws_iam_policy.send_emails.arn
}



# SSM parameter access for services
resource "aws_iam_role_policy_attachment" "services_ssm_parameter_access" {
  for_each = local.service_names

  role       = aws_iam_role.services_task_execution[each.key].name
  policy_arn = aws_iam_policy.services_ssm_parameter_access[each.key].arn
}

resource "aws_iam_policy" "services_ssm_parameter_access" {
  for_each = local.service_names

  name   = "ServiceSSMAccessPolicy_${var.project}_${each.key}_${var.env}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${var.env}/${var.project}/${each.key}/*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "services_sqs_access" {
  for_each = { for k, v in local.service_names : k => v if var.sqs_enable }

  role       = aws_iam_role.services_task_execution[each.key].name
  policy_arn = var.sqs_policy_arn
}


# S3 env files access for services
resource "aws_iam_role_policy" "services_s3_env" {
  for_each = { for k, v in local.service_names : k => v if length(local.env_files_s3) > 0 }

  name = "${var.project}_${each.key}_s3_env_${var.env}"
  role = aws_iam_role.services_task_execution[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:*"
        ]
        Resource = [
          for file in local.env_files_s3 :
          "arn:aws:s3:::${file.bucket}/${file.key}"
        ]
      }
    ]
  })
}

// create empty files if they don't exist for each env files services
resource "null_resource" "create_services_env_files" {
  for_each = {
    for pair in flatten([
      for service_name, files in local.services_env_files_s3 : [
        for file in files : {
          key = "${file.bucket}-${file.key}"
          file = file
        }
      ]
    ]) : pair.key => pair.file
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Checking if file exists: ${each.value.bucket}/${each.value.key}"
      touch empty.tmp
      aws s3api head-object --bucket ${each.value.bucket} --key ${each.value.key} || \
      aws s3api put-object --bucket ${each.value.bucket} --key ${each.value.key} --body empty.tmp
      rm empty.tmp
    EOT
  }
}

# Remote exec policy for services
resource "aws_iam_role_policy" "services_ecs_exec_policy" {
  for_each = { for k, v in local.service_names : k => v if var.backend_remote_access }

  name = "${var.project}-${each.key}-ecs-exec-policy-${var.env}"
  role = aws_iam_role.services_task[each.key].id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      }
    ]
  })
}
