########################
# Create S3 bucket
########################

locals {
  bucket_name = "${var.email_domain}-emails"
}

# Create policy which allows SES to put objects in bucket
data "aws_iam_policy_document" "bucket-policy-document" {
  statement {
    sid     = "AllowSESPuts"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.bucket_name}/*"]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:Referer"
      values = ["${var.account_id}"]
    }
  }
}

# Create bucket to store emails
resource "aws_s3_bucket" "email-bucket" {
  bucket = "${local.bucket_name}"
  policy = "${data.aws_iam_policy_document.bucket-policy-document.json}"

  lifecycle_rule {
    id      = "email-rule"
    enabled = true

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days = 60
      storage_class = "ONEZONE_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}


########################
# Create forwarding lambda
########################

# Lambda role for forwarding emails
resource "aws_iam_role" "fwd-lambda-role" {
  name        = "${var.email_domain}-${var.rule_name}-lambda_role"
  description = "Lambda execution role for forwarding emails from @${var.email_domain} for SES rule ${var.rule_name}"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

# Create policy which allows SES to put objects in bucket
data "aws_iam_policy_document" "fwd-lambda-policy-document" {
  statement {
    sid     = "AllowLambdaLogPuts"
    effect  = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }

  statement {
    sid     = "AllowLambdaSendEmails"
    effect  = "Allow"
    actions = ["ses:SendRawEmail"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }

  statement {
    sid     = "AllowLambdaGetPutS3Objects"
    effect  = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject"
    ]
    resources = ["arn:aws:s3:::${local.bucket_name}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

resource "aws_iam_policy" "fwd-lambda-policy" {
  name        = "${var.email_domain}-${var.rule_name}-lambda_policy"
  description = "Lambda policy for forwarding emails from @${var.email_domain} for SES rule ${var.rule_name}"
  policy      = "${data.aws_iam_policy_document.fwd-lambda-policy-document.json}"
}

resource "aws_iam_role_policy_attachment" "fwd-lambda-role-policy" {
  role       = "${aws_iam_role.fwd-lambda-role.name}"
  policy_arn = "${aws_iam_policy.fwd-lambda-policy.arn}"
}

data "archive_file" "lambda-source" {
  type        = "zip"
  source_file = "${path.module}/lambda.js"
  output_path = "${path.module}/lambda.js.zip"
}

resource "aws_lambda_function" "fwd-lambda" {
  filename         = "${path.module}/lambda.js.zip"
  function_name    = "${var.email_domain}-${var.rule_name}-forwarder"
  description      = "Forwards emails to ${local.bucket_name} for the SES rule ${var.rule_name}"
  role             = "${aws_iam_role.fwd-lambda-role.arn}"
  handler          = "lambda.handler"
  source_code_hash = "${data.archive_file.lambda-source.output_base64sha256}"
  runtime          = "nodejs6.10"

  environment {
    variables = {
      fromEmail       = "${var.lambda_from_email}"
      subjectPrefix   = "${var.lambda_subject_prefix}"
      emailBucket     = "${local.bucket_name}"
      emailKeyPrefix  = "forwarded/"
      forwardMapping  = "${var.lambda_forward_mapping}"
    }
  }
}

resource "aws_lambda_permission" "allow_ses" {
  statement_id   = "AllowExecutionFromSES"
  action         = "lambda:InvokeFunction"
  function_name  = "${aws_lambda_function.fwd-lambda.function_name}"
  principal      = "ses.amazonaws.com"
}

########################
# Create rule set
########################

resource "aws_ses_receipt_rule" "store-and-forward-email" {
  name          = "${var.email_domain}-${var.rule_name}-receipt_rule"
  rule_set_name = "${var.rule_set_name}"
  enabled       = true
  scan_enabled  = true
  recipients    = "${var.rule_set_recipients}"
  after         = "${var.after}"

  s3_action {
    bucket_name = "${local.bucket_name}"
    position    = 1
  }

  lambda_action {
    function_arn      = "${aws_lambda_function.fwd-lambda.arn}"
    invocation_type   = "Event"
    position          = 2
  }
}
