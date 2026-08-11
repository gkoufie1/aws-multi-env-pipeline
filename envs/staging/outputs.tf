output "vpc_id" {
  value = module.baseline.vpc_id
}

output "vpc_cidr_block" {
  value = module.baseline.vpc_cidr_block
}

output "public_subnet_ids" {
  value = module.baseline.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.baseline.private_subnet_ids
}

output "security_group_id" {
  value = module.baseline.security_group_id
}

output "s3_bucket_name" {
  value = module.baseline.s3_bucket_name
}

output "environment" {
  value = module.baseline.environment
}
