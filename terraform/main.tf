# =============================================================================
# main.tf — Core AWS Infrastructure for AI Digital Twin
# =============================================================================
# Provisions all AWS resources required to run the AI Digital Twin application:
#   - S3 buckets (conversation memory + static frontend)
#   - IAM role and policies for Lambda execution
#   - Lambda function (FastAPI backend via Mangum)
#   - API Gateway HTTP API with routes
#   - CloudFront distribution for HTTPS frontend delivery
#   - Optional: Custom domain via Route 53 and ACM certificate
# =============================================================================

# Data source to get current AWS account ID
# Used to ensure S3 bucket names are globally unique by appending the account ID as a suffix.
data "aws_caller_identity" "current" {}

locals {
  # CloudFront domain aliases — only populated when a custom domain is configured.
  # When use_custom_domain is false, CloudFront uses its default *.cloudfront.net domain.
  aliases = var.use_custom_domain && var.root_domain != "" ? [
    var.root_domain,
    "www.${var.root_domain}"
  ] : []

  # Consistent prefix used across all resource names to avoid collisions
  # when multiple environments (dev/test/prod) are deployed to the same account.
  name_prefix = "${var.project_name}-${var.environment}"

  # Standard tags applied to all resources for cost allocation,
  # environment identification, and Terraform state tracking.
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# S3 — Conversation Memory Storage
# =============================================================================
# Stores JSON conversation history files, one per session ID.
# The Lambda function reads and writes to this bucket to maintain
# conversation context across requests.

resource "aws_s3_bucket" "memory" {
  bucket = "${local.name_prefix}-memory-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

# Block all public access — this bucket contains conversation data and
# must never be publicly accessible.
resource "aws_s3_bucket_public_access_block" "memory" {
  bucket = aws_s3_bucket.memory.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enforce bucket owner as the sole owner of all objects.
# Disables ACL-based access control in favour of bucket policies only.
resource "aws_s3_bucket_ownership_controls" "memory" {
  bucket = aws_s3_bucket.memory.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# =============================================================================
# S3 — Frontend Static Website
# =============================================================================
# Hosts the Next.js static export (HTML, CSS, JS) served via CloudFront.
# Public read access is required so CloudFront can fetch and cache the files.

resource "aws_s3_bucket" "frontend" {
  bucket = "${local.name_prefix}-frontend-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

# Allow public access — required for S3 static website hosting.
# CloudFront fetches files from this bucket using the public website endpoint.
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Enable S3 static website hosting on the frontend bucket.
# index.html is served for the root path; 404.html for missing routes.
resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "404.html"
  }
}

# Bucket policy granting public read access to all objects.
# This allows CloudFront (and anyone with the S3 URL) to read frontend files.
# depends_on ensures the public access block is configured before applying the policy.
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

# =============================================================================
# IAM — Lambda Execution Role
# =============================================================================
# Grants the Lambda function permission to assume this role at runtime,
# enabling it to call AWS services (CloudWatch, Bedrock, S3).

resource "aws_iam_role" "lambda_role" {
  name = "${local.name_prefix}-lambda-role"
  tags = local.common_tags

  # Trust policy — allows the Lambda service to assume this role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      },
    ]
  })
}

# Grants Lambda permission to write logs to CloudWatch.
# Required for all Lambda functions to enable monitoring and debugging.
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_role.name
}

# Grants Lambda full access to AWS Bedrock — required to call the
# converse API and invoke foundation models for AI responses.
resource "aws_iam_role_policy_attachment" "lambda_bedrock" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
  role       = aws_iam_role.lambda_role.name
}

# Grants Lambda full access to S3 — required to read and write
# conversation history JSON files in the memory bucket.
resource "aws_iam_role_policy_attachment" "lambda_s3" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  role       = aws_iam_role.lambda_role.name
}

# =============================================================================
# Lambda — API Backend
# =============================================================================
# Runs the FastAPI application (server.py) as a serverless function.
# Triggered by API Gateway HTTP API requests via AWS_PROXY integration.

