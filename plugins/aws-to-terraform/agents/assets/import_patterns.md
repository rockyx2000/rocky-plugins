# terraform import パターン集

import ID の形式と特殊ケースのリファレンス。aws-tf-import エージェントから参照する。

## import 優先度（依存関係順）

```
優先度1: aws_vpc, aws_internet_gateway, aws_eip
優先度2: aws_subnet, aws_security_group, aws_vpc_security_group_ingress_rule, aws_vpc_security_group_egress_rule
優先度3: aws_route_table, aws_route_table_association, aws_nat_gateway
優先度4: aws_key_pair, aws_iam_role, aws_iam_policy, aws_iam_instance_profile
優先度5: aws_instance, aws_db_subnet_group, aws_db_instance, aws_elasticache_cluster
優先度6: aws_lb, aws_lb_target_group, aws_lb_listener
優先度7: aws_s3_bucket, aws_s3_bucket_policy, aws_s3_bucket_versioning
優先度8: aws_lambda_function, aws_ecs_cluster, aws_ecs_task_definition, aws_ecs_service
優先度9: aws_route53_zone, aws_route53_record, aws_cloudfront_distribution, aws_wafv2_ip_set
```

## 主要リソースの import ID 形式

| リソース | import ID の形式 | 例 |
|---------|----------------|---|
| `aws_vpc` | VPC ID | `vpc-0123456789abcdef0` |
| `aws_subnet` | Subnet ID | `subnet-0123456789abcdef0` |
| `aws_security_group` | SG ID | `sg-0123456789abcdef0` |
| `aws_internet_gateway` | IGW ID | `igw-0123456789abcdef0` |
| `aws_nat_gateway` | NAT GW ID | `nat-0123456789abcdef0` |
| `aws_eip` | Allocation ID | `eipalloc-0123456789abcdef0` |
| `aws_route_table` | RT ID | `rtb-0123456789abcdef0` |
| `aws_route_table_association` | `subnet-xxx/rtb-xxx` | `subnet-0123/rtb-0456` |
| `aws_key_pair` | Key Pair 名 | `my-key-pair` |
| `aws_instance` | Instance ID | `i-0123456789abcdef0` |
| `aws_iam_role` | ロール名 | `ecs-task-execution-role` |
| `aws_iam_policy` | Policy ARN | `arn:aws:iam::123456789012:policy/my-policy` |
| `aws_iam_role_policy_attachment` | `role-name/policy-arn` | `my-role/arn:aws:iam::aws:policy/ReadOnlyAccess` |
| `aws_s3_bucket` | バケット名 | `my-bucket-name` |
| `aws_s3_bucket_policy` | バケット名 | `my-bucket-name` |
| `aws_s3_bucket_versioning` | バケット名 | `my-bucket-name` |
| `aws_db_instance` | DB 識別子 | `my-rds-identifier` |
| `aws_db_subnet_group` | サブネットグループ名 | `my-db-subnet-group` |
| `aws_lb` | ALB/NLB ARN | `arn:aws:elasticloadbalancing:...` |
| `aws_lb_target_group` | Target Group ARN | `arn:aws:elasticloadbalancing:...` |
| `aws_lb_listener` | Listener ARN | `arn:aws:elasticloadbalancing:...` |
| `aws_lambda_function` | 関数名 | `my-lambda-function` |
| `aws_ecs_cluster` | クラスター名 | `my-ecs-cluster` |
| `aws_ecs_service` | `cluster-name/service-name` | `my-cluster/my-service` |
| `aws_ecs_task_definition` | Task Definition ARN | `arn:aws:ecs:...:task-definition/my-task:5` |
| `aws_route53_zone` | Zone ID | `Z1234567890ABCDEF` |
| `aws_cloudfront_distribution` | Distribution ID | `E1234567890ABCD` |
| `aws_wafv2_ip_set` | `id/name/scope` | `xxxx-xxxx/allow-list/REGIONAL` |

## Security Group Rules の for_each import

ジェネレーターが `for_each` パターン（CIDR をキーにしたもの）を生成した場合、
CIDR と AWS ルール ID の対応を先に取得してからimportする。

```bash
# Step 1: SGルールIDとCIDRの対応を取得
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=sg-xxxxxxxxx" \
  --query 'SecurityGroupRules[?!IsEgress].[SecurityGroupRuleId,CidrIpv4]' \
  --output text | while read RULE_ID CIDR; do
    echo "terraform import 'aws_vpc_security_group_ingress_rule.web_https[\"${CIDR}\"]' ${RULE_ID}"
done

# Step 2: 出力されたコマンドを実行（for_each キー = CIDR を引用符で囲む）
terraform import 'aws_vpc_security_group_ingress_rule.web_https["10.0.1.0/24"]' sgr-0aaa1111bbbb2222
```

## WAF IP Set の import

```bash
# REGIONAL スコープの IP Set 一覧と ID を取得
aws wafv2 list-ip-sets \
  --scope REGIONAL --region $REGION --profile $PROFILE \
  --query 'IPSets[*].[Id,Name]' --output text

# REGIONAL の import
terraform import aws_wafv2_ip_set.allow_list "<id>/allow-list/REGIONAL"

# CLOUDFRONT スコープ（us-east-1 で取得）
aws wafv2 list-ip-sets \
  --scope CLOUDFRONT --region us-east-1 --profile $PROFILE \
  --query 'IPSets[*].[Id,Name]' --output text

# CLOUDFRONT の import（リソース側に provider = aws.us_east_1 が必要）
terraform import aws_wafv2_ip_set.cf_allow_list "<id>/cf-allow-list/CLOUDFRONT"
```

## S3 バケットの追加設定

```bash
terraform import aws_s3_bucket_policy.data       my-bucket-name
terraform import aws_s3_bucket_versioning.data   my-bucket-name
terraform import aws_s3_bucket_acl.data          "my-bucket-name,private"
```

## import 失敗パターンと対処

| エラーメッセージ | 原因 | 対処 |
|----------------|------|------|
| `resource not found in configuration` | TFコードにリソース未定義 | ジェネレーターに追加依頼 |
| `Cannot import non-existent remote object` | AWSリソースが存在しない | スキャン結果から除外 |
| `The given key does not identify an existing` | import ID が間違っている | 上記の ID 形式表を確認 |
| `Provider configuration not present` | provider 設定不足 | providers.tf を確認 |
