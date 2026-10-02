# IAM Permissions Reference

This document lists every IAM permission required by the AI Gateway POC, organized by role. Each role follows least-privilege principles.

## Permission Categories

- **Deploy-time**: Permissions needed by the person/role running `deploy.sh`
- **Runtime**: Permissions assumed by Lambda functions and services during operation

---

## 1. Deployer Role (Deploy-time)

The IAM user or role executing `deploy.sh` requires these permissions. This is the broadest role — used only during deployment and cleanup.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudFormationFullAccess",
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateStack",
        "cloudformation:UpdateStack",
        "cloudformation:DeleteStack",
        "cloudformation:DescribeStacks",
        "cloudformation:DescribeStackEvents",
        "cloudformation:GetTemplate",
        "cloudformation:ListStackResources",
        "cloudformation:CreateChangeSet",
        "cloudformation:ExecuteChangeSet"
      ],
      "Resource": "arn:aws:cloudformation:*:*:stack/<company-name>-*/*"
    },
    {
      "Sid": "APIGatewayManagement",
      "Effect": "Allow",
      "Action": [
        "apigateway:POST",
        "apigateway:GET",
        "apigateway:PUT",
        "apigateway:DELETE",
        "apigateway:PATCH"
      ],
      "Resource": "arn:aws:apigateway:*::/*"
    },
    {
      "Sid": "LambdaManagement",
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:GetFunctionConfiguration",
        "lambda:DeleteFunction",
        "lambda:GetFunction",
        "lambda:AddPermission",
        "lambda:RemovePermission",
        "lambda:InvokeFunction",
        "lambda:GetPolicy"
      ],
      "Resource": "arn:aws:lambda:*:*:function:<company-name>-*"
    },
    {
      "Sid": "IAMRoleManagement",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:PassRole",
        "iam:CreatePolicy",
        "iam:DeletePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies"
      ],
      "Resource": [
        "arn:aws:iam::*:role/<company-name>-*",
        "arn:aws:iam::*:policy/<company-name>-*"
      ]
    },
    {
      "Sid": "CognitoManagement",
      "Effect": "Allow",
      "Action": [
        "cognito-idp:CreateUserPool",
        "cognito-idp:DeleteUserPool",
        "cognito-idp:DescribeUserPool",
        "cognito-idp:UpdateUserPool",
        "cognito-idp:CreateUserPoolClient",
        "cognito-idp:DeleteUserPoolClient",
        "cognito-idp:UpdateUserPoolClient",
        "cognito-idp:DescribeUserPoolClient",
        "cognito-idp:ListUserPoolClients",
        "cognito-idp:CreateUserPoolDomain",
        "cognito-idp:DeleteUserPoolDomain",
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminDeleteUser",
        "cognito-idp:AdminSetUserPassword",
        "cognito-idp:AdminGetUser"
      ],
      "Resource": "arn:aws:cognito-idp:*:*:userpool/*"
    },
    {
      "Sid": "BedrockManagement",
      "Effect": "Allow",
      "Action": [
        "bedrock:PutModelInvocationLoggingConfiguration",
        "bedrock:GetModelInvocationLoggingConfiguration",
        "bedrock:TagResource",
        "bedrock:InvokeModel",
        "bedrock:CreateInferenceProfile",
        "bedrock:DeleteInferenceProfile",
        "bedrock:ListInferenceProfiles"
      ],
      "Resource": [
        "arn:aws:bedrock:*:*:inference-profile/*",
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:*:model-invocation-logging-configuration"
      ]
    },
    {
      "Sid": "BedrockAgentManagement",
      "Effect": "Allow",
      "Action": [
        "bedrock-agent:ListAgents",
        "bedrock-agent:CreateKnowledgeBase",
        "bedrock-agent:DeleteKnowledgeBase",
        "bedrock-agent:GetKnowledgeBase",
        "bedrock-agent:ListKnowledgeBases",
        "bedrock-agent:CreateDataSource",
        "bedrock-agent:DeleteDataSource",
        "bedrock-agent:ListDataSources",
        "bedrock-agent:StartIngestionJob",
        "bedrock-agent:GetIngestionJob",
        "bedrock-agent:DeleteAgentGateway"
      ],
      "Resource": [
        "arn:aws:bedrock:*:*:knowledge-base/*",
        "arn:aws:bedrock:*:*:data-source/*"
      ]
    },
    {
      "Sid": "S3BucketManagement",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:DeleteBucket",
        "s3:PutBucketPolicy",
        "s3:GetBucketPolicy",
        "s3:DeleteBucketPolicy",
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:PutBucketWebsite",
        "s3:GetBucketWebsite",
        "s3:PutEncryptionConfiguration",
        "s3:PutBucketPublicAccessBlock"
      ],
      "Resource": [
        "arn:aws:s3:::<company-name>-*",
        "arn:aws:s3:::<company-name>-*/*"
      ]
    },
    {
      "Sid": "CloudWatchManagement",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:DeleteLogGroup",
        "logs:PutRetentionPolicy",
        "logs:DescribeLogGroups"
      ],
      "Resource": [
        "arn:aws:logs:*:*:log-group:/aws/lambda/<company-name>-*",
        "arn:aws:logs:*:*:log-group:/aws/bedrock/<company-name>-*",
        "arn:aws:logs:*:*:log-group:/aws/apigateway/<company-name>-*",
        "arn:aws:logs:*:*:log-group:/aws/agentcore/*"
      ]
    },
    {
      "Sid": "CloudWatchDashboards",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutDashboard",
        "cloudwatch:DeleteDashboards",
        "cloudwatch:GetDashboard",
        "cloudwatch:ListDashboards"
      ],
      "Resource": "arn:aws:cloudwatch:*:*:dashboard/<company-name>-*"
    },
    {
      "Sid": "BudgetsManagement",
      "Effect": "Allow",
      "Action": [
        "budgets:CreateBudget",
        "budgets:DeleteBudget",
        "budgets:DescribeBudget"
      ],
      "Resource": "arn:aws:budgets:*:*:budget/<company-name>-*"
    },
    {
      "Sid": "SNSAlertTopics",
      "Effect": "Allow",
      "Action": [
        "sns:CreateTopic",
        "sns:DeleteTopic",
        "sns:Subscribe",
        "sns:Unsubscribe",
        "sns:SetTopicAttributes"
      ],
      "Resource": "arn:aws:sns:*:*:<company-name>-*"
    },
    {
      "Sid": "DynamoDBTeamConfig",
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable",
        "dynamodb:DeleteTable",
        "dynamodb:DescribeTable",
        "dynamodb:PutItem",
        "dynamodb:Scan"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/ai-gateway-team-config"
    },
    {
      "Sid": "EventBridgeScheduledRules",
      "Effect": "Allow",
      "Action": [
        "events:PutRule",
        "events:PutTargets",
        "events:RemoveTargets",
        "events:DeleteRule",
        "events:DescribeRule",
        "events:ListTargetsByRule"
      ],
      "Resource": "arn:aws:events:*:*:rule/<company-name>-*"
    },
    {
      "Sid": "ServiceQuotasManagement",
      "Effect": "Allow",
      "Action": [
        "servicequotas:GetServiceQuota",
        "servicequotas:RequestServiceQuotaIncrease"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "servicequotas:service": "apigateway"
        }
      }
    },
    {
      "Sid": "CloudFrontManagement",
      "Effect": "Allow",
      "Action": [
        "cloudfront:CreateDistribution",
        "cloudfront:DeleteDistribution",
        "cloudfront:UpdateDistribution",
        "cloudfront:GetDistribution",
        "cloudfront:GetDistributionConfig",
        "cloudfront:CreateInvalidation",
        "cloudfront:CreateOriginAccessControl",
        "cloudfront:DeleteOriginAccessControl",
        "cloudfront:GetOriginAccessControl"
      ],
      "Resource": "arn:aws:cloudfront:*:*:distribution/*"
    },
    {
      "Sid": "CloudFrontOAC",
      "Effect": "Allow",
      "Action": [
        "cloudfront:CreateOriginAccessControl",
        "cloudfront:DeleteOriginAccessControl",
        "cloudfront:GetOriginAccessControl"
      ],
      "Resource": "arn:aws:cloudfront:*:*:origin-access-control/*"
    },
    {
      "Sid": "OpenSearchServerlessManagement",
      "Effect": "Allow",
      "Action": [
        "aoss:CreateCollection",
        "aoss:DeleteCollection",
        "aoss:BatchGetCollection",
        "aoss:ListCollections"
      ],
      "Resource": "arn:aws:aoss:*:*:collection/*"
    },
    {
      "Sid": "OpenSearchServerlessPolicies",
      "Effect": "Allow",
      "Action": [
        "aoss:CreateSecurityPolicy",
        "aoss:UpdateSecurityPolicy",
        "aoss:DeleteSecurityPolicy",
        "aoss:GetSecurityPolicy",
        "aoss:CreateAccessPolicy",
        "aoss:UpdateAccessPolicy",
        "aoss:DeleteAccessPolicy",
        "aoss:GetAccessPolicy"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AgentCoreManagement",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:CreateGateway",
        "bedrock-agentcore:DeleteGateway",
        "bedrock-agentcore:GetGateway",
        "bedrock-agentcore:ListGateways",
        "bedrock-agentcore:CreateGatewayTarget",
        "bedrock-agentcore:DeleteGatewayTarget",
        "bedrock-agentcore:GetGatewayTarget",
        "bedrock-agentcore:ListGatewayTargets",
        "bedrock-agentcore:SynchronizeGatewayTargets",
        "bedrock-agentcore:CreateAgentRuntime",
        "bedrock-agentcore:UpdateAgentRuntime",
        "bedrock-agentcore:DeleteAgentRuntime",
        "bedrock-agentcore:GetAgentRuntime",
        "bedrock-agentcore:ListAgentRuntimes",
        "bedrock-agentcore:ListAgentRuntimeEndpoints",
        "bedrock-agentcore:DeleteAgentRuntimeEndpoint",
        "bedrock-agentcore:InvokeAgentRuntime",
        "bedrock-agentcore:CreateRegistry",
        "bedrock-agentcore:GetRegistry",
        "bedrock-agentcore:ListRegistries",
        "bedrock-agentcore:DeleteRegistry",
        "bedrock-agentcore:CreateRegistryRecord",
        "bedrock-agentcore:GetRegistryRecord",
        "bedrock-agentcore:ListRegistryRecords",
        "bedrock-agentcore:DeleteRegistryRecord",
        "bedrock-agentcore:SearchRegistryRecords"
      ],
      "Resource": [
        "arn:aws:bedrock-agentcore:*:*:gateway/*",
        "arn:aws:bedrock-agentcore:*:*:runtime/*",
        "arn:aws:bedrock-agentcore:*:*:registry/*"
      ]
    },
    {
      "Sid": "STSIdentity",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

> **Action namespace:** AgentCore IAM actions live under the `bedrock-agentcore:` service
> prefix — **not** `bedrock:`. Granting `bedrock:CreateGateway` will NOT authorize
> `aws bedrock-agentcore-control create-gateway`; the call fails with AccessDenied on
> `bedrock-agentcore:CreateGateway`. The control plane (`aws bedrock-agentcore-control`) and
> data plane (`aws bedrock-agentcore`) both authorize against this same `bedrock-agentcore:`
> prefix.

> **Agent Registry enrollment (preview):** AWS Agent Registry is a preview feature that
> requires explicit account-level activation before the `ListRegistries`, `CreateRegistry`,
> and related APIs are accessible — even for users with `AdministratorAccess`. The error
> returned when not enrolled (`AccessDeniedException: not authorized to perform
> bedrock-agentcore:ListRegistries`) looks identical to an IAM denial but is actually a
> service enrollment gate. To enable it: **AWS Console → Amazon Bedrock → AgentCore →
> Agent Registry → Enable for your account and region**. IAM actions in the
> `AgentCoreManagement` Sid above are still required after enrollment.

> **Remaining `Resource: *` entries explained:**
> - `OpenSearchServerlessPolicies` — AOSS security/access policies are account-level resources with no ARN; AWS does not support resource scoping for these actions.
> - `ServiceQuotasManagement` — Service Quotas are account-level; constrained via Condition key to `apigateway` service only.
> - `sts:GetCallerIdentity` — AWS requires `*`; this is a read-only identity check with no resource target.
> - `API GW Logging Role (Section 5)` — AWS-managed policy; we reference it but cannot modify its resource scope.

---

## 2. Lambda Execution Roles (Runtime)

### 2a. search_kb Lambda Role

Allows the search_kb function to query the Bedrock Knowledge Base and write logs.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockKBRetrieve",
      "Effect": "Allow",
      "Action": [
        "bedrock:Retrieve"
      ],
      "Resource": "arn:aws:bedrock:*:*:knowledge-base/*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/lambda/<company-name>-search-kb-*:*"
    }
  ]
}
```

**Trust Policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### 2b. create_ticket Lambda Role

Minimal permissions — this function only creates mock tickets (no external API calls).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/lambda/<company-name>-create-ticket-*:*"
    }
  ]
}
```

