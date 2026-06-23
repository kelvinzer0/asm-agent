#!/bin/bash
# ============================================================================
# run_tests.sh — Live API integration tests for asm-agent
# ============================================================================
# Requires ASM_AGENT_API_KEY in environment (set by CI secret or manually).
# Runs the real binary against the real API, verifies agentic loop works.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="/tmp/asm_ci_test_$$"
OUTPUT_DIR="/tmp/asm_ci_output_$$"

PASS=0
FAIL=0

# --- Cleanup ---
cleanup() {
  rm -rf "$TEST_DIR" "$OUTPUT_DIR"
  rm -f /tmp/.asm_agent_payload.json
  rm -f /tmp/.asm_agent_response.json
}
trap cleanup EXIT

# --- Helpers ---
assert_contains() {
  local file="$1" pattern="$2" desc="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (pattern '$pattern' not found in $file)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local actual="$1" expected="$2" desc="$3"
  if [ "$actual" -eq "$expected" ]; then
    echo "  PASS: $desc (exit $actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected exit $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exists() {
  local file="$1" desc="$2"
  if [ -f "$file" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc ($file not found)"
    FAIL=$((FAIL + 1))
  fi
}

# ==========================================================================
echo "=========================================="
echo " ASM-AGENT Live Integration Tests"
echo "=========================================="
echo ""

# --- Pre-flight: check API key ---
if [ -z "${ASM_AGENT_API_KEY:-}" ]; then
  echo "SKIP: ASM_AGENT_API_KEY not set, skipping live tests"
  echo "  (This is normal if the GitHub secret is not configured yet)"
  exit 0
fi

# ==========================================================================
# TEST 1: Binary structure
# ==========================================================================
echo "--- Test 1: Binary structure ---"

assert_exists "$PROJECT_DIR/asm-agent" "Binary exists"

if file "$PROJECT_DIR/asm-agent" | grep -q "ELF 64-bit"; then
  echo "  PASS: Valid ELF 64-bit binary"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Not a valid ELF 64-bit binary"
  FAIL=$((FAIL + 1))
fi

SIZE=$(stat -c %s "$PROJECT_DIR/asm-agent")
if [ "$SIZE" -gt 50000 ] && [ "$SIZE" -lt 500000 ]; then
  echo "  PASS: Binary size reasonable ($SIZE bytes)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Binary size unexpected ($SIZE bytes)"
  FAIL=$((FAIL + 1))
fi

echo ""

# ==========================================================================
# TEST 2: Full agentic loop via live API
# ==========================================================================
echo "--- Test 2: Agentic loop (live API, create file task) ---"

mkdir -p "$TEST_DIR" "$OUTPUT_DIR"

# Clean worklog for fresh test
rm -f "$PROJECT_DIR/WORKLOG.md"

# Run the binary with a simple task
cd "$PROJECT_DIR"
timeout 180 ./asm-agent "Create a file at ${OUTPUT_DIR}/hello.txt with the text 'hello from asm-agent'" \
  > "$TEST_DIR/agent_stdout.log" 2>&1 || true
EXIT_CODE=$?

echo "  Agent exit code: $EXIT_CODE"

# Check response dump
assert_exists "/tmp/.asm_agent_response.json" "API response dump created"

# Check worklog was created
assert_exists "$PROJECT_DIR/WORKLOG.md" "Worklog created"

if [ -f "$PROJECT_DIR/WORKLOG.md" ]; then
  assert_contains "$PROJECT_DIR/WORKLOG.md" "TASK STARTED" "Worklog: task started"
  assert_contains "$PROJECT_DIR/WORKLOG.md" "EXEC" "Worklog: command executed"
  assert_contains "$PROJECT_DIR/WORKLOG.md" "DONE" "Worklog: task completed"
fi

# Check target file was created
assert_exists "$OUTPUT_DIR/hello.txt" "Target file created by agent"

if [ -f "$OUTPUT_DIR/hello.txt" ]; then
  assert_contains "$OUTPUT_DIR/hello.txt" "hello" "File content contains expected text"
  echo "  File content:"
  cat "$OUTPUT_DIR/hello.txt" | sed 's/^/    /'
fi

# Check stdout for signs of life
if [ -f "$TEST_DIR/agent_stdout.log" ]; then
  STDOUT_SIZE=$(stat -c %s "$TEST_DIR/agent_stdout.log")
  if [ "$STDOUT_SIZE" -gt 0 ]; then
    echo "  PASS: Agent produced stdout ($STDOUT_SIZE bytes)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: Agent produced no stdout"
    FAIL=$((FAIL + 1))
  fi
fi

echo ""

# ==========================================================================
echo "=========================================="
echo " Results: $PASS passed, $FAIL failed"
echo "=========================================="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1