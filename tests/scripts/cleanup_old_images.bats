#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../scripts" && pwd)"
TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"
IMAGE="gcr.io/test-proj/rss-read-kun"

setup() {
  D1="sha256:$(printf '1%.0s' $(seq 64))"
  D2="sha256:$(printf '2%.0s' $(seq 64))"
  D3="sha256:$(printf '3%.0s' $(seq 64))"
  D4="sha256:$(printf '4%.0s' $(seq 64))"
  D5="sha256:$(printf '5%.0s' $(seq 64))"
  U0="sha256:$(printf '0%.0s' $(seq 64))"
  DA="sha256:$(printf 'a%.0s' $(seq 64))"
  DB="sha256:$(printf 'b%.0s' $(seq 64))"
  DC="sha256:$(printf 'c%.0s' $(seq 64))"
  # shellcheck source=../../scripts/cleanup_old_images.sh
  source "$SCRIPT_DIR/cleanup_old_images.sh"
}

# fx '<jq filter>' : five_tagged.json に jq フィルタを適用して $INPUT に書き出す
fx() {
  INPUT="$BATS_TEST_TMPDIR/input.json"
  jq -c "$1" "$FIXTURES/five_tagged.json" > "$INPUT"
}

# fx_args --arg k v ... '<jq filter>' : 引数付きの fx
fx_args() {
  INPUT="$BATS_TEST_TMPDIR/input.json"
  jq -c "$@" "$FIXTURES/five_tagged.json" > "$INPUT"
}

# ---------------------------------------------------------------------------
# A. select_digests_to_delete / find_current_digest
# ---------------------------------------------------------------------------

@test "T1: should output every digest except the deployed one when five tagged images exist" {
  # Given
  fx '.'
  # When
  run --separate-stderr select_digests_to_delete sha5 < "$INPUT"
  # Then
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s\n%s\n%s' "$D1" "$D2" "$D3" "$D4")" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "T2: should output the same result when the input order differs" {
  # Given
  fx '[.[2], .[4], .[0], .[3], .[1]]'
  # When
  run --separate-stderr select_digests_to_delete sha5 < "$INPUT"
  # Then
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s\n%s\n%s' "$D1" "$D2" "$D3" "$D4")" ]
}

@test "T3: should protect the deployed digest when tags are comma separated and current is first" {
  # Given
  fx '.[4].tags = "sha5, latest"'
  # When
  run --separate-stderr select_digests_to_delete sha5 < "$INPUT"
  # Then
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s\n%s\n%s' "$D1" "$D2" "$D3" "$D4")" ]
}

@test "T4: should keep only the oldest when it is the deployed one" {
  # Given
  fx '.'
  # When
  run --separate-stderr select_digests_to_delete sha1 < "$INPUT"
  # Then
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s\n%s\n%s' "$D2" "$D3" "$D4" "$D5")" ]
}

@test "T5: should include untagged images and output them after tagged ones" {
  # Given
  fx_args --arg u0 "$U0" '.[0].tags = "" | .[1].tags = [] | . + [{"version": $u0, "createTime": "2026-09-01T00:00:00Z"}]'
  # When
  run --separate-stderr select_digests_to_delete sha5 < "$INPUT"
  # Then
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s\n%s\n%s\n%s' "$D3" "$D4" "$U0" "$D1" "$D2")" ]
}

@test "T7: should output nothing when only the deployed image exists" {
  # Given
  fx '[.[4]]'
  # When
  run --separate-stderr select_digests_to_delete sha5 < "$INPUT"
  # Then
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "T8: should fail with CURRENT_TAG not found when the list is empty" {
  # Given
  echo '[]' > "$BATS_TEST_TMPDIR/input.json"
  # When
  run --separate-stderr select_digests_to_delete sha5 < "$BATS_TEST_TMPDIR/input.json"
  # Then
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"CURRENT_TAG sha5 not found"* ]]
}

@test "T11: should order output by digest ascending regardless of createTime" {
  # Given
  jq -n --arg a "$DA" --arg b "$DB" --arg c "$DC" '[
    {version: $b, tags: "t1", createTime: "2026-10-01T00:00:00Z"},
    {version: $a, tags: "t2", createTime: "2026-10-03T00:00:00Z"},
    {version: $c, tags: "t3", createTime: "2026-10-02T00:00:00Z"}]' > "$BATS_TEST_TMPDIR/input.json"
  # When
  run --separate-stderr select_digests_to_delete t3 < "$BATS_TEST_TMPDIR/input.json"
  # Then
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s' "$DA" "$DB")" ]
}

