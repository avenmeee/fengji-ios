# 挑一台最新系统的 iPhone 模拟器（截图用），打印它的 UDID
import json
import subprocess
import sys

devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]


def version(runtime):
    try:
        return [int(x) for x in runtime.split("iOS-")[1].split("-")]
    except (IndexError, ValueError):
        return [0]


for runtime in sorted((k for k in devices if "iOS-" in k and devices[k]), key=version, reverse=True):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if len(sys.argv) > 1 and sys.argv[1] == "max":  # 商店截图要 6.9 寸
        pick = [d for d in phones if "Pro Max" in d["name"]] or phones
    else:
        pick = [d for d in phones if "Pro" in d["name"] and "Max" not in d["name"]] or phones
    if pick:
        print(pick[-1]["udid"])
        break
