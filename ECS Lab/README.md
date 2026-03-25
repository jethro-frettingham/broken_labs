# Broken ECS Lab

A Terraform lab for practising ECS troubleshooting. Deploy a broken ECS cluster backed by EC2 instances behind an ALB, and work out why the containerised app isn't serving traffic.

## Scenario

A containerised nginx app should be running on an ECS cluster and accessible via an Application Load Balancer:

```
Browser → ALB → ECS Service → nginx container (on EC2 instances)
```

After deploying, the ALB DNS resolves but doesn't return a successful response. ECS tasks are not in a stable running state. Your job is to find out why.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- AWS CLI configured with ECS, EC2, IAM, and ELB permissions
- An AWS account (deploys to `ap-southeast-2`)

## Getting started

```bash
git clone <your-repo-url>
cd broken-ecs-lab

terraform init
terraform apply
```

Wait about **4–5 minutes** after apply for EC2 instances to boot, the ECS agent to start, and tasks to attempt scheduling.

## Your starting point

Visit the `alb_dns_name` output URL — you should see errors. Then start digging:

```bash
# Check if container instances registered with the cluster
aws ecs list-container-instances \
  --cluster lab-cluster \
  --region ap-southeast-2

# Watch ECS service events for clues
aws ecs describe-services \
  --cluster lab-cluster \
  --services lab-app-service \
  --region ap-southeast-2 \
  --query "services[0].events[:5]"

# Check target health
aws elbv2 describe-target-health \
  --target-group-arn <TG_ARN> \
  --region ap-southeast-2
```

There are **3 bugs** spanning EC2 user data, IAM, and security groups.

## Useful commands

```bash
# Describe a stopped task to see why it failed
aws ecs describe-tasks \
  --cluster lab-cluster \
  --tasks <TASK_ARN> \
  --region ap-southeast-2 \
  --query "tasks[0].stoppedReason"

# Check ECS agent logs on an instance (via SSM Session Manager)
sudo journalctl -u ecs -f

# Check the ECS cluster config written at boot
cat /etc/ecs/ecs.config
```

## Solutions

Full walkthrough in [`SOLUTIONS.md`](./SOLUTIONS.md) — keep it closed until you're done!

## Cleaning up

```bash
terraform destroy
```