@test "T12: should fail with CURRENT_TAG not found when the tag is absent" {
  # Given
  fx '.'
  # When
  run --separate-stderr select_digests_to_delete sha-unknown < "$INPUT"
  # Then
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"CURRENT_TAG sha-unknown not found"* ]]
}

@test "T13: should fail when the input is not JSON" {
  # Given
  echo 'not-json' > "$BATS_TEST_TMPDIR/input.json"
  # When
  run --separate-stderr select_digests_to_delete sha5 < "$BATS_TEST_TMPDIR/input.json"
  # Then
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "T32: should protect current tag found as a non-first tag after trimming spaces" {
  # Given
  fx '.[0].tags = "latest, sha1"'
  # When
  run --separate-stderr select_digests_to_delete sha1 < "$INPUT"
  # Then
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s\n%s\n%s' "$D2" "$D3" "$D4" "$D5")" ]
}

@test "T33: should give the same result when tags are JSON arrays" {
  # Given
  fx 'map(.tags |= [.]) | .[0].tags = ["latest", "sha1"]'
  # When
  run --separate-stderr select_digests_to_delete sha1 < "$INPUT"
  # Then
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s\n%s\n%s' "$D2" "$D3" "$D4" "$D5")" ]
}

@test "T34: should match tags exactly and not by prefix" {
  # Given
  fx '.[4].tags = "sha55"'
  # When
  run --separate-stderr select_digests_to_delete sha5 < "$INPUT"
  # Then
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"CURRENT_TAG sha5 not found"* ]]
}

@test "T38: should return the digest carrying CURRENT_TAG" {
  # Given
  fx '.[4].tags = "latest, sha5"'
  # When
  run --separate-stderr find_current_digest sha5 < "$INPUT"
  # Then
  [ "$status" -eq 0 ]
  [ "$output" = "$D5" ]
}

# ---------------------------------------------------------------------------
# P1〜P5: select_digests_to_delete の不変条件（ランダムなフィクスチャを 50 パターン）
# ---------------------------------------------------------------------------

# gen_random_fixture : $INPUT（一覧 JSON）、$ALL（全 digest）、$TAGGED（タグ付きの digest）、
# $CURRENT_TAG、$CURRENT_DIGEST を作る。件数・tags の形式・CURRENT はランダム。
gen_random_fixture() {
  local n i kind items="" cur_idx tags_json
  n=$((RANDOM % 20 + 1))
  cur_idx=$((RANDOM % n))
  : > "$BATS_TEST_TMPDIR/tagged.txt"
  : > "$BATS_TEST_TMPDIR/all.txt"
  for i in $(seq 0 $((n - 1))); do
    local digest
    digest="$(printf 'sha256:%016x%016x%016x%016x' "$((i + 1))" "$RANDOM" "$RANDOM" "$RANDOM")"
    echo "$digest" >> "$BATS_TEST_TMPDIR/all.txt"
    if [ "$i" -eq "$cur_idx" ]; then
      kind=$((RANDOM % 2)) # CURRENT は必ずタグ付き（文字列 / 配列）
    else
      kind=$((RANDOM % 5))
    fi
    case "$kind" in
      0) tags_json="\"t$i\"" ;;
      1) tags_json="[\"x$i\",\"t$i\"]" ;;
      2) tags_json="\"latest$i, t$i\"" ;;
      3) tags_json='""' ;;
      4) tags_json='MISSING' ;;
    esac
    if [ "$kind" -le 2 ]; then
      echo "$digest" >> "$BATS_TEST_TMPDIR/tagged.txt"
    fi
    if [ "$tags_json" = "MISSING" ]; then
      items="$items{\"version\":\"$digest\",\"createTime\":\"2026-10-01T00:00:00Z\"},"
    else
      items="$items{\"version\":\"$digest\",\"tags\":$tags_json,\"createTime\":\"2026-10-01T00:00:00Z\"},"
    fi
  done
  INPUT="$BATS_TEST_TMPDIR/random.json"
  echo "[${items%,}]" > "$INPUT"
  CURRENT_TAG="t$cur_idx"
  CURRENT_DIGEST="$(sed -n "$((cur_idx + 1))p" "$BATS_TEST_TMPDIR/all.txt")"
  ALL="$BATS_TEST_TMPDIR/all.txt"
  TAGGED="$BATS_TEST_TMPDIR/tagged.txt"
}

