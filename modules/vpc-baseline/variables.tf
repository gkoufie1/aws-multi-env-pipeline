variable "environment" {
  description = "Environment name (dev, staging, prod) — stamped onto every resource's tags"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets, one per AZ"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets, one per AZ"
  type        = list(string)
}

variable "availability_zones" {
  description = "Availability zones to spread subnets across"
  type        = list(string)
}

variable "common_tags" {
  description = "Tags applied to every resource, merged with environment-specific tags"
  type        = map(string)
  default     = {}
}
