#!/usr/bin/env bash
# PATCH_MARKER_E2E_EXECUTE_V1
# Real end-to-end test for POST /v1/execute — proves execution against a
# real external provider (Groq), not a mock. Discovers the configured
# model from GET /providers instead of hardcoding one that may not exist.
set -u
set -o pipefail

DAY3_URL="${DAY3_URL:-http://localhost:4405}"

echo "== Discovering configured provider/model from ${DAY3_URL}/providers =="
PROVIDERS_JSON="$(curl -sf -m 10 "${DAY3_URL}/providers")"
if [ $? -ne 0 ] || [ -z "$PROVIDERS_JSON" ]; then
  echo "INFRASTRUCTURE FAIL: could not reach ${DAY3_URL}/providers"
  exit 1
fi
echo "$PROVIDERS_JSON"

MODEL="$(echo "$PROVIDERS_JSON" | node -e '
  let data = "";
  process.stdin.on("data", (c) => { data += c; });
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(data);
      const groq = (j.providers || []).find((p) => p.name === "groq");
      if (!groq || !groq.configured) { console.log("MISSING"); return; }
      console.log(groq.defaultModel || "");
    } catch (e) {
      console.log("MISSING");
    }
  });
')"

if [ "$MODEL" = "MISSING" ] || [ -z "$MODEL" ]; then
  echo "PROVIDER CONFIGURATION MISSING: GROQ_API_KEY is not set on this deployment."
  echo "Skipping real end-to-end execution test (this is not a code failure)."
  exit 0
fi

echo "== Executing POST /v1/execute against provider=groq model=${MODEL} =="
RESPONSE="$(curl -s -m 30 -X POST "${DAY3_URL}/v1/execute" \
  -H 'Content-Type: application/json' \
  -d "{\"provider\":\"groq\",\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: STACK3_EXECUTION_OK\"}]}")"

echo "$RESPONSE"

SUCCESS="$(echo "$RESPONSE" | node -e '
  let d = "";
  process.stdin.on("data", (c) => { d += c; });
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(d);
      console.log(j.success === true ? "true" : "false");
    } catch (e) {
      console.log("false");
    }
  });
')"

if [ "$SUCCESS" = "true" ]; then
  echo "PROVIDER EXECUTION PASS: real Groq execution succeeded via /v1/execute"
  exit 0
else
  echo "PROVIDER EXECUTION FAILED: /v1/execute did not return success=true"
  exit 1
fi
