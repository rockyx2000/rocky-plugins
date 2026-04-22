# aws-to-terraform

既存のAWS環境を自動でTerraformコードに変換するClaudeCodeカスタムエージェントです。
`terraform import` まで一貫して実行し、最終的に `terraform plan` が **No Changes** になるまで自律的に反復改善します。

## 概要

```
既存AWS環境  →  スキャン  →  TFコード生成  →  terraform import  →  No Changes 達成
```

AIエージェントが以下を自律的に実行します:

1. **Phase 1**: AWS CLIで既存リソースを網羅的にスキャン
2. **Phase 2**: スキャン結果からTerraform HCLコードを生成
3. **Phase 3**: `terraform import` でstateを取り込む
4. **Phase 4**: `terraform plan` の差分をAIが解析・修正 → No Changesまでループ

## デモ

```
$ ./run.sh --region ap-northeast-1 --profile myprofile

╔═══════════════════════════════════════╗
║      AWS to Terraform Agent           ║
║  既存AWS環境を Terraform コードに変換  ║
╚═══════════════════════════════════════╝

[Phase 1/4] AWSリソーススキャン
  ✓ VPC: 2件
  ✓ Subnet: 8件
  ✓ Security Group: 5件
  ✓ EC2 Instance: 4件
  ✓ RDS Instance: 2件
  ✓ ALB: 1件
  ✓ Lambda: 6件
  スキャン完了: 42リソースを検出

[Phase 2/4] Terraformコード生成
  ✓ networking.tf (15リソース)
  ✓ compute.tf (4リソース)
  ✓ database.tf (3リソース)
  ✓ serverless.tf (6リソース)
  ✓ iam.tf (8リソース)
  コード生成完了: 8ファイルを生成

[Phase 3/4] terraform import
  ✓ aws_vpc.main imported
  ✓ aws_subnet.public_1a imported
  ✓ aws_instance.web_1 imported
  ...
  import完了: 成功 40件 / 失敗 2件

[Phase 4/4] terraform plan & ドリフト修正
  差分が検出されました (試行 1/10) - AIが修正中...
  差分が検出されました (試行 2/10) - AIが修正中...
  ✓ No changes! Infrastructure is up-to-date.

✓ No Changes 達成! AWSとTerraformが完全に一致しています。
```

## 前提条件

