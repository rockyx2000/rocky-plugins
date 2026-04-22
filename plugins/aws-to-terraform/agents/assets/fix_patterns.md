# Terraform ドリフト修正パターン集

差分タイプ別の修正方法と、リソース固有のパターン集。aws-tf-fix エージェントから参照する。

## plan 出力の読み方

| 記号 | 意味 | 対処方針 |
|------|------|---------|
| `~` | update in-place | TFコードの値を AWS の実際の値（`->` の左辺）に修正 |
| `-/+` | destroy & recreate | **自動修正しない** — レポートに記録して返す |
| `+` | create | importし忘れ or 不要なリソース定義 |
| `-` | destroy | AWSにないリソースがコードに存在 |

## 差分カテゴリと修正方法

### A: 値の不一致（最優先）

```
~ instance_type = "t3.micro" -> "t3.small"
```

TFコードを AWS の実際の値（左辺）に変更する。

### B: タグの差分

```
~ tags = {
    + "ManagedBy" = "terraform"    # TFにあるがAWSにない → 削除
    - "Environment" = "production"  # AWSにあるがTFにない → 追加
  }
```

TFコードのタグを AWS の実際のタグに合わせる。

### C: Computed 属性の差分（修正不要）

```
~ arn = "arn:aws:..." -> (known after apply)
```

これは正常。plan 後に自動解決されるため修正不要。

### D: ignore_changes で対応（最終手段）

外部で管理される値は `lifecycle.ignore_changes` を使う:

```hcl
resource "aws_ecs_service" "api" {
  lifecycle {
    ignore_changes = [
      desired_count,  # オートスケーリング管理
    ]
  }
}
```

`ignore_changes` を使う判断基準:
- AWS が自動的に管理する属性（`last_modified_time` 等）
- Terraform 外で管理される値（スケーリングで変わる `desired_count` 等）
- 起動時のみ使用する値（`user_data` 等）

### E: destroy/recreate が必要な変更

**自動修正しない** — レポートに記録するのみ。主なケース:
- `multi_az` の変更（RDS）
- `engine_version` のメジャーアップグレード
- `vpc_id` の変更

---

## リソース固有の修正パターン

### S3 バケット設定

バージョニング・暗号化は別リソースで管理する:

```hcl
resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}
```

### EC2 ユーザーデータ

```hcl
resource "aws_instance" "web" {
  lifecycle {
    ignore_changes = [user_data, user_data_base64]
  }
}
```

### ECS desired_count（オートスケーリング管理下）

```hcl
resource "aws_ecs_service" "api" {
  desired_count = 2

  lifecycle {
    ignore_changes = [desired_count]
  }
}
```

### RDS 自動バックアップ設定

```hcl
resource "aws_db_instance" "main" {
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"
}
```

### RDS パスワード

```hcl
resource "aws_db_instance" "main" {
  password = var.db_password

  lifecycle {
    ignore_changes = [password]
  }
}
```

---

## エスカレーション判断

以下の場合は自動修正せずレポートに記録する:

1. **destroy/recreate が必要な変更** — データ損失リスクあり
2. **Terraform で管理できない属性** — AWS コンソールでの手動変更が必要
3. **複数リソースへの連鎖変更** — 影響範囲が大きい
