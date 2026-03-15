#!/bin/bash
# Pipeline Driver — polls Linear, spawns Claude agents, moves cards.
# Tracks agent PIDs, limits retries, prevents duplicate drivers.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load config
ENV_FILE="$(dirname "$SCRIPT_DIR")/.env"
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

API_KEY="${LINEAR_API_KEY}"
TEAM_ID="${LINEAR_TEAM_ID}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
MAX_AGENTS="${MAX_AGENTS:-5}"
MAX_RETRIES="${MAX_RETRIES:-3}"
MIN_CARD="${MIN_CARD:-1}"
MAX_CARD="${MAX_CARD:-9999}"
GIT_BRANCH="${GIT_BRANCH:-main}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
TEST_CMD="${TEST_CMD:-npx tsc --noEmit}"
LINT_CMD="${LINT_CMD:-npx prettier --check 'src/**/*.ts'}"

CLAUDE_BIN=$(which claude 2>/dev/null || echo "")
NODE_BIN=$(which node 2>/dev/null)

BOLD="\033[1m" DIM="\033[2m" RESET="\033[0m"
CYAN="\033[36m" GREEN="\033[32m" YELLOW="\033[33m" RED="\033[31m"

# ── Auto-discover status IDs from Linear ──
discover_statuses() {
  echo -e "${DIM}Discovering workflow states from Linear...${RESET}"
  local result
  result=$(curl -s -X POST https://api.linear.app/graphql \
    -H "Content-Type: application/json" \
    -H "Authorization: $API_KEY" \
    -d "{\"query\": \"{ team(id: \\\"$TEAM_ID\\\") { states { nodes { id name type } } } }\"}" 2>/dev/null)

  if [ -z "$result" ] || echo "$result" | grep -q '"errors"'; then
    echo -e "${RED}${BOLD}ERROR: Failed to fetch workflow states from Linear.${RESET}"
    echo -e "${RED}Check your LINEAR_API_KEY and LINEAR_TEAM_ID in .env${RESET}"
    exit 1
  fi

  S_BACKLOG=$(echo "$result" | "$NODE_BIN" -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const s=JSON.parse(d).data.team.states.nodes;const f=s.find(x=>x.name==="Backlog");console.log(f?f.id:"")}catch(e){console.log("")}})' 2>/dev/null)
  S_TODO=$(echo "$result" | "$NODE_BIN" -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const s=JSON.parse(d).data.team.states.nodes;const f=s.find(x=>x.name==="Todo");console.log(f?f.id:"")}catch(e){console.log("")}})' 2>/dev/null)
  S_SELECTED=$(echo "$result" | "$NODE_BIN" -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const s=JSON.parse(d).data.team.states.nodes;const f=s.find(x=>x.name==="Selected for Development"||x.name==="Selected");console.log(f?f.id:"")}catch(e){console.log("")}})' 2>/dev/null)
  S_IN_PROGRESS=$(echo "$result" | "$NODE_BIN" -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const s=JSON.parse(d).data.team.states.nodes;const f=s.find(x=>x.name==="In Progress");console.log(f?f.id:"")}catch(e){console.log("")}})' 2>/dev/null)
  S_IN_REVIEW=$(echo "$result" | "$NODE_BIN" -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const s=JSON.parse(d).data.team.states.nodes;const f=s.find(x=>x.name==="In Review");console.log(f?f.id:"")}catch(e){console.log("")}})' 2>/dev/null)
  S_QA_FAIL=$(echo "$result" | "$NODE_BIN" -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const s=JSON.parse(d).data.team.states.nodes;const f=s.find(x=>x.name==="QA Fail");console.log(f?f.id:"")}catch(e){console.log("")}})' 2>/dev/null)
  S_DONE=$(echo "$result" | "$NODE_BIN" -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const s=JSON.parse(d).data.team.states.nodes;const f=s.find(x=>x.name==="Done");console.log(f?f.id:"")}catch(e){console.log("")}})' 2>/dev/null)
  S_NEEDS_DOCS=$(echo "$result" | "$NODE_BIN" -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const s=JSON.parse(d).data.team.states.nodes;const f=s.find(x=>x.name==="Needs Documentation"||x.name==="Needs Docs");console.log(f?f.id:"")}catch(e){console.log("")}})' 2>/dev/null)
  S_ON_GITHUB=$(echo "$result" | "$NODE_BIN" -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const s=JSON.parse(d).data.team.states.nodes;const f=s.find(x=>x.name==="On Github"||x.name==="On GitHub");console.log(f?f.id:"")}catch(e){console.log("")}})' 2>/dev/null)

  # Validate required states
  local missing=""
  [ -z "$S_BACKLOG" ] && missing="$missing Backlog"
  [ -z "$S_TODO" ] && missing="$missing Todo"
  [ -z "$S_SELECTED" ] && missing="$missing 'Selected for Development'"
  [ -z "$S_IN_PROGRESS" ] && missing="$missing 'In Progress'"
  [ -z "$S_IN_REVIEW" ] && missing="$missing 'In Review'"
  [ -z "$S_DONE" ] && missing="$missing Done"

  if [ -n "$missing" ]; then
    echo -e "${RED}${BOLD}ERROR: Missing required workflow states:${missing}${RESET}"
    echo -e "${RED}Run setup.sh to create them, or add them manually in Linear.${RESET}"
    exit 1
  fi

  # Optional states — warn but don't fail
  [ -z "$S_QA_FAIL" ] && echo -e "${YELLOW}WARNING: No 'QA Fail' state found. QA failure loop disabled.${RESET}"
  [ -z "$S_NEEDS_DOCS" ] && echo -e "${YELLOW}WARNING: No 'Needs Documentation' state found. Docs step disabled.${RESET}"
  [ -z "$S_ON_GITHUB" ] && echo -e "${YELLOW}WARNING: No 'On Github' state found. Push-to-github step disabled.${RESET}"

  echo -e "${GREEN}${BOLD}Workflow states discovered${RESET}"
}

