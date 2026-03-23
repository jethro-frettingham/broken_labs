# Lab Solutions — Don't peek until you've tried!

## Scenario
A web application sits behind an Application Load Balancer with EC2
instances managed by an Auto Scaling Group. When you visit the ALB
DNS name you get a 502 Bad Gateway. Your job is to find out why.

## Symptom to start with
Visit the ALB DNS output URL → 502 Bad Gateway.
Check the Target Group in the console → targets are "unhealthy".

---

## SOLUTION BELOW








## Careful DONT CHEAT


























## Bug 1 — Wrong port in EC2 security group

**File:** main.tf  
**Resource:** aws_security_group.ec2  
**Problem:** The ingress rule opens port 8080, but the web server
(Apache httpd) listens on port 80. The ALB sends health checks to
port 80 ("traffic-port"), so they get dropped by the security group.

**Fix:** Change `from_port` and `to_port` from `8080` to `80`.

**How to diagnose:**
- Console → EC2 → Target Groups → select the TG → Targets tab
- Target status: unhealthy, reason: "Health checks failed"
- Console → EC2 → Security Groups → lab-ec2-sg → Inbound rules
- Notice port 8080 instead of 80

---

## Bug 2 — Typo in IAM policy ARN

**File:** main.tf  
**Resource:** aws_iam_role_policy_attachment.ssm  
**Problem:** The policy ARN ends in "AmazonSSMManagedInstanceCor"
(missing the trailing 'e'). AWS will reject this, meaning the EC2
instances won't register with Systems Manager Session Manager.
You'd have no shell access to debug further.

**Fix:** Change the policy_arn to:
`arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore`

**How to diagnose:**
- `terraform apply` output will show an error on this resource
- OR: Console → EC2 → Instances → select instance → Connect
  → Session Manager tab → "Instance not connected to SSM"
- Console → IAM → Roles → lab-ec2-role → Permissions tab
  → notice SSM policy is missing

---

## Bug 3 — Health check path returns 404

**File:** main.tf  
**Resource:** aws_lb_target_group.app  
**Problem:** The health check path is "/healthz" but Apache only
serves "/index.html" (at path "/"). The health check always gets a
404, so targets are permanently marked unhealthy and the ALB never
forwards requests to them → 502.

**Fix:** Change `path` from `"/healthz"` to `"/"`.

**How to diagnose:**
- Console → EC2 → Target Groups → Targets tab → unhealthy
- Click a target → "Health check details" → HTTP 404
- SSH/SSM onto an instance: `curl localhost/healthz` → 404
- `curl localhost/` → 200 (confirms the app works, wrong path)

---

## Recommended investigation order

1. Deploy with `terraform apply`
2. Wait ~3 minutes, visit the ALB DNS URL → 502
3. Check Target Group health in console (Bug 3 + Bug 1 visible here)
4. Try to connect via Session Manager → fails (Bug 2)
5. Check security group inbound rules → spot port 8080 (Bug 1)
6. Fix Bug 1 first (security group), re-check health checks
7. Health checks still fail → dig into the path (Bug 3)
8. Fix Bug 2 to restore SSM access

## Useful AWS CLI commands for investigation

# Check target health
aws elbv2 describe-target-health \
  --target-group-arn <TG_ARN> \
  --region ap-southeast-2

# Describe ASG instances
aws autoscaling describe-auto-scaling-instances \
  --region ap-southeast-2

# Check SSM-managed instances
aws ssm describe-instance-information \
  --region ap-southeast-2
