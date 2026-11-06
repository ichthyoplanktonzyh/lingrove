#!/usr/bin/env python3
"""Gate the official client's one-shot startup discovery on local readiness.

launchd starts independent jobs concurrently. The official client otherwise
keeps running with polling disabled if its initial MCP discovery races the server.
"""
import os, pathlib, time, urllib.request

root=pathlib.Path(__file__).resolve().parent
deadline=time.monotonic()+60
while time.monotonic()<deadline:
    try:
        with urllib.request.urlopen('http://127.0.0.1:19681/health',timeout=2) as response:
            if response.status==200: break
    except Exception: pass
    time.sleep(.5)
else:
    raise SystemExit('Local Lingrove MCP not ready; launchd will retry.')
binary=str(root/'tunnel-client')
os.execv(binary,[binary,'run','--config',str(root/'tunnel.yaml'),'--health.url-file',str(root/'health-url')])
