#!/usr/bin/env bash
# デプロイしたイメージ（CURRENT_TAG の digest）以外を Artifact Registry から削除する。
# Usage: cleanup_old_images.sh IMAGE CURRENT_TAG
#
# bash 3.2（macOS 標準）でも動くように書く。
# 関数は source してテストできるよう、set -euo pipefail は main の実行時にだけ有効にする。

# タグを正規化し、tagList（文字列の配列）を各要素に付ける jq 式。
# tags は ", " 区切りの文字列 / JSON 配列 / 空文字 / null（キーなし）のいずれか。
readonly NORMALIZE_TAGS='map(. + {tagList: (
  .tags
  | if type == "array" then .
    elif . == null or . == "" then []
    else split(",") end
  | map(gsub("^\\s+|\\s+$"; ""))
  | map(select(. != ""))
)})'

# find_current_digest CURRENT_TAG
# 標準入力の一覧 JSON から、CURRENT_TAG（完全一致）が付いた digest を出力する。
find_current_digest() {
  local tag="$1" json digest
  json="$(cat)" || return 1
  digest="$(jq -r --arg tag "$tag" "
    $NORMALIZE_TAGS
    | map(select(.tagList | any(. == \$tag)))
    | (first // empty) | .version" <<<"$json")" || return 1
  if [ -z "$digest" ]; then
    echo "CURRENT_TAG $tag not found" >&2
    return 1
  fi
  printf '%s\n' "$digest"
}

# select_digests_to_delete CURRENT_TAG
# 標準入力の一覧 JSON から、削除する digest を「タグ付き → タグなし、それぞれ昇順」で出力する。
select_digests_to_delete() {
  local tag="$1" json current
  json="$(cat)" || return 1
  current="$(find_current_digest "$tag" <<<"$json")" || return 1
  jq -r --arg current "$current" "
    $NORMALIZE_TAGS
    | map(select(.version != \$current))
    | sort_by([(.tagList | length == 0), .version])
    | .[].version" <<<"$json"
}

# assert_valid_digests
# 標準入力の各行が sha256:<64 桁の 16 進数> でなければ異常終了する。
assert_valid_digests() {
  local digest
  while IFS= read -r digest; do
    if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "invalid digest: $digest" >&2
      return 1
    fi
  done
}

# assert_single_manifest REF
# 標準入力の manifest JSON が単一の manifest（許可リスト）でなければ異常終了する。
assert_single_manifest() {
  local ref="$1" media_type
  media_type="$(jq -r '.mediaType // empty')" || return 1
  case "$media_type" in
    application/vnd.docker.distribution.manifest.v2+json | application/vnd.oci.image.manifest.v1+json)
      return 0
      ;;
    application/vnd.oci.image.index.v1+json | application/vnd.docker.distribution.manifest.list.v2+json)
      echo "$ref is an image index ($media_type); refusing to delete" >&2
      return 1
      ;;
    *)
      echo "unsupported manifest mediaType: $media_type" >&2
      return 1
      ;;
  esac
}

main() {
  if [ "$#" -ne 2 ]; then
    echo "Usage: cleanup_old_images.sh IMAGE CURRENT_TAG" >&2
    return 1
  fi
  local image="$1" tag="$2" list current digests manifest digest

  list="$(gcloud artifacts docker images list "$image" --include-tags --format=json)"
  current="$(find_current_digest "$tag" <<<"$list")"
  digests="$(select_digests_to_delete "$tag" <<<"$list")"

  if [ -z "$digests" ]; then
    echo "No images to delete"
    return 0
  fi

  assert_valid_digests <<<"$digests"

  manifest="$(docker buildx imagetools inspect --raw "$image@$current")"
  assert_single_manifest "$image@$current" <<<"$manifest"

  while IFS= read -r digest; do
    gcloud artifacts docker images delete "$image@$digest" --delete-tags --quiet
  done <<<"$digests"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  main "$@"
fi
