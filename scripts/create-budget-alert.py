#!/usr/bin/env python3
"""
Create AWS Budget alert for AI Gateway POC.
$500/month threshold filtered to CostCenter=IT-Operations tag.
SNS alert at 80% to provided email address.
"""
import argparse
import sys

import boto3
from botocore.exceptions import ClientError


def main():
    ap = argparse.ArgumentParser(description="Create AWS Budget alert for AI Gateway")
    ap.add_argument("alert_email", help="Email address for budget alert notifications")
    ap.add_argument("--budget-name", default="anycompany-ai-gateway-poc",
                    help="Budget name (default: anycompany-ai-gateway-poc)")
    ap.add_argument("--region", default="us-east-1")
    args = ap.parse_args()

    alert_email = args.alert_email
    budget_name = args.budget_name

    # Get AWS account ID
    sts = boto3.client("sts")
    account_id = sts.get_caller_identity()["Account"]
    print(f"AWS Account: {account_id}")

    budgets = boto3.client("budgets")

    try:
        budgets.create_budget(
            AccountId=account_id,
            Budget={
                "BudgetName": budget_name,
                "BudgetLimit": {"Amount": "500", "Unit": "USD"},
                "TimeUnit": "MONTHLY",
                "BudgetType": "COST",
                "CostFilters": {
                    "TagKeyValue": ["user:CostCenter$IT-Operations"]
                },
            },
            NotificationsWithSubscribers=[
                {
                    "Notification": {
                        "NotificationType": "ACTUAL",
                        "ComparisonOperator": "GREATER_THAN",
                        "Threshold": 80.0,
                        "ThresholdType": "PERCENTAGE",
                    },
                    "Subscribers": [
                        {
                            "SubscriptionType": "EMAIL",
                            "Address": alert_email,
                        }
                    ],
                }
            ],
        )
        print(f"✅ Budget '{budget_name}' created successfully.")
        print(f"   Limit: $500 USD/month")
        print(f"   Alert: 80% threshold ({alert_email})")
        print(f"   Filter: CostCenter=IT-Operations")
    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        if error_code in ("BudgetAlreadyExistsException", "DuplicateRecordException"):
            print(f"ℹ️  Budget '{budget_name}' already exists. No changes made.")
        elif error_code == "InvalidParameterException":
            print(f"⚠️  Budget alert skipped: invalid email address '{alert_email}'.")
            print(f"   Use a verified email address in your AWS account.")
            sys.exit(0)
        else:
            raise


if __name__ == "__main__":
    main()