| ツール | バージョン | インストール方法 |
|--------|-----------|----------------|
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | v2.x | `brew install awscli` |
| [Terraform](https://developer.hashicorp.com/terraform/downloads) | >= 1.5.0 | `brew install terraform` |
| [jq](https://jqlang.github.io/jq/) | 1.6+ | `brew install jq` |
| [Claude Code](https://claude.ai/code) | 最新 | `npm install -g @anthropic-ai/claude-code` |

AWSの権限: 対象リソースへの `Describe*` / `List*` / `Get*` 権限が必要です。

## インストール

### Claude Code プラグインとして追加（推奨）

```bash
# 1. マーケットプレイスを登録
/plugin marketplace add https://github.com/rockyx2000/rocky-plugins.git

# 2. プラグインをインストール
/plugin install aws-to-terraform@rocky-plugins
```

インストール後は **どのディレクトリからでも** スラッシュコマンドで呼び出せます:

```
/aws-to-terraform --region ap-northeast-1 --profile myprofile
```

### クローンして使う（従来方式）

```bash
# 1. クローン
git clone https://github.com/rockyx2000/rocky-plugins
cd aws-to-terraform

# 2. AWS認証を確認
aws sts get-caller-identity --profile myprofile

# 3. claude を起動（CLAUDE.md が自動で読み込まれる）
claude
```

## クイックスタート

AWS認証さえ通っていれば、一言で始められます:

```
/aws-to-terraform
```

引数を指定する場合:

```
/aws-to-terraform --region us-east-1 --profile prod --filter networking,compute
```

生成されたTerraformコードは `output/terraform/` に出力されます。

## `/aws-to-terraform` コマンドの仕組み

`/aws-to-terraform` と入力してから No Changes に達するまで、内部で何が起きているかを説明します。

### 全体像

```
ユーザー: /aws-to-terraform --region ap-northeast-1
            │
            ▼
┌─────────────────────────────────────────────────────────┐
│  Claude Code がスキルを読み込む                           │
│  skills/aws-to-terraform/SKILL.md                        │
│  （フロントマターで使用ツール・引数ヒントを定義）            │
└──────────────────────┬──────────────────────────────────┘
                       │ Claudeがオーケストレーターとして動作
                       ▼
         ┌─────────────────────────┐
         │  Phase 1: スキャン       │  AWS CLI で既存リソースを収集
         │  (Bash ツール)           │  → output/scan_results/resources.json
         └────────────┬────────────┘
                      │
         ┌────────────▼────────────┐
         │  Phase 2: コード生成     │  resources.json から HCL を生成
         │  (Write/Edit ツール)     │  → output/terraform/*.tf
         └────────────┬────────────┘
                      │
         ┌────────────▼────────────┐
         │  Phase 3: import        │  terraform init → terraform import
         │  (Bash ツール)           │  リソースごとに state へ取り込み
         └────────────┬────────────┘
                      │
         ┌────────────▼────────────┐
         │  Phase 4: plan & 修正   │  terraform plan を実行し差分を解析
         │  (Bash/Edit ツール)      │  .tf ファイルを修正して再実行
         │                         │  ↑ No Changes になるまでループ（最大10回）
         └────────────┬────────────┘
                      │
                      ▼
               完了レポート出力
```

### スキルファイルの役割

`/aws-to-terraform` を入力すると、Claude Code は以下を行います:

1. **スキルを検索** — インストール済みのスキル一覧から `aws-to-terraform` を照合
2. **SKILL.md を読み込む** — `skills/aws-to-terraform/SKILL.md` の内容をプロンプトとして展開
3. **引数を受け渡す** — `--region ap-northeast-1` などの引数を `$ARGUMENTS` 変数として注入
4. **Claudeが実行** — SKILL.md の指示に従って Bash・Read・Write・Edit ツールを使いながら各フェーズを進める

```
# SKILL.md のフロントマター（メタ情報）
---
name: aws-to-terraform
description: 既存のAWS環境をスキャンしてTerraformコードを生成...
argument-hint: "[--region REGION] [--profile PROFILE] ..."
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Agent
---

# 本文（= Claudeへの指示）
Phase 1: AWSリソーススキャン
  aws ec2 describe-vpcs ... を実行して ...
Phase 2: ...
```

### フェーズ間のデータフロー

各フェーズはファイルを介してデータを受け渡します。Claude のコンテキストが途切れても再開できるのはこのためです。

```
Phase 1 ──(resources.json)──▶ Phase 2 ──(*.tf ファイル)──▶ Phase 3
                                                                │
Phase 4 ◀──(plan_output.txt)── terraform plan ◀──(state)───────┘
   │
   └──(*.tf 修正)──▶ terraform plan ──▶ No Changes ✓
```

### プラグイン配布の仕組み

```
リポジトリ構成
├── .claude-plugin/
│   ├── plugin.json        # プラグイン名・バージョン・スキルパスを定義
│   └── marketplace.json   # /plugin marketplace add の検索エントリ
└── skills/
    └── aws-to-terraform/
        └── SKILL.md       # /aws-to-terraform の実体
```

| コマンド | 処理内容 |
|---------|---------|
| `/plugin marketplace add <url>` | `marketplace.json` を取得してローカルに登録 |
| `/plugin install aws-to-terraform@...` | `plugin.json` に従い `skills/` 以下をインストール |
| `/aws-to-terraform` | `SKILL.md` を展開してClaude に渡す |

---

## 使い方

### 基本

```bash
./run.sh [オプション]
```

### オプション

| オプション | 説明 | デフォルト |
|-----------|------|----------|
| `-r, --region REGION` | AWSリージョン | `ap-northeast-1` |
| `-p, --profile PROFILE` | AWSプロファイル | `default` |
| `-o, --output DIR` | 出力先ディレクトリ | `./output` |
| `-f, --filter CATEGORY` | スキャン対象カテゴリ（カンマ区切り） | 全カテゴリ |
| `-m, --max-attempts N` | ドリフト修正の最大試行回数 | `10` |
| `--skip-scan` | スキャンをスキップ（既存スキャン結果を使用） | - |
| `--skip-generate` | コード生成をスキップ | - |
| `--skip-import` | importをスキップ | - |
| `--non-interactive` | 非インタラクティブモード | - |

### 実行例

```bash
# 特定カテゴリのみ変換
./run.sh --region us-east-1 --filter networking,compute

# スキャン済み結果からTFコード生成のみ
./run.sh --skip-scan

# importから再実行（スキャン・生成済みの場合）
./run.sh --skip-scan --skip-generate

# Claudeのインタラクティブモードで実行
cd aws-to-terraform && claude
```

### インタラクティブモード

```bash
cd aws-to-terraform && claude
```

`CLAUDE.md` に基づいてClaudeが対話的にガイドします。
リソースの選択、変換方針の確認、エラー対応などを対話しながら進められます。

---

## 対話的な使い方（プロンプト例）

`claude` コマンドで起動後、自然言語でやりとりしながら変換を進める例を紹介します。

### 基本：VPC単位で変換する

```
このターミナルの環境変数にAWSクレデンシャルを入れています。
「myapp」という名前のVPCとそこに載っている関連リソースを
ホームディレクトリに新規ディレクトリを作成して、Terraform化して
```

> **ポイント:** リソース名のキーワードを渡すだけでOK。スキャン〜import〜No Changes達成まで自動でやってくれます。

---

### リージョンやプロファイルを指定する

```
ap-northeast-1 リージョン、prod プロファイルの
「myapp-production」VPCをTerraform化して。
出力先は ~/terraform/myapp にして。
```

---

### 特定のリソースタイプだけ変換する

```
us-east-1 のIAMロールとポリシーだけTerraformコードに変換して。
EC2やVPCは対象外で。
```

---

### 途中から再開する（スキャン済みの場合）

```
output/scan_results/resources.json は既にあるので、
スキャンはスキップしてTerraformコード生成からやり直して。
```

---

### planのdiffを手動で直してもらう

```
terraform plan の結果が以下のようになっています：

  ~ aws_security_group.web_sg
      + tags = { "Name" = "web-sg" }

これを No Changes にするにはどう修正すればいい？
```

---

### 全体の進捗を確認する

```
今どのフェーズまで完了している？
import に失敗したリソースはどれ？
```

---

### よくある対話パターン

| 状況 | プロンプト例 |
|------|-------------|
| 最初の一言 | `〇〇という名前のVPCをTerraform化して` |
| 出力先を変えたい | `出力先を ~/infra/terraform に変えて` |
| NAT Gatewayが削除済み | `NAT Gatewayはすでに消えてるので除外して` |
| タグの不一致が多い | `Owner タグは無視して No Changes にして` |
| import を1件だけやり直したい | `aws_instance.web だけ import し直して` |
| diffの原因を調べたい | `この plan の差分が出る原因を説明して` |

---

### 実際のセッション例（抜粋）

```
ユーザー: このターミナルの環境変数にAWSクレデンシャルを入れています。
         「myapp」という名前のVPCとそこに載ってる関連リソースを
         ホームディレクトリに新規ディレクトリを作成して、Terraform化して

Claude: まず事前確認から始めます。

        [事前確認] 完了
        - AWS認証: user@example.com (Account: 123456789012)
        - Terraform: v1.9.7

        [Phase 1] myapp を含むVPCを検索...
          ✓ myapp-test-vpc (vpc-01db6..., 10.0.0.0/16)
          ✓ サブネット: 4件（public×2, private×2）
          ✓ IGW: 1件
          ✓ ルートテーブル: 3件
          ✓ セキュリティグループ: 3件
          ✓ EC2インスタンス: 2件（stopped）
          ⚠ NAT Gateway: 削除済み（RTBに参照残あり）

        [Phase 2] ~/myapp-test-terraform/ にTerraformコードを生成...
          ✓ networking.tf
          ✓ security_groups.tf
          ✓ compute.tf

        [Phase 3] terraform init & import...
          ✓ aws_vpc.myapp_test_vpc
          ✓ aws_internet_gateway.myapp_test_igw
          ✓ aws_subnet.* × 4
          ✓ aws_route_table.* × 3
          ✓ aws_route_table_association.* × 4
          ✓ aws_security_group.* × 3
          ✓ aws_instance.* × 2

        [Phase 4] terraform plan（試行 1/10）
          差分: 14リソース（Ownerタグ欠落、EC2タグ欠落）
          → コードを修正中...

        [Phase 4] terraform plan（試行 2/10）
          ✓ No changes. Infrastructure is up-to-date.

        [Phase 5] 完了！
          変換リソース数: 19
          生成ファイル: ~/myapp-test-terraform/
          Planサイクル: 2回
```

## 対応リソース

| カテゴリ | リソース |
|---------|---------|
| **networking** | VPC, Subnet, Route Table, Security Group, IGW, NAT GW, VPC Endpoint, EIP |
| **compute** | EC2 Instance, Key Pair, Auto Scaling Group |
| **storage** | S3 Bucket (+ versioning, policy, encryption) |
| **database** | RDS Instance, DB Subnet Group, DynamoDB Table |
| **iam** | IAM Role, Policy, Instance Profile, Role Policy Attachment |
| **load_balancing** | ALB/NLB, Target Group, Listener, Listener Rule |
| **serverless** | Lambda Function, SQS Queue, SNS Topic |
| **container** | ECS Cluster, Task Definition, Service |
| **dns** | Route53 Zone, Record |
| **cdn** | CloudFront Distribution |
| **secrets** | Secrets Manager Secret |
| **monitoring** | CloudWatch Log Group, Metric Alarm |

## 出力ファイル

```
output/
├── scan_results/
│   ├── resources.json          # スキャン結果（全リソース情報）
│   ├── import_results.json     # terraform import 結果
│   ├── plan_output.txt         # 最後の terraform plan 出力
│   └── fix_report_attempt_N.md # ドリフト修正レポート（試行ごと）
├── terraform/
│   ├── versions.tf             # Terraformバージョン制約
│   ├── providers.tf            # AWSプロバイダー設定
│   ├── variables.tf            # 変数定義
│   ├── locals.tf               # ローカル値
│   ├── networking.tf           # ネットワークリソース
│   ├── compute.tf              # コンピュートリソース
│   ├── database.tf             # データベースリソース
│   ├── iam.tf                  # IAMリソース
│   └── ...                     # カテゴリ別ファイル
└── logs/
    ├── scan.log                # スキャンログ
    ├── generate.log            # コード生成ログ
    ├── import.log              # importログ
    └── fix_attempt_N.log       # 修正試行ログ
```

## アーキテクチャ

```
┌─────────────────────────────────────────────────────┐
│                   run.sh (CLI Entry)                 │
└──────────────────────┬──────────────────────────────┘
                       │ claude --print
                       ▼
┌─────────────────────────────────────────────────────┐
│              CLAUDE.md (Orchestrator)                │
│                                                      │
│  Phase 1        Phase 2        Phase 3   Phase 4    │
│  ┌─────────┐   ┌───────────┐  ┌──────┐  ┌───────┐  │
│  │Scanner  │→  │Generator  │→ │Import│→ │Fixer  │  │
│  │Agent    │   │Agent      │  │Agent │  │Agent  │  │
│  └─────────┘   └───────────┘  └──────┘  └───┬───┘  │
│  01_scanner.md  02_generator.md  03_importer │      │
│                                  .md    04_fixer.md  │
│                                              │       │
│                                    No Changes? ─── 完了│
└─────────────────────────────────────────────────────┘
```

各エージェントはAWS CLI・Terraform CLIを通じてAWSと通信し、
ファイル経由でフェーズ間のデータを受け渡します。

## カスタマイズ

### 対応リソースの追加

`scripts/resource_registry.json` にエントリを追加します:

```json
{
  "category": "networking",
  "tf_resource_type": "aws_vpc_peering_connection",
  "list_command": "aws ec2 describe-vpc-peering-connections --query 'VpcPeeringConnections'",
  "id_jq": ".VpcPeeringConnectionId",
  "name_jq": "(.Tags // [] | map(select(.Key == \"Name\")) | first | .Value) // .VpcPeeringConnectionId",
  "import_id_template": "{VpcPeeringConnectionId}",
  "import_id_example": "pcx-0123456789abcdef0",
  "is_global": false
}
```

### スキャン対象のフィルタリング

特定のリソースをスキャン除外したい場合は `skip_patterns` を編集:

```json
"skip_patterns": {
  "aws_s3_bucket": "Name starts_with \"aws-\""
}
```

### 修正ポリシーの調整

特定リソースタイプに対して常に `ignore_changes` を適用したい場合は `common_ignore_changes` を編集:

```json
"common_ignore_changes": {
  "aws_ecs_service": ["desired_count", "task_definition"]
}
```

## よくある問題

### `terraform plan` でdiffが収束しない

以下の属性は収束が難しい場合があります:

- **Security Group rules**: `aws_security_group` の `ingress`/`egress` ブロックを
  `aws_security_group_rule` リソースに分割することで解決できます
- **S3 Bucket ACL**: ACLが `private` でない場合は `aws_s3_bucket_acl` リソースが必要です
- **RDS パスワード**: `ignore_changes = [password]` で対応します

### `terraform import` が失敗する

```bash
# 手動でimport
cd output/terraform
terraform import aws_instance.web_1 i-0123456789abcdef0
```

### AWS権限エラー

最低限必要な権限ポリシー:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ec2:Describe*",
      "s3:GetBucket*", "s3:ListBuckets",
      "rds:Describe*",
      "iam:List*", "iam:Get*",
      "ecs:List*", "ecs:Describe*",
      "lambda:List*", "lambda:GetFunction*",
      "elasticloadbalancing:Describe*",
      "route53:List*", "route53:Get*",
      "cloudfront:List*", "cloudfront:Get*",
      "logs:DescribeLogGroups",
      "cloudwatch:DescribeAlarms",
      "secretsmanager:ListSecrets"
    ],
    "Resource": "*"
  }]
}
```

## セキュリティに関する注意

- 生成された `terraform.tfstate` はAWSリソースの詳細情報を含みます。`.gitignore` で除外されていますが、取り扱いに注意してください
- RDSのパスワード等のシークレットはTerraformコードに含まれません（変数化されます）
- 本番環境への適用前に必ず `terraform plan` の内容をレビューしてください

## ライセンス

MIT License

## Contributing

1. Fork this repository
2. Create a feature branch: `git checkout -b feature/add-new-resource`
3. Add resource mappings to `scripts/resource_registry.json`
4. Test with your AWS environment
5. Submit a Pull Request
