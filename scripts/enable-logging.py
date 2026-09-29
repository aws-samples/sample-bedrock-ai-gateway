#!/usr/bin/env python3
"""
Enable Bedrock model invocation logging to CloudWatch Logs.
Captures input tokens, output tokens, model ID, and latency.

Usage:
    python scripts/enable-logging.py --region us-east-1
    python scripts/enable-logging.py --region us-east-1 --company-name anycompany --stage poc
"""
import argparse
import json as _json
import os
import sys
import time

import boto3
from botocore.exceptions import ClientError


def enable_logging(region: str, company_name: str, stage: str) -> None:
    """Configure Bedrock invocation logging to CloudWatch Logs."""
    # All resource names derived from company_name + stage so multiple deployments
    # in the same account don't collide.
    prefix = f"{company_name}-{stage}"
    log_group_name = f"/aws/bedrock/{prefix}-invocations"
    role_name = f"{prefix}-bedrock-logging-role"

    sts = boto3.client("sts")
    account_id = sts.get_caller_identity()["Account"]
    logging_role_arn = f"arn:aws:iam::{account_id}:role/{role_name}"
    s3_bucket = f"{prefix}-invocation-logs-{account_id}"

    bedrock = boto3.client("bedrock", region_name=region)
    logs = boto3.client("logs", region_name=region)
    iam = boto3.client("iam")

    # Create log group if it doesn't exist
    try:
        logs.create_log_group(logGroupName=log_group_name)
        print(f"  Created log group: {log_group_name}")
    except ClientError as e:
        if "ResourceAlreadyExistsException" in str(e):
            print(f"  Log group already exists: {log_group_name}")
        else:
            raise

    # Set retention to 30 days to manage costs
    try:
        logs.put_retention_policy(logGroupName=log_group_name, retentionInDays=30)
    except ClientError:
        pass

    # Create or verify the IAM role for Bedrock logging
    try:
        iam.get_role(RoleName=role_name)
        print(f"  IAM role already exists: {role_name}")
    except ClientError as e:
        if "NoSuchEntity" in str(e):
            print(f"  Creating IAM role: {role_name}")
            trust_policy = _json.dumps({
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": "bedrock.amazonaws.com"},
                    "Action": "sts:AssumeRole"
                }]
            })
            iam.create_role(
                RoleName=role_name,
                AssumeRolePolicyDocument=trust_policy,
                Description="Allows Bedrock to write invocation logs to CloudWatch"
            )
            iam.put_role_policy(
                RoleName=role_name,
                PolicyName="BedrockLoggingPolicy",
                PolicyDocument=_json.dumps({
                    "Version": "2012-10-17",
                    "Statement": [{
                        "Effect": "Allow",
                        "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
                        "Resource": f"arn:aws:logs:{region}:{account_id}:log-group:{log_group_name}:*"
                    }]
                })
            )
            print(f"  ✅ IAM role created. Waiting 10s for propagation...")
            time.sleep(10)  # intentional: wait for IAM role propagation before use  # nosemgrep
        else:
            raise

    # Configure Bedrock invocation logging
    try:
        bedrock.put_model_invocation_logging_configuration(
            loggingConfig={
                "cloudWatchConfig": {
                    "logGroupName": log_group_name,
                    "roleArn": logging_role_arn,
                    "largeDataDeliveryS3Config": {
                        "bucketName": s3_bucket,
                        "keyPrefix": "bedrock-logs/",
                    },
                },
                "textDataDeliveryEnabled": True,
                "imageDataDeliveryEnabled": False,
                "embeddingDataDeliveryEnabled": False,
            }
        )
        print(f"  ✅ Invocation logging enabled → {log_group_name}")
        print(f"     Captures: input tokens, output tokens, model ID, latency")
    except ClientError as e:
        if "ValidationException" in str(e):
            # Retry with simplified config (CloudWatch only, no S3 large data delivery)
            try:
                bedrock.put_model_invocation_logging_configuration(
                    loggingConfig={
                        "cloudWatchConfig": {
                            "logGroupName": log_group_name,
                            "roleArn": logging_role_arn,
                        },
                        "textDataDeliveryEnabled": True,
                        "imageDataDeliveryEnabled": False,
                        "embeddingDataDeliveryEnabled": False,
                    }
                )
                print(f"  ✅ Invocation logging enabled (CloudWatch only) → {log_group_name}")
                print(f"     Captures: input tokens, output tokens, model ID, latency")
            except ClientError as e2:
                print(f"  ⚠️  Could not enable invocation logging: {e2}")
                print(f"  ℹ️  You may need to create the logging IAM role manually:")
                print(f"      Role: {role_name}")
                print(f"      Trust: bedrock.amazonaws.com")
                print(f"      Permissions: logs:CreateLogStream, logs:PutLogEvents")
                sys.exit(1)
        else:
            print(f"  ❌ Logging configuration failed: {e}")
            sys.exit(1)

    print(f"\n✅ Success! Bedrock invocation logging configured.")
    print(f"   Log group: {log_group_name}")
    print(f"   IAM role:  {role_name}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Enable Bedrock model invocation logging to CloudWatch Logs"
    )
    parser.add_argument(
        "--region",
        default=os.environ.get("AWS_REGION"),
        help="AWS region (defaults to AWS_REGION environment variable)",
    )
    parser.add_argument(
        "--company-name",
        default=os.environ.get("COMPANY_NAME", "anycompany"),
        help="Company name prefix for resource names (default: anycompany)",
    )
    parser.add_argument(
        "--stage",
        default=os.environ.get("STAGE", "poc"),
        help="Deployment stage suffix for resource names (default: poc)",
    )
    args = parser.parse_args()

    if not args.region:
        print("❌ Error: AWS region is required.")
        print("   Set AWS_REGION environment variable or pass --region flag.")
        sys.exit(1)

    print(f"Configuring Bedrock invocation logging in {args.region}...")
    print(f"  Company: {args.company_name}  Stage: {args.stage}")
    enable_logging(args.region, args.company_name, args.stage)


if __name__ == "__main__":
    main()
