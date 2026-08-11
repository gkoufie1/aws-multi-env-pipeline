locals {
  tags = merge(var.common_tags, {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = "aws-multi-env-pipeline"
  })
}

# ─── VPC ───
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = "${var.environment}-baseline-vpc"
  })
}

# ─── Flow logs — every VPC gets one, not optional ───
# No customer-managed KMS key (see .checkov.yaml CKV_AWS_158) — default
# AWS-managed encryption at rest is sufficient for flow log metadata, and a
# KMS key adds real per-month cost for no added protection at this scope.
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc-flow-logs/${var.environment}-baseline-vpc"
  retention_in_days = 365

  tags = local.tags
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.environment}-baseline-vpc-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.environment}-baseline-vpc-flow-logs"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn

  tags = merge(local.tags, {
    Name = "${var.environment}-baseline-flow-log"
  })
}

# ─── Lock down the VPC's auto-created default SG — it should never be used ───
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  # No ingress, no egress — deliberately empty. Anything that needs network
  # access gets its own purpose-built SG (like aws_security_group.baseline
  # below), never the VPC default.

  tags = merge(local.tags, {
    Name = "${var.environment}-default-sg-DO-NOT-USE"
  })
}

# ─── Internet Gateway (public subnets only — no NAT, keeps this at ~$0) ───
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${var.environment}-baseline-igw"
  })
}

# ─── Public subnets ───
# Auto-assigning a public IP is the entire point of a public subnet, not an
# oversight — see .checkov.yaml CKV_AWS_130.
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${var.environment}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  })
}

# ─── Private subnets (no NAT attached — nothing in them needs outbound internet for this baseline) ───
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.tags, {
    Name = "${var.environment}-private-${var.availability_zones[count.index]}"
    Tier = "private"
  })
}

# ─── Public route table ───
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, {
    Name = "${var.environment}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ─── Private route table (local traffic only — no NAT) ───
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${var.environment}-private-rt"
  })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ─── Baseline security group — no ingress, HTTPS egress only ───
# Not attached to anything yet by design — baseline network, no compute
# deployed into it. App workloads attach this (or their own SG) when they
# land here. See .checkov.yaml CKV2_AWS_5.
resource "aws_security_group" "baseline" {
  name        = "${var.environment}-baseline-sg"
  description = "Baseline SG: no inbound, HTTPS egress only. Every app-specific SG should be its own resource, not a hole punched in this one."
  vpc_id      = aws_vpc.this.id

  egress {
    description = "HTTPS out"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${var.environment}-baseline-sg"
  })
}

# ─── Tagged, private-by-default S3 bucket (stand-in for env-specific artifacts/logs) ───
# Four things intentionally not enabled here, all suppressed in .checkov.yaml:
# access logging (would need a second bucket, not worth it while empty),
# cross-region replication (real ongoing cost, nothing worth replicating yet),
# SSE-KMS (SSE-S3/AES256 below is free and sufficient at this scope),
# event notifications (no Lambda/SQS/SNS consumer exists to notify).
resource "aws_s3_bucket" "baseline" {
  bucket = "${var.environment}-multi-env-pipeline-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.tags, {
    Name = "${var.environment}-baseline-bucket"
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "baseline" {
  bucket = aws_s3_bucket.baseline.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {} # applies to every object in the bucket

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "baseline" {
  bucket = aws_s3_bucket.baseline.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "baseline" {
  bucket = aws_s3_bucket.baseline.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "baseline" {
  bucket = aws_s3_bucket.baseline.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_caller_identity" "current" {}
