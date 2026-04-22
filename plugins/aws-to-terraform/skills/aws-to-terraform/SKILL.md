---
name: aws-to-terraform
description: 既存のAWS環境をスキャンしてTerraformコードを生成し、terraform importからNo Changes状態まで自動変換する
disable-model-invocation: true
allowed-tools: Agent AskUserQuestion Bash(aws sts get-caller-identity*) Read Write Edit Glob
---

あなたはAWS環境をTerraformコードに変換するオーケストレーターです。
各フェーズを専用のエージェントに委譲しながら、HITLを担当します。

## 起動時のヒアリング

### Step 1: アカウント確認

以下を実行してアカウント情報を表示する:

```bash
aws sts get-caller-identity
```

### Step 2: リージョン確認

`AskUserQuestion` で確認する:
- 質問: 「対象リージョンを入力してください（Enterで ap-northeast-1）」
- 空欄なら `ap-northeast-1` を使用

### Step 3: 出力先確認

`AskUserQuestion` で確認する:
- 質問: 「出力先ディレクトリを入力してください（Enterで ./terraform）」
- 空欄なら `./terraform` を使用

以降の処理で {REGION} と {OUTPUT} にこの値を使用する。

## Phase 1: AWSリソーススキャン

`aws-tf-scan` エージェントを以下のプロンプトで呼び出す:

```
以下の設定でAWSリソースをスキャンしてください:
- リージョン: {REGION}
- 出力先: {OUTPUT}/scan_results
```

## HITL: スキャン結果の確認（Phase 1 → Phase 2 の間）

エージェントが返したスキャンサマリーをユーザーに提示した後、`AskUserQuestion` で以下を確認する:

```
質問内容:
「上記のリソースを Terraform で管理します。コード生成に進む前に確認してください。

  [ ] 不要なリソース（テスト用等）が含まれていないか
  [ ] CDK・CloudFormation など他のツールで管理しているリソースがないか
  [ ] 手動管理のまま残したいリソース（踏み台サーバー等）がないか
  [ ] スキャン漏れがないか

変更が必要な場合は指示してください（例: 「aws_instance.bastion を除外して」「iam カテゴリを全部除外して」）
問題なければ「OK」と入力してください。」
```

### ユーザーの回答に応じた resources.json の更新

ユーザーの指示に従って `{OUTPUT}/scan_results/resources.json` を直接更新する:

| ユーザー指示 | 処理 |
|------------|------|
| `XXX を除外` | resources から該当エントリを削除し skipped に移動（reason: "user_excluded"） |
| `YYY カテゴリを全部除外` | そのカテゴリのエントリを全て skipped に移動 |
| `ZZZ を追加して` | 不足リソースを AWS CLI で追加スキャンして resources に追加 |
| `OK` / `続行` / 変更なし | resources.json をそのまま確定 |

変更があった場合は resources.json を更新してからユーザーに変更内容を報告し、
追加の変更がなければ Phase 2 に進む。

## Phase 2: Terraformコード生成

`aws-tf-generate` エージェントを以下のプロンプトで呼び出す:

```
以下の設定でTerraformコードを生成してください:
- 入力ファイル: {OUTPUT}/scan_results/resources.json
- 出力先: {OUTPUT}
```

## Phase 3: terraform import

`aws-tf-import` エージェントを以下のプロンプトで呼び出す:

```
以下の設定でterraform importを実行してください:
- 入力ファイル: {OUTPUT}/scan_results/resources.json
- Terraformディレクトリ: {OUTPUT}
- リージョン: {REGION}
```

## Phase 4: terraform plan & ドリフト修正

`aws-tf-fix` エージェントを以下のプロンプトで呼び出す:

```
以下の設定でterraform planの差分を修正してください:
- Terraformディレクトリ: {OUTPUT}
- 最大試行回数: 10
- リージョン: {REGION}
```

エージェントが `destroy/recreate` が必要な差分を返した場合は、ユーザーに提示して対処方法を確認する。

## Phase 5: 完了レポート

以下を出力する:
- 変換リソース数と種類の内訳
- import 成功/失敗数
- Plan 試行回数
- 生成ファイル一覧（`{OUTPUT}/` 配下）
- 手動対応が必要な項目（あれば）
