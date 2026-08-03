# =============================================================================
# outputs.tf
# Exposes key resource attributes after `terraform apply` so they can be
# referenced by other Terraform modules, piped into scripts, or checked
# quickly with `terraform output` without opening the AWS console.
# =============================================================================

# The invoke URL for the HTTP API Gateway — this is what the frontend or
# external clients call to reach the Lambda backend. Ends in
# /execute-api.<region>.amazonaws.com with no stage suffix (HTTP APIs v2).
output "api_gateway_url" {
  description = "URL of the API Gateway"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

# The public HTTPS URL served by CloudFront. All frontend traffic should use
# this URL rather than hitting the S3 bucket directly, since CloudFront
# handles caching, HTTPS termination, and geo-distribution.
output "cloudfront_url" {
  description = "URL of the CloudFront distribution"
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "s3_frontend_bucket" {
  description = "Name of the S3 bucket for frontend"
  value       = aws_s3_bucket.frontend.id
}

# The S3 bucket name that holds the compiled frontend assets (HTML, JS, CSS).
# Use this when running deployment scripts that sync build output to S3, e.g.:
# aws s3 sync ./dist s3://$(terraform output -raw s3_frontend_bucket)
output "s3_memory_bucket" {
  description = "Name of the S3 bucket for memory storage"
  value       = aws_s3_bucket.memory.id
}

# The deployed Lambda function name. Useful for manual invocations,
# log lookups in CloudWatch, or triggering the function from CI/CD:
# aws lambda invoke --function-name $(terraform output -raw lambda_function_name) out.json
output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.api.function_name
}

# The root URL of the production site. Returns the custom domain URL
# (e.g. https://example.com) when var.use_custom_domain is true, otherwise
# returns an empty string — in which case use cloudfront_url above instead.
# Conditional on whether a custom domain and ACM certificate have been
# configured in variables.tf.
output "custom_domain_url" {
  description = "Root URL of the production site"
  value       = var.use_custom_domain ? "https://${var.root_domain}" : ""
}