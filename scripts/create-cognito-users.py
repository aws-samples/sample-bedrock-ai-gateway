#!/usr/bin/env python3
"""
Create a user in the Cognito User Pool during deployment.

Usage:
    python3 scripts/create-cognito-users.py <user_pool_id> <email> --temp-password <password> [--team TEAM] [--role ROLE]

The script creates a Cognito user with a temporary password supplied by the caller.
The Cognito Hosted UI handles forced password change on first login — the temporary
password is never reused after that point.

Region is read from AWS_REGION environment variable (defaults to us-east-1).
"""
import argparse
import os
import sys

import boto3
from botocore.exceptions import ClientError


def create_user(user_pool_id, email, temp_password, team="Architecture", role="admin"):
    """Create a user in the specified Cognito User Pool."""
    region = os.environ.get("AWS_REGION", "us-east-1")
    cognito = boto3.client("cognito-idp", region_name=region)

    try:
        cognito.admin_create_user(
            UserPoolId=user_pool_id,
            Username=email,
            TemporaryPassword=temp_password,
            UserAttributes=[
                {"Name": "email", "Value": email},
                {"Name": "email_verified", "Value": "true"},
                {"Name": "custom:team", "Value": team},
                {"Name": "custom:role", "Value": role},
            ],
            MessageAction="SUPPRESS",
        )
        print(f"✅ User created successfully")
        print(f"   Username: {email}")
        print(f"   Team: {team}")
        print(f"   Role: {role}")
        print(f"   Temporary Password: {temp_password}")
    except ClientError as e:
        if e.response["Error"]["Code"] == "UsernameExistsException":
            print(f"⚠️  User already exists: {email}")
            print(f"   Username: {email}")
            print(f"   Team: {team}")
            print(f"   Role: {role}")
        else:
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Create Cognito user for AI Gateway POC")
    parser.add_argument("user_pool_id", help="Cognito User Pool ID")
    parser.add_argument("email", help="User email (becomes username)")
    parser.add_argument("--temp-password", required=True,
                        help="Temporary password for the new user. Cognito forces a change on first login.")
    parser.add_argument("--team", default="Architecture", help="Team name (default: Architecture)")
    parser.add_argument("--role", default="admin", help="Role (default: admin)")
    parser.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))

    args = parser.parse_args()
    os.environ["AWS_REGION"] = args.region

    create_user(args.user_pool_id, args.email, args.temp_password, args.team, args.role)
