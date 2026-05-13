#!/usr/bin/env python3
"""NTM Status Dashboard Server

Serves the status dashboard HTML and provides a JSON API.

Agent activity is detected via CPU-tick sampling (reading /proc/PID/stat
twice, 3 seconds apart) because ntm health --json reports all running
processes as "active" regardless of whether they're actually working.

Endpoints:
  GET  /              Dashboard HTML
  GET  /api/status    All sessions with agent health (JSON)
  GET  /api/config    Blink Shell config for deep links (JSON)
  POST /api/spawn     Create new session (name required, spawns cc=1)
"""

import collections
import http.server
import json
import os
import re
import subprocess
import threading
import time
import urllib.parse
from datetime import datetime, timezone

_SEARCH_PATHS = [
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 "dashboard", "status.html"),
    os.path.expanduser("~/.local/share/ntm-dashboard/status.html"),
]
DASHBOARD_HTML = next((p for p in _SEARCH_PATHS if os.path.exists(p)),
                      _SEARCH_PATHS[1])

PORT = int(os.environ.get("DASHBOARD_PORT", "7338"))
HOST = os.environ.get("DASHBOARD_HOST", "127.0.0.1")

_VALID_SESSION_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")
_PROJECTS_DIR = os.environ.get("PROJECTS_DIR", os.path.expanduser("~/projects"))

# CPU tick threshold: above this in a 3-second window = actively working.
# Claude Code's idle event loop uses ~7-17 ticks/3s (heartbeats, keepalive).
# Truly active agents (mid-turn) use 100+ ticks/3s.
# Idle Codex (bun) uses 0 ticks/3s.
# Threshold of 30 cleanly separates idle-loop from real work.
try:
    _ACTIVE_TICK_THRESHOLD = int(
        os.environ.get("DASHBOARD_ACTIVE_TICK_THRESHOLD", "30")
    )
except ValueError:
    _ACTIVE_TICK_THRESHOLD = 30

# --- Security: bearer token auth (optional) ---
# Set DASHBOARD_TOKEN to require Authorization: Bearer <token> on API endpoints.
# When empty, API is open (backward compatible for localhost-only setups).
_AUTH_TOKEN = os.environ.get("DASHBOARD_TOKEN", "")

# --- Rate limiting ---
# Simple per-IP rate limiter: max requests per window.
_RATE_LIMIT_MAX = int(os.environ.get("DASHBOARD_RATE_LIMIT", "120"))
_RATE_LIMIT_WINDOW = 60  # seconds
_rate_lock = threading.Lock()
_rate_counters = collections.defaultdict(list)  # ip -> [timestamps]


def _rate_limit_check(ip):
    """Return True if the request should be allowed."""
    now = time.time()
    cutoff = now - _RATE_LIMIT_WINDOW
    with _rate_lock:
        _rate_counters[ip] = [t for t in _rate_counters[ip] if t > cutoff]
        if len(_rate_counters[ip]) >= _RATE_LIMIT_MAX:
            return False
        _rate_counters[ip].append(now)
        return True

# Map tmux pane_current_command to agent type codes.
# ntm's agent_type heuristic is unreliable (e.g., reports claude as cod),
# so we use the actual tmux process as source of truth.
_PROCESS_TO_TYPE = {
    "claude": "cc",
    "bun": "cod",       # Codex runs via bun — but check child for claude-code
    "node": "cod",       # Codex alternate — but check child for claude-code
    "gemini": "gmi",
    "aider": "aider",
}


def _resolve_type(cmd, pane_pid=None):
    """Resolve agent type, checking child process cmdline for bun/node.

    bun and node host both Codex and Claude Code CLI. Read /proc/<child>/cmdline
    to distinguish them instead of assuming bun == codex.
    """
    if cmd not in _PROCESS_TO_TYPE:
        return ""
    if cmd not in ("bun", "node") or pane_pid is None:
        return _PROCESS_TO_TYPE[cmd]
    try:
        children = subprocess.run(
            ["pgrep", "-P", str(pane_pid)],
            capture_output=True, text=True, timeout=3
        )
        for child_pid in children.stdout.strip().split("\n"):
            child_pid = child_pid.strip()
            if not child_pid:
                continue
            try:
                with open(f"/proc/{child_pid}/cmdline") as f:
                    cmdline = f.read().replace("\x00", " ").lower()
                if "claude" in cmdline:
                    return "cc"
                if "codex" in cmdline:
                    return "cod"
            except (FileNotFoundError, PermissionError):
                pass
    except Exception:
        pass
    return _PROCESS_TO_TYPE[cmd]  # fallback to cod