### 2c. Sign-and-Forward Lambda Role (Streaming Proxy)

Allows the proxy Lambda to invoke Bedrock models, invoke the AgentCore Runtime, read team config from DynamoDB (budget check + AIP routing — read-only), and write logs.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockInvoke",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:GetInferenceProfile"
      ],
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:*:inference-profile/*"
      ]
    },
    {
      "Sid": "AgentCoreInvoke",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:InvokeAgentRuntime"
      ],
      "Resource": "arn:aws:bedrock-agentcore:*:*:runtime/*"
    },
    {
      "Sid": "DynamoDBTeamConfig",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/ai-gateway-team-config"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/lambda/<company-name>-*:*"
    }
  ]
}
```

> **Note**: Bedrock invoke is scoped to all foundation models and inference profiles. This covers per-BU AIP routing (Task 16/19) and multi-model support. Tighten further to specific model ARNs (e.g., `us.anthropic.claude-sonnet-4-6`) if only one model family is needed.
>
> **`bedrock:GetInferenceProfile`**: Used by `diagnose_model_access()` to distinguish a malformed ARN from an unauthorised profile when Bedrock returns the unhelpful "The provided model identifier is invalid" error. It is not required for model invocation itself.
>
> **Task 18**: `bedrock-agentcore:InvokeAgentRuntime` allows the Lambda to route `/agent/chat` requests to the AgentCore Runtime (demo agent).
>
> **Task 20 (budget check)**: The Streaming Proxy reads `budget_limit` and `month_spend` via `dynamodb:GetItem` and returns 429 if the team has exceeded its limit. It has **no write access** to DynamoDB — spend counters are maintained exclusively by the SpendAggregatorLambda (see Section 2f).

### 2f. SpendAggregatorLambda Role (Task 20.3)

Computes month-to-date token cost per business unit from AWS/Bedrock CloudWatch metrics and writes `month_spend` to DynamoDB. Runs every 2 minutes via EventBridge.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DynamoDBSpendUpdate",
      "Effect": "Allow",
      "Action": [
        "dynamodb:Scan",
        "dynamodb:UpdateItem"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/ai-gateway-team-config"
    },
    {
      "Sid": "CloudWatchMetrics",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:GetMetricStatistics"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/lambda/ai-gateway-*-SpendAggregator:*"
    }
  ]
}
```

> **`cloudwatch:GetMetricStatistics`** requires `Resource: *` — CloudWatch metric APIs are account-level and cannot be scoped to specific metric namespaces via IAM.
>
> **No `dynamodb:GetItem` needed** — the aggregator reads the full table via `Scan` to build its team→profile mapping in one call, then writes back with `UpdateItem`.

### 2d. Lambda Authorizer Role

Validates Cognito tokens. Needs access to Cognito user pool metadata for JWKS verification and CloudWatch for logging.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/lambda/<company-name>-authorizer-*:*"
    }
  ]
}
```

> **Note**: The Lambda Authorizer validates Cognito tokens using the JWKS endpoint (public URL). It does not need `cognito-idp:*` permissions — token validation is done via JWT signature verification against the public keys.

### 2e. Budget Reset Lambda Role (Task 20.4)

Resets `month_spend` to 0 and updates `month_key` for all teams on the 1st of each month. Triggered by EventBridge scheduled rule `cron(0 0 1 * ? *)`. Deployed as `BudgetResetRole` in `cloudformation/gateway-stack.yaml`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DynamoDBResetSpend",
      "Effect": "Allow",
      "Action": [
        "dynamodb:Scan",
        "dynamodb:UpdateItem"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/ai-gateway-team-config"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/lambda/ai-gateway-*-BudgetReset:*"
    }
  ]
}
```

**Trust Policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

> **Note**: This Lambda is invoked by an EventBridge cron rule (`0 0 1 * ? *`). It scans all team records and atomically sets `month_spend = 0` and `month_key = current month`. No Bedrock or API Gateway permissions needed.

---

## 3. AgentCore Runtime Role

Allows the demo agent running in AgentCore Runtime to invoke tools and call Bedrock. When AIP routing is enabled (Task 19), the agent receives the user's AIP ARN in the invocation payload and uses it as the model ID — so the Bedrock invoke resource must cover both the base model and all inference profiles.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockInvoke",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:GetInferenceProfile"
      ],
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/us.anthropic.claude-sonnet-4-6",
        "arn:aws:bedrock:*:*:inference-profile/*"
      ]
    },
    {
      "Sid": "AgentCoreGatewayAccess",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:InvokeGateway"
      ],
      "Resource": "arn:aws:bedrock-agentcore:*:*:gateway/*"
    },
    {
      "Sid": "AgentCoreTokenVault",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:GetResourceOauth2Token",
        "bedrock-agentcore:GetWorkloadAccessToken",
        "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
        "bedrock-agentcore:GetWorkloadAccessTokenForUsernamePassword",
        "bedrock-agentcore:CreateWorkloadIdentity",
        "bedrock-agentcore:GetWorkloadIdentity",
        "bedrock-agentcore:ListWorkloadIdentities"
      ],
      "Resource": [
        "arn:aws:bedrock-agentcore:*:*:token-vault/*",
        "arn:aws:bedrock-agentcore:*:*:workload-identity-directory/*"
      ]
    },
    {
      "Sid": "AgentCoreMemory",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:CreateEvent",
        "bedrock-agentcore:ListEvents",
        "bedrock-agentcore:GetEvent",
        "bedrock-agentcore:RetrieveMemoryRecords",
        "bedrock-agentcore:ListMemoryRecords"
      ],
      "Resource": "arn:aws:bedrock-agentcore:*:*:memory/*"
    },
    {
      "Sid": "SecretsManagerTokenVaultBacking",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:*:*:secret:bedrock-agentcore-identity!*"
    },
    {
      "Sid": "LambdaToolInvocation",
      "Effect": "Allow",
      "Action": [
        "lambda:InvokeFunction"
      ],
      "Resource": [
        "arn:aws:lambda:*:*:function:ai-gateway-poc-search-kb-*",
        "arn:aws:lambda:*:*:function:ai-gateway-poc-create-ticket-*"
      ]
    },
    {
      "Sid": "TeamConfigLookup",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/ai-gateway-team-config"
    },
    {
      "Sid": "ECRImagePull",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRImagePullFromRepo",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "arn:aws:ecr:*:*:repository/<company-name>-demo-agent"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/bedrock-agentcore/*:*"
    },
    {
      "Sid": "XRayTracing",
      "Effect": "Allow",
      "Action": [
        "xray:PutTraceSegments",
        "xray:PutTelemetryRecords",
        "xray:GetSamplingRules",
        "xray:GetSamplingTargets"
      ],
      "Resource": "*"
    }
  ]
}
```

> **`bedrock-agentcore:` not `bedrock:`**: All AgentCore gateway, memory, and token vault actions use the `bedrock-agentcore:` prefix. The old `bedrock:InvokeAgent`, `bedrock:GetGateway`, and `bedrock:InvokeGateway` actions do not authorize AgentCore operations — those would fail with AccessDenied. The correct action for invoking the AgentCore MCP Gateway from the runtime is `bedrock-agentcore:InvokeGateway`.
>
> **`bedrock:GetInferenceProfile`**: Used by `diagnose_model_access()` to distinguish a malformed ARN from an unauthorised profile, not required for invocation itself.
>
> **Token vault**: `GetResourceOauth2Token` and `GetWorkloadAccessToken*` allow the agent to retrieve the Cognito M2M bearer token stored in the AgentCore Identity token vault, so `GATEWAY_CLIENT_SECRET` does not need to be in the runtime environment.
>
> **`ecr:GetAuthorizationToken`** requires `Resource: *` — AWS does not support resource-level scoping for this action.
>
> **`xray:*`** requires `Resource: *` — X-Ray tracing actions are account-level and cannot be scoped to a specific resource ARN.

**Trust Policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "<ACCOUNT_ID>"
        }
      }
    }
  ]
}
```

---

## 4. Bedrock Knowledge Base Role

Allows the Knowledge Base service to read documents from the S3 source bucket and index into OpenSearch Serverless.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ReadAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::ai-gateway-kb-docs-*",
        "arn:aws:s3:::ai-gateway-kb-docs-*/*"
      ]
    },
    {
      "Sid": "BedrockEmbeddings",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel"
      ],
      "Resource": "arn:aws:bedrock:*::foundation-model/amazon.titan-embed-text-v2*"
    },
    {
      "Sid": "OpenSearchVectorIndexing",
      "Effect": "Allow",
      "Action": [
        "aoss:APIAccessAll"
      ],
      "Resource": "arn:aws:aoss:*:*:collection/*"
    }
  ]
}
```

**Trust Policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "bedrock.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "<ACCOUNT_ID>"
        }
      }
    }
  ]
}
```

