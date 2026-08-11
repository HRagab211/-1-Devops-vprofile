terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.92"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }

  required_version = ">= 1.2"
}

provider "aws" {
  region = var.region
}

