#!/bin/bash
# Live operations are opt-in; cloud preparation and audits stay inert.
if [[ "${LINEAR_PIPELINE_ENABLE_LIVE:-}" != "1" ]]; then
  printf '%s\n' 'Live pipeline disabled. Static audit: python3 tools/cloud_audit.py'
  exit 0
fi
# End live-operation gate.
# ─────────────────────────────────────────────────────────────────
# Pipeline Watcher — live terminal feed of Linear card activity.
#
# Shows:
#   - Card-style boxes for agent comments (with full body)
#   - Status change notifications
#   - Dashboard grid every N polls
#
# Usage:
#   bash scripts/pipeline-watch.sh
# ─────────────────────────────────────────────────────────────────

set -uo pipefail

# Load config
ENV_FILE="$(dirname "$(dirname "$0")")/.env"
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

API_KEY="${LINEAR_API_KEY}"
TEAM_ID="${LINEAR_TEAM_ID}"
POLL_INTERVAL="${POLL_INTERVAL:-3}"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# State tracking
STATE_DIR="/tmp/linear-pipeline-watch-$$"
mkdir -p "$STATE_DIR"
SEEN_COMMENTS="$STATE_DIR/seen_comments"
CARD_STATES="$STATE_DIR/card_states"
touch "$SEEN_COMMENTS" "$CARD_STATES"

cleanup() {
    rm -rf "$STATE_DIR"
    echo ""
    echo -e "${DIM}Pipeline watcher stopped.${RESET}"
    exit 0
}
trap cleanup INT TERM

NODE_BIN=$(which node 2>/dev/null || echo "/tmp/node-v22.14.0-darwin-arm64/bin/node")

fetch_cards() {
    curl -s -X POST https://api.linear.app/graphql \
        -H "Content-Type: application/json" \
        -H "Authorization: $API_KEY" \
        -d "{\"query\": \"query { team(id: \\\"$TEAM_ID\\\") { issues(first: 50, orderBy: updatedAt) { nodes { id identifier title number state { name } updatedAt comments(first: 20) { nodes { id body createdAt user { name } } } } } } }\"}"
}

ts() { date "+%H:%M:%S"; }

# ── Agent detection ──
agent_name() {
    local body="$1"
    if echo "$body" | grep -qi "Architect Assessment"; then echo "Architect (Assessment)";
    elif echo "$body" | grep -qi "Architect Review"; then echo "Architect (Design)";
    elif echo "$body" | grep -qi "Agent Builder Assessment"; then echo "Agent Builder";
    elif echo "$body" | grep -qi "Consolidated Pre-Development Plan"; then echo "Coordinator (Plan)";
    elif echo "$body" | grep -qi "Coordinator Review"; then echo "Coordinator";
    elif echo "$body" | grep -qi "Developer Summary (Rework)"; then echo "Developer (Rework)";
    elif echo "$body" | grep -qi "Developer Summary"; then echo "Developer";
    elif echo "$body" | grep -qi "Developer Started"; then echo "Developer (Started)";
    elif echo "$body" | grep -qi "Tester Results.*PASSED"; then echo "Tester (PASSED)";
    elif echo "$body" | grep -qi "Tester Results.*FAILED"; then echo "Tester (FAILED)";
    elif echo "$body" | grep -qi "Tester.*REJECTED"; then echo "Tester (REJECTED)";
    elif echo "$body" | grep -qi "QA Review.*APPROVED"; then echo "QA Reviewer (APPROVED)";
    elif echo "$body" | grep -qi "QA Review.*CHANGES"; then echo "QA Reviewer (CHANGES)";
    elif echo "$body" | grep -qi "Docs Writer"; then echo "Docs Writer";
    elif echo "$body" | grep -qi "DevOps"; then echo "DevOps";
    else echo "Comment"; fi
}

agent_color() {
    case "$1" in
        Architect*)       echo "$CYAN" ;;
        "Agent Builder"*) echo "$MAGENTA" ;;
        Coordinator*)     echo "$YELLOW" ;;
        Developer*)       echo "$BLUE" ;;
        "Tester (PASSED)") echo "$GREEN" ;;
        "Tester (FAILED)"|"Tester (REJECTED)") echo "$RED" ;;
        "QA Reviewer"*)   echo "$YELLOW" ;;
        "Docs Writer")    echo "$DIM" ;;
        DevOps)           echo "$RED" ;;
        *)                echo "$RESET" ;;
    esac
}