---

## 5. API Gateway CloudWatch Logging Role

Allows API Gateway to write access logs to CloudWatch. Created by `cloudformation/gateway-stack.yaml`.

**Role Name:** `${StackName}-ApiGwLogsRole` (e.g., `ai-gateway-poc-ApiGwLogsRole`)

**Managed Policy:** `arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs`

This managed policy grants:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents",
        "logs:GetLogEvents",
        "logs:FilterLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
```

**Trust Policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "apigateway.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

> **Note**: This role is set as the account-level API Gateway CloudWatch role via `AWS::ApiGateway::Account`. It enables the `AccessLogSetting` on the API stage to write structured JSON access logs including user identity.

---

## 6. Bedrock Invocation Logging Role

Allows Bedrock to write model invocation logs (token usage, latency, model ID) to CloudWatch. Created by `scripts/enable-logging.py`.

**Role Name:** `ai-gateway-poc-bedrock-logging-role`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchLogWrite",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/bedrock/ai-gateway-poc-invocations:*"
    }
  ]
}
```

**Trust Policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "bedrock.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

> **Note**: This role is passed to `bedrock:PutModelInvocationLoggingConfiguration`. It allows Bedrock to write invocation metadata (input/output tokens, model ID, latency) to the designated log group for cost tracking and observability.

