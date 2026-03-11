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
HOST = os.environ.get("DASHBOARD_HOST", "0.0.0.0")

_VALID_SESSION_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")
_PROJECTS_DIR = os.environ.get("PROJECTS_DIR", os.path.expanduser("~/projects"))

# CPU tick threshold: above this in a 3-second window = actively working.
# Claude Code's idle event loop uses ~7-17 ticks/3s (heartbeats, keepalive).
# Truly active agents (mid-turn) use 100+ ticks/3s.
# Idle Codex (bun) uses 0 ticks/3s.
# Threshold of 30 cleanly separates idle-loop from real work.
_ACTIVE_TICK_THRESHOLD = 30

# Map tmux pane_current_command to agent type codes.
# ntm's agent_type heuristic is unreliable (e.g., reports claude as cod),
# so we use the actual tmux process as source of truth.
_PROCESS_TO_TYPE = {
    "claude": "cc",
    "bun": "cod",       # Codex runs via bun
    "node": "cod",       # Codex alternate
    "gemini": "gmi",
    "aider": "aider",
}


def load_config():
    """Load cc-notify config.env values."""
    config = {
        "MACHINE": "",
        "SSH_USER": "",
        "SSH_HOST": "",
        "BLINK_KEY": "",
        "PROJECTS_DIR": "",
    }
    config_path = os.path.expanduser(
        os.path.join(os.environ.get("XDG_CONFIG_HOME", "~/.config"),
                     "cc-notify", "config.env"))
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
                    is_active = delta > _ACTIVE_TICK_THRESHOLD
                    new_activity[key] = is_active
                    if is_active:
                        _last_active_ts[key] = now_iso
                # Also grab elapsed time
                elapsed = _read_elapsed_seconds(info["pid"])
                if elapsed is not None:
                    new_elapsed[key] = elapsed

            with _activity_lock:
                _activity_cache.update(new_activity)
                _agent_elapsed.update(new_elapsed)
                # Clean stale entries (sessions that no longer exist)
                live_keys = set(agents.keys())
                for stale in set(_activity_cache.keys()) - live_keys:
                    _activity_cache.pop(stale, None)
                    _agent_elapsed.pop(stale, None)

        except Exception:
            pass

        # Wait before next cycle (total cycle is ~8s: 3s sample + 5s sleep)
        time.sleep(5)


def _start_sampler():
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

    # Get tmux pane commands for type mapping
    try:
        all_panes_result = subprocess.run(
            ["tmux", "list-panes", "-a",
             "-F", "#{session_name} #{pane_index} #{pane_current_command}"],
            capture_output=True, text=True, timeout=5
        )
        pane_commands = {}  # 'session:pane' -> command
        if all_panes_result.returncode == 0:
            for line in all_panes_result.stdout.strip().split("\n"):
                parts = line.split()
                if len(parts) >= 3:
                    pane_commands[f"{parts[0]}:{parts[1]}"] = parts[2]
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
        for key, cmd in pane_commands.items():
            if not key.startswith(f"{name}:"):
                continue
            pane_idx = int(key.split(":")[1])
            real_type = _PROCESS_TO_TYPE.get(cmd, "")
            if not real_type:
                continue

            is_active = activity_snapshot.get(key, False)
            elapsed_secs = elapsed_snapshot.get(key)
            last_active_iso = last_active_snapshot.get(key, "")

            activity = "active" if is_active else "idle"

            # Per-agent blink deep link with pane zoom
            agent_ssh_cmd = (
                f"ssh -t {config['SSH_USER']}@{config['SSH_HOST']} "
                f"/home/{config['SSH_USER']}/.local/bin/"
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
            f"/home/{config['SSH_USER']}/.local/bin/tmux-mobile-attach.sh {name}"
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

    def do_GET(self):
        if self.path == "/" or self.path == "/status.html":
            self.serve_html()
        elif self.path == "/api/status":
            self.serve_status()
        elif self.path == "/api/config":
            self.serve_config()
        else:
            self.send_error(404)

    def do_OPTIONS(self):
        """Handle CORS preflight for POST requests."""
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_POST(self):
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
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body_bytes)

    def _json_error(self, code, message):
        """Send a JSON error response."""
        resp = {"ok": False, "error": message}
        body = json.dumps(resp).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def serve_html(self):
        try:
            with open(DASHBOARD_HTML, "rb") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
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
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def serve_config(self):
        config = load_config()
        body = json.dumps(config, indent=2).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
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
