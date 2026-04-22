terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # バックエンド設定 (初期変換時はローカル、本番環境では以下を有効化)
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "aws-to-terraform/terraform.tfstate"
  #   region         = "ap-northeast-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-state-lock"
  # }
}
