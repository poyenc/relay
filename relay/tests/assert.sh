#!/usr/bin/env bash
# Tiny assert helper. Source this; call finish at end.
_A_PASS=0; _A_FAIL=0
assert_eq() { if [ "$1" = "$2" ]; then _A_PASS=$((_A_PASS+1));
  else _A_FAIL=$((_A_FAIL+1)); echo "FAIL: $3 (got='$1' want='$2')"; fi; }
assert_contains() { if printf '%s' "$1" | grep -qF -- "$2"; then _A_PASS=$((_A_PASS+1));
  else _A_FAIL=$((_A_FAIL+1)); echo "FAIL: $3 (missing '$2' in '$1')"; fi; }
assert_file_exists() { if [ -e "$1" ]; then _A_PASS=$((_A_PASS+1));
  else _A_FAIL=$((_A_FAIL+1)); echo "FAIL: $2 (no file $1)"; fi; }
assert_file_absent() { if [ ! -e "$1" ]; then _A_PASS=$((_A_PASS+1));
  else _A_FAIL=$((_A_FAIL+1)); echo "FAIL: $2 (file exists $1)"; fi; }
finish() { echo "--- $_A_PASS passed, $_A_FAIL failed ---"; [ "$_A_FAIL" -eq 0 ]; }
