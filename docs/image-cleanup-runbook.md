# 古いコンテナイメージの自動削除 手順書

main への push のたびに、`.github/workflows/push_main.yml` の最後の方で `scripts/cleanup_old_images.sh` が動き、
今回デプロイしたイメージ以外を Artifact Registry（gcr.io）から削除する。
この手順書は、GCP 側で人間が行う作業をまとめたもの。以下の `PROJECT_ID` はそれぞれの環境の値に置き換える。

```sh
export PROJECT_ID=<GCP のプロジェクト ID>
```

## (0) 作業の順序

**(1) 確認 → (2) 権限の確認と付与 → PR マージ → (3) マージ後の確認** の順に行う。

- (2) より前にマージすると、削除が 403 で失敗する。デプロイは成功しているのに "deploy failure" と通知される。
- マージ後の最初のデプロイで、デプロイしたもの以外のイメージ（タグのないものも含む）がすべて削除される。取り消しはできない。

## (1) 保存場所と出力形式の確認（読み取りだけ）

```sh
gcloud artifacts repositories list --project=$PROJECT_ID
gcloud artifacts docker images list gcr.io/$PROJECT_ID/rss-read-kun --include-tags --format=json
```

- `gcr.io` という名前のリポジトリ（format が DOCKER）が Artifact Registry 上にあることを確かめる。location も控える（以降の `<location>`）。
- 出力の各要素が `package`、`tags`、`version`（`sha256:...`）、`createTime`、`updateTime` を持つことを確かめる。
- この一覧のうち、今回デプロイするイメージ以外が、マージ後の最初のデプロイで削除される。

## (2) サービスアカウント（SA）の権限の確認と付与

削除には Repository Administrator（`roles/artifactregistry.repoAdmin`）相当の権限が必要。
Artifact Registry Writer（`roles/artifactregistry.writer`）では削除できない。

- https://cloud.google.com/artifact-registry/docs/access-control#roles
- https://cloud.google.com/artifact-registry/docs/docker/manage-images （「Delete images or remove tags」）

1. SA のメールアドレスを調べる。鍵の JSON が手元にあれば `jq -r .client_email <key.json>`。無ければ次で絞り込む。

   ```sh
   gcloud iam service-accounts list --project=$PROJECT_ID
   gcloud iam service-accounts keys list --iam-account=<SA> --managed-by=user
   ```

2. プロジェクト単位のロールを確認する。

   ```sh
   gcloud projects get-iam-policy $PROJECT_ID --flatten='bindings[].members' \
     --filter="bindings.members:serviceAccount:<SA>" --format='table(bindings.role)'
   ```

3. リポジトリ単位のロールを確認する。

   ```sh
   gcloud artifacts repositories get-iam-policy gcr.io --location=<location> --project=$PROJECT_ID
   ```

4. 見つかった各ロールに削除の権限があるか確認する。次のコマンドで 2 行とも出れば足りている。

   ```sh
   gcloud iam roles describe <role> --format='value(includedPermissions)' | tr ';' '\n' \
     | grep -xE 'artifactregistry\.(versions|tags)\.delete'
   ```

5. 足りないときだけ、gcr.io リポジトリ単位で付与する。

   ```sh
   gcloud artifacts repositories add-iam-policy-binding gcr.io --location=<location> \
     --project=$PROJECT_ID --member=serviceAccount:<SA> --role=roles/artifactregistry.repoAdmin
   ```

## (3) マージ後の確認

main への最初の push の後に、次を確認する。

1. 残っているイメージがデプロイした 1 件だけで、タグのないものが 0 件であること。

   ```sh
   gcloud artifacts docker images list gcr.io/$PROJECT_ID/rss-read-kun --include-tags --format=json | jq length   # 1
   gcloud artifacts docker images list gcr.io/$PROJECT_ID/rss-read-kun --include-tags
   ```

   その 1 件に、今回の `github.sha` のタグが付いていること。

2. Cloud Run のリビジョンが正常に動いていること。

   ```sh
   gcloud run services describe rss-read-kun --region us-central1 \
     --format='value(status.latestReadyRevisionName,spec.template.spec.containers[0].image)'
   curl -s -o /dev/null -w '%{http_code}' <サービスの URL>/
   ```

   最新のリビジョンが Ready で、image が今回の SHA であること。HTTP ステータスはデプロイ前と同じであること。

