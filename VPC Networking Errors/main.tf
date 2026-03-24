###############################################################
# BROKEN LAB — VPC + Public/Private Subnets + NAT + Bastion
#
# Scenario: A two-tier architecture. A bastion host in the
# public subnet should be SSH-accessible from the internet.
# A private EC2 instance in the private subnet should be
# reachable FROM the bastion, and should be able to reach
# the internet outbound (to download packages etc) via a
# NAT Gateway. Something is wrong — find and fix it.
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
# VPC
###############################################################

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "lab-vpc" }
}

###############################################################
# INTERNET GATEWAY
###############################################################

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lab-igw" }
}

###############################################################
# SUBNETS
###############################################################

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "lab-public-subnet" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "lab-private-subnet" }
}

###############################################################
# NAT GATEWAY
# Allows private subnet instances to reach the internet
# outbound without being directly reachable inbound.
###############################################################

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "lab-nat-eip" }
}

# BUG 1: The NAT Gateway is deployed into the PRIVATE subnet.
# A NAT Gateway must live in the PUBLIC subnet so it can route
# outbound traffic through the Internet Gateway. Placing it in
# the private subnet means private instances get no outbound
# internet access — package installs, curl, etc. will all hang.
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.private.id

  tags = { Name = "lab-nat-gw" }

  depends_on = [aws_internet_gateway.main]
}

###############################################################
# ROUTE TABLES
###############################################################

# Public route table — sends all traffic to the IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "lab-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private route table — sends outbound traffic through the NAT GW
# BUG 2: This route table is never associated with the private subnet.
# Without an association, the private subnet falls back to the VPC's
# default/main route table, which has no route to the NAT Gateway.
# Private instances cannot reach the internet at all.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "lab-private-rt" }
}

# Missing: aws_route_table_association for the private subnet

###############################################################
# SECURITY GROUPS
###############################################################

# Bastion security group — should allow SSH from the internet
resource "aws_security_group" "bastion" {
  name        = "lab-bastion-sg"
  description = "SSH access to bastion host"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from internet"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lab-bastion-sg" }
}

# Private instance security group
# BUG 3: This allows SSH ingress from "0.0.0.0/0" (the whole internet),
# but the instance has no public IP so that rule is irrelevant anyway.
# The real problem is: there is NO rule allowing SSH from the bastion's
# security group (or even the public subnet CIDR 10.0.1.0/24).
# So when you SSH from the bastion to the private instance, the
# connection will time out — the security group silently drops it.
resource "aws_security_group" "private" {
  name        = "lab-private-sg"
  description = "Security group for private instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lab-private-sg" }
}

###############################################################
# KEY PAIR
# Generate a key pair locally before applying:
#   ssh-keygen -t rsa -b 4096 -f lab-key
# Then terraform apply will upload the public key.
###############################################################

resource "aws_key_pair" "lab" {
  key_name   = "lab-key"
  public_key = file("${path.module}/lab-key.pub")
}

###############################################################
# EC2 INSTANCES
###############################################################

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = aws_key_pair.lab.key_name
  associate_public_ip_address = true

  tags = { Name = "lab-bastion" }
}

resource "aws_instance" "private" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.private.id]
  key_name                    = aws_key_pair.lab.key_name
  associate_public_ip_address = false

  tags = { Name = "lab-private" }
}

###############################################################
# OUTPUTS
###############################################################

output "bastion_public_ip" {
  description = "SSH to this IP to reach the bastion"
  value       = aws_instance.bastion.public_ip
}

output "private_instance_ip" {
  description = "Private IP of the internal instance (reach via bastion)"
  value       = aws_instance.private.private_ip
}

output "nat_gateway_id" {
  description = "NAT Gateway ID — check which subnet it's in"
  value       = aws_nat_gateway.main.id
}
