#!/bin/bash
INSTANCE_ID_STRING="astropy__astropy-12907"
# SAMPLES=1
OUTPUT_BASE_DIR="openhands_results"

# add cd to path
export PYTHONPATH=$PYTHONPATH:$(pwd)
# Path to the JSON file containing instance details
CODEARENA_INSTANCES_FILE="../../data/codearena_instances.json"

# do the same for codearena repo so we can access monkeypatched swebench
cd ../../

export PYTHONPATH=$PYTHONPATH:$(pwd)
cd baselines/OpenHands

# exit immediately if any of the commands fail
set -e

# --- Configuration ---
# Specify the OpenHands agent class to use (e.g., CodeActAgent, ReadOnlyAgent)
AGENT_CLASS="CodeActAgent"
# Specify the LLM model configuration (ensure this matches your OpenHands setup)
MODEL="gemini/gemini-2.5-pro" # Default, change if needed
# Maximum iterations for the agent
MAX_ITERATIONS=50
# OpenHands entry point (adjust if your installation differs)
OPENHANDS_ENTRY_POINT="python -m openhands.core.main"

# --- Validate Input ---
# if [ -z "$TARGET_ID" ]; then
#   echo "Error: TARGET_ID is not set in the script."
#   exit 1
# fi

# --- Validate Input ---
if [ -z "$INSTANCE_ID_STRING" ]; then
  echo "Usage: $0 <instance_id_string>"
  echo "Example: $0 astropy__astropy-12907"
  exit 1
fi

if [ ! -f "$CODEARENA_INSTANCES_FILE" ]; then
  echo "Error: CodeArena instances file not found: $CODEARENA_INSTANCES_FILE"
  exit 1
fi

# --- Extract Instance JSON from the Main File ---
echo "Looking up instance '$INSTANCE_ID_STRING' in '$CODEARENA_INSTANCES_FILE'..."
# Use -c for compact output to ensure INSTANCE_JSON_OBJECT is a single, valid JSON line.
INSTANCE_JSON_OBJECT=$(jq -c --arg inst_id "$INSTANCE_ID_STRING" '.[] | select(.instance_id == $inst_id)' "$CODEARENA_INSTANCES_FILE")

if [ -z "$INSTANCE_JSON_OBJECT" ] || [ "$INSTANCE_JSON_OBJECT" == "null" ]; then
  echo "Error: Instance ID '$INSTANCE_ID_STRING' not found in '$CODEARENA_INSTANCES_FILE'."
  exit 1
fi
echo "Instance data found."
# Optional: For debugging, print the start of the extracted JSON object
# echo "DEBUG: INSTANCE_JSON_OBJECT (first 200 chars): $(echo "$INSTANCE_JSON_OBJECT" | cut -c 1-200)"

# --- Extract Information from JSON Object using here-strings for robustness ---
TARGET_ID="$INSTANCE_ID_STRING"
OUTPUT_DIR="${OUTPUT_BASE_DIR}/${TARGET_ID}"

REPO=$(jq -r '.repo' <<< "$INSTANCE_JSON_OBJECT")
BASE_COMMIT=$(jq -r '.base_commit' <<< "$INSTANCE_JSON_OBJECT")
PROBLEM_STATEMENT=$(jq -r '.problem_statement' <<< "$INSTANCE_JSON_OBJECT")
# For FAIL_TO_PASS and PASS_TO_PASS, jq -c ensures the output is a compact JSON array string
FAIL_TO_PASS=$(jq -c '.FAIL_TO_PASS' <<< "$INSTANCE_JSON_OBJECT")
PASS_TO_PASS=$(jq -c '.PASS_TO_PASS' <<< "$INSTANCE_JSON_OBJECT")

echo "--- Configuration ---"
echo "Target Instance ID: $TARGET_ID"
echo "Output Dir: $OUTPUT_DIR"
echo "Repository: $REPO"
echo "Base Commit: $BASE_COMMIT"
echo "Agent Class: $AGENT_CLASS"
echo "Model: $MODEL"
echo "Max Iterations: $MAX_ITERATIONS"
echo "---------------------"

# Exit immediately if any command fails
set -e

# --- Setup Workspace ---
WORKSPACE_DIR="${OUTPUT_DIR}/workspace"
REPO_NAME=$(basename "$REPO")
REPO_DIR="${WORKSPACE_DIR}/${REPO_NAME}"

echo "Setting up workspace in: $WORKSPACE_DIR"
mkdir -p "$WORKSPACE_DIR"

if [ ! -d "$REPO_DIR" ]; then
  echo "Cloning repository $REPO..."
  git clone "https://github.com/${REPO}.git" "$REPO_DIR"
else
  echo "Repository already exists in $REPO_DIR. Fetching latest and resetting."
  git -C "$REPO_DIR" fetch
fi

echo "Checking out base commit $BASE_COMMIT..."
git -C "$REPO_DIR" reset --hard HEAD
git -C "$REPO_DIR" clean -fdx
git -C "$REPO_DIR" checkout "$BASE_COMMIT"

echo "Workspace setup complete."

# --- Construct Initial Prompt ---
INITIAL_PROMPT=$(cat <<EOF
Please fix the following bug in the repository '$REPO'.

**Problem Statement:**
$PROBLEM_STATEMENT

**Repository Information:**
The relevant code is located in the workspace directory. You are currently at the base commit '$BASE_COMMIT'.

**Testing Information:**
- The following tests are currently failing and should pass after your fix:
$FAIL_TO_PASS
- The following tests are currently passing and should continue to pass after your fix:
$PASS_TO_PASS

**Your Task:**
1.  Analyze the problem statement and the provided test information.
2.  Explore the codebase in the workspace directory as needed to understand the context and locate the bug. Use file reading and search tools.
3.  Develop a patch to fix the bug. Use file editing tools to apply the changes.
4.  Verify your fix by running the relevant tests. Ensure the FAIL_TO_PASS tests now pass and the PASS_TO_PASS tests still pass. You might need to figure out the exact test commands (e.g., using pytest).
5.  If tests pass, finalize the task. If not, debug and refine your patch, then re-test.

Please proceed with analyzing the code and implementing the fix. Remember to execute tests to validate your changes.
EOF
)

echo "--- Initial Prompt for OpenHands ---"
echo "Prompt constructed (length: ${#INITIAL_PROMPT} chars)."
echo "------------------------------------"

# --- Run OpenHands Agent ---
echo "Starting OpenHands agent..."

PROMPT_FILE="${OUTPUT_DIR}/prompt.txt"
echo "$INITIAL_PROMPT" > "$PROMPT_FILE"

$OPENHANDS_ENTRY_POINT \
    --directory  "$REPO_DIR" \
    --agent-cls "$AGENT_CLASS" \
    --llm-config "$MODEL" \
    --max-iterations "$MAX_ITERATIONS" \
    --file "$PROMPT_FILE"

echo "OpenHands agent finished."
echo "Bug fixing process complete for $TARGET_ID. Results are in $OUTPUT_DIR and the OpenHands log/trajectory files."
rm "$PROMPT_FILE" # Clean up the temporary prompt file
exit 0
