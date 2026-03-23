###############################################################
# BROKEN LAB — EC2 + ALB + Auto Scaling
# Scenario: A web application should be reachable via an
# Application Load Balancer, with EC2 instances managed by
# an Auto Scaling Group. Something is wrong — find and fix it.
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

# Latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

###############################################################
# VPC & NETWORKING
###############################################################

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "lab-vpc" }
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

# Security group for the Application Load Balancer
resource "aws_security_group" "alb" {
  name        = "lab-alb-sg"
  description = "Allow HTTP traffic to the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
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

# Security group for EC2 instances
# BUG 1: This security group only allows traffic from the internet
# directly — it should only allow traffic FROM the ALB security group.
# But more critically, the port is wrong: the app runs on port 80,
# yet this rule opens port 8080, so the ALB health checks will fail
# and no traffic will reach the instances.
resource "aws_security_group" "ec2" {
  name        = "lab-ec2-sg"
  description = "Allow traffic to EC2 instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "App traffic"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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
# IAM ROLE FOR EC2
###############################################################

resource "aws_iam_role" "ec2_role" {
  name = "lab-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# BUG 2: AmazonSSMManagedInstanceCore is attached so you can
# connect via Session Manager — but the policy ARN has a typo
# ("AmazonSSMManagedInstanceCor" is missing the trailing 'e').
# This means SSM won't work, so if SSH is also unavailable
# you'll have no way to access the instance to debug it.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCor"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "lab-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

###############################################################
# LAUNCH TEMPLATE
###############################################################

resource "aws_launch_template" "app" {
  name_prefix   = "lab-app-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ec2.id]
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y httpd
    systemctl start httpd
    systemctl enable httpd
    echo "<h1>Hello from $(hostname)</h1>" > /var/www/html/index.html
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "lab-app-instance" }
  }
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

  tags = { Name = "lab-alb" }
}

# BUG 3: The target group health check path is set to "/healthz"
# but the user_data only creates "/var/www/html/index.html" (served
# at "/"). The health check will always return 404, the targets will
# never be marked healthy, and the ALB will return 502 Bad Gateway
# to every request.
resource "aws_lb_target_group" "app" {
  name     = "lab-app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/healthz"
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
# AUTO SCALING GROUP
###############################################################

resource "aws_autoscaling_group" "app" {
  name                = "lab-asg"
  desired_capacity    = 2
  min_size            = 1
  max_size            = 4
  vpc_zone_identifier = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  target_group_arns   = [aws_lb_target_group.app.arn]
  health_check_type   = "ELB"

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "lab-asg-instance"
    propagate_at_launch = true
  }
}

###############################################################
# OUTPUTS
###############################################################

output "alb_dns_name" {
  description = "Hit this URL to test the application"
  value       = "http://${aws_lb.main.dns_name}"
}

output "asg_name" {
  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.app.name
}

output "target_group_arn" {
  description = "Target Group ARN — check target health in the console"
  value       = aws_lb_target_group.app.arn
}
