resource "aws_lambda_function" "create-transform-lambda-function" {
  count = length(var.transform-lambda-information)

  s3_bucket     = var.lambda-jar-bucket
  s3_key        = var.transform-lambda-information[count.index].jar_path
  runtime       = var.transform-lambda-information[count.index].runtime
  timeout       = var.transform-lambda-information[count.index].timeout
  memory_size   = var.transform-lambda-information[count.index].memory
  role          = aws_iam_role.assume-lambda-role.arn
  layers        = concat([aws_lambda_layer_version.xslt-layer.arn], [aws_lambda_layer_version.transform-properties-layer.arn])
  function_name = substr("${var.environment}-${var.transform-lambda-information[count.index].name}", 0, 64)
  handler       = var.transform-lambda-information[count.index].handler
  publish       = true

  vpc_config {
    subnet_ids         = [data.aws_subnet.cudl_subnet.id]
    security_group_ids = [data.aws_security_group.default.id]
  }

  file_system_config {
    arn = aws_efs_access_point.efs-access-point.arn

    # Local mount path inside the lambda function. Must start with '/mnt/', and must not end with /
    local_mount_path = var.dst-efs-prefix
  }

  depends_on = [aws_efs_mount_target.efs-mount-point]
}

resource "aws_lambda_alias" "create-transform-lambda-alias" {
  count = length(var.transform-lambda-information)

  name             = var.lambda-alias-name
  function_name    = aws_lambda_function.create-transform-lambda-function[count.index].arn
  #function_version = var.transform-lambda-information[count.index].live_version
  function_version = aws_lambda_function.create-transform-lambda-function[count.index].version

  depends_on = [aws_lambda_function.create-transform-lambda-function]
}

resource "aws_lambda_function" "create-db-lambda-function" {
  count = length(var.db-lambda-information)

  s3_bucket     = var.lambda-jar-bucket
  s3_key        = var.db-lambda-information[count.index].jar_path
  runtime       = var.db-lambda-information[count.index].runtime
  timeout       = var.db-lambda-information[count.index].timeout
  memory_size   = var.db-lambda-information[count.index].memory
  role          = aws_iam_role.assume-lambda-role.arn
  layers        = [aws_lambda_layer_version.db-properties-layer.arn]
  function_name = substr("${var.environment}-${var.db-lambda-information[count.index].name}", 0, 64)
  handler       = var.db-lambda-information[count.index].handler
  publish       = true

  vpc_config {
    subnet_ids         = [data.aws_subnet.cudl_subnet.id]
    security_group_ids = [data.aws_security_group.default.id]
  }

  file_system_config {
    arn = aws_efs_access_point.efs-access-point.arn

    # Local mount path inside the lambda function. Must start with '/mnt/', and must not end with /
    local_mount_path = var.dst-efs-prefix
  }

  depends_on = [aws_efs_mount_target.efs-mount-point]
}

resource "aws_lambda_alias" "create-db-lambda-alias" {
  count = length(var.db-lambda-information)

  name             = var.lambda-alias-name
  function_name    = aws_lambda_function.create-db-lambda-function[count.index].arn
  #function_version = var.db-lambda-information[count.index].live_version
  function_version = aws_lambda_function.create-db-lambda-function[count.index].version
}

