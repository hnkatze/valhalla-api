variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix for resources and the S3 bucket."
  type        = string
  default     = "valhalla-api"
}

variable "instance_type" {
  description = "Graviton instance type for the runtime host."
  type        = string
  default     = "t4g.medium"
}

variable "allowed_cidrs" {
  description = "CIDR blocks allowed to reach the API on ports 80 and 443."
  type        = list(string)
}

variable "repo_url" {
  description = "Git URL of this repository, cloned by cloud-init on the runtime host."
  type        = string
}

variable "git_ref" {
  description = "Branch or tag of the repository to deploy."
  type        = string
  default     = "main"
}

variable "valhalla_api_key" {
  description = "Shared secret clients send in X-API-Key. Provide via TF_VAR_valhalla_api_key."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.valhalla_api_key) >= 16
    error_message = "valhalla_api_key must be at least 16 characters."
  }
}

variable "tiles_s3_prefix" {
  description = "Key prefix inside the tiles bucket where the tile set is published."
  type        = string
  default     = "valhalla/honduras"
}

variable "root_volume_size_gb" {
  description = "Root volume size; tiles for Honduras are small, the margin is for Docker images and logs."
  type        = number
  default     = 30
}
