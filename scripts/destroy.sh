#!/bin/bash

# destroy.sh
# Tears down all AWS infrastructure for a given environment by:
#   1. Validating the target environment exists as a Terraform workspace
#   2. Emptying S3 buckets (required before Terraform can delete them —
#      AWS will refuse to destroy a non-empty bucket)
#   3. Running `terraform destroy` against the selected workspace
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

# $# is the number of arguments passed to the script.
# Require at least one argument (the environment name).
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
# Used to construct resource names (S3 buckets, etc.) that were created
# with this prefix during deployment.
PROJECT_NAME=${2:-twin}

echo "🗑️ Preparing to destroy ${PROJECT_NAME}-${ENVIRONMENT} infrastructure..."

# ---------------------------------------------------------------------------
# Terraform workspace setup
# ---------------------------------------------------------------------------

# Change to the terraform directory relative to this script's location,
# regardless of where the script is called from. Ensures all terraform
# commands target the correct configuration directory.
# Navigate to terraform directory
cd "$(dirname "$0")/../terraform"

# Verify the target workspace exists before attempting to select it.
# Selecting a non-existent workspace would create a new empty one,
# which would then find no infrastructure to destroy — a silent no-op
# when we actually want an early failure with a clear error message.
# Check if workspace exists
if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
    echo "❌ Error: Workspace '$ENVIRONMENT' does not exist"
    echo "Available workspaces:"
    terraform workspace list
    exit 1
fi

# Switch to the target workspace so all subsequent terraform commands
# operate on the correct environment's state file.
# Select the workspace
terraform workspace select "$ENVIRONMENT"

# ---------------------------------------------------------------------------
# Empty S3 buckets
# ---------------------------------------------------------------------------

echo "📦 Emptying S3 buckets..."

# Retrieve the AWS account ID for the currently authenticated IAM identity.
# The account ID is embedded in bucket names (set during deployment) to
# guarantee global uniqueness across AWS accounts.
# Get AWS Account ID for bucket names
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Reconstruct the bucket names using the same naming convention used
# during deployment: <project>-<environment>-<purpose>-<account_id>
# Get bucket names with account ID
FRONTEND_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-frontend-${AWS_ACCOUNT_ID}"
MEMORY_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-memory-${AWS_ACCOUNT_ID}"

# S3 buckets must be empty before Terraform can delete them.
# `aws s3 ls` is used as an existence check — it returns non-zero if the
# bucket doesn't exist. stderr is suppressed (2>/dev/null) to avoid
# noisy "NoSuchBucket" errors when the bucket was never created or was
# already deleted by a previous partial destroy.

# Empty the frontend bucket (holds compiled JS/CSS/HTML assets)
# Empty frontend bucket if it exists
if aws s3 ls "s3://$FRONTEND_BUCKET" 2>/dev/null; then
    echo "  Emptying $FRONTEND_BUCKET..."
    aws s3 rm "s3://$FRONTEND_BUCKET" --recursive
else
    echo "  Frontend bucket not found or already empty"
fi

# Empty the memory bucket (holds persistent agent memory/storage files)
# Empty memory bucket if it exists
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


# Destroy all resources tracked in the current workspace's state file.
# -auto-approve skips the interactive confirmation prompt, enabling the
# script to run non-interactively in CI/CD pipelines.
#
# prod environments use a dedicated prod.tfvars file which may contain
# production-specific overrides (larger instance sizes, longer retention
# periods, etc.). All other environments use only inline -var flags.
# Run terraform destroy with auto-approve
if [ "$ENVIRONMENT" = "prod" ] && [ -f "prod.tfvars" ]; then
    # Production: load prod-specific variable overrides from file
    terraform destroy -var-file=prod.tfvars -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve
else
    terraform destroy -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve
fi


# ---------------------------------------------------------------------------
# Post-destroy instructions
# ---------------------------------------------------------------------------

echo "✅ Infrastructure for ${ENVIRONMENT} has been destroyed!"

# Note: terraform destroy removes all resources but leaves the workspace
# itself intact. Run the commands below if you also want to delete the
# workspace — for example, when permanently retiring an environment rather
# than just tearing it down temporarily.
echo ""
echo "💡 To remove the workspace completely, run:"
echo "   terraform workspace select default"
echo "   terraform workspace delete $ENVIRONMENT"