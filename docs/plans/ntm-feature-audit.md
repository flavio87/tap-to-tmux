# NTM Feature Audit: What We're Not Using (and How It Changes the Slack Bridge Plan)

> ⚠️ **STALE — NEEDS REDO.** Written 2026-02-23 against NTM v1.7.0 under the old `ntfy-notify` name. Preserved for reference only. Re-audit against current NTM version before acting on any recommendations here.

**Date:** 2026-02-23
**NTM Version:** 1.7.0

## Executive Summary

NTM v1.7.0 is far more capable than we've been treating it. We built ntfy-notify to fill gaps in NTM's notification system (which is real -- the webhook events are dead code for `agent.idle`). But NTM has ~60+ subcommands, a full REST API (`ntm serve`), robot mode (70+ `--robot-*` flags), `ntm wait --until=idle` for scripting, workflow pipelines, and much more. Several of these features can dramatically simplify the Slack bridge.

---

## Part 1: NTM Features We're Not Using

### 1. `ntm serve` -- Built-in HTTP Server + SSE Event Stream

**What it does:** Starts a REST API on localhost with Server-Sent Events (SSE) for real-time agent state changes.

```bash
ntm serve --port=7337
# Endpoints:
# GET  /api/sessions              -- list sessions
# GET  /api/sessions/{id}/health  -- health status
# GET  /api/sessions/{id}/status  -- detailed status
# POST /api/sessions              -- create session
# POST /api/sessions/{id}/attach  -- attach
# DELETE /api/sessions/{id}       -- kill
# GET  /events                    -- SSE event stream
# GET  /health                    -- server health
```

**Why it matters for Slack bridge:** Instead of polling `ntm health --json` every 5s in our own loop, we could subscribe to the SSE `/events` endpoint and get **real-time push notifications** when agents go idle.

**Status:** Not used. The NTM monitor polls `ntm health --json` in a bash while loop.

### 2. `ntm wait --until=idle` -- Script-Friendly Agent State Waiting

**What it does:** Blocks until agents reach a specified state. Returns proper exit codes for scripting.

```bash
ntm wait myproject --until=idle              # blocks until all agents are idle
ntm wait myproject --until=idle --timeout=2m # with timeout
ntm wait myproject --until=healthy           # blocks until all healthy
ntm wait myproject --until=idle --type=claude # filter by agent type
ntm wait myproject --until=idle --pane=2     # filter by pane
```

Exit codes: 0=condition met, 1=timeout, 2=error, 3=agent error (with --exit-on-error).

**Why it matters for Slack bridge:** After sending a prompt via `ntm send`, simply `ntm wait session --until=idle` instead of building a polling loop.

**Status:** Not used anywhere in ntfy-notify. **Now leveraged** in the monitor's `--stream` mode.

### 3. Robot Mode -- 70+ Machine-Readable Flags

**What it does:** Every NTM command has a `--robot-*` equivalent that outputs structured JSON.

Key robot commands for our use cases:
```bash
ntm --robot-status=session       # JSON session status
ntm --robot-health=session       # JSON health with per-agent details
ntm --robot-tail=session         # Capture pane output as JSON
ntm --robot-errors=session       # Error output as JSON
ntm --robot-capabilities         # Self-describing API
ntm --robot-monitor=session      # Proactive monitoring as JSONL stream
```

**Status:** `--robot-tail` **now used** in `extract_pane_context_robot()`. `--robot-errors` **now used** in health check.

### 4. `ntm --robot-monitor` -- JSONL Monitoring Stream

**What it does:** Continuous JSONL output of proactive warnings (stuck agents, resource issues).

**IMPORTANT FINDING:** `--robot-monitor` emits **proactive warnings** (stuck, resource), NOT idle state transitions. It uses a 30s polling interval internally and is designed for detecting problems, not for idle->active monitoring. **Our polling loop is still needed for state transition detection.**

**Status:** Evaluated and found unsuitable as a replacement for the polling loop.

### 5. `ntm logs` / `ntm errors` / `ntm copy` -- Output Capture

**What it does:**
- `ntm logs session` -- aggregated logs from all panes with filtering
- `ntm errors session` -- just error output (tracebacks, failures, rate limits)
- `ntm copy session:pane` -- copy pane output to clipboard or file
- `ntm extract session pane` -- extract code blocks from output

**Status:** `ntm --robot-errors` **now used** in health check. `ntm --robot-tail` **now used** in context extraction.

