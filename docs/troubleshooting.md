# Troubleshooting Guide

Common issues encountered during deployment and operation of the AI Gateway POC, with resolutions.

---

---

## CloudFormation Stack Failures

### Symptom
```
CREATE_FAILED - AWS::IAM::Role - Resource already exists
```

### Cause
A previous failed deployment left orphaned IAM roles. CloudFormation can't create resources that already exist outside its management.

### Resolution
1. Check for existing resources: `aws iam get-role --role-name <role-name>`
2. Delete the orphaned role manually: `aws iam delete-role --role-name <role-name>`
3. Re-run `deploy.sh`

### Symptom
```
ROLLBACK_COMPLETE - stack is in ROLLBACK_COMPLETE state and can not be updated
```

### Cause
A previous deployment failed and the stack rolled back. CloudFormation won't update a stack in this state.

### Resolution
Delete the failed stack and re-deploy:
```bash
aws cloudformation delete-stack --stack-name <stack-name> --region <region>
aws cloudformation wait stack-delete-complete --stack-name <stack-name> --region <region>
./deploy.sh --region <region> --stage poc --alert-email <email>
```

### Symptom
```
CREATE_FAILED - AWS::CloudFormation::Stack - Requires capabilities: [CAPABILITY_IAM]
```

### Resolution
This should be handled by `deploy.sh` automatically. If running CloudFormation manually, add `--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM`.

---

## Bedrock Model Access Not Enabled

### Symptom
```
AccessDeniedException: You don't have access to the model with the specified model ID.
```

### Cause
The Bedrock model (`us.anthropic.claude-sonnet-4-6`) hasn't been enabled in your AWS account.

### Resolution
1. Go to **AWS Console → Amazon Bedrock → Model access**
2. Click **Manage model access**
3. Select **Anthropic → Claude** models
4. Click **Request model access**
5. Wait for access to be granted (usually immediate for on-demand models)
6. Re-run the deployment or test

> **Note**: Model access is region-specific. Enable access in the same region you're deploying to.

---

## S3 Bucket Name Conflicts

### Symptom
```
CREATE_FAILED - AWS::S3::Bucket - ai-gateway-kb-123456789012 already exists
```

### Cause
S3 bucket names are globally unique. Another account (or a previous deployment in the same account) already created a bucket with this name.

### Resolution
1. If it's from a previous deployment, run cleanup first:
   ```bash
   ./cleanup/destroy.sh --region <region> --stage poc
   ```
2. If the bucket exists in another account, the CloudFormation template uses `${AWS::AccountId}` suffix to avoid conflicts. Check that the template is using the correct naming pattern.
3. As a last resort, manually empty and delete the conflicting bucket:
   ```bash
   aws s3 rm s3://<bucket-name> --recursive
   aws s3 rb s3://<bucket-name>
   ```

---

## AgentCore Gateway Registration Failures

### Symptom
```
An error occurred (ValidationException) when calling the CreateGateway operation
```

### Cause
AgentCore Gateway may not be available in your region, or the API has changed.

### Resolution
1. Verify AgentCore is available in your deployment region
2. Check that your AWS CLI is up to date: `aws --version` (need v2.15+)
3. Verify the Bedrock AgentCore service endpoint exists:
   ```bash
   aws bedrock-agent list-agents --region <region>
   ```
4. If AgentCore is not available in your region, deploy to `us-east-1` or `us-west-2`

### Symptom
```
ResourceNotFoundException: Gateway not found
```

### Resolution
The gateway may not have been created yet. Ensure the deployment steps ran in order. Check the `register-tools.sh` script is receiving the correct gateway ARN from previous steps.

---

## Client UI CORS Issues

### Symptom
Browser console shows:
```
Access to fetch at 'https://<api-id>.execute-api.<region>.amazonaws.com/poc/...'
from origin 'https://<distribution>.cloudfront.net' has been blocked by CORS policy
```

### Cause
The API Gateway CORS configuration doesn't include the CloudFront distribution URL as an allowed origin.

### Resolution
1. Verify the CORS configuration was applied during deployment (Step 9 in deploy.sh)
2. Check the API Gateway console → Resources → select a method → check Method Response and Integration Response for CORS headers
3. Manually configure CORS if needed:
   ```bash
   # Check current Gateway Responses
   aws apigateway get-gateway-responses --rest-api-id <api-id>
   
   # Update DEFAULT_4XX response with CORS header
   aws apigateway put-gateway-response \
     --rest-api-id <api-id> \
     --response-type DEFAULT_4XX \
     --response-parameters '{"gatewayresponse.header.Access-Control-Allow-Origin": "'\''https://<cloudfront-domain>'\''"}' \
     --region <region>
   
   # Redeploy the API stage
   aws apigateway create-deployment --rest-api-id <api-id> --stage-name poc
   ```
4. Ensure the OPTIONS preflight method exists on each resource path with a Mock integration

### Symptom
CORS works for successful responses but fails on 4XX/5XX errors.

