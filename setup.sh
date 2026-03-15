#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# Linear Pipeline Agents — Interactive Setup
#
# Checks dependencies, queries Linear for teams and workflow states,
# creates missing states, and writes a .env file.
# ─────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# ── Colors ──
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"

ok()   { echo -e "  ${GREEN}[OK]${RESET} $1"; }
fail() { echo -e "  ${RED}[FAIL]${RESET} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $1"; }
ask()  { echo -en "  ${CYAN}?${RESET} $1"; }

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Linear Pipeline Agents — Setup${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# ── Step 1: Check dependencies ──
echo -e "${BOLD}Step 1: Checking dependencies${RESET}"

MISSING=0

if command -v claude &>/dev/null; then
  ok "claude CLI found ($(which claude))"
else
  fail "claude CLI not found — install from https://claude.ai/claude-code"
  MISSING=1
fi

if command -v node &>/dev/null; then
  ok "node found ($(node --version))"
else
  fail "node not found — install from https://nodejs.org"
  MISSING=1
fi

if command -v jq &>/dev/null; then
  ok "jq found ($(which jq))"
else
  fail "jq not found — install with: brew install jq"
  MISSING=1
fi

if command -v curl &>/dev/null; then
  ok "curl found"
else
  fail "curl not found"
  MISSING=1
fi

if [ "$MISSING" -eq 1 ]; then
  echo ""
  echo -e "${RED}${BOLD}Install the missing dependencies above and re-run setup.sh${RESET}"
  exit 1
fi

echo ""

# ── Step 2: Linear API key ──
echo -e "${BOLD}Step 2: Linear API configuration${RESET}"

LINEAR_API_KEY=""
if [ -f "$ENV_FILE" ]; then
  EXISTING_KEY=$(grep '^LINEAR_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
  if [ -n "$EXISTING_KEY" ] && [ "$EXISTING_KEY" != "lin_api_xxxxx" ]; then
    ask "Found existing API key. Use it? [Y/n]: "
    read -r USE_EXISTING
    if [ "$USE_EXISTING" != "n" ] && [ "$USE_EXISTING" != "N" ]; then
      LINEAR_API_KEY="$EXISTING_KEY"
    fi
  fi
fi

if [ -z "$LINEAR_API_KEY" ]; then
  ask "Enter your Linear API key (lin_api_...): "
  read -r LINEAR_API_KEY
  if [ -z "$LINEAR_API_KEY" ]; then
    fail "API key is required"
    exit 1
  fi
fi

# Validate API key
echo -e "  ${DIM}Validating API key...${RESET}"
VALIDATE_RESULT=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "{ viewer { id name } }"}' 2>/dev/null)

VIEWER_NAME=$(echo "$VALIDATE_RESULT" | jq -r '.data.viewer.name // empty' 2>/dev/null)
if [ -z "$VIEWER_NAME" ]; then
  fail "Invalid API key — could not authenticate with Linear"
  exit 1
fi
ok "Authenticated as: $VIEWER_NAME"
echo ""

# ── Step 3: Select team ──
echo -e "${BOLD}Step 3: Select Linear team${RESET}"

TEAMS_RESULT=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "{ teams { nodes { id name key } } }"}' 2>/dev/null)

TEAM_COUNT=$(echo "$TEAMS_RESULT" | jq '.data.teams.nodes | length' 2>/dev/null)

if [ "$TEAM_COUNT" -eq 0 ]; then
  fail "No teams found in your Linear workspace"
  exit 1
elif [ "$TEAM_COUNT" -eq 1 ]; then
  LINEAR_TEAM_ID=$(echo "$TEAMS_RESULT" | jq -r '.data.teams.nodes[0].id')
  TEAM_NAME=$(echo "$TEAMS_RESULT" | jq -r '.data.teams.nodes[0].name')
  TEAM_KEY=$(echo "$TEAMS_RESULT" | jq -r '.data.teams.nodes[0].key')
  ok "Auto-selected team: $TEAM_NAME ($TEAM_KEY)"