resource "local_file" "create-local-lambda-properties-file" {

  content = <<-EOT
    # This file is generated by Terraform, and shouldn't need to be modified manually.

    # NOTE: transcriptions are written to cudl-transcriptions-staging bucket and only copied to
    # cudl-transcriptions (LIVE) bucket by bitbucket pipeline when data is published (so a commit is made
    # to cudl-data 'live' branch).

    VERSION=${upper(var.environment)}
    DST_BUCKET=${var.environment}-${var.destination-bucket-name}
    DST_PREFIX=${var.dst-prefix}
    DST_EFS_PREFIX=${var.dst-efs-prefix}
    DST_S3_PREFIX=${var.dst-s3-prefix}
    DST_ITEMS_FOLDER=json/
    DST_ITEMS_SUFFIX=.json
    TMP_DIR=${var.tmp-dir}
    LARGE_FILE_LIMIT=${var.large-file-limit}
    CHUNKS=${var.chunks}
    XSLT=/opt/xslt/msTeiPreFilter.xsl,/opt/xslt/jsonDocFormatter.xsl
    REGION=${var.deployment-aws-region}

    # Database details for editing/inserting collection data into CUDL
    DB_JDBC_DRIVER=${var.lambda-db-jdbc-driver}
    DB_URL=${var.lambda-db-url}
    DB_SECRET_KEY=${var.lambda-db-secret-key}

    TRANSCRIPTION_DST_BUCKET=${var.environment}-${var.transcriptions-bucket-name}
    TRANSCRIPTION_DST_PREFIX=${var.dst-prefix}
    TRANSCRIPTION_LARGE_FILE_LIMIT=${var.large-file-limit}
    TRANSCRIPTION_CHUNKS=${var.chunks}
    TRANSCRIPTION_FUNCTION_NAME=${var.transcription-function-name}
    TRANSCRIPTION_PAGIFY_XSLT=${var.transcription-pagify-xslt}
    TRANSCRIPTION_MSTEI_XSLT=${var.transcription-mstei-xslt}
  EOT

  filename = "${path.module}/properties_files/${var.environment}/java/lib/cudl-loader-lambda.properties"
}

data "archive_file" "zip_transform_properties_lambda_layer" {
  type        = "zip"
  output_path = "${path.module}/zipped_properties_files/${var.environment}.properties.zip"
  source_dir  = "${path.module}/properties_files/${var.environment}"

  # Without the `depends_on` argument, the zip file creation fails because the file to zip
  # doesn't exist on the local filesystem yet
  depends_on = [local_file.create-local-lambda-properties-file]
}

resource "aws_lambda_layer_version" "transform-properties-layer" {
  filename   = "${path.module}/zipped_properties_files/${var.environment}.properties.zip"
  layer_name = "${var.environment}-properties"
  source_code_hash  = data.archive_file.zip_transform_properties_lambda_layer.output_base64sha256

  compatible_runtimes = distinct([for lambda in concat(var.transform-lambda-information, var.db-lambda-information) : lambda.runtime])
  depends_on = [data.archive_file.zip_transform_properties_lambda_layer]
}

resource "aws_lambda_layer_version" "db-properties-layer" {

  filename   = "${path.module}/zipped_properties_files/${var.environment}.properties.zip"
  layer_name = "${var.environment}-properties"
  source_code_hash  = data.archive_file.zip_transform_properties_lambda_layer.output_base64sha256

  compatible_runtimes = distinct([for lambda in concat(var.transform-lambda-information, var.db-lambda-information) : lambda.runtime])
  depends_on = [data.archive_file.zip_transform_properties_lambda_layer]
}

resource "aws_lambda_layer_version" "xslt-layer" {
  s3_bucket  = var.lambda-layer-bucket
  s3_key     = var.lambda-layer-filepath
  layer_name = "${var.environment}-${var.lambda-layer-name}"

  compatible_runtimes = distinct([for lambda in concat(var.transform-lambda-information, var.db-lambda-information) : lambda.runtime])
}

# Trigger lambda from the SQS queues
resource "aws_lambda_event_source_mapping" "sqs-trigger-lambda-transforms" {
  count = length(var.transform-lambda-information)

  event_source_arn = aws_sqs_queue.transform-lambda-sqs-queue[count.index].arn
  function_name    = aws_lambda_function.create-transform-lambda-function[count.index].arn
}

resource "aws_lambda_event_source_mapping" "sqs-trigger-lambda-db" {
  count = length(var.db-lambda-information)

  event_source_arn = aws_sqs_queue.db-lambda-sqs-queue[count.index].arn
  function_name    = aws_lambda_function.create-db-lambda-function[count.index].arn
}