# Broken EC2 Lab

A Terraform lab environment for practising AWS troubleshooting. Deploy a deliberately broken EC2 + ALB + Auto Scaling setup and work out why it isn't functioning.

## Scenario

You've inherited a web application that should be reachable via an Application Load Balancer, with EC2 instances managed by an Auto Scaling Group. When you visit the ALB URL, you get a **502 Bad Gateway**. Your job is to find out why and fix it.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- AWS CLI configured with credentials that have EC2, IAM, and ELB permissions
- An AWS account (resources deployed to `ap-southeast-2` by default)

## Getting started

```bash
# Clone the repo
git clone <your-repo-url>
cd broken-ec2-lab

# Initialise Terraform
terraform init

# Deploy the broken environment
terraform apply
```

Wait about **3 minutes** after apply completes for instances to launch and health checks to run, then visit the `alb_dns_name` output URL.

## Your starting point

The ALB DNS name is printed as an output after `terraform apply`. Visit it in your browser — you should see a `502 Bad Gateway`. That's intentional.

From there, use the AWS Console, AWS CLI, or both to investigate. There are **3 bugs** to find across different areas of the stack.

## Useful investigation commands

```bash
# Check target health
aws elbv2 describe-target-health \
  --target-group-arn <TG_ARN> \
  --region ap-southeast-2

# List ASG instances
aws autoscaling describe-auto-scaling-instances \
  --region ap-southeast-2

# Check SSM-managed instances
aws ssm describe-instance-information \
  --region ap-southeast-2
```

## Solutions

Solutions and a step-by-step diagnosis walkthrough are in [`SOLUTIONS.md`](./SOLUTIONS.md). Try not to peek until you've had a proper go!

## Cleaning up

```bash
terraform destroy
```

This removes all resources to avoid ongoing AWS charges.
