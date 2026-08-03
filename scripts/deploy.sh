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
terraform init -input=false

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