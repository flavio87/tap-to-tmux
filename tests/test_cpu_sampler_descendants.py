"""Regression test: the CPU sampler must attribute activity from grandchild
processes back to the agent.

This mirrors codex's real process tree:

    zsh (tmux pane)
      └─ node /home/ubuntu/.bun/bin/codex   ← immediate child, ~0 CPU
           └─ codex (Rust binary)           ← grandchild, does all the work

Sampling only the immediate child (node) misses every cycle of work, so
codex was never seen as active and `last_active` stayed empty forever.
"""

import importlib.util
import pathlib
import subprocess
import sys
import time

import pytest


def _load_dashboard_module():
    path = (
        pathlib.Path(__file__).resolve().parent.parent
        / "scripts" / "ntm-dashboard-server.py"
    )
    spec = importlib.util.spec_from_file_location("ntm_dashboard_server", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Wrapper: spawn a CPU-burning grandchild, then sleep.  The wrapper itself
# consumes ~zero CPU while the grandchild burns ticks — exactly codex's
# topology where the node wrapper is idle while the Rust binary thinks.
_WRAPPER_CODE = (
    "import subprocess, sys, time\n"
    "child = subprocess.Popen([sys.executable, '-c',\n"
    "    'end = __import__(\"time\").time() + 6\\n'\n"
    "    'x = 0\\n'\n"
    "    'while __import__(\"time\").time() < end:\\n'\n"
    "    '    x += 1\\n'])\n"
    "time.sleep(7)\n"
    "child.wait()\n"
)


@pytest.fixture
def wrapper_process():
    proc = subprocess.Popen([sys.executable, "-c", _WRAPPER_CODE])
    # Give the wrapper a moment to fork its CPU-burning child.
    time.sleep(0.5)
    yield proc
    try:
        proc.kill()
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def test_immediate_child_sampling_misses_grandchild_work(wrapper_process):
    """Sanity check: the old (broken) approach really does miss the work."""
    mod = _load_dashboard_module()

    t0 = mod._read_cpu_ticks(wrapper_process.pid)
    assert t0 is not None
    time.sleep(3.0)
    t1 = mod._read_cpu_ticks(wrapper_process.pid)
    assert t1 is not None

    delta = t1 - t0
    # Wrapper sits in time.sleep, so its own ticks are well below the
    # dashboard's 30-tick threshold even though a grandchild is burning CPU.
    assert delta < 30, (
        f"Wrapper itself used {delta} ticks; test premise (idle wrapper, "
        f"busy grandchild) no longer holds."
    )


def test_tree_sampling_captures_grandchild_work(wrapper_process):
    """The fix: summing ticks across descendants surfaces the grandchild."""
    mod = _load_dashboard_module()

    assert hasattr(mod, "_read_cpu_ticks_tree"), (
        "Dashboard server is missing _read_cpu_ticks_tree — without it, "
        "codex's node→rust process tree is invisible to the sampler."
    )

    t0 = mod._read_cpu_ticks_tree(wrapper_process.pid)
    assert t0 is not None
    time.sleep(3.0)
    t1 = mod._read_cpu_ticks_tree(wrapper_process.pid)
    assert t1 is not None

    delta = t1 - t0
    # The grandchild is in a tight Python loop; on any reasonable host it
    # generates well over the 30-tick threshold in 3 seconds.
    assert delta > 100, (
        f"Tree sampler only saw {delta} ticks over 3s — grandchild work "
        f"is not being attributed to the wrapper subtree."
    )
