# Servicios globales: Route 53, WAF y CloudFront (sitio en S3 y /api/*)
provider "aws" {
  alias  = "respaldo"
  region = var.region_respaldo

  default_tags {
    tags = {
      Proyecto = "ShopPeru"
      Entorno  = var.entorno
      Curso    = "Infraestructura como Codigo"
    }
  }
}

resource "aws_s3_bucket" "sitio" {
  bucket = "${local.nombre}-sitio"
}

resource "aws_s3_bucket_public_access_block" "sitio" {
  bucket                  = aws_s3_bucket.sitio.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "sitio" {
  bucket = aws_s3_bucket.sitio.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.datos.arn
    }
  }
}

resource "aws_cloudfront_origin_access_control" "sitio" {
  name                              = "${local.nombre}-sitio"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "sitio" {
  bucket = aws_s3_bucket.sitio.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.sitio.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.tienda.arn } }
    }]
  })
}

# WAF asociado a CloudFront: 100 solicitudes por minuto por IP (RNF 17)
resource "aws_wafv2_web_acl" "tienda" {
  provider = aws.respaldo
  name     = "${local.nombre}-waf"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "reglas-comunes"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "reglas-comunes"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "limite-por-ip"
    priority = 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = 100
        evaluation_window_sec = 60
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "limite-por-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.nombre}-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudfront_distribution" "tienda" {
  enabled             = true
  default_root_object = "index.html"
  web_acl_id          = aws_wafv2_web_acl.tienda.arn
  aliases             = [var.dominio]

  origin {
    origin_id                = "sitio"
    domain_name              = aws_s3_bucket.sitio.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.sitio.id
  }

  origin {
    origin_id   = "api"
    domain_name = replace(aws_apigatewayv2_api.api.api_endpoint, "https://", "")

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # API de consulta en espera en us-east-1
  origin {
    origin_id   = "api-respaldo"
    domain_name = replace(aws_apigatewayv2_api.respaldo.api_endpoint, "https://", "")

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Failover de consultas: si la API principal falla, va a la de respaldo
  origin_group {
    origin_id = "api-con-failover"

    failover_criteria {
      status_codes = [500, 502, 503, 504]
    }

    member {
      origin_id = "api"
    }

    member {
      origin_id = "api-respaldo"
    }
  }

  default_cache_behavior {
    target_origin_id       = "sitio"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "api-con-failover"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.tienda.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "aws_acm_certificate" "tienda" {
  provider          = aws.respaldo
  domain_name       = var.dominio
  validation_method = "DNS"
}

resource "aws_route53_zone" "tienda" {
  name = var.dominio
}

resource "aws_route53_record" "tienda" {
  zone_id = aws_route53_zone.tienda.zone_id
  name    = var.dominio
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.tienda.domain_name
    zone_id                = aws_cloudfront_distribution.tienda.hosted_zone_id
    evaluate_target_health = false
  }
}