else
  echo -e "  ${DIM}Found $TEAM_COUNT teams:${RESET}"
  echo "$TEAMS_RESULT" | jq -r '.data.teams.nodes | to_entries[] | "    \(.key + 1)) \(.value.name) (\(.value.key))"' 2>/dev/null
  echo ""
  ask "Select team number [1-$TEAM_COUNT]: "
  read -r TEAM_CHOICE
  TEAM_IDX=$((TEAM_CHOICE - 1))
  LINEAR_TEAM_ID=$(echo "$TEAMS_RESULT" | jq -r ".data.teams.nodes[$TEAM_IDX].id")
  TEAM_NAME=$(echo "$TEAMS_RESULT" | jq -r ".data.teams.nodes[$TEAM_IDX].name")
  TEAM_KEY=$(echo "$TEAMS_RESULT" | jq -r ".data.teams.nodes[$TEAM_IDX].key")
  ok "Selected team: $TEAM_NAME ($TEAM_KEY)"
fi

echo ""

# ── Step 4: Discover and create workflow states ──
echo -e "${BOLD}Step 4: Workflow states${RESET}"

STATES_RESULT=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d "{\"query\": \"{ team(id: \\\"$LINEAR_TEAM_ID\\\") { states { nodes { id name type } } } }\"}" 2>/dev/null)

STATES_JSON=$(echo "$STATES_RESULT" | jq '.data.team.states.nodes' 2>/dev/null)

check_state() {
  local name="$1"
  local id
  id=$(echo "$STATES_JSON" | jq -r ".[] | select(.name == \"$name\") | .id" 2>/dev/null | head -1)
  if [ -n "$id" ] && [ "$id" != "null" ]; then
    ok "Found state: $name"
    return 0
  fi
  return 1
}

# Check required states
REQUIRED_STATES=("Backlog" "Todo" "Selected for Development" "In Progress" "In Review" "Done")
REQUIRED_OK=true
for state in "${REQUIRED_STATES[@]}"; do
  if ! check_state "$state"; then
    fail "Missing required state: $state"
    REQUIRED_OK=false
  fi
done

if [ "$REQUIRED_OK" = false ]; then
  echo ""
  echo -e "${RED}${BOLD}Your team is missing required workflow states.${RESET}"
  echo -e "${RED}Add them in Linear: Settings > Teams > $TEAM_NAME > Workflow${RESET}"
  exit 1
fi

# Check optional states (offer to create if missing)
OPTIONAL_STATES=("QA Fail:started" "Needs Documentation:completed" "On Github:completed")

for entry in "${OPTIONAL_STATES[@]}"; do
  state_name="${entry%%:*}"
  state_type="${entry##*:}"

  if ! check_state "$state_name"; then
    warn "Missing optional state: $state_name"
    ask "Create '$state_name' state in Linear? [Y/n]: "
    read -r CREATE_IT
    if [ "$CREATE_IT" != "n" ] && [ "$CREATE_IT" != "N" ]; then
      CREATE_RESULT=$(curl -s -X POST https://api.linear.app/graphql \
        -H "Content-Type: application/json" \
        -H "Authorization: $LINEAR_API_KEY" \
        -d "{\"query\": \"mutation { workflowStateCreate(input: { teamId: \\\"$LINEAR_TEAM_ID\\\", name: \\\"$state_name\\\", type: \\\"$state_type\\\", color: \\\"#808080\\\" }) { success workflowState { id name } } }\"}" 2>/dev/null)
      if echo "$CREATE_RESULT" | jq -e '.data.workflowStateCreate.success' &>/dev/null; then
        ok "Created state: $state_name"
        # Refresh states
        STATES_RESULT=$(curl -s -X POST https://api.linear.app/graphql \
          -H "Content-Type: application/json" \
          -H "Authorization: $LINEAR_API_KEY" \
          -d "{\"query\": \"{ team(id: \\\"$LINEAR_TEAM_ID\\\") { states { nodes { id name type } } } }\"}" 2>/dev/null)
        STATES_JSON=$(echo "$STATES_RESULT" | jq '.data.team.states.nodes' 2>/dev/null)
      else
        warn "Could not create state: $state_name (you can add it manually later)"
      fi
    fi
  fi
done

echo ""

# ── Step 5: Project configuration ──
echo -e "${BOLD}Step 5: Project configuration${RESET}"