@test "P1-P5: should hold selection invariants for 50 random fixtures" {
  local seed="${PBT_SEED:-$RANDOM}"
  echo "# PBT seed: $seed (PBT_SEED=$seed で再現)" >&3
  RANDOM=$seed
  local iter
  for iter in $(seq 50); do
    # Given
    gen_random_fixture
    # When
    local out
    out="$(select_digests_to_delete "$CURRENT_TAG" < "$INPUT")" || {
      echo "iteration $iter failed (seed $seed): $(cat "$INPUT")" >&2
      return 1
    }
    printf '%s\n' "$out" | sed '/^$/d' > "$BATS_TEST_TMPDIR/out.txt"
    # Then
    # P1: 出力の集合 == 全 digest - CURRENT
    [ "$(sort "$BATS_TEST_TMPDIR/out.txt")" = "$(grep -vx "$CURRENT_DIGEST" "$ALL" | sort)" ]
    # P2: CURRENT は出力に含まれない
    if grep -qx "$CURRENT_DIGEST" "$BATS_TEST_TMPDIR/out.txt"; then
      echo "P2 violated (seed $seed)" >&2
      return 1
    fi
    # P3: 入力件数 - 出力件数 == 1
    [ "$(( $(wc -l < "$ALL") - $(wc -l < "$BATS_TEST_TMPDIR/out.txt") ))" -eq 1 ]
    # P4: タグなしがタグ付きより先に出ない
    local seen_untagged=0 d
    while IFS= read -r d; do
      if grep -qx "$d" "$TAGGED"; then
        [ "$seen_untagged" -eq 0 ]
      else
        seen_untagged=1
      fi
    done < "$BATS_TEST_TMPDIR/out.txt"
    # P5: 出力を除いた入力で再度選んでも、追加の削除対象は出ない
    jq -c --rawfile out "$BATS_TEST_TMPDIR/out.txt" \
      '($out | split("\n")) as $del | map(select(.version as $v | $del | index($v) | not))' \
      "$INPUT" > "$BATS_TEST_TMPDIR/after.json"
    [ -z "$(select_digests_to_delete "$CURRENT_TAG" < "$BATS_TEST_TMPDIR/after.json")" ]
  done
}

# ---------------------------------------------------------------------------
# B. エントリポイント scripts/cleanup_old_images.sh（gcloud / docker はスタブ）
# ---------------------------------------------------------------------------

# stub_env : スタブを PATH の先頭に置き、呼び出しログと既定のフィクスチャを用意する
stub_env() {
  export PATH="$TESTS_DIR/helpers:$PATH"
  export GCLOUD_CALLS_LOG="$BATS_TEST_TMPDIR/gcloud.log"
  export DOCKER_CALLS_LOG="$BATS_TEST_TMPDIR/docker.log"
  : > "$GCLOUD_CALLS_LOG"
  : > "$DOCKER_CALLS_LOG"
  export GCLOUD_LIST_FIXTURE="$FIXTURES/five_tagged.json"
  export DOCKER_MANIFEST_FIXTURE="$FIXTURES/manifest_docker_v2.json"
  unset GCLOUD_LIST_EXIT GCLOUD_DELETE_FAIL_DIGEST DOCKER_INSPECT_EXIT
}

run_cleanup() {
  run --separate-stderr "$SCRIPT_DIR/cleanup_old_images.sh" "$@"
}

# delete の呼び出し行だけを抜き出す
delete_calls() { grep '^artifacts docker images delete' "$GCLOUD_CALLS_LOG" || true; }

# list フィクスチャを five_tagged.json から jq で作る
use_list() {
  GCLOUD_LIST_FIXTURE="$BATS_TEST_TMPDIR/list.json"
  jq -c "$1" "$FIXTURES/five_tagged.json" > "$GCLOUD_LIST_FIXTURE"
  export GCLOUD_LIST_FIXTURE
}