# Run discovery
discover_statuses

# ── Persistent state ──
STATE_DIR="/tmp/linear-pipeline-state"
mkdir -p "$STATE_DIR"

# Lockfile — prevent duplicate drivers
LOCKFILE="$STATE_DIR/driver.lock"
if [ -f "$LOCKFILE" ]; then
  OLD_PID=$(cat "$LOCKFILE" 2>/dev/null)
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Driver already running (PID $OLD_PID). Killing old one."
    kill "$OLD_PID" 2>/dev/null
    sleep 1
  fi
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"; exit 0' INT TERM EXIT

# Track active agents: FILE per card+role containing PID
# $STATE_DIR/agents/CARD-124_developer.pid
AGENTS_DIR="$STATE_DIR/agents"
mkdir -p "$AGENTS_DIR"

# Track retry counts: FILE per card+role containing count
RETRIES_DIR="$STATE_DIR/retries"
mkdir -p "$RETRIES_DIR"

gql() {
  curl -s -X POST https://api.linear.app/graphql \
    -H "Content-Type: application/json" \
    -H "Authorization: $API_KEY" \
    -d "$1" 2>/dev/null
}

move_issue() {
  gql "{\"query\": \"mutation { issueUpdate(id: \\\"$1\\\", input: { stateId: \\\"$2\\\" }) { success } }\"}" > /dev/null 2>&1
}