resource "aws_lambda_function" "api" {
  # Deployment package — ZIP file containing the FastAPI app and dependencies.
  # Created by deploy.py in the backend directory.
  filename         = "${path.module}/../backend/lambda-deployment.zip"
  function_name    = "${local.name_prefix}-api"
  role             = aws_iam_role.lambda_role.arn

  # Entry point — Lambda calls lambda_handler.handler() for each request.
  handler          = "lambda_handler.handler"

  # Hash of the ZIP file — triggers Lambda redeployment when the code changes.
  source_code_hash = filebase64sha256("${path.module}/../backend/lambda-deployment.zip")

  runtime          = "python3.12"
  architectures    = ["x86_64"]
  timeout          = var.lambda_timeout
  tags             = local.common_tags

  environment {
    variables = {
      # CORS_ORIGINS — the allowed frontend origin for cross-origin requests.
      # Uses the custom domain if configured, otherwise the CloudFront default domain.
      CORS_ORIGINS     = var.use_custom_domain ? "https://${var.root_domain},https://www.${var.root_domain}" : "https://${aws_cloudfront_distribution.main.domain_name}"

      # S3 bucket for conversation memory storage.
      S3_BUCKET        = aws_s3_bucket.memory.id

      # Enable S3 storage mode in server.py (overrides local file storage).
      USE_S3           = "true"

      # Bedrock model to use for AI responses — configurable per environment.
      BEDROCK_MODEL_ID = var.bedrock_model_id
    }
  }

  # Lambda must wait for CloudFront to be created first so that the
  # CloudFront domain name is available for the CORS_ORIGINS variable.
  depends_on = [aws_cloudfront_distribution.main]
}

# =============================================================================
# API Gateway — HTTP API
# =============================================================================
# Provides the public HTTPS endpoint that the frontend calls.
# Routes requests to the Lambda function via AWS_PROXY integration,
# passing the full request event for the FastAPI/Mangum handler to process.

resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name_prefix}-api-gateway"
  protocol_type = "HTTP"
  tags          = local.common_tags

  # CORS configuration at the API Gateway level.
  # allow_origins = "*" permits requests from any origin at the gateway layer.
  # The FastAPI CORSMiddleware provides additional origin filtering in server.py.
  cors_configuration {
    allow_credentials = false
    allow_headers     = ["*"]
    allow_methods     = ["GET", "POST", "OPTIONS"]
    allow_origins     = ["*"]
    max_age           = 300
  }
}

# Default stage — auto-deploys on any configuration change.
# Throttling limits prevent abuse and control AWS costs.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
  tags        = local.common_tags

  default_route_settings {
    # Maximum concurrent requests allowed in a burst above the rate limit.
    throttling_burst_limit = var.api_throttle_burst_limit
    # Steady-state requests per second allowed through the API.
    throttling_rate_limit  = var.api_throttle_rate_limit
  }
}

# Lambda integration — forwards all matched API Gateway requests
# to the Lambda function as a proxied AWS_PROXY event.
resource "aws_apigatewayv2_integration" "lambda" {
  api_id           = aws_apigatewayv2_api.main.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.api.invoke_arn
}

# =============================================================================
# API Gateway Routes
# =============================================================================

# GET / — returns API info and current configuration summary.
resource "aws_apigatewayv2_route" "get_root" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# POST /chat — main conversational AI endpoint.
# Accepts a message and session_id, returns the AI response.
resource "aws_apigatewayv2_route" "post_chat" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /chat"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# GET /health — lightweight health check for monitoring and load balancers.
resource "aws_apigatewayv2_route" "get_health" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# Grant API Gateway permission to invoke the Lambda function.
# source_arn restricts invocation to this specific API Gateway only.
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# =============================================================================
# CloudFront — Frontend CDN Distribution
# =============================================================================
# Serves the static Next.js frontend over HTTPS with global edge caching.
# Origin is the S3 static website endpoint (HTTP) — CloudFront terminates TLS.
# Redirects all HTTP requests to HTTPS automatically.

