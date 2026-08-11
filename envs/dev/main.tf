module "baseline" {
  source = "../../modules/vpc-baseline"

  environment          = "dev"
  vpc_cidr             = "10.10.0.0/16"
  public_subnet_cidrs  = ["10.10.0.0/24", "10.10.1.0/24"]
  private_subnet_cidrs = ["10.10.10.0/24", "10.10.11.0/24"]
  availability_zones   = ["us-east-1a", "us-east-1b"]
}