count_agents() {
  local count=0
  local pidfiles
  pidfiles=$(ls "$AGENTS_DIR"/*.pid 2>/dev/null) || true
  for pidfile in $pidfiles; do
    [ -f "$pidfile" ] || continue
    local pid=$(cat "$pidfile" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      count=$((count + 1))
    else
      rm -f "$pidfile"  # dead agent, clean up
    fi
  done
  echo "$count"
}

# Check if agent is currently running for this card+role
agent_alive() {
  local key="$1"  # e.g. CARD-124_developer
  local pidfile="$AGENTS_DIR/${key}.pid"
  if [ -f "$pidfile" ]; then
    local pid=$(cat "$pidfile" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0  # alive
    fi
    rm -f "$pidfile"  # dead, clean up
  fi
  return 1  # not alive
}

get_retries() {
  local key="$1"
  cat "$RETRIES_DIR/${key}.count" 2>/dev/null || echo "0"
}

inc_retries() {
  local key="$1"
  local current=$(get_retries "$key")
  echo $((current + 1)) > "$RETRIES_DIR/${key}.count"
}

PUSH_INTERVAL=10  # push every 10 polls (~5 min at 30s interval)
POLL_COUNT=0

try_push() {
  cd "$PROJECT_DIR"
  local unpushed
  unpushed=$(git log origin/${GIT_BRANCH}..${GIT_BRANCH} --oneline 2>/dev/null) || true
  if [ -z "$unpushed" ]; then return; fi

  echo -e "${YELLOW}${BOLD}Pushing ${GIT_BRANCH} to origin...${RESET}"
  if git push origin ${GIT_BRANCH} 2>/dev/null; then
    local count=$(echo "$unpushed" | wc -l | tr -d ' ')
    echo -e "${GREEN}${BOLD}Pushed ${count} commit(s) to origin/${GIT_BRANCH}${RESET}"

    # Move all "Needs Documentation" cards to "On Github"
    local needs_docs_ids
    needs_docs_ids=$("$NODE_BIN" -e "
      const d=$(gql '{\"query\": \"{ team(id: \\\\\"$TEAM_ID\\\\\\\") { issues(first: 50, filter: { state: { id: { eq: \\\\\"$S_NEEDS_DOCS\\\\\\\" } } }) { nodes { id identifier number } } } }\"}' 2>/dev/null);
      const issues = (d?.data?.team?.issues?.nodes || []).filter(i => i.number >= $MIN_CARD && i.number <= $MAX_CARD);
      issues.forEach(i => console.log(i.id + '|' + i.identifier));
    " 2>/dev/null) || true

    while IFS='|' read -r issue_id issue_ident; do
      [ -z "$issue_id" ] && continue
      move_issue "$issue_id" "$S_ON_GITHUB"
      echo -e "${GREEN}${BOLD}${issue_ident}${RESET} ${DIM}Pushed -> On Github${RESET}"
    done <<< "$needs_docs_ids"
  else
    echo -e "${RED}${BOLD}Push failed${RESET}"
  fi
}

spawn_agent() {
  local role="$1" ident="$2" issue_id="$3" title="$4" desc="$5"
  local key="${ident}_${role}"

  if [ -z "$CLAUDE_BIN" ]; then return 1; fi

  # Check if already running
  if agent_alive "$key"; then
    return 1
  fi

  # Check retry limit
  local retries=$(get_retries "$key")
  if [ "$retries" -ge "$MAX_RETRIES" ]; then
    echo -e "${RED}${ident}${RESET} ${DIM}${role} failed ${retries}x, skipping${RESET}"
    return 1
  fi

  # Check capacity
  local active=$(count_agents)
  if [ "$active" -ge "$MAX_AGENTS" ]; then
    return 1
  fi

  local prompt=""
  case "$role" in
    architect)
      prompt="You are the Architect agent. Review card $ident: \"$title\". Read source code in $PROJECT_DIR. Post an Architect Review comment on Linear with: Verdict, Existing Code Analysis (specific files/lines), Technical Recommendations, Risk Assessment, Acceptance Criteria Review. Use curl to post: curl -s -X POST https://api.linear.app/graphql -H 'Content-Type: application/json' -H 'Authorization: $API_KEY' -d '{\"query\":\"mutation(\$i:String!,\$b:String!){commentCreate(input:{issueId:\$i,body:\$b}){success}}\",\"variables\":{\"issueId\":\"$issue_id\",\"body\":\"YOUR_REVIEW\"}}'. Card description: $desc"
      ;;
    coordinator)
      prompt="You are the Coordinator agent. For card $ident (issue ID: $issue_id): 1) Fetch the card and its comments from Linear, 2) Read the Architect Review, 3) Update card description with all recommendations (it becomes the single source of truth), 4) Post a Coordinator Review comment. API key: $API_KEY. Fetch: curl -s -X POST https://api.linear.app/graphql -H 'Content-Type: application/json' -H 'Authorization: $API_KEY' -d '{\"query\":\"{ issue(id: \\\"$issue_id\\\") { id identifier title description comments(first:20) { nodes { body } } } }\"}'. Update desc and post comment using mutations."
      ;;
    developer*)
      local rework_note=""
      local summary_label="Developer Summary"
      if [[ "$role" == *rework* ]]; then
        rework_note="REWORK: This card failed QA. Fetch comments, read 'Tester Results — FAILED', fix ONLY those issues."
        summary_label="Developer Summary (Rework)"
      fi
      prompt="You are the Developer agent. Implement card $ident: \"$title\". $rework_note Card description: $desc. Your job: 1) Read card description, 2) Implement in $PROJECT_DIR on branch ${GIT_BRANCH}, 3) Write clean minimal code following existing patterns, 4) Post a '$summary_label' comment on Linear, 5) Commit locally, do NOT push. Fetch comments: curl -s -X POST https://api.linear.app/graphql -H 'Content-Type: application/json' -H 'Authorization: $API_KEY' -d '{\"query\":\"{ issue(id: \\\"$issue_id\\\") { comments(first:20) { nodes { body } } } }\"}'. Post: curl -s -X POST https://api.linear.app/graphql -H 'Content-Type: application/json' -H 'Authorization: $API_KEY' -d '{\"query\":\"mutation(\$i:String!,\$b:String!){commentCreate(input:{issueId:\$i,body:\$b}){success}}\",\"variables\":{\"issueId\":\"$issue_id\",\"body\":\"YOUR_SUMMARY\"}}'. Do NOT touch prompt files."
      ;;
    tester*)
      prompt="You are the Tester agent. Validate card $ident: \"$title\". Card description: $desc. Your job: 1) Fetch card comments from Linear (issue $issue_id), read Developer Summary, 2) Check the implementation against acceptance criteria, 3) Run: cd $PROJECT_DIR && $TEST_CMD 2>&1 | head -30, 4) Run: cd $PROJECT_DIR && $LINT_CMD 2>&1 | head -20, 5) Post 'Tester Results — PASSED' or 'Tester Results — FAILED' with specific failures. Fetch: curl -s -X POST https://api.linear.app/graphql -H 'Content-Type: application/json' -H 'Authorization: $API_KEY' -d '{\"query\":\"{ issue(id: \\\"$issue_id\\\") { comments(first:20) { nodes { body } } } }\"}'. Post using commentCreate mutation with issueId $issue_id. API key: $API_KEY."
      ;;
    agent_builder)
      prompt="You are the Agent Builder agent — the prompt engineering expert. Review card $ident: \"$title\". Your expertise is in agent prompts, system instructions, tool definitions, and multi-agent architectures. Read the source code in $PROJECT_DIR. Post an 'Agent Builder Assessment' comment on Linear with: 1) Prompt Quality Analysis, 2) Tool Binding Recommendations (which tools this agent needs), 3) Model Selection (which LLM model fits this agent's workload), 4) System Prompt Template (draft the key sections), 5) Integration Notes (how this connects to orchestrator/handoff). Use curl to post: curl -s -X POST https://api.linear.app/graphql -H 'Content-Type: application/json' -H 'Authorization: $API_KEY' -d '{\"query\":\"mutation(\$i:String!,\$b:String!){commentCreate(input:{issueId:\$i,body:\$b}){success}}\",\"variables\":{\"issueId\":\"$issue_id\",\"body\":\"YOUR_ASSESSMENT\"}}'. Card description: $desc"
      ;;
    docs_writer)
      prompt="You are the Docs Writer agent. Review card $ident for documentation needs. Card description: $desc. Post a 'Docs Writer' comment on Linear (issue $issue_id) summarizing what docs are needed or confirming none needed. Use curl with API key: $API_KEY and commentCreate mutation."
      ;;
  esac

  echo -e "${CYAN}${BOLD}${ident}${RESET} ${DIM}Spawning ${role} (attempt $((retries+1))/${MAX_RETRIES})...${RESET}"

  (
    cd "$PROJECT_DIR"
    "$CLAUDE_BIN" -p "$prompt" --dangerously-skip-permissions 2>/dev/null
  ) &
  local pid=$!
  echo "$pid" > "$AGENTS_DIR/${key}.pid"
  inc_retries "$key"
}

# ── Header ──
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Linear Pipeline Driver${RESET}"
echo -e "${DIM}  Max agents: ${MAX_AGENTS} | Poll: ${POLL_INTERVAL}s | Max retries: ${MAX_RETRIES}${RESET}"
echo -e "${DIM}  Cards: ${MIN_CARD} to ${MAX_CARD}${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

while true; do
  RESULT=$(gql '{
    "query": "{ team(id: \"'"$TEAM_ID"'\") { issues(first: 50, filter: { state: { id: { in: [\"'"$S_BACKLOG"'\", \"'"$S_TODO"'\", \"'"$S_SELECTED"'\", \"'"$S_IN_PROGRESS"'\", \"'"$S_IN_REVIEW"'\", \"'"$S_QA_FAIL"'\", \"'"$S_DONE"'\"] } } }) { nodes { id identifier number title description state { id name } comments { nodes { body } } updatedAt } } } }"
  }')

  if [ -z "$RESULT" ]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Node outputs action lines
  ACTIONS=$("$NODE_BIN" -e "
    try {
    const data = $RESULT;
    const issues = (data?.data?.team?.issues?.nodes || [])
      .filter(i => i.number >= $MIN_CARD && i.number <= $MAX_CARD)
      .sort((a,b) => a.number - b.number);

    for (const issue of issues) {
      const sid = issue.state?.id;
      const cs = issue.comments?.nodes || [];
      const has = m => cs.some(c => c.body?.includes(m));
      const I = issue.identifier, ID = issue.id, T = issue.title;

      const hasArch = has('Architect Review');
      const hasAgentBuilder = has('Agent Builder Assessment');
      const hasCoord = has('Coordinator Review') || has('Consolidated Pre-Development Plan');
      const hasDev = has('Developer Summary');
      const hasDocs = has('Docs Writer');

      // Count QA fail cycles to prevent infinite rework loops (max 3 cycles)
      const MAX_QA_CYCLES = 3;
      const failCount = cs.filter(c => c.body?.includes('Tester Results — FAILED') || c.body?.includes('Tester — REJECTED')).length;

      // FIX: Use LAST comment index to determine state — prevents loops
      // where old pass/fail/rework comments re-trigger status bouncing
      const lastTesterIdx = cs.reduce((acc, c, idx) => (c.body?.includes('Tester Results') || c.body?.includes('Tester —')) ? idx : acc, -1);
      const lastDevReworkIdx = cs.reduce((acc, c, idx) => c.body?.includes('Developer Summary (Rework)') ? idx : acc, -1);
      const lastDevAnyIdx = cs.reduce((acc, c, idx) => c.body?.includes('Developer Summary') ? idx : acc, -1);
      const hasTestPass = lastTesterIdx >= 0 && (cs[lastTesterIdx].body?.includes('PASSED'));
      const hasTestFail = lastTesterIdx >= 0 && (cs[lastTesterIdx].body?.includes('FAILED') || cs[lastTesterIdx].body?.includes('REJECTED'));
      // Only treat rework as new if it came AFTER the last tester failure
      const hasDevRework = lastDevReworkIdx > lastTesterIdx;

      // Cards that need Agent Builder review (prompt/agent related)
      const agentCards = '${AGENT_BUILDER_CARDS}'.split(',').map(Number).filter(Boolean);
      const needsAgentBuilder = agentCards.includes(issue.number);

      // Test cards gate REMOVED — all cards flow through full pipeline
      const isTestCard = false;

      if (sid === '$S_BACKLOG' || sid === '$S_TODO') {
        if (!hasArch) console.log('spawn|architect|'+ID+'|'+I+'|'+T);
        else if (needsAgentBuilder && !hasAgentBuilder) console.log('spawn|agent_builder|'+ID+'|'+I+'|'+T);
        else if (!hasCoord) console.log('spawn|coordinator|'+ID+'|'+I+'|'+T);
        else console.log('move|$S_SELECTED|'+ID+'|'+I+'|Reviews done → Selected');
      }
      if (sid === '$S_SELECTED' && !isTestCard) {
        console.log('move|$S_IN_PROGRESS|'+ID+'|'+I+'|Selected → In Progress');
        console.log('spawn|developer|'+ID+'|'+I+'|'+T);
      }
      if (sid === '$S_IN_PROGRESS') {
        if (hasDev) {
          console.log('move|$S_IN_REVIEW|'+ID+'|'+I+'|Developer done → In Review');
          console.log('spawn|tester|'+ID+'|'+I+'|'+T);
        } else {
          console.log('spawn|developer|'+ID+'|'+I+'|'+T);
        }
      }
      if (sid === '$S_IN_REVIEW') {
        // Only act on tester results if they came AFTER the last dev summary (original or rework)
        // This prevents old tester FAIL comments from immediately bouncing cards back to QA Fail
        const testerIsNew = lastTesterIdx > lastDevAnyIdx;
        if (testerIsNew && hasTestPass) console.log('move|$S_DONE|'+ID+'|'+I+'|Tester PASSED → Done');
        else if (testerIsNew && hasTestFail) console.log('move|$S_QA_FAIL|'+ID+'|'+I+'|Tester FAILED → QA Fail');
        else console.log('spawn|tester|'+ID+'|'+I+'|'+T);
      }
      if (sid === '$S_QA_FAIL') {
        if (failCount >= MAX_QA_CYCLES) {
          console.log('escalate|'+ID+'|'+I+'|'+T+'|STUCK after '+failCount+' QA failures');
        } else if (hasDevRework) {
          console.log('move|$S_IN_REVIEW|'+ID+'|'+I+'|Rework done → In Review');
          console.log('spawn|tester_rework|'+ID+'|'+I+'|'+T);
        } else {
          console.log('spawn|developer_rework|'+ID+'|'+I+'|'+T);
        }
      }
      if (sid === '$S_DONE') {
        if (hasDocs) console.log('move|$S_NEEDS_DOCS|'+ID+'|'+I+'|Docs done → Needs Docs');
        else console.log('spawn|docs_writer|'+ID+'|'+I+'|'+T);
      }
    }
    } catch(e) {}
  " 2>/dev/null)

  if [ -z "$ACTIONS" ]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  while IFS='|' read -r atype val1 aid aident val2; do
    [ -z "$atype" ] && continue
    if [ "$atype" = "escalate" ]; then
      local esc_key="${aident}_escalate"
      if ! agent_alive "$esc_key"; then
        local esc_retries=$(get_retries "$esc_key")
        if [ "$esc_retries" -lt 1 ]; then
          echo -e "${RED}${BOLD}${aident}${RESET} ${DIM}${val2} — escalating to orchestrator${RESET}"
          RAW_DESC=$(gql "{\"query\": \"{ issue(id: \\\"${aid}\\\") { description comments(last:10) { nodes { body } } } }\"}" 2>/dev/null)
          ESC_CONTEXT=$(echo "$RAW_DESC" | "$NODE_BIN" -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const j=JSON.parse(d);const desc=(j.data.issue.description||"").substring(0,1500);const comments=(j.data.issue.comments.nodes||[]).map(c=>c.body).join("\n---\n").substring(0,3000);console.log("DESCRIPTION:\n"+desc+"\n\nCOMMENTS:\n"+comments)}catch(e){console.log("")}})' 2>/dev/null)
          local esc_prompt="You are the Orchestrator performing emergency triage on card $aident: \"$val1\". This card has FAILED QA $((${val2##* })) times. The rework agents could not fix it.

Your job:
1. Read the Tester failure comments below to understand EXACTLY what is broken
2. Read the relevant source files in $PROJECT_DIR
3. Make the minimal fix directly (TypeScript errors, prettier formatting, missing imports, etc.)
4. Run: cd $PROJECT_DIR && $TEST_CMD 2>&1 | head -20
5. Run: cd $PROJECT_DIR && $LINT_CMD 2>&1 | tail -5
6. Commit with message: fix($aident): orchestrator triage — [description of fix]
7. Post a 'Developer Summary (Rework)' comment on Linear (issue $aid) explaining what you fixed
8. Use curl to post: curl -s -X POST https://api.linear.app/graphql -H 'Content-Type: application/json' -H 'Authorization: $API_KEY' -d '{\"query\":\"mutation(\$i:String!,\$b:String!){commentCreate(input:{issueId:\$i,body:\$b}){success}}\",\"variables\":{\"i\":\"$aid\",\"b\":\"YOUR_SUMMARY\"}}'

If the fix requires significant refactoring (not a mechanical fix), instead:
1. Post a comment explaining why it cannot be auto-fixed
2. Create a new scoped Linear card for the specific fix needed

Card context:
$ESC_CONTEXT"
          (
            cd "$PROJECT_DIR"
            "$CLAUDE_BIN" -p "$esc_prompt" --dangerously-skip-permissions 2>/dev/null
          ) &
          local esc_pid=$!
          echo "$esc_pid" > "$AGENTS_DIR/${esc_key}.pid"
          inc_retries "$esc_key"
        fi
      fi
    elif [ "$atype" = "move" ]; then
      move_issue "$aid" "$val1"
      echo -e "${GREEN}${BOLD}${aident}${RESET} ${DIM}${val2}${RESET}"
    elif [ "$atype" = "spawn" ]; then
      RAW_DESC=$(gql "{\"query\": \"{ issue(id: \\\"${aid}\\\") { description } }\"}" 2>/dev/null)
      DESC=$(echo "$RAW_DESC" | "$NODE_BIN" -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const j=JSON.parse(d);console.log((j.data.issue.description||"").substring(0,3000))}catch(e){console.log("")}})' 2>/dev/null)
      spawn_agent "$val1" "$aident" "$aid" "$val2" "$DESC"
    fi
  done <<< "$ACTIONS"

  # Push to GitHub every PUSH_INTERVAL polls
  POLL_COUNT=$((POLL_COUNT + 1))
  if [ "$((POLL_COUNT % PUSH_INTERVAL))" -eq 0 ]; then
    try_push
  fi

  sleep "$POLL_INTERVAL"
done