### Resolution
Gateway Responses (DEFAULT_4XX, DEFAULT_5XX) must include the `Access-Control-Allow-Origin` header. These are separate from method-level CORS configuration. See step 3 above.

---

## OAuth2/PKCE Callback Errors

### Symptom: "code_verifier not found"
The callback page shows an error about missing code_verifier.

### Cause
The PKCE `code_verifier` is stored in `sessionStorage` during the login redirect. If the session was lost (browser closed, different tab, incognito mode cleared), the verifier is gone.

### Resolution
1. Click "Back to Login" and try signing in again
2. Ensure you're not blocking sessionStorage (check browser privacy settings)
3. Don't open the callback URL directly — always start from the Sign In button

### Symptom: "Token exchange failed" or "invalid_grant"
```
Error: Token exchange failed
```

### Cause
The authorization code has expired (codes are single-use and short-lived, typically 5 minutes) or the `redirect_uri` in the token exchange doesn't match the one used in the authorize request.

### Resolution
1. Try signing in again (codes expire quickly)
2. Verify the callback URL in Cognito matches exactly: `https://<cloudfront-domain>/callback`
3. Check that `config.js` has the correct `COGNITO_REDIRECT_URI` value
4. Ensure there's no trailing slash mismatch between the configured callback URL and the actual redirect

### Symptom: "access_denied" from Cognito
The callback URL contains `?error=access_denied`.

### Resolution
1. The user may not exist in the Cognito User Pool
2. The user's account may be disabled
3. Check user status: `aws cognito-idp admin-get-user --user-pool-id <pool-id> --username <email>`

---

## Cognito Hosted UI Domain Conflicts

### Symptom
```
InvalidParameterException: Domain already associated with another user pool
```

### Cause
The Cognito Hosted UI domain prefix (`ai-gateway-poc`) is globally unique across all AWS accounts. Another deployment is using this prefix.

### Resolution
1. Choose a different domain prefix by modifying `config/cognito-setup.json`:
   ```json
   "domain": "ai-gateway-poc-<unique-suffix>"
   ```
2. Or delete the existing domain first:
   ```bash
   aws cognito-idp delete-user-pool-domain \
     --user-pool-id <pool-id> \
     --domain ai-gateway-poc
   ```
3. Re-run the deployment

---

## First Login Password Change Issues

### Symptom
After entering the temporary password, the Hosted UI shows an error or loops back to login.

### Cause
The new password doesn't meet Cognito's password policy requirements.

### Resolution
Cognito's default password policy requires:
- Minimum 8 characters
- At least one uppercase letter
- At least one lowercase letter
- At least one number
- At least one special character

Choose a password that meets all requirements (e.g., `MyNewPass@2026!`).

### Symptom
"User does not exist" error on the Hosted UI.

### Resolution
1. Verify the user was created during deployment:
   ```bash
   aws cognito-idp admin-get-user \
     --user-pool-id <pool-id> \
     --username <email>
   ```
2. If the user doesn't exist, create them manually:
   ```bash
   python3 scripts/create-cognito-users.py <pool-id> <email>
   ```

---

## Rate Limiting Not Working

### Symptom
Sending more than 100 requests/minute doesn't produce any 429 responses.

### Cause
The usage plan may not be associated with the API Gateway stage, or requests aren't including the API key.

### Resolution
1. Verify the usage plan exists and is associated:
   ```bash
   aws apigateway get-usage-plans --region <region>
   ```
2. Check that the API key is included in requests:
   ```bash
   curl -H "x-api-key: <your-api-key>" https://<gateway-url>/poc/...
   ```
3. Verify the API Gateway stage requires API keys:
   - In the console: API Gateway → Resources → Method Request → API Key Required = true
4. If the usage plan exists but isn't associated with the stage:
   ```bash
   aws apigateway update-usage-plan \
     --usage-plan-id <plan-id> \
     --patch-operations op=add,path=/apiStages,value='<api-id>:poc'
   ```

### Symptom
429 responses appear but without a `Retry-After` header.

### Resolution
API Gateway includes `Retry-After` in throttled responses by default. If it's missing, check that you're reading the response headers correctly. The header value is in seconds.

---

## General Debugging Tips

1. **Check CloudFormation events** for deployment failures:
   ```bash
   aws cloudformation describe-stack-events --stack-name <stack-name> --region <region> | head -50
   ```

2. **Check Lambda logs** for runtime errors:
   ```bash
   aws logs tail /aws/lambda/<function-name> --since 5m --region <region>
   ```

3. **Check API Gateway execution logs** (if enabled):
   ```bash
   aws logs tail API-Gateway-Execution-Logs_<api-id>/poc --since 5m --region <region>
   ```

4. **Verify AWS credentials** are configured correctly:
   ```bash
   aws sts get-caller-identity
   ```

5. **Check service quotas** if you hit limits:
   ```bash
   aws service-quotas get-service-quota \
     --service-code apigateway \
     --quota-code <quota-code> \
     --region <region>
   ```
