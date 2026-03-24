# Lab Solutions — Don't peek until you've tried!

## Scenario
A POST to the API Gateway endpoint should write a message to SQS,
which triggers a Lambda function to process it and log to CloudWatch.

## Symptoms to start with
1. POST to the API endpoint → gets a 404 response
2. Even if you get messages into SQS manually → Lambda never fires
3. CloudWatch logs for the Lambda → no invocations at all

---

## Bug 1 — Lambda has no SQS read permissions

**Resource:** Missing `aws_iam_role_policy_attachment` for SQS  
**Problem:** The Lambda role only has `AWSLambdaBasicExecutionRole`
(CloudWatch Logs). It has no permission to read from SQS. The event
source mapping will fail internally — Lambda can't poll the queue to
retrieve messages. Messages pile up unprocessed.

**Fix:** Add an SQS policy attachment to the Lambda role:

```hcl
resource "aws_iam_role_policy_attachment" "lambda_sqs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}
```

**How to diagnose:**
- Console → Lambda → lab-processor → Configuration → Triggers
  → SQS trigger shows "Last result: ERROR"
- Console → Lambda → lab-processor → Monitor → View CloudWatch logs
  → no log streams exist (Lambda never invoked)
- Console → IAM → Roles → lab-lambda-role → Permissions
  → only BasicExecutionRole attached, no SQS policy

---

## Bug 2 — Event source mapping points at the wrong ARN

**Resource:** `aws_lambda_event_source_mapping.sqs_trigger`  
**Problem:** `event_source_arn` is set to
`aws_lambda_function.processor.arn` (the Lambda's own ARN) instead
of `aws_sqs_queue.messages.arn`. The event source must be the SQS
queue — Lambda polls the queue for new messages. Pointing it at
itself is invalid and will error on apply or silently never trigger.

**Fix:**
```hcl
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.messages.arn   # <-- was processor.arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 1
  enabled          = true
}
```

**How to diagnose:**
- Console → Lambda → lab-processor → Configuration → Triggers
  → the SQS trigger is missing or shows an error
- Console → SQS → lab-messages → Lambda triggers tab
  → no Lambda is associated with the queue
- AWS CLI:
  ```bash
  aws lambda list-event-source-mappings \
    --function-name lab-processor \
    --region ap-southeast-2
  ```
  → EventSourceArn will show the Lambda ARN instead of an SQS ARN

---

## Bug 3 — API Gateway route uses GET instead of POST

**Resource:** `aws_apigatewayv2_route.post_message`  
**Problem:** `route_key` is set to `"GET /messages"` but clients
are sending `POST` requests. API Gateway has no matching POST route
and returns a 404. The SQS integration is perfectly fine — it just
never gets called.

**Fix:**
```hcl
resource "aws_apigatewayv2_route" "post_message" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /messages"   # <-- was GET
  target    = "integrations/${aws_apigatewayv2_integration.sqs.id}"
}
```

**How to diagnose:**
- `curl -X POST <api_endpoint> -d '{"msg":"hello"}'` → 404
- `curl -X GET <api_endpoint>` → actually gets a response (wrong method works!)
- Console → API Gateway → lab-api → Routes
  → only a GET /messages route listed, no POST

---

## Recommended investigation order

1. `terraform apply`
2. POST to the API endpoint:
   ```bash
   curl -X POST <api_endpoint> \
     -H "Content-Type: application/json" \
     -d '{"message": "hello world"}'
   ```
   → 404 (Bug 3 visible immediately)
3. Fix Bug 3, re-apply, POST again → 200 now
4. Check SQS message count — messages arriving but not draining
   ```bash
   aws sqs get-queue-attributes \
     --queue-url <SQS_QUEUE_URL> \
     --attribute-names ApproximateNumberOfMessages \
     --region ap-southeast-2
   ```
5. Check Lambda triggers in console → error or missing (Bug 2)
6. Fix Bug 2, re-apply → trigger now wired up
7. Messages still not processing → check IAM permissions (Bug 1)
8. Fix Bug 1, re-apply → Lambda finally fires, logs appear

## Useful commands

# Send a test message via CLI directly to SQS (bypasses API GW)
aws sqs send-message \
  --queue-url <SQS_QUEUE_URL> \
  --message-body '{"message": "test"}' \
  --region ap-southeast-2

# Watch Lambda logs live
aws logs tail /aws/lambda/lab-processor \
  --follow \
  --region ap-southeast-2

# Check event source mapping status
aws lambda list-event-source-mappings \
  --function-name lab-processor \
  --region ap-southeast-2
