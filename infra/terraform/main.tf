data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# --- Tiles bucket ---------------------------------------------------------------------------

resource "aws_s3_bucket" "tiles" {
  bucket = "${var.project}-tiles-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "tiles" {
  bucket = aws_s3_bucket.tiles.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tiles" {
  bucket = aws_s3_bucket.tiles.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tiles" {
  bucket = aws_s3_bucket.tiles.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- IAM: SSM access plus read-only access to the tiles bucket ----------------------------

data "aws_iam_policy_document" "instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runtime" {
  name               = "${var.project}-runtime"
  assume_role_policy = data.aws_iam_policy_document.instance_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.runtime.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "tiles_read" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tiles.arn]
  }

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.tiles.arn}/${var.tiles_s3_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "tiles_read" {
  name   = "${var.project}-tiles-read"
  role   = aws_iam_role.runtime.id
  policy = data.aws_iam_policy_document.tiles_read.json
}

resource "aws_iam_instance_profile" "runtime" {
  name = "${var.project}-runtime"
  role = aws_iam_role.runtime.name
}

# --- Network --------------------------------------------------------------------------------

resource "aws_security_group" "runtime" {
  name        = "${var.project}-runtime"
  description = "Valhalla API host: HTTP/HTTPS from allowed CIDRs, no SSH (SSM only)."
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.runtime.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.runtime.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.runtime.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Runtime instance -----------------------------------------------------------------------

resource "aws_instance" "runtime" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.runtime.id]
  iam_instance_profile   = aws_iam_instance_profile.runtime.name

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    repo_url         = var.repo_url
    git_ref          = var.git_ref
    valhalla_api_key = var.valhalla_api_key
    tiles_s3_uri     = "s3://${aws_s3_bucket.tiles.bucket}/${var.tiles_s3_prefix}"
    aws_region       = var.aws_region
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = {
    Name = "${var.project}-runtime"
  }
}