resource "aws_cloudfront_distribution" "main" {
  # Custom domain aliases — empty when using the default CloudFront domain.
  aliases = local.aliases
  
  # TLS certificate configuration.
  # Uses ACM certificate for custom domains, default CloudFront cert otherwise.
  viewer_certificate {
    acm_certificate_arn            = var.use_custom_domain ? aws_acm_certificate.site[0].arn : null
    cloudfront_default_certificate = var.use_custom_domain ? false : true
    ssl_support_method             = var.use_custom_domain ? "sni-only" : null
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  # Origin — the S3 static website endpoint.
  # Uses http-only origin protocol because S3 website endpoints don't support HTTPS.
  # CloudFront handles HTTPS termination on the viewer side.
  origin {
    domain_name = aws_s3_bucket_website_configuration.frontend.website_endpoint
    origin_id   = "S3-${aws_s3_bucket.frontend.id}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  tags                = local.common_tags

  # Default cache behaviour — applies to all paths not matched by a specific behaviour.
  # Caches GET/HEAD responses from S3 for up to 24 hours (86400 seconds).
  # Redirects HTTP viewers to HTTPS.
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.frontend.id}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  # No geographic restrictions — content is accessible worldwide.
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

# =============================================================================
# Optional: Custom Domain Configuration
# =============================================================================
# All resources below are conditional on var.use_custom_domain = true.
# They provision an ACM certificate (in us-east-1 as required by CloudFront),
# validate it via Route 53 DNS records, and create A/AAAA alias records
# pointing the custom domain to the CloudFront distribution.

# Look up the existing Route 53 hosted zone for the root domain.
# The zone must already exist in Route 53 before applying this configuration.
data "aws_route53_zone" "root" {
  count        = var.use_custom_domain ? 1 : 0
  name         = var.root_domain
  private_zone = false
}

# ACM certificate for the custom domain and www subdomain.
# Must be created in us-east-1 — CloudFront only accepts certificates
# from the US East (N. Virginia) region.
resource "aws_acm_certificate" "site" {
  count                     = var.use_custom_domain ? 1 : 0
  provider                  = aws.us_east_1
  domain_name               = var.root_domain
  subject_alternative_names = ["www.${var.root_domain}"]
  validation_method         = "DNS"

  # Allows a new certificate to be created before the old one is destroyed
  # during certificate renewal, preventing downtime.
  lifecycle { create_before_destroy = true }
  tags = local.common_tags
}

# Route 53 DNS records used by ACM to validate domain ownership.
# One record is created per domain name covered by the certificate
# (root domain + www subdomain).
resource "aws_route53_record" "site_validation" {
  for_each = var.use_custom_domain ? {
    for dvo in aws_acm_certificate.site[0].domain_validation_options :
    dvo.domain_name => dvo
  } : {}

  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 300
  records = [each.value.resource_record_value]
}

# Wait for ACM to complete DNS validation before allowing dependent resources
# (e.g. CloudFront) to use the certificate.
resource "aws_acm_certificate_validation" "site" {
  count           = var.use_custom_domain ? 1 : 0
  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [
    for r in aws_route53_record.site_validation : r.fqdn
  ]
}

# Route 53 A record (IPv4) — aliases the root domain to the CloudFront distribution.
resource "aws_route53_record" "alias_root" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = var.root_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

# Route 53 AAAA record (IPv6) — aliases the root domain to CloudFront for IPv6 clients.
resource "aws_route53_record" "alias_root_ipv6" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = var.root_domain
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

# Route 53 A record (IPv4) — aliases www subdomain to the CloudFront distribution.
resource "aws_route53_record" "alias_www" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = "www.${var.root_domain}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

# Route 53 AAAA record (IPv6) — aliases www subdomain to CloudFront for IPv6 clients.
resource "aws_route53_record" "alias_www_ipv6" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = "www.${var.root_domain}"
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}