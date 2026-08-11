module "baseline" {
  source = "../../modules/vpc-baseline"

  environment          = "prod"
  vpc_cidr             = "10.30.0.0/16"
  public_subnet_cidrs  = ["10.30.0.0/24", "10.30.1.0/24"]
  private_subnet_cidrs = ["10.30.10.0/24", "10.30.11.0/24"]
  availability_zones   = ["us-east-1a", "us-east-1b"]
}
