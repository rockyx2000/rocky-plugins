# aws-to-terraform

既存AWS環境をスキャンしてTerraformコードに自動変換する Claude Code プラグインです。
`terraform import` から `terraform plan` の No Changes 達成まで全自動で行います。

## インストール

マーケットプレイスをまだ追加していない場合は先に追加してください。

```
/plugin marketplace add https://github.com/rockyx2000/rocky-plugins.git
```

```
/plugin install aws-to-terraform@rocky-plugins
```

## 使い方

```
/aws-to-terraform
```

実行すると対話形式でリージョン・出力先を確認してから4フェーズを順に実行します。
各フェーズ間にはスキャン結果の確認（HITL）が入り、不要なリソースの除外等が可能です。

## 実行例

### 全リソースをTerraform化する

```
> /aws-to-terraform

Claude: アカウント情報を確認しました（123456789012 / arn:aws:iam::...）
        対象リージョンを入力してください（Enter で ap-northeast-1）

> ap-northeast-1

Claude: 出力先ディレクトリを入力してください（Enter で ./terraform）

> ./output

Claude: [Phase 1] スキャン中...

        ━━━━━━━━━━━━━━━━━━━━━━━━
         スキャン完了（32件 / 除外7件）
        ━━━━━━━━━━━━━━━━━━━━━━━━
        ## networking (12件)
        │ aws_vpc.myapp_vpc       │ myapp-vpc   │ vpc-xxx │ 10.0.0.0/16 │
        │ aws_subnet.public_1a    │ myapp-pub-1a│ ...     │ ...         │
        ...

        上記のリソースを Terraform で管理します。確認してください。
          [ ] 不要なリソースが含まれていないか
          [ ] 他ツール管理のリソースがないか
          ...
        変更が必要な場合は指示してください。問題なければ「OK」と入力してください。

> aws_instance.bastion を除外して

Claude: aws_instance.bastion を除外しました（31件）。他に変更はありますか？

> OK

Claude: [Phase 2] Terraformコード生成中...
        [Phase 3] terraform import 中...（31件）
        [Phase 4] plan 差分修正中...（3回で No Changes 達成）

        ━━━━━━━━━━━━━━━━━━━━━━━━
         完了
        ━━━━━━━━━━━━━━━━━━━━━━━━
        変換: 31件 / import 成功: 29件 / 失敗: 2件
        生成ファイル: ./output/terraform/*.tf
        手動対応: aws_lb_listener.https（証明書ARNの確認が必要）
```

### 特定リソースを絞り込んでTerraform化する

スキル名の後に自然言語で指示を添えると、スキャン対象を絞り込めます。

```
> /aws-to-terraform myappというプレフィックスのついたVPCと関連するリソースをすべてTerraform化してください

Claude: アカウント情報を確認しました（123456789012 / arn:aws:iam::...）
        対象リージョンを入力してください（Enter で ap-northeast-1）

> （Enter）

Claude: 出力先ディレクトリを入力してください（Enter で ./terraform）

> （Enter）

Claude: [Phase 1] 「myapp」プレフィックスのVPCと関連リソースをスキャン中...

        ━━━━━━━━━━━━━━━━━━━━━━━━
         スキャン完了（18件 / 除外3件）
        ━━━━━━━━━━━━━━━━━━━━━━━━
        ## networking (8件)
        │ aws_vpc.myapp_vpc       │ myapp-vpc    │ vpc-xxx │ 10.0.0.0/16 │
        │ aws_subnet.myapp_pub_1a │ myapp-pub-1a │ ...     │ ...         │
        ...
```

## 実行フロー

```
[Phase 1] AWSリソーススキャン    → output/scan_results/resources.json
          ↓ HITL: スキャン結果確認・除外指示
[Phase 2] Terraformコード生成    → output/terraform/*.tf
[Phase 3] terraform import       → terraform.tfstate に取り込み
[Phase 4] terraform plan & 修正  → No Changes になるまで最大10回ループ
```

### 対応リソース

VPC / Subnet / Security Group / EC2 / RDS / ElastiCache / DynamoDB / ALB / Lambda / SQS / SNS / ECS / S3 / IAM / Route53 / CloudFront / WAF IP Set

## 生成ファイル構成

```
output/terraform/
├── .gitignore
├── versions.tf
├── providers.tf
├── variables.tf       # CIDR管理を含む変数定義
├── networking.tf      # VPC, Subnet, IGW, NAT GW, Route Table
├── sg.tf              # Security Group + Inbound/Outbound Rules
├── ec2.tf             # EC2, Launch Template, ASG
├── s3.tf              # S3
├── rds.tf             # RDS, DB Subnet Group
├── elasticache.tf     # ElastiCache
├── dynamodb.tf        # DynamoDB
├── iam.tf             # IAM Role, Policy, Instance Profile
├── alb.tf             # ALB, Target Group, Listener
├── lambda.tf          # Lambda
├── sqs.tf             # SQS
├── sns.tf             # SNS
├── ecs.tf             # ECS Cluster, Service, Task Definition
├── route53.tf         # Route53
├── cloudfront.tf      # CloudFront
└── waf.tf             # WAF IP Set
```

リソースが存在しないカテゴリのファイルは生成しません。

## コード生成の方針

**Security Group ルール**: インライン `ingress`/`egress` は使わず、常に `aws_vpc_security_group_ingress_rule` + `for_each` で生成します（AWS Provider v5推奨方式）。ルール1件の変更で既存ルールが削除→再作成されるリスクを排除するためです。

**IP アドレス管理**: SG インバウンドルールおよび WAF IP Set で使用する CIDR は `variables.tf` に `map(string)` 変数として一元管理します。キーが用途・フロア等の説明、値が CIDR です。SG ルールの `description` フィールドをもとに会社・拠点単位でグループ化し、SG と WAF で同じ変数を参照します。

```hcl
# variables.tf
variable "example_company_cidrs" {
  description = "Example社のCIDR"
  type        = map(string)
  default = {
    "Example社 1F"  = "1.1.1.1/32"
    "Example社 2F"  = "1.1.1.2/32"
  }
}
```

## セキュリティ

`allowed-tools` で実行可能なコマンドを `aws ec2 describe-*` のような読み取り系のみに制限しています。削除・変更系のAWS操作は実行されません。

## ディレクトリ構造

```
aws-to-terraform/
├── .claude-plugin/
│   └── plugin.json
├── agents/
│   ├── aws-tf-scan.md      # Phase 1
│   ├── aws-tf-generate.md  # Phase 2
│   ├── aws-tf-import.md    # Phase 3
│   ├── aws-tf-fix.md       # Phase 4
│   └── assets/             # 遅延ロードアセット
├── hooks/
├── hooks-handlers/
├── skills/
│   └── aws-to-terraform/   # フルフロー（唯一のエントリポイント）
└── README.md
```
