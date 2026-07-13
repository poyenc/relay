#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/subcommands.sh

work="$(mktemp -d)"
sl="$work/statusline.sh"

# a user's existing statusline script that reads the JSON and prints a field
cat > "$sl" <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
echo "ctx=$(printf '%s' "$input" | jq -r '.context_window.used_percentage')"
EOF
chmod +x "$sl"

# --- install ---
relay_cmd_install_statusline "$sl" >/dev/null 2>&1
assert_eq "$?" "0" "install succeeds"
assert_contains "$(cat "$sl")" "relay statusline tee" "sentinel inserted"
assert_file_exists "$sl.relay-bak" "backup written"
# exec bit preserved
[ -x "$sl" ] && assert_ok "exec bit preserved" || assert_eq exec noexec "should stay executable"
# shebang still first line
assert_eq "$(head -1 "$sl")" "#!/usr/bin/env bash" "shebang still first"

# --- behavior: with RELAY_STATE set, JSON is teed AND body still runs ---
state="$work/statusline.json"
out="$(RELAY_STATE="$state" bash "$sl" <<<'{"context_window":{"used_percentage":55.5}}')"
assert_contains "$out" "ctx=55.5" "user body still runs after tee"
assert_file_exists "$state" "RELAY_STATE written"
assert_eq "$(jq -r '.context_window.used_percentage' "$state")" "55.5" "teed JSON correct"

# --- behavior: without RELAY_STATE (plain claude), transparent no-op ---
out="$(unset RELAY_STATE; bash "$sl" <<<'{"context_window":{"used_percentage":12.3}}')"
assert_contains "$out" "ctx=12.3" "plain run unaffected"

# --- idempotency: second install does not double-insert ---
relay_cmd_install_statusline "$sl" >/dev/null 2>&1
assert_eq "$(grep -c 'relay statusline tee' "$sl")" "1" "tee inserted exactly once"

# --- missing file errors ---
if relay_cmd_install_statusline "$work/nope.sh" >/dev/null 2>&1; then assert_eq bad ok "missing file should error"; else assert_ok "missing file rejected"; fi

# --- no-shebang file: insert at top, still works ---
sl2="$work/plain.sh"
printf 'input="$(cat)"\necho "got=$input"\n' > "$sl2"
relay_cmd_install_statusline "$sl2" >/dev/null 2>&1
assert_contains "$(cat "$sl2")" "relay statusline tee" "sentinel inserted (no shebang)"
out="$(RELAY_STATE="$work/s2.json" bash "$sl2" <<<'{"a":1}')"
assert_contains "$out" 'got={"a":1}' "no-shebang body still runs"
assert_file_exists "$work/s2.json" "no-shebang tee wrote state"

# --- byte-identity: input with multiple trailing newlines is re-fed unchanged ---
sl3="$work/bytes.sh"
cat > "$sl3" <<'EOF'
#!/usr/bin/env bash
cat > "$BODY_OUT"
EOF
relay_cmd_install_statusline "$sl3" >/dev/null 2>&1
in="$work/in.bin"; bodyout="$work/body.bin"
printf 'line1\nline2\n\n\n' > "$in"          # 2 extra trailing newlines
BODY_OUT="$bodyout" RELAY_STATE="$work/s3.json" bash "$sl3" < "$in"
assert_eq "$(cksum < "$bodyout")" "$(cksum < "$in")" "re-fed stdin is byte-identical (trailing newlines preserved)"
assert_eq "$(cksum < "$work/s3.json")" "$(cksum < "$in")" "teed state is byte-identical to input"

rm -rf "$work"
finish
