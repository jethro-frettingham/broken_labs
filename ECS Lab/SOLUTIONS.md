# Lab Solutions — Don't peek until you've tried!

## Scenario
An ECS cluster backed by EC2 instances runs a containerised nginx
app behind an ALB. Visiting the ALB DNS returns errors, and ECS
tasks are not reaching a steady running state.

## Symptoms to start with
1. Visit ALB DNS → 502 or 503
2. Console → ECS → lab-cluster → Tasks → tasks stuck in
   PROVISIONING or cycling RUNNING → STOPPED
3. Console → ECS → lab-cluster → Container Instances → 0 registered

---

## Bug 1 — EC2 security group blocks ALB on port 80

**Resource:** `aws_security_group.ec2`  
**Problem:** The ingress rule only opens the Docker ephemeral port
range (32768–65535), which is correct for *dynamic* port mapping.
But the task definition uses a *fixed* host port of 80. The ALB
sends health checks to port 80 on the EC2 instance — the security
group drops them, targets stay unhealthy, and the ALB returns 502.

**Fix:** Add port 80 from the ALB security group:

```hcl
ingress {
  description     = "HTTP from ALB"
  from_port       = 80
  to_port         = 80
  protocol        = "tcp"
  security_groups = [aws_security_group.alb.id]
}
```

**How to diagnose:**
- Console → EC2 → Target Groups → lab-app-tg → Targets
  → targets unhealthy, reason: "Health checks failed"
- Console → EC2 → Security Groups → lab-ec2-sg → Inbound rules
  → only 32768-65535 listed, no port 80
- From an EC2 instance: `curl localhost:80` works (nginx is up)
  but the ALB can't reach it

---

## Bug 2 — Task execution role has wrong assume role principal

**Resource:** `aws_iam_role.ecs_task_execution_role`  
**Problem:** The `assume_role_policy` has `"ec2.amazonaws.com"` as
the principal instead of `"ecs-tasks.amazonaws.com"`. ECS cannot
assume this role to pull the container image or write CloudWatch
logs. Tasks get stuck in PROVISIONING or fail immediately with
a CannotPullContainerError.

**Fix:**
```hcl
Principal = { Service = "ecs-tasks.amazonaws.com" }
```

**How to diagnose:**
- Console → ECS → lab-cluster → Tasks → click a stopped task
  → "Stopped reason: CannotPullContainerError" or similar
- Console → IAM → Roles → lab-ecs-task-execution-role
  → Trust relationships tab → shows ec2.amazonaws.com
  → should be ecs-tasks.amazonaws.com
- AWS CLI:
  ```bash
  aws ecs describe-tasks \
    --cluster lab-cluster \
    --tasks <TASK_ARN> \
    --region ap-southeast-2
  ```
  → stoppedReason will mention the role issue

---

## Bug 3 — ECS agent registering with wrong cluster name

**Resource:** `aws_launch_template.ecs` user_data  
**Problem:** The bootstrap script writes
`ECS_CLUSTER=lab-cluster-wrong` to `/etc/ecs/ecs.config`. The ECS
agent on each EC2 instance reads this file on startup and registers
with that cluster name — which doesn't exist. The real `lab-cluster`
has zero container instances, so ECS has nowhere to schedule tasks.

**Fix:** Correct the cluster name in user_data:
```hcl
user_data = base64encode(<<-EOF
  #!/bin/bash
  echo ECS_CLUSTER=lab-cluster >> /etc/ecs/ecs.config
EOF
)
```

Note: after fixing this you need to terminate the existing EC2
instances so the ASG replaces them with correctly configured ones.
The old instances already ran the wrong user_data and won't re-run it.

```bash
# Terminate instances so ASG relaunches with correct user_data
aws ec2 terminate-instances \
  --instance-ids $(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=lab-ecs-instance" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text) \
  --region ap-southeast-2
```

**How to diagnose:**
- Console → ECS → lab-cluster → Infrastructure tab
  → "0 container instances" even though EC2 instances are running
- Console → EC2 → Instances → select an ECS instance
  → Connect via Session Manager → check the config:
  ```bash
  cat /etc/ecs/ecs.config
  # Shows: ECS_CLUSTER=lab-cluster-wrong
  ```
- Also visible in ECS agent logs:
  ```bash
  sudo journalctl -u ecs -f
  # Will show registration attempts against wrong cluster
  ```

---

## Recommended investigation order

1. `terraform apply`
2. Wait 3–4 minutes, visit ALB DNS → 502/503
3. Console → ECS → lab-cluster → Infrastructure
   → "0 container instances" (Bug 3 immediately obvious)
4. SSH/SSM onto an EC2 instance → check `/etc/ecs/ecs.config`
5. Fix Bug 3 in main.tf, re-apply, terminate old instances
6. Container instances now register → tasks start scheduling
7. Tasks still failing → check stopped task reason (Bug 2)
8. Fix Bug 2, re-apply → tasks now pull image and start
9. ALB still 502 → check target group health (Bug 1)
10. Fix Bug 1, re-apply → healthy targets, ALB returns 200

## Useful commands

# Watch ECS service events
aws ecs describe-services \
  --cluster lab-cluster \
  --services lab-app-service \
  --region ap-southeast-2 \
  --query "services[0].events[:5]"

# Check container instances registered to cluster
aws ecs list-container-instances \
  --cluster lab-cluster \
  --region ap-southeast-2

# Describe a stopped task to see failure reason
aws ecs describe-tasks \
  --cluster lab-cluster \
  --tasks <TASK_ARN> \
  --region ap-southeast-2 \
  --query "tasks[0].stoppedReason"

# Check target health
aws elbv2 describe-target-health \
  --target-group-arn <TG_ARN> \
  --region ap-southeast-2