use_list_args() {
  GCLOUD_LIST_FIXTURE="$BATS_TEST_TMPDIR/list.json"
  jq -c "$@" "$FIXTURES/five_tagged.json" > "$GCLOUD_LIST_FIXTURE"
  export GCLOUD_LIST_FIXTURE
}

expected_deletes() {
  local d
  for d in "$@"; do
    echo "artifacts docker images delete $IMAGE@$d --delete-tags --quiet"
  done
}

@test "T19: should print usage and exit 1 when argument count is not 2" {
  stub_env
  local args
  for args in "" "$IMAGE" "$IMAGE 3 sha5"; do
    # Given: 引数の数が 2 でない
    : > "$GCLOUD_CALLS_LOG"; : > "$DOCKER_CALLS_LOG"
    # When
    # shellcheck disable=SC2086
    run_cleanup $args
    # Then
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Usage: cleanup_old_images.sh IMAGE CURRENT_TAG"* ]]
    [ ! -s "$GCLOUD_CALLS_LOG" ]
    [ ! -s "$DOCKER_CALLS_LOG" ]
  done
}

@test "T14: should call images list exactly once with the expected arguments" {
  # Given
  stub_env
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$GCLOUD_CALLS_LOG")" = "artifacts docker images list $IMAGE --include-tags --format=json" ]
  [ "$(grep -c '^artifacts docker images list' "$GCLOUD_CALLS_LOG")" -eq 1 ]
}

@test "T15: should delete every digest except the deployed one in order" {
  # Given
  stub_env
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -eq 0 ]
  [ "$(sed -n '2,$p' "$GCLOUD_CALLS_LOG")" = "$(expected_deletes "$D1" "$D2" "$D3" "$D4")" ]
}

@test "T17: should exit 0 with a message when there is nothing to delete" {
  # Given
  stub_env
  use_list '[.[4]]'
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -eq 0 ]
  [ -z "$(delete_calls)" ]
  [[ "$output" == *"No images to delete"* ]]
}

@test "T20: should not delete when listing fails" {
  # Given
  stub_env
  export GCLOUD_LIST_EXIT=1
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -ne 0 ]
  [ -z "$(delete_calls)" ]
  [ ! -s "$DOCKER_CALLS_LOG" ]
}

@test "T22: should not delete when CURRENT_TAG is not in the list" {
  # Given
  stub_env
  # When
  run_cleanup "$IMAGE" sha-unknown
  # Then
  [ "$status" -ne 0 ]
  [ -z "$(delete_calls)" ]
  [ ! -s "$DOCKER_CALLS_LOG" ]
  [[ "$stderr" == *"CURRENT_TAG sha-unknown not found"* ]]
}

@test "T35: should reject an empty digest before any delete call" {
  # Given
  stub_env
  use_list '.[0].version = ""'
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -ne 0 ]
  [ -z "$(delete_calls)" ]
  [[ "$stderr" == *"invalid digest"* ]]
}

@test "T36: should not delete the first image when the second digest is malformed" {
  # Given
  stub_env
  use_list '.[1].version = "latest"'
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -ne 0 ]
  [ -z "$(delete_calls)" ]
  [[ "$stderr" == *"invalid digest: latest"* ]]
}

@test "T37: should reject look-alike digests" {
  stub_env
  local bad
  for bad in "sha256:$(printf 'A%.0s' $(seq 64))" "sha256:$(printf '1%.0s' $(seq 63))" "$(printf '1%.0s' $(seq 64))"; do
    # Given
    : > "$GCLOUD_CALLS_LOG"
    use_list ".[0].version = \"$bad\""
    # When
    run_cleanup "$IMAGE" sha5
    # Then
    [ "$status" -ne 0 ]
    [ -z "$(delete_calls)" ]
  done
}

@test "T39: should inspect the deployed manifest once before deleting" {
  # Given
  stub_env
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_CALLS_LOG")" = "buildx imagetools inspect --raw $IMAGE@$D5" ]
  [ "$(delete_calls)" = "$(expected_deletes "$D1" "$D2" "$D3" "$D4")" ]
}

@test "T40: should proceed to delete when the manifest is an OCI image manifest" {
  # Given
  stub_env
  export DOCKER_MANIFEST_FIXTURE="$FIXTURES/manifest_oci.json"
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -eq 0 ]
  [ "$(delete_calls)" = "$(expected_deletes "$D1" "$D2" "$D3" "$D4")" ]
}

