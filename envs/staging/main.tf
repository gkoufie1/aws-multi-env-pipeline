module "baseline" {
  source = "../../modules/vpc-baseline"

  environment          = "staging"
  vpc_cidr             = "10.20.0.0/16"
  public_subnet_cidrs  = ["10.20.0.0/24", "10.20.1.0/24"]
  private_subnet_cidrs = ["10.20.10.0/24", "10.20.11.0/24"]
  availability_zones   = ["us-east-1a", "us-east-1b"]
}
