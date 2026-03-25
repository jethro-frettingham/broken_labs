###############################################################
# BROKEN LAB — ECS (EC2 launch type) + ALB
#
# Scenario: A containerised web app runs on an ECS cluster
# backed by EC2 instances, sitting behind an Application Load
# Balancer. When you visit the ALB DNS name you should see a
# simple nginx welcome page served from a running ECS task.
#
# After deploying, the ALB DNS resolves but returns errors.
# ECS tasks may be starting and stopping. Find and fix it.
###############################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"
}

###############################################################
# DATA SOURCES
###############################################################

data "aws_availability_zones" "available" {
  state = "available"
}

# ECS-optimised Amazon Linux 2 AMI
data "aws_ami" "ecs_optimized" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*-x86_64-ebs"]
  }
}

###############################################################
# VPC & NETWORKING
###############################################################

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "lab-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lab-igw" }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "lab-public-a" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
  tags                    = { Name = "lab-public-b" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "lab-public-rt" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

###############################################################
# SECURITY GROUPS
###############################################################

resource "aws_security_group" "alb" {
  name        = "lab-alb-sg"
  description = "Allow HTTP from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lab-alb-sg" }
}

# BUG 1: The EC2 instances running ECS tasks need to accept
# traffic from the ALB on the container port (80). This security
# group only allows traffic on port 32768-65535 (the Docker
# ephemeral port range used for dynamic port mapping) but the
# task definition uses a fixed host port of 80. The ALB health
# checks target port 80 on the instances and will fail, causing
# tasks to cycle through unhealthy → draining → stopped.
resource "aws_security_group" "ec2" {
  name        = "lab-ec2-sg"
  description = "Allow traffic to ECS instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Dynamic port range from ALB"
    from_port       = 32768
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lab-ec2-sg" }
}

###############################################################
# IAM — ECS EC2 INSTANCE ROLE
###############################################################

resource "aws_iam_role" "ecs_instance_role" {
  name = "lab-ecs-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs" {
  name = "lab-ecs-instance-profile"
  role = aws_iam_role.ecs_instance_role.name
}

resource "aws_iam_role_policy_attachment" "ecs_ssm" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

###############################################################
# IAM — ECS TASK EXECUTION ROLE
###############################################################

# BUG 2: The task execution role is what ECS uses to pull the
# container image from ECR and write logs to CloudWatch. The
# assume_role_policy here has the wrong service principal —
# it says "ec2.amazonaws.com" instead of "ecs-tasks.amazonaws.com".
# ECS cannot assume this role, so tasks will fail to start with
# a CannotPullContainerError or are stuck in PROVISIONING.
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "lab-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

###############################################################
# ECS CLUSTER
###############################################################

resource "aws_ecs_cluster" "main" {
  name = "lab-cluster"
  tags = { Name = "lab-cluster" }
}

###############################################################
# ECS TASK DEFINITION
###############################################################

resource "aws_ecs_task_definition" "app" {
  family                   = "lab-app"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  cpu                      = "256"
  memory                   = "256"

  container_definitions = jsonencode([{
    name      = "nginx"
    image     = "nginx:latest"
    essential = true

    portMappings = [{
      containerPort = 80
      hostPort      = 80
      protocol      = "tcp"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/lab-app"
        "awslogs-region"        = "ap-southeast-2"
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/lab-app"
  retention_in_days = 7
}

###############################################################
# APPLICATION LOAD BALANCER
###############################################################

resource "aws_lb" "main" {
  name               = "lab-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  tags               = { Name = "lab-alb" }
}

resource "aws_lb_target_group" "app" {
  name     = "lab-app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = { Name = "lab-app-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

###############################################################
# EC2 AUTO SCALING GROUP (ECS container instances)
###############################################################

resource "aws_launch_template" "ecs" {
  name_prefix   = "lab-ecs-"
  image_id      = data.aws_ami.ecs_optimized.id
  instance_type = "t3.small"

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ec2.id]
  }

  # BUG 3: The user_data script registers the instance with the
  # ECS cluster by writing to /etc/ecs/ecs.config. However the
  # cluster name here is hardcoded as "lab-cluster-wrong" instead
  # of the actual cluster name "lab-cluster". The EC2 instance
  # boots and runs the ECS agent, but the agent registers with a
  # non-existent cluster so no tasks are ever scheduled onto it.
  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo ECS_CLUSTER=lab-cluster >> /etc/ecs/ecs.config
    yum install -y amazon-ssm-agent
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "lab-ecs-instance" }
  }
}

resource "aws_autoscaling_group" "ecs" {
  name                = "lab-ecs-asg"
  desired_capacity    = 2
  min_size            = 1
  max_size            = 3
  vpc_zone_identifier = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "lab-ecs-instance"
    propagate_at_launch = true
  }
}

###############################################################
# ECS SERVICE
###############################################################

resource "aws_ecs_service" "app" {
  name            = "lab-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 2
  launch_type     = "EC2"

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "nginx"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.http]
}

###############################################################
# OUTPUTS
###############################################################

output "alb_dns_name" {
  description = "Visit this URL in your browser"
  value       = "http://${aws_lb.main.dns_name}"
}

output "ecs_cluster_name" {
  description = "ECS cluster — check container instances and tasks here"
  value       = aws_ecs_cluster.main.name
}

output "log_group" {
  description = "CloudWatch log group for container logs"
  value       = aws_cloudwatch_log_group.ecs.name
}
