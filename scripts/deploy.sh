#!/bin/bash
# Exit immediately if any command fails, so a broken step doesn't cascade into further deployment steps
set -e 

# Positional arguments with defaults:
#   $1 = environment to deploy to (dev, test, or prod) - defaults to "dev" if not provided
#   $2 = project name, used for naming/tagging resources - defaults to "twin" if not provided
ENVIRONMENT=${1:-dev}          # dev | test | prod
PROJECT_NAME=${2:-twin}

echo "🚀 Deploying ${PROJECT_NAME} to ${ENVIRONMENT}..."

# 1. Build Lambda package
# Move to the project root (one level up from this script's own directory),
# regardless of where the script was invoked from
cd "$(dirname "$0")/.."        # project root
echo "📦 Building Lambda package..."
# Run the backend's own build script (in a subshell so we don't change
# the current shell's working directory) to produce the Lambda deployment zip
(cd backend && uv run deploy.py)

# 2. Terraform workspace & apply
cd terraform

# Initialize Terraform (download providers/modules) without prompting for input,
# so this script can run non-interactively (e.g. in CI)
# The following is the initial command before using GitHub Actions. It is used to initialize the Terraform configuration.
# terraform init -input=false

# The following is the revised command for using GitHub Actions. We have created an AWS S3 bucket and DynamoDB to record state and locks. It is used to initialize the Terraform configuration.
# Initialise Terraform with the remote S3 backend for the target environment.
#
# Backend configuration is passed at runtime via -backend-config flags rather
# than hardcoded in a .tf file, so the same configuration can be reused across
# environments and AWS accounts without modification.

# Retrieve the AWS account ID of the currently authenticated IAM identity.
# Used to construct the state bucket name, which embeds the account ID for
# global uniqueness (matches the name set in backend-setup.tf).
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
# Use the DEFAULT_AWS_REGION environment variable if set, otherwise fall back
# to us-east-1. Must match the region where the S3 bucket and DynamoDB table
# were created by backend-setup.tf.
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}
# -input=false prevents Terraform from prompting for missing variables
#  interactively — required for non-interactive CI/CD runs.
# Each -backend-config flag supplies one backend setting at init time,
# keeping environment-specific values out of committed .tf files.
# Line 2 below is the S3 bucket that stores all Terraform state files (created in backend-setup.tf).
# Account ID is embedded in the name to guarantee global uniqueness.
# Line 3 below is the state file path within the bucket. Using the environment name as a prefix
# isolates each workspace's state: dev/terraform.tfstate, prod/terraform.tfstate, etc.
# Line 4 below is the AWS region where the S3 bucket and DynamoDB lock table reside.
# Line 5 below is the DynamoDB table used for state locking — prevents concurrent terraform runs
# from corrupting the shared state file (created in backend-setup.tf).
# Line 6 below is the Enforce server-side AES-256 encryption on the state file at rest,
# matching the encryption configuration set on the S3 bucket in backend-setup.tf.
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

# Terraform workspaces isolate state per environment (dev/test/prod).
# Create the workspace if it doesn't exist yet, otherwise just switch to it.
if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
  terraform workspace new "$ENVIRONMENT"
else
  terraform workspace select "$ENVIRONMENT"
fi

# Use prod.tfvars for production environment
# Production gets its own tfvars file (e.g. for stricter resource sizing,
# scaling, or security settings); other environments use only the inline vars below
if [ "$ENVIRONMENT" = "prod" ]; then
  TF_APPLY_CMD=(terraform apply -var-file=prod.tfvars -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve)
else
  TF_APPLY_CMD=(terraform apply -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve)
fi

echo "🎯 Applying Terraform..."
# Run the apply command built above as an array, so arguments with spaces/special
# characters are passed through correctly rather than being re-split by the shell
"${TF_APPLY_CMD[@]}"

# Pull key infrastructure outputs from Terraform's state so we can wire the
# frontend build to the freshly created/updated backend resources
API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)
# Custom domain output may not exist for every environment (e.g. dev might not
# have one configured) - suppress the error and default to empty instead of failing
CUSTOM_URL=$(terraform output -raw custom_domain_url 2>/dev/null || true)

# 3. Build + deploy frontend
cd ../frontend

# Create production environment file with API URL
# Next.js reads NEXT_PUBLIC_* vars at build time and bakes them into the static
# output, so this must be written before running `npm run build` below
echo "📝 Setting API URL for production..."
echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.production

npm install
npm run build
# Sync the static export output to the frontend's S3 bucket, deleting any files
# in the bucket that no longer exist locally (keeps the bucket in sync exactly)
aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete
cd ..

# 4. Final messages
# Print a summary of where everything ended up, so the person running this
# script doesn't need to dig through Terraform output manually afterward
echo -e "\n✅ Deployment complete!"
echo "🌐 CloudFront URL : $(terraform -chdir=terraform output -raw cloudfront_url)"
if [ -n "$CUSTOM_URL" ]; then
  echo "🔗 Custom domain  : $CUSTOM_URL"
fi
echo "📡 API Gateway    : $API_URL"