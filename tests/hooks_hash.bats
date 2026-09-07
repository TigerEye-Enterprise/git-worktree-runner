#!/usr/bin/env bats
# Exercise actual executables and the public CLI with a controlled PATH.
load test_helper

setup() {
  setup_integration_repo
  export XDG_CONFIG_HOME="$TEST_REPO/xdg"
  source_gtr_libs
  HASH_BIN="$TEST_REPO/hash-bin"
  mkdir -p "$HASH_BIN"
  REAL_SHA256SUM=$(command -v sha256sum || true)
  REAL_SHASUM=$(command -v shasum || true)
  # Forward ordinary utilities while deliberately excluding both hash tools.
  local tool path
  for tool in bash env git dirname basename cat mkdir mktemp mv rm date awk sed tr cut grep sort head uname wc find tee readlink realpath cp xargs expr which; do
    path=$(command -v "$tool") || continue
    printf '#!/bin/bash\nexec %q "$@"\n' "$path" > "$HASH_BIN/$tool"
    chmod +x "$HASH_BIN/$tool"
  done
  git config -f .gtrconfig hooks.postCreate 'echo trusted-hook > hook-proof'
  git add .gtrconfig
  git commit -qm 'benign reviewed hook'
}

teardown() {
  teardown_integration_repo
}

install_real_hasher() {
  local name="$1" path
  if [ "$name" = shasum ]; then path="$REAL_SHASUM"; else path="$REAL_SHA256SUM"; fi
  [ -n "$path" ] || skip "$name is unavailable"
  printf '#!/bin/bash\nexec %q "$@"\n' "$path" > "$HASH_BIN/$name"
  chmod +x "$HASH_BIN/$name"
}

install_fault() {
  printf '#!/bin/bash\n%s\n' "$1" > "$HASH_BIN/shasum"
  chmod +x "$HASH_BIN/shasum"
}

public_trust() {
  PATH="$HASH_BIN" "$HASH_BIN/bash" "$PROJECT_ROOT/bin/git-gtr" trust <<< y
}

assert_no_grant() {
  [ "$status" -ne 0 ]
  [[ "$output" != *'marked as trusted'* ]]
  [[ "$output" == *'trust hash'* ]]
  [ ! -d "$_GTR_TRUST_DIR" ] || [ -z "$(find "$_GTR_TRUST_DIR" -type f -print)" ]
  # Conditional caller deliberately suppresses errexit.
  if PATH="$HASH_BIN" _hooks_are_trusted "$TEST_REPO/.gtrconfig"; then
    return 1
  fi
}

@test "public trust fails closed without SHA executables" {
  run public_trust
  assert_no_grant
}

@test "public trust rejects failing hasher even with valid-looking output" {
  install_fault 'printf "%064d  -\n" 0; exit 7'
  run public_trust
  assert_no_grant
}

@test "public trust rejects empty malformed and wrong-length digests" {
  local fault
  for fault in 'exit 0' 'echo malformed' 'printf "%063d  -\n" 0' 'printf "%065d  -\n" 0' 'printf "%064s  -\n" z'; do
    install_fault "$fault"
    run public_trust
    assert_no_grant
  done
}

@test "public trust fails when hashing breaks after marker write" {
  install_real_hasher sha256sum
  install_fault 'if [ -d "$XDG_CONFIG_HOME/gtr/trusted" ]; then exit 9; fi; exec sha256sum'
  run public_trust
  [ "$status" -ne 0 ]
  [[ "$output" == *'Failed to verify current executable commands'* ]]
  [[ "$output" != *'marked as trusted'* ]]
  [ -n "$(find "$_GTR_TRUST_DIR" -type f -print)" ]
  if PATH="$HASH_BIN" _hooks_are_trusted "$TEST_REPO/.gtrconfig"; then return 1; fi

  # Approval survives a transient verification failure once hashing recovers.
  install_fault 'exec sha256sum'
  PATH="$HASH_BIN" _hooks_are_trusted "$TEST_REPO/.gtrconfig"
  run public_trust
  [ "$status" -eq 0 ]
  [[ "$output" == *'are already trusted'* ]]
  [[ "$output" != *'marked as trusted'* ]]
}

@test "sha256sum fallback preserves trust keys and public worktree hooks" {
  install_real_hasher sha256sum
  local content expected_hash expected_key repo_root marker second_repo
  content=$(_hooks_read_definitions "$TEST_REPO/.gtrconfig")
  expected_hash=$(printf '%s\n' "$content" | "$REAL_SHA256SUM" | cut -d' ' -f1)
  repo_root=$(_hooks_repo_root "$TEST_REPO/.gtrconfig")
  expected_key=$(printf '%s\n%s\n' "$repo_root" "$expected_hash" | "$REAL_SHA256SUM" | cut -d' ' -f1)
  [ "$(PATH="$HASH_BIN" _hooks_current_trust_key "$TEST_REPO/.gtrconfig")" = "$expected_key" ]
  run public_trust
  [ "$status" -eq 0 ]
  [[ "$output" == *'marked as trusted'* ]]
  marker="$_GTR_TRUST_DIR/$expected_key"
  [ -s "$marker" ]
  PATH="$HASH_BIN" _hooks_are_trusted "$TEST_REPO/.gtrconfig"
  run env PATH="$HASH_BIN" bash "$PROJECT_ROOT/bin/git-gtr" new hash-smoke --from HEAD --no-fetch --no-copy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$TEST_WORKTREES_DIR/hash-smoke/hook-proof")" = trusted-hook ]
  second_repo="$TEST_REPO/other"
  mkdir -p "$second_repo"
  cp .gtrconfig "$second_repo/.gtrconfig"
  if PATH="$HASH_BIN" _hooks_are_trusted "$second_repo/.gtrconfig"; then return 1; fi
  git config -f .gtrconfig hooks.postCreate 'echo changed'
  if PATH="$HASH_BIN" _hooks_are_trusted "$TEST_REPO/.gtrconfig"; then return 1; fi
}

@test "shasum preserves legacy content and identity bytes" {
  install_real_hasher shasum
  local content expected_hash expected_key repo_root
  content=$(_hooks_read_definitions "$TEST_REPO/.gtrconfig")
  expected_hash=$(printf '%s\n' "$content" | "$REAL_SHASUM" -a 256 | cut -d' ' -f1)
  repo_root=$(_hooks_repo_root "$TEST_REPO/.gtrconfig")
  expected_key=$(printf '%s\n%s\n' "$repo_root" "$expected_hash" | "$REAL_SHASUM" -a 256 | cut -d' ' -f1)
  [ "$(PATH="$HASH_BIN" _hooks_content_hash "$content")" = "$expected_hash" ]
  [ "$(PATH="$HASH_BIN" _hooks_current_trust_key "$TEST_REPO/.gtrconfig")" = "$expected_key" ]
}
