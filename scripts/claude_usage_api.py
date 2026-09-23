#!/usr/bin/env python3
import json
import subprocess
import urllib.request
import urllib.error
from pathlib import Path

FILE_PATH = "/tmp/claude-usage.txt"


def get_token_keychain():
    try:
        cmd = ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except Exception:
        return None


def get_token_file():
    try:
        paths = [
            Path.home() / ".claude" / ".credentials.json",
            Path.home() / ".config" / "claude" / ".credentials.json",
        ]
        for p in paths:
            if p.exists():
                data = json.loads(p.read_text("utf-8"))
                token = data.get("claudeAiOauth", {}).get("accessToken")
                if token:
                    return token
    except Exception:
        pass
    return None


def to_epoch(v):
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, str):
        s = v.strip()
        if s.isdigit():
            return int(s)
        try:
            from datetime import datetime
            return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
        except Exception:
            return None
    return None


def fetch_usage(token):
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            # User-Agent is required — bare requests get 429.
            "User-Agent": "claude-code/0.2.9",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))
    except (urllib.error.HTTPError, Exception):
        return None


def main():
    token = get_token_keychain() or get_token_file()
    if not token:
        return

    data = fetch_usage(token)
    if not data:
        return

    limits = {}
    resets = {}
    for key, api_keys in [("5h", ["fiveHour", "five_hour"]), ("7d", ["sevenDay", "seven_day"])]:
        for ak in api_keys:
            val = data.get("usageLimit", {}).get(ak) or data.get(ak)
            if isinstance(val, dict):
                pct = val.get("utilizationPercent") or val.get("utilization_percent") or val.get("percent")
                if pct is not None:
                    limits[key] = f"{int(round(float(pct)))}%"
                    ep = to_epoch(val.get("resetsAt") or val.get("resets_at") or val.get("resetAt"))
                    if ep:
                        resets[key] = ep
                    break
            elif isinstance(val, (int, float)):
                limits[key] = f"{int(round(float(val)))}%"
                break

    if not limits:
        for k in ["5h", "7d", "five_hour", "seven_day"]:
            if k in data:
                limits[k] = f"{data[k]}%"

    lines = []
    for key in ("5h", "7d"):
        if key in limits:
            reset = resets.get(key)
            lines.append(f"{key}:{limits[key]}" + (f"|{reset}" if reset else ""))

    if lines:
        with open(FILE_PATH, "w") as f:
            f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