status_color() {
    case "$1" in
        Triage|Backlog)         echo "$DIM" ;;
        Todo)                   echo "$BLUE" ;;
        "Selected for Development") echo "$CYAN" ;;
        "In Progress")          echo "$YELLOW" ;;
        "In Review")            echo "$MAGENTA" ;;
        "QA Fail")              echo "$RED" ;;
        Done)                   echo "$GREEN" ;;
        "Needs Documentation")  echo "$GREEN" ;;
        *)                      echo "$RESET" ;;
    esac
}

# ── Print a card-style comment box ──
# Format:
# ┌─ CARD-124 | Architect (Design)
# |  Add Mongoose userId Multi-Tenancy Middleware
# |  Status: In Progress  10:25 AM
# |  Risk: HIGH
# |  Areas: Data model, Middleware
# |
# |  [full comment body, indented]
# └──────────────────────────────────────────
print_comment_box() {
    local card_id="$1"
    local card_title="$2"
    local card_status="$3"
    local agent="$4"
    local body="$5"
    local suffix="${6:-}"

    local COLOR
    COLOR=$(agent_color "$agent")
    local SCOLOR
    SCOLOR=$(status_color "$card_status")

    # Header
    echo -e "${COLOR}${BOLD}┌─ ${card_id} │ ${agent}${RESET}${suffix:+  ${DIM}${suffix}${RESET}}"
    echo -e "${COLOR}│${RESET}  ${DIM}${card_title}${RESET}"
    echo -e "${COLOR}│${RESET}  Status: ${SCOLOR}${BOLD}${card_status}${RESET}"

    # Extract key metadata from body
    local risk=$(echo "$body" | grep -o '\*\*Risk level:\*\* [A-Za-z]*' | head -1 | sed 's/\*\*Risk level:\*\* //')
    local areas=$(echo "$body" | grep -o '\*\*Affected areas:\*\* .*' | head -1 | sed 's/\*\*Affected areas:\*\* //')
    local verdict=$(echo "$body" | grep -oi 'Verdict: [A-Z ]*' | head -1)
    local checklist_count
    checklist_count=$(echo "$body" | grep -c '^\- \[' 2>/dev/null) || checklist_count=0

    [ -n "$risk" ] && echo -e "${COLOR}│${RESET}  Risk: ${BOLD}${risk}${RESET}"
    [ -n "$areas" ] && echo -e "${COLOR}│${RESET}  Areas: ${areas}"
    [ -n "$verdict" ] && echo -e "${COLOR}│${RESET}  ${BOLD}${verdict}${RESET}"
    [ "$checklist_count" -gt 0 ] 2>/dev/null && echo -e "${COLOR}│${RESET}  Checklist: ${checklist_count} items"

    # Full comment body — pre-wrap then add color prefix
    local tw
    tw=$(tput cols 2>/dev/null || echo 80)
    local cw=$((tw - 4))  # space for "| " prefix

    echo -e "${COLOR}│${RESET}"
    echo "$body" | fold -s -w "$cw" | while IFS= read -r wline; do
        printf '%b' "${COLOR}│${RESET} ${wline}\n"
    done

    # Footer
    local fw=$((tw - 2))
    echo -e "${COLOR}└$(printf '─%.0s' $(seq 1 $fw))${RESET}"
    echo ""
}

# ── Header ──
echo ""
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
HEADER_LINE=$(printf '━%.0s' $(seq 1 $TERM_WIDTH))
echo -e "${BOLD}${HEADER_LINE}${RESET}"
echo -e "${BOLD}  Linear Pipeline Watcher${RESET}  ${DIM}polling every ${POLL_INTERVAL}s${RESET}"
echo -e "${BOLD}${HEADER_LINE}${RESET}"
echo -e "  ${DIM}Ctrl+C to stop${RESET}"
echo ""

# ── Main loop ──
FIRST_RUN=true
POLL_COUNT=0

