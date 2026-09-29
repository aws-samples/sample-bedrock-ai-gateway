# Multi-Cloud Extension Guide: LiteLLM for Phase 2

This guide describes how to extend the AI Gateway POC to route requests to multiple model providers (Azure OpenAI, Databricks, and AWS Bedrock) using LiteLLM as a unified proxy layer.

## Overview

Phase 2 adds a LiteLLM proxy between the API Gateway and model providers. This enables:

- **Unified API**: Single OpenAI-compatible endpoint for all providers
- **Provider routing**: Route requests to Azure OpenAI, Databricks, or Bedrock based on model selection
- **Bedrock Guardrails**: Apply content safety guardrails to all providers (not just Bedrock)
- **Fallback**: Automatic failover between providers
- **Cost tracking**: Unified token usage logging across all providers

## Architecture

```
                                    ┌─────────────────────┐
                                    │   Azure OpenAI      │
                                    │   (GPT-4, GPT-4o)   │
                                    └─────────────────────┘
                                              ▲
                                              │
Client → API Gateway → Lambda Authorizer     │
       → LiteLLM Proxy ──────────────────────┤
         (ECS Fargate)                        │
              │                               │
              │                    ┌─────────────────────┐
              │                    │   Databricks        │
              │                    │   (DBRX, Llama)     │
              │                    └─────────────────────┘
              │
              ▼
    ┌─────────────────────┐
    │   Amazon Bedrock    │
    │   (Claude, Titan)   │
    │   + Guardrails      │
    └─────────────────────┘
```

### Key Changes from Phase 1

| Component | Phase 1 (Current) | Phase 2 (LiteLLM) |
|-----------|-------------------|-------------------|
| Model proxy | Sign-and-Forward Lambda | LiteLLM on ECS Fargate |
| Providers | Bedrock only | Bedrock + Azure OpenAI + Databricks |
| API format | Bedrock Converse API | OpenAI-compatible (unified) |
| Guardrails | N/A | Bedrock Guardrails applied to all |
| Scaling | Lambda concurrency | ECS auto-scaling |

## LiteLLM Configuration

LiteLLM runs as a containerized proxy on ECS Fargate. Configuration example:

```yaml
# litellm_config.yaml
model_list:
  # AWS Bedrock models
  - model_name: claude-sonnet
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-6
      aws_region_name: us-east-1

  - model_name: claude-haiku
    litellm_params:
      model: bedrock/anthropic.claude-3-haiku-20240307-v1:0
      aws_region_name: us-east-1

  # Azure OpenAI models
  - model_name: gpt-4o
    litellm_params:
      model: azure/gpt-4o
      api_base: https://<resource>.openai.azure.com/
      api_key: os.environ/AZURE_API_KEY
      api_version: "2024-02-01"

  - model_name: gpt-4
    litellm_params:
      model: azure/gpt-4
      api_base: https://<resource>.openai.azure.com/
      api_key: os.environ/AZURE_API_KEY
      api_version: "2024-02-01"

  # Databricks models
  - model_name: dbrx
    litellm_params:
      model: databricks/databricks-dbrx-instruct
      api_base: https://<workspace>.cloud.databricks.com/serving-endpoints
      api_key: os.environ/DATABRICKS_TOKEN

litellm_settings:
  # Apply Bedrock Guardrails to all providers
  guardrail_name: "bedrock_guardrails"
  callbacks: ["bedrock_guardrails"]

  # Logging
  success_callback: ["cloudwatch"]
  failure_callback: ["cloudwatch"]

  # Rate limiting (per-user)
  max_budget: 50.0
  budget_duration: "1d"

guardrails:
  - guardrail_name: "bedrock_guardrails"
    litellm_params:
      guardrail: bedrock
      guardrailIdentifier: "<guardrail-id>"
      guardrailVersion: "DRAFT"
      mode: "during_call"
```

## Bedrock Guardrails for All Providers

A key advantage of this architecture: Bedrock Guardrails applies content filtering to responses from **all** providers, not just Bedrock models.

```
Azure OpenAI response → LiteLLM → Bedrock Guardrails check → Client
Databricks response   → LiteLLM → Bedrock Guardrails check → Client
Bedrock response      → LiteLLM → Bedrock Guardrails check → Client
```

