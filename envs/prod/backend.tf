terraform {
  backend "s3" {
    bucket         = "gkoufie-multi-env-pipeline-tfstate"
    key            = "envs/prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "gkoufie-multi-env-pipeline-tflock"
  }
}
