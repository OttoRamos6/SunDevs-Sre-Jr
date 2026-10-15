terraform {
  backend "s3" {
    bucket       = "sundevs-tf-state-584763186660-c9fd02ae"
    key          = "sundevs/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
