# Lab Solutions — Don't peek until you've tried!

## Scenario
A bastion host in the public subnet should be SSH-accessible from
the internet. A private EC2 instance should be reachable FROM the
bastion via SSH, and should have outbound internet access via a
NAT Gateway (e.g. to run `dnf update` or `curl`).

## Symptoms to start with
1. SSH to bastion → works fine
2. SSH from bastion to private instance → connection times out
3. On private instance: `curl https://example.com` → hangs / times out

---

## Bug 1 — NAT Gateway in the wrong subnet

**Resource:** `aws_nat_gateway.main`  
**Problem:** `subnet_id` points to `aws_subnet.private.id`. A NAT
Gateway must be in a **public** subnet so it can send traffic out
through the Internet Gateway. In a private subnet it has no path
to the internet, so outbound traffic from private instances goes
nowhere.

**Fix:** Change `subnet_id` to `aws_subnet.public.id`.

**How to diagnose:**
- Console → VPC → NAT Gateways → check the Subnet column
- Notice it says `lab-private-subnet` instead of `lab-public-subnet`
- OR: from private instance, `curl -m 5 https://example.com` times out
- Check the private route table — route to NAT GW exists, but NAT
  GW itself is misconfigured

---

## Bug 2 — Private route table not associated with the private subnet

**Resource:** `aws_route_table.private` (association is missing entirely)  
**Problem:** The private route table has a correct `0.0.0.0/0` route
via the NAT Gateway, but it is never associated with the private
subnet. The private subnet therefore uses the VPC's implicit main
route table, which has no outbound route at all.

**Fix:** Add the missing association:

```hcl
resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
```

**How to diagnose:**
- Console → VPC → Subnets → select `lab-private-subnet`
  → Route table tab → notice it shows the "Main" route table,
  not `lab-private-rt`
- Console → VPC → Route Tables → `lab-private-rt` → Subnet
  associations → "No explicit associations"

---

## Bug 3 — Private instance security group blocks SSH from bastion

**Resource:** `aws_security_group.private`  
**Problem:** The ingress rule allows SSH from `0.0.0.0/0` (all
internet), but the private instance has no public IP so that rule
is effectively useless. There is no rule permitting SSH from the
bastion host (or the public subnet CIDR `10.0.1.0/24`). The
security group silently drops the connection.

**Fix:** Replace the `0.0.0.0/0` ingress rule with one that allows
SSH from the bastion's security group:

```hcl
ingress {
  description     = "SSH from bastion"
  from_port       = 22
  to_port         = 22
  protocol        = "tcp"
  security_groups = [aws_security_group.bastion.id]
}
```

Or if you prefer CIDR-based (less precise but works):
```hcl
cidr_blocks = ["10.0.1.0/24"]
```

**How to diagnose:**
- SSH from bastion to private IP → connection times out (not refused
  — timeouts mean the SG is dropping packets, not the OS rejecting)
- Console → EC2 → Security Groups → `lab-private-sg` → Inbound rules
  → the rule says `0.0.0.0/0` but instance has no public IP,
  so this never matches real traffic from the bastion

---

## Recommended investigation order

1. `terraform apply` + generate key pair first (see README)
2. SSH to bastion: `ssh -i lab-key ec2-user@<bastion_public_ip>`  ✓
3. From bastion, SSH to private instance → timeout (Bug 3 visible)
4. From bastion, `curl -m 5 https://example.com` on private instance → timeout (Bug 1 + 2)
5. Console → VPC → Subnets → check private subnet's route table (Bug 2)
6. Console → VPC → NAT Gateways → check subnet (Bug 1)
7. Console → EC2 → Security Groups → inspect private SG (Bug 3)

## Useful AWS CLI commands

# Check route tables for a subnet
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=<PRIVATE_SUBNET_ID>" \
  --region ap-southeast-2

# Check NAT gateway details
aws ec2 describe-nat-gateways \
  --region ap-southeast-2

# Check security group rules
aws ec2 describe-security-groups \
  --group-ids <SG_ID> \
  --region ap-southeast-2