---

## Deploy-time vs Runtime Summary

| Permission | When Used | Role |
|------------|-----------|------|
| CloudFormation CRUD | Deploy/Cleanup | Deployer |
| API Gateway management | Deploy | Deployer |
| Lambda create/update/delete | Deploy | Deployer |
| IAM role management | Deploy | Deployer |
| Cognito pool/client/user management | Deploy | Deployer |
| OpenSearch Serverless management | Deploy | Deployer |
| Bedrock AIP create/delete/list | Deploy | Deployer |
| DynamoDB table create/seed/delete | Deploy/Cleanup | Deployer |
| EventBridge rule create/delete | Deploy/Cleanup | Deployer |
| Service Quotas (API GW timeout increase) | Deploy | Deployer |
| S3 bucket create/delete | Deploy/Cleanup | Deployer |
| CloudFront create/delete | Deploy/Cleanup | Deployer |
| Budget/SNS create | Deploy | Deployer |
| sts:GetCallerIdentity | Deploy | Deployer |
| bedrock:Retrieve | Runtime | search_kb Lambda |
| bedrock:InvokeModel, InvokeModelWithResponseStream | Runtime | Streaming Proxy Lambda, AgentCore Runtime |
| bedrock:GetInferenceProfile | Runtime | Streaming Proxy Lambda, AgentCore Runtime (model diagnostics) |
| bedrock-agentcore:InvokeAgentRuntime | Runtime | Streaming Proxy Lambda |
| bedrock-agentcore:InvokeGateway | Runtime | AgentCore Runtime |
| bedrock-agentcore:GetResourceOauth2Token, GetWorkloadAccessToken* | Runtime | AgentCore Runtime (token vault) |
| bedrock-agentcore:CreateEvent/ListEvents/GetEvent/RetrieveMemoryRecords | Runtime | AgentCore Runtime (memory) |
| secretsmanager:GetSecretValue (bedrock-agentcore-identity!*) | Runtime | AgentCore Runtime (token vault backing secret) |
| dynamodb:GetItem (team config) | Runtime | Streaming Proxy Lambda (budget check + AIP routing — read-only) |
| dynamodb:Scan + UpdateItem (spend tracking) | Runtime (every 2 min) | SpendAggregatorLambda |
| dynamodb:Scan + UpdateItem (reset) | Runtime (monthly) | Budget Reset Lambda |
| logs:PutLogEvents | Runtime | All Lambdas, API GW Logging Role, Bedrock Logging Role |
| lambda:InvokeFunction | Runtime | AgentCore Runtime |
| s3:GetObject (KB bucket) | Runtime | Knowledge Base service |
| aoss:APIAccessAll | Runtime | Knowledge Base service (vector indexing) |
| AmazonAPIGatewayPushToCloudWatchLogs | Runtime | API GW CloudWatch Logging Role |
| logs:CreateLogStream + PutLogEvents | Runtime | Bedrock Invocation Logging Role |