@test "T41: should refuse to delete when the deployed digest is an OCI image index" {
  # Given
  stub_env
  export DOCKER_MANIFEST_FIXTURE="$FIXTURES/index_oci.json"
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -eq 1 ]
  [ -z "$(delete_calls)" ]
  [[ "$stderr" == *"is an image index"* ]]
}

@test "T42: should refuse to delete when the deployed digest is a Docker manifest list" {
  # Given
  stub_env
  export DOCKER_MANIFEST_FIXTURE="$FIXTURES/manifest_list_docker.json"
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -eq 1 ]
  [ -z "$(delete_calls)" ]
  [[ "$stderr" == *"is an image index"* ]]
}

@test "T43: should refuse to delete when the manifest has no mediaType" {
  # Given
  stub_env
  export DOCKER_MANIFEST_FIXTURE="$FIXTURES/manifest_no_media_type.json"
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -eq 1 ]
  [ -z "$(delete_calls)" ]
  [[ "$stderr" == *"unsupported manifest mediaType"* ]]
}

@test "T44: should not delete when fetching the manifest fails" {
  # Given
  stub_env
  export DOCKER_INSPECT_EXIT=1
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -ne 0 ]
  [ -z "$(delete_calls)" ]
}

@test "T21: should stop at the first failed delete" {
  # Given
  stub_env
  export GCLOUD_DELETE_FAIL_DIGEST="$D1"
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -ne 0 ]
  [ "$(delete_calls)" = "$(expected_deletes "$D1")" ]
}

@test "T45: should delete tagged images before untagged ones" {
  # Given
  stub_env
  use_list_args --arg u0 "$U0" '.[0].tags = "" | .[1].tags = [] | . + [{"version": $u0, "createTime": "2026-09-01T00:00:00Z"}]'
  # When
  run_cleanup "$IMAGE" sha5
  # Then
  [ "$status" -eq 0 ]
  [ "$(delete_calls)" = "$(expected_deletes "$D3" "$D4" "$U0" "$D1" "$D2")" ]
}

# ---------------------------------------------------------------------------
# P6 / P7
# ---------------------------------------------------------------------------

@test "P6: every delete call should be IMAGE@sha256:<64 hex> (full run and mid-run failure)" {
  stub_env
  local mode
  for mode in full fail; do
    # Given
    : > "$GCLOUD_CALLS_LOG"
    unset GCLOUD_DELETE_FAIL_DIGEST
    [ "$mode" = fail ] && export GCLOUD_DELETE_FAIL_DIGEST="$D3"
    # When
    run_cleanup "$IMAGE" sha5
    # Then
    [ -n "$(delete_calls)" ]
    local line
    while IFS= read -r line; do
      [[ "$line" =~ ^artifacts\ docker\ images\ delete\ gcr\.io/test-proj/rss-read-kun@sha256:[0-9a-f]{64}\ --delete-tags\ --quiet$ ]]
    done <<<"$(delete_calls)"
  done
}

@test "P7: should never delete unless the deployed manifest is a single manifest" {
  stub_env
  local fixture
  for fixture in index_oci.json manifest_list_docker.json manifest_no_media_type.json; do
    # Given
    : > "$GCLOUD_CALLS_LOG"
    export DOCKER_MANIFEST_FIXTURE="$FIXTURES/$fixture"
    # When
    run_cleanup "$IMAGE" sha5
    # Then
    [ "$status" -ne 0 ]
    [ -z "$(delete_calls)" ]
  done
  # 取得失敗
  : > "$GCLOUD_CALLS_LOG"
  export DOCKER_MANIFEST_FIXTURE="$FIXTURES/manifest_docker_v2.json" DOCKER_INSPECT_EXIT=1
  run_cleanup "$IMAGE" sha5
  [ "$status" -ne 0 ]
  [ -z "$(delete_calls)" ]
}

# ---------------------------------------------------------------------------
# C. 静的検証
# ---------------------------------------------------------------------------

@test "T48: should exclude auth action credentials from the docker build context" {
  # Given
  local dockerignore="$TESTS_DIR/../../.dockerignore"
  # When
  run grep -qxF 'gha-creds-*.json' "$dockerignore"
  # Then
  [ "$status" -eq 0 ]
}
