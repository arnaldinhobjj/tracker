#!/usr/bin/env python3
"""Prints the UDID of the newest available iPhone simulator (reads `simctl list -j` on stdin)."""
import json
import re
import sys

devices = json.load(sys.stdin)["devices"]
best = None
for runtime, entries in devices.items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for device in entries:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            key = (version, device["name"])
            if best is None or key > best[0]:
                best = (key, device["udid"])
if best is None:
    sys.exit("No available iPhone simulator found")
print(best[1])
