# Broken Serverless Lab

A Terraform lab for practising AWS serverless troubleshooting. Deploy a broken Lambda + API Gateway + SQS pipeline and work out why messages aren't being processed.

## Scenario

A simple event-driven pipeline:

```
Client → POST → API Gateway → SQS Queue → Lambda → CloudWatch Logs
```

When you POST to the API endpoint you should get a `200` response, and within a few seconds a CloudWatch log entry should appear showing the message was processed. Neither of those things is working correctly. Your job is to find out why.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- AWS CLI configured with Lambda, API Gateway, SQS, and IAM permissions
- An AWS account (deploys to `ap-southeast-2`)

## Getting started

```bash
git clone <your-repo-url>
cd broken-serverless-lab

terraform init
terraform apply
```

## Your starting point

After apply, the API endpoint is printed as an output. Try hitting it:

```bash
curl -X POST <api_endpoint> \
  -H "Content-Type: application/json" \
  -d '{"message": "hello world"}'
```

Then check if Lambda processed anything:

```bash
aws logs tail /aws/lambda/lab-processor \
  --follow \
  --region ap-southeast-2
```

There are **3 bugs** spanning API Gateway, Lambda, and IAM.

## Useful investigation commands

```bash
# Check SQS message count
aws sqs get-queue-attributes \
  --queue-url <SQS_QUEUE_URL> \
  --attribute-names ApproximateNumberOfMessages \
  --region ap-southeast-2

# Send a message directly to SQS (bypasses API Gateway)
aws sqs send-message \
  --queue-url <SQS_QUEUE_URL> \
  --message-body '{"message": "test"}' \
  --region ap-southeast-2

# Check Lambda event source mappings
aws lambda list-event-source-mappings \
  --function-name lab-processor \
  --region ap-southeast-2

# Watch Lambda logs live
aws logs tail /aws/lambda/lab-processor \
  --follow \
  --region ap-southeast-2
```

## Solutions

Full walkthrough in [`SOLUTIONS.md`](./SOLUTIONS.md) — keep it closed until you're done!

## Cleaning up

```bash
terraform destroy
```