ask "Project directory (absolute path) [$(pwd)]: "
read -r PROJECT_DIR
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
if [ ! -d "$PROJECT_DIR" ]; then
  warn "Directory does not exist: $PROJECT_DIR (will be created later)"
else
  ok "Project directory: $PROJECT_DIR"
fi

ask "Git branch to work on [main]: "
read -r GIT_BRANCH
GIT_BRANCH="${GIT_BRANCH:-main}"
ok "Git branch: $GIT_BRANCH"

echo ""

# ── Step 6: Test and lint commands ──
echo -e "${BOLD}Step 6: Test and lint commands${RESET}"
echo -e "  ${DIM}These are run by the tester agent to validate card implementations.${RESET}"

ask "Test command [npx tsc --noEmit]: "
read -r TEST_CMD
TEST_CMD="${TEST_CMD:-npx tsc --noEmit}"
ok "Test command: $TEST_CMD"

ask "Lint command [npx prettier --check 'src/**/*.ts']: "
read -r LINT_CMD
LINT_CMD="${LINT_CMD:-npx prettier --check 'src/**/*.ts'}"
ok "Lint command: $LINT_CMD"

echo ""

# ── Step 7: Agent Builder cards (optional) ──
echo -e "${BOLD}Step 7: Agent Builder configuration (optional)${RESET}"
echo -e "  ${DIM}Comma-separated card numbers that need agent-builder review.${RESET}"
echo -e "  ${DIM}Leave empty if you don't use an agent builder agent.${RESET}"

ask "Agent Builder card numbers []: "
read -r AGENT_BUILDER_CARDS
AGENT_BUILDER_CARDS="${AGENT_BUILDER_CARDS:-}"

echo ""

# ── Step 8: Card range ──
echo -e "${BOLD}Step 8: Card range${RESET}"
echo -e "  ${DIM}The pipeline will only process cards within this number range.${RESET}"

ask "Minimum card number [1]: "
read -r MIN_CARD
MIN_CARD="${MIN_CARD:-1}"

ask "Maximum card number [9999]: "
read -r MAX_CARD
MAX_CARD="${MAX_CARD:-9999}"

ok "Card range: $MIN_CARD to $MAX_CARD"
echo ""

# ── Write .env ──
echo -e "${BOLD}Writing .env file...${RESET}"

cat > "$ENV_FILE" << EOF
# Linear API
LINEAR_API_KEY=$LINEAR_API_KEY
LINEAR_TEAM_ID=$LINEAR_TEAM_ID

# Pipeline settings
POLL_INTERVAL=30
MAX_AGENTS=5
MAX_RETRIES=3
MIN_CARD=$MIN_CARD
MAX_CARD=$MAX_CARD

# Project
GIT_BRANCH=$GIT_BRANCH
PROJECT_DIR=$PROJECT_DIR

# Test & lint commands (run by the tester agent)
TEST_CMD="$TEST_CMD"
LINT_CMD="$LINT_CMD"

# Agent Builder: comma-separated card numbers that need agent-builder review, or empty
AGENT_BUILDER_CARDS=$AGENT_BUILDER_CARDS
EOF

ok "Wrote $ENV_FILE"
echo ""

# ── Validation call ──
echo -e "${BOLD}Validating setup...${RESET}"

FINAL_CHECK=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d "{\"query\": \"{ team(id: \\\"$LINEAR_TEAM_ID\\\") { name issues(first: 1) { nodes { identifier } } } }\"}" 2>/dev/null)

FINAL_TEAM=$(echo "$FINAL_CHECK" | jq -r '.data.team.name // empty' 2>/dev/null)
if [ -n "$FINAL_TEAM" ]; then
  ok "Successfully connected to team: $FINAL_TEAM"
else
  warn "Validation call returned unexpected result — check your .env"
fi

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  Setup complete!${RESET}"
echo -e ""
echo -e "  ${DIM}Start the pipeline:${RESET}"
echo -e "    ${BOLD}bash start.sh${RESET}"
echo -e ""
echo -e "  ${DIM}Or run components separately:${RESET}"
echo -e "    ${BOLD}bash scripts/pipeline-driver.sh${RESET}   ${DIM}(polls and drives cards)${RESET}"
echo -e "    ${BOLD}bash scripts/pipeline-watch.sh${RESET}    ${DIM}(live dashboard)${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
