#!/usr/bin/env python3
"""Call one MobAI MCP tool: mcpcall.py <tool_name> <json_args>."""
import json
import sys
import urllib.request

URL = "http://127.0.0.1:8686/mcp"
session = None


def call(method, params=None, notify=False, timeout=600):
    global session
    body = {"jsonrpc": "2.0", "method": method}
    if not notify:
        body["id"] = 1
    if params is not None:
        body["params"] = params
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if session:
        headers["Mcp-Session-Id"] = session
    req = urllib.request.Request(
        URL, data=json.dumps(body).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        if session is None:
            session = r.headers.get("Mcp-Session-Id")
        raw = r.read().decode()
    if not raw.strip():
        return None
    if "data:" in raw:
        for line in reversed(raw.strip().split("\n")):
            if line.startswith("data:"):
                raw = line[5:].strip()
                break
    return json.loads(raw)


call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                    "clientInfo": {"name": "claude-code", "version": "1"}})
call("notifications/initialized", notify=True)

res = call("tools/call", {"name": sys.argv[1], "arguments": json.loads(sys.argv[2])})
for block in res.get("result", {}).get("content", []):
    print(block.get("text", ""))
if res.get("result", {}).get("isError"):
    print("!! isError")
