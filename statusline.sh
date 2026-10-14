#!/usr/bin/env python3
"""Grok status line: cwd, branch, model, context, weekly usage bar."""
import json
import os
import sys
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
CACHE = os.path.join(HOME, ".grok", "statusline-weekly.json")
AUTH = os.path.join(HOME, ".grok", "auth.json")
BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
CACHE_TTL = 300
BAR_WIDTH = 16


def ellipsize(text, limit):
    if len(text) <= limit:
        return text
    if limit <= 1:
        return "…"
    return text[: limit - 1] + "…"


def basename(path):
    trimmed = path.rstrip("/")
    if not trimmed:
        return ""
    return trimmed.rsplit("/", 1)[-1]


def read_cache():
    try:
        with open(CACHE, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def write_cache(payload):
    tmp = CACHE + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        os.chmod(tmp, 0o600)
        os.replace(tmp, CACHE)
    except OSError:
        return


def access_token():
    try:
        with open(AUTH, encoding="utf-8") as handle:
            auth = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(auth, dict):
        return None
    for entry in auth.values():
        if isinstance(entry, dict):
            key = entry.get("key")
            if isinstance(key, str) and key:
                return key
    return None


def fetch_weekly():
    token = access_token()
    if not token:
        return None
    request = urllib.request.Request(
        BILLING_URL,
        headers={"Authorization": "Bearer " + token, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            body = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, ValueError, TimeoutError):
        return None
    config = body.get("config") if isinstance(body, dict) else None
    if not isinstance(config, dict):
        return None
    percent = config.get("creditUsagePercent")
    period = config.get("currentPeriod") if isinstance(config.get("currentPeriod"), dict) else {}
    kind = period.get("type")
    if not isinstance(percent, (int, float)):
        return None
    label = {"USAGE_PERIOD_TYPE_WEEKLY": "week", "USAGE_PERIOD_TYPE_MONTHLY": "month"}.get(kind)
    if label is None:
        return None
    payload = {"label": label, "percent": max(0, min(100, int(round(percent)))), "fetched_at": int(time.time())}
    write_cache(payload)
    return payload


def session_attached_at(data, now):
    """Seconds since epoch when this process attached the session."""
    cost = data.get("cost") if isinstance(data, dict) else None
    duration = cost.get("total_duration_ms") if isinstance(cost, dict) else None
    if not isinstance(duration, (int, float)) or duration < 0:
        return None
    return now - int(duration) // 1000


def launch_already_checked(cached, attached):
    if attached is None or not isinstance(cached, dict):
        return False
    checked = cached.get("launch_checked_at")
    return isinstance(checked, int) and abs(checked - attached) < 2


def should_refresh_on_launch(cached, attached):
    """True once per process attach when the cache was written by an earlier run."""
    if attached is None or launch_already_checked(cached, attached):
        return False
    fetched = cached.get("fetched_at") if isinstance(cached, dict) else None
    if not isinstance(fetched, int):
        return True
    return fetched < attached


def mark_launch_checked(cached, attached):
    payload = dict(cached) if isinstance(cached, dict) else {}
    payload["launch_checked_at"] = attached
    write_cache(payload)


def weekly_segment(trigger, data):
    cached = read_cache()
    now = int(time.time())
    attached = session_attached_at(data, now)
    fresh = (
        isinstance(cached, dict)
        and isinstance(cached.get("fetched_at"), int)
        and now - cached["fetched_at"] < CACHE_TTL
        and isinstance(cached.get("percent"), int)
    )
    launch = should_refresh_on_launch(cached, attached)
    # Busy turns re-run this script constantly. Fetch on the timer, when the
    # cache is missing or older than the TTL, and once per Grok launch.
    if trigger == "refresh_interval" or not fresh or launch:
        fetched = fetch_weekly()
        if fetched is not None:
            cached = fetched
        elif launch:
            mark_launch_checked(cached, attached)
    if not isinstance(cached, dict) or not isinstance(cached.get("percent"), int):
        return None
    percent = max(0, min(100, cached["percent"]))
    label = cached.get("label") if cached.get("label") in ("week", "month") else "week"
    filled = max(0, min(BAR_WIDTH, int(round(percent * BAR_WIDTH / 100))))
    bar = "█" * filled + "░" * (BAR_WIDTH - filled)
    color = "31" if percent >= 95 else "33" if percent >= 80 else "37"
    return f"{label} \033[{color}m{bar}\033[0m {percent}%"


def main():
    data = json.load(sys.stdin)
    workspace = data.get("workspace") or {}
    window = data.get("context_window") or {}
    parts = []
    directory = basename(data.get("cwd") or workspace.get("current_dir") or "")
    if directory:
        parts.append(ellipsize(directory, 40))
    branch = workspace.get("branch")
    if isinstance(branch, str) and branch:
        parts.append(ellipsize(branch, 40))
    model = (data.get("model") or {}).get("display_name")
    if isinstance(model, str) and model:
        parts.append(ellipsize(model, 30))
    used = window.get("used_percentage")
    if isinstance(used, int):
        parts.append(f"{used}% ctx")
    weekly = weekly_segment(data.get("trigger"), data)
    if weekly:
        parts.append(weekly)
    if parts:
        print(" │ ".join(parts))


if __name__ == "__main__":
    main()
