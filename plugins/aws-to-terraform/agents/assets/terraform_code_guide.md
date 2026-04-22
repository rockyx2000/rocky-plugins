# Terraform コード生成ガイド

生成ルールの詳細リファレンス。aws-tf-generate エージェントから参照する。

## 基本原則

1. スキャンで取得した実際の値をそのまま設定する
2. リソース間の参照は ID ハードコードでなく参照式を使う（例: `aws_vpc.main.id`）
3. computed 属性（`arn`, `id` 等）は記述しない
4. リソースが存在しないカテゴリのファイルは生成しない

## 基本ファイルのテンプレート

### versions.tf

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

### providers.tf

```hcl
provider "aws" {
  region = var.aws_region
}

# CLOUDFRONT スコープの WAF がある場合のみ追加
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
```

### variables.tf

```hcl
variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

# センシティブな値はここに追加（RDSパスワード等）
variable "db_password" {
  description = "RDSマスターパスワード"
  type        = string
  sensitive   = true
}
```

## IP アドレス管理パターン（重要）

SG インバウンドルールおよび WAF IP Set で使用する CIDR は、すべて `variables.tf` に
`map(string)` 変数として定義する。キーが説明（用途・フロア等）、値が CIDR。

### description がある場合 → グループ変数に集約

SG ルールの description を変数名のベースにし、同じ description を持つ CIDR をまとめる:

```hcl
# variables.tf
variable "example_company_cidrs" {
  description = "Example社のCIDR（SGルールdescriptionから自動グループ化）"
  type        = map(string)
  default = {
    "Example社 1F"  = "1.1.1.1/32"
    "Example社 2F"  = "1.1.1.2/32"
    "Example社 20F" = "1.1.1.20/32"
  }
}
```

SG ルールでの参照:

```hcl
resource "aws_vpc_security_group_ingress_rule" "web_https_example" {
  for_each          = var.example_company_cidrs
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = each.key
}
```

WAF IP Set での参照（同じ変数を使い回す）:

```hcl
resource "aws_wafv2_ip_set" "example_company" {
  name               = "example-company"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = values(var.example_company_cidrs)
}
```

### description がない場合 → ungrouped_cidrs にまとめてコメントで整理を促す

```hcl
# variables.tf
variable "ungrouped_cidrs" {
  description = "TODO: 用途・グループ名を確認して整理してください"
  type        = map(string)
  default = {
    "rule_1" = "2.2.2.2/32"
    "rule_2" = "3.3.3.3/32"
  }
}
```

## Security Group のパターン（重要）

SG のルールは **常に** `aws_vpc_security_group_ingress_rule` / `aws_vpc_security_group_egress_rule`
として別リソース化する。`aws_security_group` のインライン `ingress`/`egress` ブロックは使わない。

**理由**: インラインブロックはルール1件の変更で既存ルールが削除→再作成されるリスクがある。
AWS Provider v5 推奨方式。

CIDR の参照元は上記「IP アドレス管理パターン」に従い、必ず variables.tf の変数を使う:

```hcl
# sg.tf
resource "aws_security_group" "web" {
  name        = "web-sg"
  description = "Web server security group"
  vpc_id      = aws_vpc.main.id
  # ingress/egress ブロックは書かない
  tags = { Name = "web-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "web_https_example" {
  for_each          = var.example_company_cidrs
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = each.key
}

resource "aws_vpc_security_group_egress_rule" "web_all" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
```

## WAF IP Set のパターン

IP アドレス管理パターンで定義した変数を `values()` で参照する:

```hcl
# waf.tf
resource "aws_wafv2_ip_set" "example_company" {
  name               = "example-company"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = values(var.example_company_cidrs)
  tags = { Name = "example-company" }
}

# CLOUDFRONT スコープは us-east-1 固定 + provider エイリアス必須
resource "aws_wafv2_ip_set" "cf_allow_list" {
  provider           = aws.us_east_1
  name               = "cf-allow-list"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = values(var.example_company_cidrs)
  tags = { Name = "cf-allow-list" }
}
```

## リソース依存関係の解決順序

以下の順序でリソースを配置・生成する:

1. IAM Role / Policy（他リソースが参照）
2. VPC
3. Subnet / Security Group
4. Internet Gateway / NAT Gateway / Route Table
5. WAF IP Set（WebACL が参照）
6. ALB / NLB / Target Group
7. EC2 Instance / RDS Instance
8. Lambda / ECS
9. Route53 / CloudFront

## センシティブな属性の変数化

以下の属性は変数化して `variables.tf` に追加する:
- RDS / ElastiCache のパスワード
- API キー
- 証明書の秘密鍵

## import で問題になりやすい属性

| リソース | 注意点 |
|---------|-------|
| Security Group | `ingress`/`egress` の順序はTerraformが管理するため別リソースにする |
| Route Table | メインルートテーブルのデフォルトルート（local）は記述不要 |
| IAM Policy | `jsonencode` で記述し、条件やワイルドカードを正確に反映 |
| S3 Bucket | バケットポリシーは `aws_s3_bucket_policy` として別リソースで定義 |
| Launch Template | 最新バージョンを `$Latest` または具体的なバージョン番号で指定 |