Configure guardrails in the AWS Console:
1. Go to **Amazon Bedrock → Guardrails → Create guardrail**
2. Configure content filters (hate, violence, sexual, etc.)
3. Add denied topics relevant to your use case
4. Note the guardrail ID and version for the LiteLLM config

## Infrastructure Changes

### New Resources

| Resource | Purpose |
|----------|---------|
| ECS Cluster (Fargate) | Hosts LiteLLM container |
| ECS Task Definition | LiteLLM container config + secrets |
| ALB (internal) | Load balances LiteLLM instances |
| Secrets Manager | Azure/Databricks API keys |
| ECR Repository | LiteLLM container image |
| Bedrock Guardrail | Content safety filtering |

### Modified Resources

| Resource | Change |
|----------|--------|
| API Gateway | Routes to ALB instead of Sign-and-Forward Lambda |
| VPC | Add private subnets for ECS tasks |
| Security Groups | Allow API Gateway → ALB → ECS traffic |

### Deployment Addition

Add to `deploy.sh`:

```bash
# Step N: Deploy LiteLLM proxy
echo "🔄 Deploying LiteLLM proxy..."
aws cloudformation deploy \
  --template-file cloudformation/litellm-stack.yaml \
  --stack-name ai-gateway-litellm-poc \
  --parameter-overrides \
    AzureApiKey=$AZURE_API_KEY \
    DatabricksToken=$DATABRICKS_TOKEN \
    GuardrailId=$GUARDRAIL_ID \
  --capabilities CAPABILITY_IAM
```

## Client UI Changes

Update the model selection dropdown in `frontend/src/models.js`:

```javascript
export const AVAILABLE_MODELS = [
  // AWS Bedrock
  { id: 'claude-sonnet', name: 'Claude Sonnet 4.6 (Bedrock)', provider: 'aws' },
  { id: 'claude-haiku', name: 'Claude 3 Haiku (Bedrock)', provider: 'aws' },
  // Azure OpenAI
  { id: 'gpt-4o', name: 'GPT-4o (Azure)', provider: 'azure' },
  { id: 'gpt-4', name: 'GPT-4 (Azure)', provider: 'azure' },
  // Databricks
  { id: 'dbrx', name: 'DBRX Instruct (Databricks)', provider: 'databricks' },
];
```

The API format stays OpenAI-compatible, so `bedrockService.js` needs minimal changes (just the endpoint path).

## Cost Tracking Across Providers

LiteLLM provides unified cost tracking:

```yaml
litellm_settings:
  success_callback: ["cloudwatch"]
  service_callback: ["cloudwatch"]
```

This emits metrics to CloudWatch for all providers:
- `litellm.input_tokens` (by model, provider)
- `litellm.output_tokens` (by model, provider)
- `litellm.spend` (estimated cost by provider)
- `litellm.latency` (by model)

Update the CloudWatch dashboard to include multi-provider widgets.

## Reference Implementation

AWS provides a reference architecture for multi-provider AI gateways:

**Repository**: [guidance-for-multi-provider-generative-ai-gateway-on-aws](https://github.com/aws-solutions-library-samples/guidance-for-multi-provider-generative-ai-gateway-on-aws)

This repo includes:
- LiteLLM deployment on ECS Fargate
- Multi-provider routing configuration
- Bedrock Guardrails integration
- Cost tracking and observability
- CloudFormation templates

The POC's CloudFormation templates can be adapted for this deployment at Phase 2.

## Migration Steps

1. **Create Bedrock Guardrail** in the AWS Console with appropriate content filters
2. **Store API keys** in Secrets Manager (Azure OpenAI key, Databricks token)
3. **Build LiteLLM container** with the config above and push to ECR
4. **Deploy ECS infrastructure** (cluster, task definition, ALB, security groups)
5. **Update API Gateway** integration to point to the internal ALB
6. **Update Client UI** model list and redeploy
7. **Update CloudWatch dashboard** with multi-provider metrics
8. **Test** each provider through the unified endpoint
9. **Verify Guardrails** block inappropriate content from all providers