### 6. `ntm spawn` -- Full Session Creation with Recipes

6 built-in recipes, 4 workflow templates, 11 session templates, 5 personas. Supports `--with-cass` for auto-injecting historical context from CASS.

**Status:** Available for Slack bridge use. `--with-cass` recommended for Slack-spawned sessions.

### 7. `ntm assign` -- Smart Work Distribution

Intelligent work assignment with strategies: balanced, speed, quality, dependency, round-robin. `ntm send --smart` auto-selects best agent.

**Status:** Not used. Available for multi-agent Slack sessions.

### 8. `ntm doctor` -- Ecosystem Health Check

**What it does:** Validates all NTM dependencies, daemons, and configuration. Supports `--json` output.

**Status:** **Now integrated** into `ntfy-health-check.sh`.

### 9. NTM Notification System -- What's Working vs Dead

**Configured events:** agent.idle, agent.completed, agent.stopped, agent.error, agent.crashed, agent.rate_limited, agent.stuck

**What actually fires:** Only resilience events (crashes, rate limits). The `agent.idle` and `agent.completed` webhooks are **dead code** in v1.7.0. Our polling monitor remains the only working solution for idle detection.

**Shell notification channel** (not configured):
```toml
[notifications.shell]
enabled = false
command = "~/bin/notify.sh"
pass_json = true
```
Could replace our CC hook if it worked for idle events. Worth testing when NTM updates.

---

## Part 2: How This Changes the Slack Bridge Plan

### Revised Slack Bridge Architecture

```bash
# Instead of a complex Python daemon with custom monitoring:

# 1. Receive Slack message -> spawn session
ntm spawn "slack-${thread_id}" --cod=1 --with-cass

# 2. Send task
ntm send "slack-${thread_id}" --cod "cd /data/projects/foo && fix the auth bug"

# 3. Wait for completion (BLOCKING - no polling loop needed)
ntm wait "slack-${thread_id}" --until=idle

# 4. Capture result
result=$(ntm --robot-tail="slack-${thread_id}:1" --json)

# 5. Post result to Slack thread (via chat.postMessage)

# 6. Cleanup
ntm kill "slack-${thread_id}"
```

| Slack Bridge Need | Old Plan | NTM Feature |
|---|---|---|
| Detect Codex finished | Custom polling loop | `ntm wait --until=idle` |
| Spawn session | `ntm spawn slack-<id> --cod=1` | Same + `--with-cass` |
| Send user message | `ntm send` | Same + `--smart` for routing |
| Capture result | `tmux capture-pane` + Python | `ntm --robot-tail` |
| Monitor health | Python asyncio polling | `ntm serve` SSE or `ntm wait` |
| Session cleanup | Custom timer + tmux kill | `ntm kill session` |
| Error detection | Custom health field parsing | `ntm --robot-errors` |

---

## Part 3: Should We Deprecate ntfy-notify?

**No. Not yet.**

1. NTM's webhook for agent.idle is dead code -- most critical event doesn't fire
2. CC hook provides richer context (transcript extraction) than NTM webhooks
3. Cooldown-on-interaction system is unique to ntfy-notify
4. Dual delivery (ntfy + Slack) -- NTM webhook targets one URL

**Watch for:** NTM v1.8+ fixing webhook dead code, and `[notifications.shell]` working for idle events.

---

## Part 4: Changes Implemented

1. **`extract_pane_context_robot()`** in `ntfy-notify-common.sh` -- tries `ntm --robot-tail` first for cleaner output capture, falls back to tmux capture-pane + Python parsing
2. **`ntm doctor --json`** integrated into `ntfy-health-check.sh` -- validates NTM ecosystem health
3. **`ntm --robot-errors`** integrated into `ntfy-health-check.sh` -- reports agent errors for active sessions
4. **CLAUDE.md updated** with NTM feature awareness section

---

## Part 5: Future Recommendations

### For the Slack Bridge
1. Use `ntm wait` instead of custom monitoring loops
2. Use `ntm serve` SSE if real-time events needed beyond `wait`
3. Use `ntm spawn --with-cass` for historical context injection
4. Use `ntm --robot-tail` for clean output capture

### Long-term
1. Watch NTM webhook fix -- if agent.idle fires, polling monitor becomes redundant
2. Workflow pipelines for complex Slack requests ("implement, test, and review")
3. Ensemble reasoning from Slack ("analyze this architecture")
4. CASS-powered context -- search before spawning for richer context