def load_config():
    """Load tap-to-tmux config.env values."""
    config = {
        "MACHINE": "",
        "SSH_USER": "",
        "SSH_HOST": "",
        "BLINK_KEY": "",
        "PROJECTS_DIR": "",
        "SSH_REMOTE_HOME": "",
    }
    config_path = os.path.expanduser(
        os.path.join(os.environ.get("XDG_CONFIG_HOME", "~/.config"),
                     "tap-to-tmux", "config.env"))
    if os.path.exists(config_path):
        with open(config_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, _, val = line.partition("=")
                    key = key.strip()
                    val = val.strip().strip('"').strip("'")
                    if key in config:
                        config[key] = val
    # Apply fallbacks for empty values
    if not config["MACHINE"]:
        config["MACHINE"] = os.uname().nodename
    if not config["SSH_USER"]:
        config["SSH_USER"] = os.environ.get("USER", "user")
    if not config["SSH_HOST"]:
        config["SSH_HOST"] = os.uname().nodename
    if not config["PROJECTS_DIR"]:
        config["PROJECTS_DIR"] = _PROJECTS_DIR
    if not config["SSH_REMOTE_HOME"]:
        # Remote home path for deep links; matches ntfy-notify-common.sh default.
        config["SSH_REMOTE_HOME"] = f"/home/{config['SSH_USER']}"
    return config


def get_project_sessions():
    """List tmux sessions that correspond to project directories.
    Excludes mob-* (temporary mobile grouped sessions)."""
    try:
        result = subprocess.run(
            ["tmux", "list-sessions", "-F", "#{session_name}"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return []
        sessions = []
        for name in result.stdout.strip().split("\n"):
            name = name.strip()
            if not name:
                continue
            if name.startswith("mob-"):
                continue
            if os.path.isdir(os.path.join(_PROJECTS_DIR, name)):
                sessions.append(name)
        return sorted(sessions)
    except Exception:
        return []


def _get_all_agent_pids():
    """Get all agent processes across all tmux panes.
    Returns dict of { 'session:pane_index': { session, pane, cmd, pid } }."""
    try:
        result = subprocess.run(
            ["tmux", "list-panes", "-a",
             "-F", "#{session_name} #{pane_index} #{pane_pid} #{pane_current_command}"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return {}
    except Exception:
        return {}

    agents = {}
    for line in result.stdout.strip().split("\n"):
        parts = line.split()
        if len(parts) < 4:
            continue
        sess, pane_idx, pid, cmd = parts[0], parts[1], parts[2], parts[3]
        if cmd not in _PROCESS_TO_TYPE:
            continue

        # Find the child process (the actual agent binary)
        try:
            children = subprocess.run(
                ["pgrep", "-P", pid],
                capture_output=True, text=True, timeout=3
            )
            for cpid in children.stdout.strip().split("\n"):
                cpid = cpid.strip()
                if not cpid:
                    continue
                agents[f"{sess}:{pane_idx}"] = {
                    "session": sess,
                    "pane": int(pane_idx),
                    "cmd": cmd,
                    "pid": int(cpid),
                }
                break  # first child only
        except Exception:
            pass

    return agents


def _read_cpu_ticks(pid):
    """Read total CPU ticks (user+system) from /proc/PID/stat."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            fields = f.read().split()
            return int(fields[13]) + int(fields[14])
    except (FileNotFoundError, IndexError, ValueError):
        return None


def _read_elapsed_seconds(pid):
    """Read elapsed time of a process from /proc/PID/stat (no subprocess)."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            fields = f.read().split()
            start_ticks = int(fields[21])  # starttime in clock ticks
        with open("/proc/uptime") as f:
            uptime_secs = float(f.read().split()[0])
        hz = os.sysconf("SC_CLK_TCK")
        return int(uptime_secs - (start_ticks / hz))
    except (FileNotFoundError, IndexError, ValueError, OSError):
        return None


# ── Background CPU sampler ──────────────────────────────────────────

# Shared state: { 'session:pane': True/False } meaning active/idle.
# Updated by background thread every cycle.
_activity_lock = threading.Lock()
_activity_cache = {}       # key -> bool (True=active)
_last_active_ts = {}       # key -> ISO timestamp of last time agent was active
_agent_elapsed = {}        # key -> process elapsed seconds (for "running since")
_prev_activity = {}        # key -> bool from previous cycle (for transition detection)
_consecutive_active = {}   # key -> int, consecutive active cycles (debounce spikes)

# Require this many consecutive active cycles before declaring "active".
# A single spike from GC/heartbeat (1 cycle ≈ 3s) is ignored.
_ACTIVE_DEBOUNCE_CYCLES = 2

# Persist last_active timestamps to disk so they survive restarts.
_RUNTIME_BASE = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
_LAST_ACTIVE_FILE = os.path.join(_RUNTIME_BASE, "tap-to-tmux-state",
                                 "dashboard-last-active.json")


def _load_last_active():
    """Load persisted last_active timestamps from disk."""
    try:
        with open(_LAST_ACTIVE_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save_last_active():
    """Persist last_active timestamps to disk."""
    try:
        os.makedirs(os.path.dirname(_LAST_ACTIVE_FILE), exist_ok=True)
        with open(_LAST_ACTIVE_FILE, "w") as f:
            json.dump(_last_active_ts, f)
    except OSError:
        pass


def _cpu_sampler_loop():
    """Background loop: sample CPU ticks twice, 3s apart, update cache."""
    while True:
        try:
            agents = _get_all_agent_pids()

            # First snapshot
            t1 = {}
            for key, info in agents.items():
                ticks = _read_cpu_ticks(info["pid"])
                if ticks is not None:
                    t1[key] = ticks

            time.sleep(3)

            # Second snapshot
            now_iso = datetime.now(timezone.utc).isoformat()
            new_activity = {}
            new_elapsed = {}
            for key, info in agents.items():
                ticks = _read_cpu_ticks(info["pid"])
                if ticks is not None and key in t1:
                    delta = ticks - t1[key]
                    raw_active = delta > _ACTIVE_TICK_THRESHOLD

                    # Debounce: require consecutive active cycles to filter
                    # GC/heartbeat spikes (~7-17 ticks) that occasionally
                    # exceed the threshold for a single cycle.
                    if raw_active:
                        _consecutive_active[key] = \
                            _consecutive_active.get(key, 0) + 1
                    else:
                        _consecutive_active[key] = 0
                    is_active = (
                        _consecutive_active.get(key, 0)
                        >= _ACTIVE_DEBOUNCE_CYCLES
                    )

                    new_activity[key] = is_active

                    # Record "stopped at" timestamp on active→idle transition.
                    # This captures when the agent finished working, not when
                    # it happened to spike once.  While still active, keep
                    # updating the timestamp so it reflects the latest moment.
                    was_active = _prev_activity.get(key, False)
                    if was_active and not is_active:
                        # Transition: was working, now idle → record stop time
                        _last_active_ts[key] = now_iso
                    elif is_active:
                        # Still working → keep updating (will be snapshot when
                        # it eventually stops)
                        _last_active_ts[key] = now_iso

                # Also grab elapsed time
                elapsed = _read_elapsed_seconds(info["pid"])
                if elapsed is not None:
                    new_elapsed[key] = elapsed

            with _activity_lock:
                _activity_cache.update(new_activity)
                _agent_elapsed.update(new_elapsed)
                # Save current activity for next cycle's transition detection
                _prev_activity.update(new_activity)
                # Clean stale entries (sessions that no longer exist)
                live_keys = set(agents.keys())
                for stale in set(_activity_cache.keys()) - live_keys:
                    _activity_cache.pop(stale, None)
                    _agent_elapsed.pop(stale, None)
                    _last_active_ts.pop(stale, None)
                    _prev_activity.pop(stale, None)
                    _consecutive_active.pop(stale, None)

            # Persist timestamps to disk (survives restarts)
            _save_last_active()

        except Exception:
            pass

        # Wait before next cycle (total cycle is ~8s: 3s sample + 5s sleep)
        time.sleep(5)


def _start_sampler():
    # Restore persisted timestamps from previous run
    _last_active_ts.update(_load_last_active())
    t = threading.Thread(target=_cpu_sampler_loop, daemon=True)
    t.start()


# ── Status builder ──────────────────────────────────────────────────

def build_status():
    """Build full status JSON for all project sessions."""
    sessions = get_project_sessions()
    config = load_config()
    status = {
        "machine": config["MACHINE"],
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sessions": [],
    }

    # Get tmux pane commands + PIDs for type mapping
    try:
        all_panes_result = subprocess.run(
            ["tmux", "list-panes", "-a",
             "-F", "#{session_name} #{pane_index} #{pane_pid} #{pane_current_command}"],
            capture_output=True, text=True, timeout=5
        )
        pane_commands = {}  # 'session:pane' -> (command, pid)
        if all_panes_result.returncode == 0:
            for line in all_panes_result.stdout.strip().split("\n"):
                parts = line.split()
                if len(parts) >= 4:
                    pane_commands[f"{parts[0]}:{parts[1]}"] = (parts[3], int(parts[2]))
    except Exception:
        pane_commands = {}

    total_agents = 0

    # Non-blocking lock: serve stale data rather than hang if sampler is stuck
    if _activity_lock.acquire(timeout=2):
        try:
            activity_snapshot = dict(_activity_cache)
            elapsed_snapshot = dict(_agent_elapsed)
            last_active_snapshot = dict(_last_active_ts)
        finally:
            _activity_lock.release()
    else:
        activity_snapshot = {}
        elapsed_snapshot = {}
        last_active_snapshot = {}

    for name in sessions:
        agents = []

        # Build agents from tmux pane info + CPU activity cache
        for key, (cmd, pane_pid) in pane_commands.items():
            if not key.startswith(f"{name}:"):
                continue
            pane_idx = int(key.split(":")[1])
            real_type = _resolve_type(cmd, pane_pid)
            if not real_type:
                continue

            is_active = activity_snapshot.get(key, False)
            elapsed_secs = elapsed_snapshot.get(key)
            last_active_iso = last_active_snapshot.get(key, "")

            activity = "active" if is_active else "idle"

            # Per-agent blink deep link with pane zoom
            agent_ssh_cmd = (
                f"ssh -t {config['SSH_USER']}@{config['SSH_HOST']} "
                f"{config['SSH_REMOTE_HOME']}/.local/bin/"
                f"tmux-mobile-attach.sh {name} {pane_idx}"
            )
            agent_blink_url = (
                f"blinkshell://run?key={config['BLINK_KEY']}"
                f"&cmd={urllib.parse.quote(agent_ssh_cmd)}"
            )

            agents.append({
                "pane": pane_idx,
                "type": real_type,
                "activity": activity,
                "last_active": last_active_iso,
                "elapsed_seconds": elapsed_secs,
                "blink_url": agent_blink_url,
            })

        if not agents:
            continue

        total_agents += len(agents)

        # Derive overall state
        activities = [a["activity"] for a in agents]
        if all(a == "idle" for a in activities):
            overall_state = "idle"
        elif any(a == "active" for a in activities):
            overall_state = "active"
        else:
            overall_state = "unknown"

        # Session overview blink link (no pane zoom)
        ssh_cmd = (
            f"ssh -t {config['SSH_USER']}@{config['SSH_HOST']} "
            f"{config['SSH_REMOTE_HOME']}/.local/bin/tmux-mobile-attach.sh {name}"
        )
        blink_url = (
            f"blinkshell://run?key={config['BLINK_KEY']}"
            f"&cmd={urllib.parse.quote(ssh_cmd)}"
        )

        # Desktop link: ntm-connect:// URL scheme (macOS handler activates WezTerm tab)
        desktop_url = f"ntm-connect://{name}"

        status["sessions"].append({
            "name": name,
            "agents": agents,
            "agent_count": len(agents),
            "overall_state": overall_state,
            "blink_url": blink_url,
            "desktop_url": desktop_url,
        })

    status["session_count"] = len(status["sessions"])
    status["total_agents"] = total_agents
    return status


class DashboardServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


class DashboardHandler(http.server.BaseHTTPRequestHandler):
    timeout = 10  # seconds per request (prevents hung connections from blocking threads)

    def _check_rate_limit(self):
        """Return True if request is within rate limit."""
        ip = self.client_address[0]
        if not _rate_limit_check(ip):
            self.send_error(429, "Too Many Requests")
            return False
        return True

    def _check_auth(self):
        """Return True if request is authenticated (or no token configured)."""
        if not _AUTH_TOKEN:
            return True
        auth = self.headers.get("Authorization", "")
        if auth == f"Bearer {_AUTH_TOKEN}":
            return True
        self.send_error(401, "Unauthorized")
        return False

    def _allowed_origin(self):
        """Return the allowed CORS origin (same-host only, not wildcard)."""
        origin = self.headers.get("Origin", "")
        if not origin:
            return None
        # Allow same-host origins (any port) for dashboard access
        try:
            parsed = urllib.parse.urlparse(origin)
            server_host = self.headers.get("Host", "").split(":")[0]
            if parsed.hostname in ("127.0.0.1", "localhost", server_host):
                return origin
        except Exception:
            pass
        return None

    def _check_origin_for_mutation(self):
        """For state-changing requests, reject cross-origin unless from same host."""
        origin = self.headers.get("Origin", "")
        if not origin:
            return True  # non-browser clients (curl, etc.) don't send Origin
        if self._allowed_origin():
            return True
        self.send_error(403, "Cross-origin request blocked")
        return False

    def _add_cors_headers(self):
        """Add CORS headers scoped to same-host origins."""
        allowed = self._allowed_origin()
        if allowed:
            self.send_header("Access-Control-Allow-Origin", allowed)
            self.send_header("Vary", "Origin")

    def do_GET(self):
        if not self._check_rate_limit():
            return
        if self.path == "/" or self.path == "/status.html":
            self.serve_html()
        elif self.path == "/api/status":
            if not self._check_auth():
                return
            self.serve_status()
        elif self.path == "/api/config":
            if not self._check_auth():
                return
            self.serve_config()
        else:
            self.send_error(404)

    def do_OPTIONS(self):
        """Handle CORS preflight for POST requests."""
        if not self._check_rate_limit():
            return
        self.send_response(204)
        self._add_cors_headers()
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_POST(self):
        if not self._check_rate_limit():
            return
        if not self._check_auth():
            return
        if not self._check_origin_for_mutation():
            return
        if self.path == "/api/spawn":
            self.serve_spawn()
        else:
            self.send_error(404)

    def serve_spawn(self):
        """POST /api/spawn — create a new session with cc=1."""
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length > 4096:
                return self._json_error(400, "Request body too large")
            raw = self.rfile.read(length)
            body = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            return self._json_error(400, "Invalid JSON")

        name = body.get("name", "").strip()

        # Validate name
        if not name:
            return self._json_error(400, "Name is required")
        if len(name) < 2 or len(name) > 50:
            return self._json_error(400, "Name must be 2-50 characters")
        if not _VALID_SESSION_NAME.match(name):
            return self._json_error(
                400, "Name must be lowercase alphanumeric and hyphens, "
                     "starting with a letter or digit")

        # Check if tmux session already exists
        try:
            result = subprocess.run(
                ["tmux", "has-session", "-t", name],
                capture_output=True, timeout=5)
            if result.returncode == 0:
                return self._json_error(
                    409, f"Session '{name}' already exists")
        except subprocess.TimeoutExpired:
            return self._json_error(500, "Timeout checking session")

        # Create project directory + git init
        project_dir = os.path.join(_PROJECTS_DIR, name)
        try:
            os.makedirs(project_dir, exist_ok=True)
            subprocess.run(
                ["git", "init", project_dir],
                capture_output=True, timeout=10)
        except OSError as exc:
            return self._json_error(
                500, f"Failed to create project directory: {exc}")
        except subprocess.TimeoutExpired:
            return self._json_error(500, "Timeout during git init")

        # Spawn via ntm
        try:
            result = subprocess.run(
                ["ntm", "spawn", name, "--cc=1", "--no-user"],
                capture_output=True, text=True, timeout=30)
            if result.returncode != 0:
                err = result.stderr.strip() or result.stdout.strip()
                return self._json_error(
                    500, f"ntm spawn failed: {err[:200]}")
        except FileNotFoundError:
            return self._json_error(500, "ntm not found in PATH")
        except subprocess.TimeoutExpired:
            return self._json_error(500, "ntm spawn timed out")

        resp = {"ok": True, "name": name,
                "message": f"Session '{name}' spawned with 1 Claude agent"}
        body_bytes = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_bytes)))
        self._add_cors_headers()
        self.end_headers()
        self.wfile.write(body_bytes)

    def _json_error(self, code, message):
        """Send a JSON error response."""
        resp = {"ok": False, "error": message}
        body = json.dumps(resp).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._add_cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def serve_html(self):
        try:
            with open(DASHBOARD_HTML, "rb") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.end_headers()
            self.wfile.write(content)
        except FileNotFoundError:
            self.send_error(404, "Dashboard HTML not found")

    def serve_status(self):
        status = build_status()
        body = json.dumps(status, indent=2).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._add_cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def serve_config(self):
        config = load_config()
        body = json.dumps(config, indent=2).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._add_cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass  # Suppress request logs


def _self_watchdog(interval=300):
    """Background thread: every `interval` seconds, check if we can serve.
    If /api/status doesn't respond within 10s, exit so systemd restarts us."""
    import urllib.request
    while True:
        time.sleep(interval)
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{PORT}/api/status")
            with urllib.request.urlopen(req, timeout=10) as resp:
                resp.read()
        except Exception as exc:
            print(f"WATCHDOG: self-check failed ({exc}), exiting for restart",
                  flush=True)
            os._exit(1)


def main():
    _start_sampler()
    # Give sampler one cycle to populate initial data
    print("Waiting for initial CPU sample...")
    time.sleep(4)
    server = DashboardServer((HOST, PORT), DashboardHandler)
    print(f"Dashboard server listening on http://{HOST}:{PORT}")
    # Self-watchdog: exits if server stops responding (systemd restarts us)
    threading.Thread(target=_self_watchdog, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