## (4) 削除が止まったときの対応

スクリプトは、安全が確かめられないときは削除を 1 件も行わずに異常終了する。メッセージごとの確認先は次のとおり。

| メッセージ | 確認すること |
|---|---|
| `CURRENT_TAG <tag> not found` | デプロイしたイメージにその SHA のタグが付いているか。`images list` で確かめる |
| `invalid digest: <値>` | `images list` の `version` が `sha256:` + 64 桁の 16 進数か。gcloud の出力形式が変わっていないか |
| `<IMAGE>@<digest> is an image index (...)` | build が単一の manifest になっているか。`docker build --provenance=false --sbom=false` が効いているか |
| `unsupported manifest mediaType: <値>` | `docker buildx imagetools inspect --raw <IMAGE>@<digest>` の `.mediaType` を確かめる |

**`imagetools inspect` が失敗したとき**（例: `docker-credential-gcloud` が見つからない、401 / 403 が返る）:

- `gcloud auth configure-docker gcr.io --quiet` のステップが削除より前で成功しているか。
- setup-gcloud が入れた gcloud が `PATH` に入っているか。
- SA に読み取り権限があるか。
- このとき削除は 1 件も行われていないので、原因を直してから再実行すればよい。

**delete が途中で失敗したとき**:

- 削除は fail-fast なので、失敗した digest より後は手付かずのまま残る。
- どこまで消えたかは `gcloud artifacts docker images list gcr.io/$PROJECT_ID/rss-read-kun --include-tags` で確かめる。
- 原因（権限、index の子が参照されている、など）を直したら、失敗した workflow の run を「Re-run jobs」で再実行するか、`./scripts/cleanup_old_images.sh gcr.io/$PROJECT_ID/rss-read-kun <稼働中のタグ>` を手で実行してよい。同じ run の再実行なら、CURRENT_TAG は同じ SHA になる。
- ただし Re-run するのは、失敗した run が main の最新のコミットのときだけにする。そうでなければ、スクリプトを手で実行するか、次の push に任せる。
- スクリプトは冪等で、残っているものだけを削除するので、何度実行しても最終的にはデプロイした 1 件だけの状態になる。
- 次の main への push で自動的に片付けてもよい。

## (5) ロールバック

古いイメージは残らないので、`git revert` して main に push し、再ビルドする。

## (6) 今後の改善

- 認証を、SA キー（`secrets.GCP_KEY`）から Workload Identity Federation（WIF）に移行する。
- 代わりの案として、Artifact Registry のクリーンアップポリシーがある。今回は採らなかった。
  チケットが「デプロイが成功した後に workflow で削除する」ことを求めていることと、ポリシーはデプロイとは関係なく非同期に動くため、
  「デプロイした digest は必ず残す」「index なら削除しない」をリポジトリ内のテストで保証できないことが理由。

## (7) SA キーがイメージに入っていた可能性への対応（人間が判断）

- `google-github-actions/auth` は SA キーを `$GITHUB_WORKSPACE/gha-creds-*.json` に書き出す。`docker build ./` と `COPY . .` により、これがイメージに入る可能性があった。この PR で `.dockerignore` に `gha-creds-*.json` を追加して防ぐ。
- 旧構成（setup-gcloud の `service_account_key`）でも、キーがイメージに入っていた可能性が高い。
- マージ後の最初のデプロイで、古いイメージはすべて削除される。
- それでもキーが見えていた可能性は残るので、キーのローテーションを検討する。手順:
  1. `gcloud iam service-accounts keys create <new-key.json> --iam-account=<SA>`
  2. `secrets.GCP_KEY` を新しいキーの JSON に更新する。
  3. main へ push するなどして、デプロイが通ることを確かめる。
  4. `gcloud iam service-accounts keys list --iam-account=<SA> --managed-by=user` で古いキーの ID を調べ、`gcloud iam service-accounts keys delete <OLD_KEY_ID> --iam-account=<SA>` で削除する。
