#!/bin/bash

# destroy.sh
# Tears down all AWS infrastructure for a given environment by:
#   1. Initialising Terraform with the remote S3 backend
#   2. Validating the target environment exists as a Terraform workspace
#   3. Emptying S3 buckets (required before Terraform can delete them —
#      AWS will refuse to destroy a non-empty bucket)
#   4. Running `terraform destroy` against the selected workspace
#
# Usage:   ./destroy.sh <environment> [project_name]
# Example: ./destroy.sh dev
#          ./destroy.sh prod twin
#
# WARNING: This is irreversible. All infrastructure and S3 data for the
#          target environment will be permanently deleted.

# Exit immediately if any command returns a non-zero exit code.
# Prevents the script from continuing after a failed AWS or Terraform call,
# which could leave infrastructure in a partially destroyed state.
set -e

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
# Require at least one argument (the environment name).
# $# is the number of arguments passed to the script.
# Check if environment parameter is provided
if [ $# -eq 0 ]; then
    echo "❌ Error: Environment parameter is required"
    echo "Usage: $0 <environment>"
    echo "Example: $0 dev"
    echo "Available environments: dev, test, prod"
    exit 1
fi

# First argument: target environment (dev, test, prod).
ENVIRONMENT=$1
# Second argument: project name, defaults to "twin" if not supplied.
# Used to construct resource names (S3 buckets, Terraform workspace, etc.)
# that were created with this prefix during deployment.
PROJECT_NAME=${2:-twin}

echo "🗑️ Preparing to destroy ${PROJECT_NAME}-${ENVIRONMENT} infrastructure..."

# ---------------------------------------------------------------------------
# Terraform backend initialisation
# ---------------------------------------------------------------------------
# Change to the terraform directory relative to this script's location,
# regardless of where the script is called from. Ensures all terraform
# commands target the correct configuration directory.
cd "$(dirname "$0")/../terraform"

# Retrieve the AWS account ID of the currently authenticated IAM identity.
# Used to reconstruct the state bucket name, which embeds the account ID
# for global uniqueness (matches the name set in backend-setup.tf).
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
# Use the DEFAULT_AWS_REGION environment variable if set, otherwise fall back
# to us-east-1. Must match the region where the S3 bucket and DynamoDB table
# were created by backend-setup.tf.
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}

# Initialise Terraform with the remote S3 backend so destroy operations
# read and update the correct remote state file rather than looking for
# a local terraform.tfstate. Backend config is passed at runtime so the
# same .tf files work across environments and AWS accounts.
# -input=false prevents interactive prompts, required for CI/CD pipelines.
# Line 2 below is the S3 bucket that stores all Terraform state files (created in backend-setup.tf).
# Line 3 below is the state file path within the bucket. Using the environment name as a prefix
# isolates each workspace's state: dev/terraform.tfstate, prod/terraform.tfstate, etc.
# Line 4 below is the AWS region where the S3 bucket and DynamoDB lock table reside.
# Line 5 below is the DynamoDB table used for state locking — prevents concurrent terraform runs
# from corrupting the shared state file (created in backend-setup.tf).
# Line 6 below is the Enforce server-side AES-256 encryption on the state file at rest,
# matching the encryption configuration set on the S3 bucket in backend-setup.tf.
echo "🔧 Initializing Terraform with S3 backend..."
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

# ---------------------------------------------------------------------------
# Terraform workspace selection
# ---------------------------------------------------------------------------
# Verify the target workspace exists before attempting to select it.
# Selecting a non-existent workspace would create a new empty one,
# which would find no state to destroy — a silent no-op when we actually
# want an early failure with a clear error message.
# Check if workspace exists
if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
    echo "❌ Error: Workspace '$ENVIRONMENT' does not exist"
    echo "Available workspaces:"
    terraform workspace list
    exit 1
fi

# Switch to the target workspace so all subsequent terraform commands
# operate on the correct environment's state file.
terraform workspace select "$ENVIRONMENT"

# ---------------------------------------------------------------------------
# Empty S3 buckets
# ---------------------------------------------------------------------------

echo "📦 Emptying S3 buckets..."

# Reconstruct the bucket names using the same naming convention used
# during deployment: <project>-<environment>-<purpose>-<account_id>.
# The account ID suffix guarantees global uniqueness across AWS accounts.
FRONTEND_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-frontend-${AWS_ACCOUNT_ID}"
MEMORY_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-memory-${AWS_ACCOUNT_ID}"

# S3 buckets must be completely empty before Terraform can delete them —
# AWS will return an error if destroy is attempted on a non-empty bucket.
# `aws s3 ls` is used as an existence check: it returns non-zero if the
# bucket doesn't exist. stderr is suppressed (2>/dev/null) to avoid noisy
# "NoSuchBucket" errors when the bucket was never created or was already
# deleted by a previous partial destroy run.

# Empty the frontend bucket (holds compiled JS/CSS/HTML assets).
if aws s3 ls "s3://$FRONTEND_BUCKET" 2>/dev/null; then
    echo "  Emptying $FRONTEND_BUCKET..."
    aws s3 rm "s3://$FRONTEND_BUCKET" --recursive
else
    echo "  Frontend bucket not found or already empty"
fi

# Empty the memory bucket (holds persistent agent memory/storage files).
if aws s3 ls "s3://$MEMORY_BUCKET" 2>/dev/null; then
    echo "  Emptying $MEMORY_BUCKET..."
    aws s3 rm "s3://$MEMORY_BUCKET" --recursive
else
    echo "  Memory bucket not found or already empty"
fi

# ---------------------------------------------------------------------------
# Terraform destroy
# ---------------------------------------------------------------------------

echo "🔥 Running terraform destroy..."

# Terraform's aws_lambda_function resource requires a valid deployment zip
# to exist when evaluating the plan — even during destroy, it reads the
# current resource configuration. If the zip doesn't exist (common in
# GitHub Actions where the build step is skipped for destroy-only runs),
# Terraform will error before it can proceed with the destroy.
# A minimal dummy zip satisfies the file existence check without needing
# a real Lambda build.
# Create a dummy lambda zip if it doesn't exist (needed for destroy in GitHub Actions)
if [ ! -f "../backend/lambda-deployment.zip" ]; then
    echo "Creating dummy lambda package for destroy operation..."
    echo "dummy" | zip ../backend/lambda-deployment.zip -
fi

# Destroy all resources tracked in the current workspace's state file.
# -auto-approve skips the interactive confirmation prompt, enabling the
# script to run non-interactively in CI/CD pipelines.
#
# prod environments use a dedicated prod.tfvars file which may contain
# production-specific variable overrides. All other environments use
# only inline -var flags.
# Run terraform destroy with auto-approve
if [ "$ENVIRONMENT" = "prod" ] && [ -f "prod.tfvars" ]; then
    terraform destroy -var-file=prod.tfvars -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve
else
    terraform destroy -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve
fi

# ---------------------------------------------------------------------------
# Post-destroy instructions
# ---------------------------------------------------------------------------
echo "✅ Infrastructure for ${ENVIRONMENT} has been destroyed!"
echo ""

# Note: terraform destroy removes all resources tracked in the workspace
# state file but leaves the workspace itself intact in the S3 backend.
# Run the commands below if you also want to permanently delete the
# workspace — for example, when retiring an environment entirely rather
# than just tearing it down temporarily before redeploying.
echo "💡 To remove the workspace completely, run:"
echo "   terraform workspace select default"
echo "   terraform workspace delete $ENVIRONMENT"