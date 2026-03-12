# cc-notify Marketing Ideas

## Core message

Push-based vs pull-based. Remote Control and similar tools require you to check.
cc-notify finds you the moment something needs attention, then drops you into
the right tmux pane in one tap.

The demo is everything — a 30-second recording of the full flow (Claude running
in tmux → notification on lock screen → tap → Blink opens → right pane, zoomed)
communicates the value instantly. Record this first. Everything else builds around it.

---

## X (Twitter) — highest ROI, do this first

**Audience:** dev Twitter, AI coding workflow crowd, tmux/terminal power users.

**Format:** Short thread.
1. Lead tweet: demo video + one line ("Built this so I stop babysitting AI agents")
2. The problem: "Claude finished 20 mins ago. I didn't know. That's 20 minutes gone."
3. The stack: tmux + ntfy + Blink Shell — open source, self-host everything
4. The extensibility: Discord, Telegram, Teams, email — one curl command per destination

**Voice:** "I built this because I was annoyed" outperforms product launch framing.

**Amplifiers to tag:**
- `@blinkshell` — showcase of their x-callback-url used creatively; likely to repost
- `@ntfysh` — their tool is central to the stack
- Anthropic devrel — they share CC ecosystem tools periodically

**Hashtags:** #ClaudeCode #AIAgents #DevTools #tmux

---

## Personal website — the canonical piece

Long-form blog post. This is what X threads and LinkedIn posts link to,
and what ranks in search long-term.

**Title candidates:**
- "Push notifications for AI agents running in tmux"
- "Stop babysitting Claude Code — get notified when it needs you"
- "The missing piece of the agentic coding workflow"

**Structure:**
1. Problem: walking away, coming back too late or too early
2. The pull vs push distinction (Remote Control vs cc-notify)
3. Architecture walkthrough — Mermaid state diagram, the Blink deep link flow
4. Demo video embedded
5. Install instructions (5 minutes)
6. Extensibility: add any destination in ~20 lines of bash

**SEO targets (low competition, growing fast):**
- "Claude Code notifications"
- "AI agent monitoring tmux"
- "tmux push notifications"
- "Claude Code remote notifications"

---

## LinkedIn — lower priority, different framing

**Audience:** founders, PMs, technical leads — less code, more outcome.

**Framing:** "I run 5+ AI agents in parallel overnight. Here's how I manage them from my phone."

Skip the stack in the post body. Lead with the outcome:
- You kick off agents before bed
- You get push notifications when they're blocked or done
- You tap to connect, unblock them, go back to sleep
- In the morning, review what got done

One screenshot of the notification on a phone lock screen. Link to blog post for the how.

---

## The demo video (blocking asset)

Nothing lands without this. Capture it first.

**Structure: two acts, ~50 seconds total**

### Act 1 — Notification → tap → zoomed pane (~25s) — lead with this

**Shot 1 — Mac screen recording (~5s)**
Open the NTM dashboard in Safari on iPhone, mirrored to Mac. Show 3–4 session cards,
all yellow/idle. Header: "19 sessions · 29 agents". Cut to a tmux terminal where
Claude Code is mid-task in cc-notify-demo. You're not watching it.

**Shot 2 — iPhone (camera or screen mirror) (~3s)**
Lock screen. Notification drops in:
  `ovh2 · cc-notify-demo`
  `Claude stopped and is waiting for input`
Let it sit 1 second so viewers can read it.

**Shot 3 — iPhone, same shot (~10s)**
Tap the notification. Blink opens, SSH connects, tmux pane appears zoomed on the
exact pane where Claude is waiting. Type a short reply (`y` + Enter). Claude continues.

**Shot 4 — iPhone (~5s)**
Blink session active, Claude responding. Detach or let run.

### Act 2 — NTM dashboard (~20s)

**Shot 5 — iPhone, NTM dashboard (~10s)**
Open the NTM dashboard. Show session cards. Point out the session you just answered
is now green/active. Tap "Connect" on another session to demonstrate it works the
same way from the dashboard without needing a notification.

**Shot 6 — iPhone, "+ New" modal (~8s)**
Tap "+ New", type a project name, hit Launch. New card appears. Optional: tap
Connect immediately — shows the spawn→connect flow.

---

**Recording logistics:**

| What | How |
|------|-----|
| Mac terminal (tmux) | QuickTime screen recording |
| iPhone lock screen + tap | Camera pointed at phone OR QuickTime iPhone mirror (macOS Sequoia) |
| Blink connecting | iPhone screen mirror → Mac recording |
| NTM dashboard | iPhone screen mirror → Mac recording |

**Recommended:** Record desktop in one take. Record iPhone separately. The cut
from lock screen → Blink → dashboard is the wow moment.

**Tools:** Screenflick or QuickTime on Mac. Edit in iMovie or DaVinci Resolve (free).
Add captions for the key moments — most viewers watch muted.

---

## Potential amplifier communities

- Blink Shell community (iOS terminal power users — perfect audience)
- ntfy community / r/selfhosted
- r/ClaudeAI, r/MachineLearning, Hacker News (Show HN)
- AI coding Discord servers
- The broader "agentic coding" Twitter crowd (following Anthropic, Karpathy, etc.)

---

## Timing note

Agentic coding workflows are exploding right now (early 2026). People are just
starting to run multiple agents in parallel and hitting the "I need to babysit this"
problem. First-mover advantage on clear solutions to this problem is real.
