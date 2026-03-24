# Broken Networking Lab

A Terraform lab for practising AWS VPC troubleshooting. Deploy a deliberately broken two-tier network and work out why connectivity isn't functioning.

## Scenario

You've been handed a VPC with a public and private subnet. A bastion host in the public subnet should be SSH-accessible from the internet. A private EC2 instance should be reachable **from the bastion** via SSH, and should have **outbound internet access** via a NAT Gateway (for package installs, etc).

Neither of the last two things work. Your job is to find out why.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- AWS CLI configured with EC2 and VPC permissions
- An AWS account (deploys to `ap-southeast-2`)

## Getting started

```bash
# 1. Clone the repo
git clone <your-repo-url>
cd broken-networking-lab

# 2. Generate a key pair for SSH access
ssh-keygen -t rsa -b 4096 -f lab-key -N ""

# 3. Deploy
terraform init
terraform apply
```

## Your starting point

After apply, two IPs are printed as outputs:

- `bastion_public_ip` — SSH to this first
- `private_instance_ip` — try to reach this from the bastion

```bash
# Step 1: connect to the bastion
ssh -i lab-key ec2-user@<bastion_public_ip>

# Step 2: from the bastion, try to reach the private instance
ssh -i lab-key ec2-user@<private_instance_ip>

# Step 3: test outbound internet from the private instance
curl -m 5 https://example.com
```

There are **3 bugs** to find across the VPC networking stack.

## Useful investigation commands

```bash
# Check which route table is associated with a subnet
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=<SUBNET_ID>" \
  --region ap-southeast-2

# Inspect NAT Gateway details
aws ec2 describe-nat-gateways \
  --region ap-southeast-2

# Check security group rules
aws ec2 describe-security-groups \
  --group-ids <SG_ID> \
  --region ap-southeast-2
```

## Solutions

Full walkthrough in [`SOLUTIONS.md`](./SOLUTIONS.md) — keep it closed until you're done!

## Cleaning up

```bash
terraform destroy
```