while true; do
    RAW_DATA=$(fetch_cards 2>/dev/null | tr -d '\000-\011\013-\014\016-\037' || echo '{}')
    ALL_CARDS=$(echo "$RAW_DATA" | jq '[.data.team.issues.nodes // []] | add // [] | [.[] | select(.state.name != "On Github" and .state.name != "Done" and .state.name != "Needs documentation" and .state.name != "Canceled" and .state.name != "Duplicate")] | sort_by(.number)' 2>/dev/null || echo '[]')

    echo "$ALL_CARDS" | jq -c '.[]' 2>/dev/null | while read -r card; do
        CARD_ID=$(echo "$card" | jq -r '.identifier')
        CARD_TITLE=$(echo "$card" | jq -r '.title' | cut -c1-60)
        CARD_STATUS=$(echo "$card" | jq -r '.state.name')
        CARD_NUMBER=$(echo "$card" | jq -r '.number')
        CARD_UPDATED=$(echo "$card" | jq -r '.updatedAt')

        # Compute relative time for card
        CARD_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%S" "${CARD_UPDATED%%.*}" "+%s" 2>/dev/null || echo "0")
        NOW_EPOCH=$(date "+%s")
        CARD_AGE_MINS=$(( (NOW_EPOCH - CARD_EPOCH) / 60 ))
        if [ "$CARD_AGE_MINS" -lt 1 ]; then
            CARD_AGE="just now"
        elif [ "$CARD_AGE_MINS" -lt 60 ]; then
            CARD_AGE="${CARD_AGE_MINS}m ago"
        elif [ "$CARD_AGE_MINS" -lt 1440 ]; then
            CARD_AGE="$(( CARD_AGE_MINS / 60 ))h ago"
        else
            CARD_AGE="$(( CARD_AGE_MINS / 1440 ))d ago"
        fi

        # ── Status changes ──
        PREV_STATUS=$(grep "^${CARD_ID}=" "$CARD_STATES" 2>/dev/null | cut -d= -f2-)
        if [ -n "$PREV_STATUS" ] && [ "$PREV_STATUS" != "$CARD_STATUS" ]; then
            SCOLOR=$(status_color "$CARD_STATUS")
            echo -e "  ${BOLD}${CARD_ID}${RESET}  ${DIM}${PREV_STATUS}${RESET} -> ${SCOLOR}${BOLD}${CARD_STATUS}${RESET}  ${DIM}(${CARD_AGE})${RESET}"
            echo -e "    ${DIM}${CARD_TITLE}${RESET}"
            echo ""
        elif [ -z "$PREV_STATUS" ] && [ "$FIRST_RUN" != "true" ]; then
            SCOLOR=$(status_color "$CARD_STATUS")
            echo -e "  ${GREEN}${BOLD}NEW${RESET}  ${BOLD}${CARD_ID}${RESET}  ${SCOLOR}${CARD_STATUS}${RESET}"
            echo -e "    ${DIM}${CARD_TITLE}${RESET}"
            echo ""
        fi

        # Update stored status
        if grep -q "^${CARD_ID}=" "$CARD_STATES" 2>/dev/null; then
            sed -i '' "s|^${CARD_ID}=.*|${CARD_ID}=${CARD_STATUS}|" "$CARD_STATES"
        else
            echo "${CARD_ID}=${CARD_STATUS}" >> "$CARD_STATES"
        fi

        # ── Comments ──
        if [ "$FIRST_RUN" = "true" ]; then
            # Seed all comment IDs as seen
            echo "$card" | jq -r '.comments.nodes[]?.id' 2>/dev/null | while read -r cid; do
                echo "$cid" >> "$SEEN_COMMENTS"
            done
            # Show latest agent comment per card for context
            LATEST=$(echo "$card" | jq -c '[.comments.nodes[]? | select(.body | test("Architect Review|Coordinator Review|Developer Summary|Tester Results|Docs Writer"; "i"))] | last' 2>/dev/null)
            if [ -n "$LATEST" ] && [ "$LATEST" != "null" ]; then
                BODY=$(echo "$LATEST" | jq -r '.body')
                CTIME=$(echo "$LATEST" | jq -r '.createdAt')
                # Calculate relative time
                COMMENT_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%S" "${CTIME%%.*}" "+%s" 2>/dev/null || echo "0")
                NOW_EPOCH=$(date "+%s")
                DIFF_MINS=$(( (NOW_EPOCH - COMMENT_EPOCH) / 60 ))
                if [ "$DIFF_MINS" -lt 1 ]; then
                    REL_TIME="just now"
                elif [ "$DIFF_MINS" -lt 60 ]; then
                    REL_TIME="${DIFF_MINS}m ago"
                elif [ "$DIFF_MINS" -lt 1440 ]; then
                    REL_TIME="$(( DIFF_MINS / 60 ))h ago"
                else
                    REL_TIME="$(( DIFF_MINS / 1440 ))d ago"
                fi
                AGENT=$(agent_name "$BODY")
                print_comment_box "$CARD_ID" "$CARD_TITLE" "$CARD_STATUS" "$AGENT" "$BODY" "(${REL_TIME})"
            fi
        else
            echo "$card" | jq -c '.comments.nodes[]?' 2>/dev/null | while read -r comment; do
                CID=$(echo "$comment" | jq -r '.id')
                if grep -q "^${CID}$" "$SEEN_COMMENTS" 2>/dev/null; then continue; fi
                echo "$CID" >> "$SEEN_COMMENTS"

                BODY=$(echo "$comment" | jq -r '.body')
                CTIME2=$(echo "$comment" | jq -r '.createdAt')
                C2_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%S" "${CTIME2%%.*}" "+%s" 2>/dev/null || echo "0")
                C2_MINS=$(( (NOW_EPOCH - C2_EPOCH) / 60 ))
                if [ "$C2_MINS" -lt 1 ]; then C2_AGE="just now";
                elif [ "$C2_MINS" -lt 60 ]; then C2_AGE="${C2_MINS}m ago";
                else C2_AGE="$(( C2_MINS / 60 ))h ago"; fi
                AGENT=$(agent_name "$BODY")
                print_comment_box "$CARD_ID" "$CARD_TITLE" "$CARD_STATUS" "$AGENT" "$BODY" "(${C2_AGE})"
            done
        fi
    done

    if [ "$FIRST_RUN" = "true" ]; then
        CARD_COUNT=$(echo "$ALL_CARDS" | jq 'length' 2>/dev/null || echo "0")
        echo -e "  ${GREEN}Watching ${CARD_COUNT} cards. Waiting for activity...${RESET}"
        echo ""
        FIRST_RUN=false
    fi

    # ── Dashboard every N polls ──
    POLL_COUNT=$((POLL_COUNT + 1))
    DASHBOARD_EVERY=${DASHBOARD_EVERY:-10}
    if [ "$POLL_COUNT" -ge "$DASHBOARD_EVERY" ]; then
        POLL_COUNT=0
        DASHBOARD_CARDS=$(echo "$ALL_CARDS" | jq -c "[.[] | select(.number >= ${MIN_CARD:-1} and .number <= ${MAX_CARD:-9999}) | select(.state.name != \"On Github\")] | sort_by(.number)" 2>/dev/null || echo '[]')
        DASHBOARD_COUNT=$(echo "$DASHBOARD_CARDS" | jq 'length' 2>/dev/null || echo "0")

        if [ "$DASHBOARD_COUNT" -gt "0" ]; then
            echo -e "  ${BOLD}── Card Dashboard ──${RESET}"
            echo ""
            echo "$DASHBOARD_CARDS" | jq -c '.[]' 2>/dev/null | while read -r mcard; do
                M_ID=$(echo "$mcard" | jq -r '.identifier')
                M_TITLE=$(echo "$mcard" | jq -r '.title' | cut -c1-42)
                M_STATUS=$(echo "$mcard" | jq -r '.state.name')
                M_COMMENTS=$(echo "$mcard" | jq -r '[.comments.nodes[].body // ""] | join("\n")' 2>/dev/null)

                HAS_ARCH=" "
                HAS_COORD=" "
                HAS_DEV=" "
                HAS_TEST=" "
                if echo "$M_COMMENTS" | grep -qi "Architect Review"; then HAS_ARCH="${MAGENTA}A${RESET}"; fi
                if echo "$M_COMMENTS" | grep -qi "Coordinator Review"; then HAS_COORD="${CYAN}C${RESET}"; fi
                if echo "$M_COMMENTS" | grep -qi "Developer Summary"; then HAS_DEV="${GREEN}D${RESET}"; fi
                if echo "$M_COMMENTS" | grep -qi "Tester Results"; then HAS_TEST="${GREEN}T${RESET}"; fi
                if echo "$M_COMMENTS" | grep -qi "Tester Results.*FAILED\|Tester.*REJECTED"; then HAS_TEST="${RED}T${RESET}"; fi

                SCOLOR=$(status_color "$M_STATUS")
                printf "    ${BOLD}%-8s${RESET} ${SCOLOR}%-14s${RESET} [${HAS_ARCH}${HAS_COORD}${HAS_DEV}${HAS_TEST}] %-42s\n" "$M_ID" "$M_STATUS" "$M_TITLE"
            done
            echo ""
            echo -e "    ${DIM}Legend: ${MAGENTA}A${DIM}=Architect ${CYAN}C${DIM}=Coordinator ${GREEN}D${DIM}=Developer ${GREEN}T${DIM}=Tester(pass) ${RED}T${DIM}=Tester(fail)${RESET}"
            echo ""
        fi
    fi

    sleep "$POLL_INTERVAL"
done
