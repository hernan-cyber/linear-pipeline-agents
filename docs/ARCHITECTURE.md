# Architecture

Technical deep-dive into the Linear Pipeline Agents system.

## Comment-Based State Machine

The pipeline uses a hybrid state model: Linear's workflow statuses provide the coarse-grained state (Backlog, In Progress, In Review, etc.), but the **comments on each card** are the fine-grained state markers that drive decisions.

Each agent posts a specifically-named comment when it finishes:
- `Architect Review` — Architect agent completed its review
- `Agent Builder Assessment` — Agent Builder completed its assessment
- `Coordinator Review` or `Consolidated Pre-Development Plan` — Coordinator finished consolidation
- `Developer Summary` — Developer finished implementation
- `Developer Summary (Rework)` — Developer finished a rework cycle
- `Tester Results — PASSED` — Tester validated successfully
- `Tester Results — FAILED` — Tester found failures
- `Docs Writer` — Documentation review complete

The driver's polling loop reads both the card status and its comments, then determines the next action. For example, a card in "Backlog" with no "Architect Review" comment gets an architect agent spawned. A card in "Backlog" WITH an Architect Review but WITHOUT a Coordinator Review gets a coordinator. This means the comments are the real source of truth for pipeline progress — the status field is a consequence, not a cause.

## Why Comment Index Ordering Matters

### The QA Loop Bug

Early versions of the pipeline used simple presence checks:

```javascript
const hasTestFail = has('Tester Results — FAILED');
```

This worked for the happy path but created an infinite loop in the QA cycle:

1. Card enters "In Review"
2. Tester posts "Tester Results — FAILED"
3. Driver moves card to "QA Fail"
4. Developer reworks and posts "Developer Summary (Rework)"
5. Driver moves card back to "In Review"
6. Driver checks: `has('Tester Results — FAILED')` => `true` (the old comment is still there!)
7. Driver immediately moves card back to "QA Fail"
8. Steps 4-7 repeat forever

The card would bounce between "In Review" and "QA Fail" on every poll cycle because the old failure comment never goes away — Linear comments are append-only.

### The Fix: Index-Based Ordering

The solution tracks the **array index** of the last comment matching each pattern:

```javascript
const lastTesterIdx = cs.reduce((acc, c, idx) =>
  (c.body?.includes('Tester Results') || c.body?.includes('Tester —')) ? idx : acc, -1);
const lastDevAnyIdx = cs.reduce((acc, c, idx) =>
  c.body?.includes('Developer Summary') ? idx : acc, -1);
const testerIsNew = lastTesterIdx > lastDevAnyIdx;
```

The key insight: **only act on tester results if they came AFTER the last developer summary**. This means:

- After a developer posts a rework summary at index 8, and the old tester failure is at index 6, `testerIsNew` is `false` — the driver spawns a new tester instead of bouncing the card
- When the new tester posts results at index 9, `testerIsNew` is `true` — now the driver acts on the result

Similarly, `hasDevRework` (used in the QA Fail state) is only `true` when `lastDevReworkIdx > lastTesterIdx`, preventing old rework comments from re-triggering the review cycle.

This index-based approach was debugged over many iterations with real cards cycling through the pipeline. It is the only reliable mechanism for determining current state in an append-only comment stream.

## Agent Concurrency Model

### PID Tracking

Each spawned agent runs as a background process. The driver tracks agents via PID files:

```
/tmp/linear-pipeline-state/agents/PROJ-42_developer.pid
/tmp/linear-pipeline-state/agents/PROJ-43_tester.pid
```

Before spawning an agent, the driver calls `agent_alive()` which:
1. Checks if a PID file exists for the card+role combination
2. Sends `kill -0` to test if the process is still running
3. If the process is dead, removes the stale PID file
4. Returns alive/not-alive

### MAX_AGENTS Cap

The `count_agents()` function iterates all PID files, checks which processes are still alive, cleans up dead ones, and returns the count. If the count meets `MAX_AGENTS`, no new agents are spawned until one finishes.

### Single-Driver Lockfile

Only one driver instance should run at a time. On startup, the driver:
1. Checks for `/tmp/linear-pipeline-state/driver.lock`
2. If it exists and the PID inside is alive, kills the old driver
3. Writes its own PID to the lockfile
4. Registers a trap to remove the lockfile on exit

## Retry and Escalation

### Retry Tracking

Each card+role combination has a retry counter stored as a file:

```
/tmp/linear-pipeline-state/retries/PROJ-42_developer.count
```

Every time `spawn_agent()` is called, it increments the counter via `inc_retries()`. Before spawning, it checks if `retries >= MAX_RETRIES` and skips the card if exhausted.

### Escalation to Orchestrator

When a card accumulates 3 or more QA failures (`failCount >= MAX_QA_CYCLES`), the normal developer-rework loop is bypassed. Instead, the driver emits an `escalate` action that spawns an orchestrator agent.

The orchestrator:
1. Receives the full card context (description + last 10 comments)
2. Reads the actual source files to understand the failure
3. Makes minimal direct fixes (type errors, formatting, missing imports)
4. Runs the test and lint commands to verify
5. Commits with a descriptive message
6. Posts a "Developer Summary (Rework)" comment so the normal pipeline resumes

The orchestrator only gets one attempt (`esc_retries < 1`). If even the orchestrator cannot fix it, the card stays in QA Fail for manual intervention.

## The Watcher

The watcher (`pipeline-watch.sh`) is a separate, read-only process that provides live visibility into the pipeline.

### How It Works

1. Polls Linear every `POLL_INTERVAL` seconds (default 3s, faster than the driver)
2. Maintains two state files:
   - `seen_comments` — IDs of all comments already displayed
   - `card_states` — last known status of each card

### Comment Detection

On each poll:
- Extract all comment IDs from the response
- Compare against `seen_comments`
- New comments get printed as card-style boxes with agent detection, metadata extraction, and full body display

### Status Change Detection

On each poll:
- Compare each card's current status against `card_states`
- If changed, print a status transition notification with relative timestamps
- New cards (not in `card_states` and not first run) get a "NEW" notification

### First-Run Seeding

On the very first poll, the watcher seeds all existing comment IDs into `seen_comments` so it does not replay historical comments. It shows only the latest agent comment per card for context, then transitions to live monitoring.

### Dashboard Grid

Every `DASHBOARD_EVERY` polls (default 10), the watcher prints a compact grid showing all cards within the configured range, their current status, and a legend showing which pipeline stages have completed ([A]rchitect, [C]oordinator, [D]eveloper, [T]ester).

## Data Flow

```
Linear API
    |
    | (poll every POLL_INTERVAL seconds)
    v
Pipeline Driver
    |
    | (parse card status + comments)
    v
Action Lines (spawn|move|escalate)
    |
    +---> move_issue() ---> Linear API (status update)
    |
    +---> spawn_agent() ---> Claude Code CLI (background process)
                                |
                                | (reads code, posts comment)
                                v
                            Linear API (comment created)
                                |
                                | (next poll cycle reads new comment)
                                v
                            Pipeline Driver (determines next action)
```

The system is eventually consistent: an agent posts a comment, and on the next poll cycle (30s later by default), the driver reads it and advances the card. There is no webhook or real-time notification — the polling loop is the heartbeat.
