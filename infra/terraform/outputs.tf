output "instance_id" {
  description = "Runtime instance id; use it with 'aws ssm start-session --target'."
  value       = aws_instance.runtime.id
}

output "public_ip" {
  description = "Public IPv4 of the runtime host."
  value       = aws_instance.runtime.public_ip
}

output "tiles_bucket" {
  description = "S3 bucket holding the published tile set."
  value       = aws_s3_bucket.tiles.bucket
}

output "tiles_s3_uri" {
  description = "Value for TILES_S3_URI in .env on the build machine."
  value       = "s3://${aws_s3_bucket.tiles.bucket}/${var.tiles_s3_prefix}"
}
