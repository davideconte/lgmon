"""lgmon: control an LG webOS smart monitor from your Mac, over the network.

Usage:
  lgmon                          status
  lgmon brightness [N|+N|-N]     backlight 0-100            (alias: b)
  lgmon volume [N|+N|-N]         built-in speakers 0-100    (alias: v)
  lgmon mute                     toggle mute
  lgmon input [NAME]             list inputs, or switch (hdmi1, hdmi2, dp, usbc)
  lgmon screen off|on            panel off/on, the monitor stays awake
  lgmon off                      standby
  lgmon on                       wake from standby (Wake-on-LAN)
  lgmon mode [NAME]              picture mode (e.g. normal, game, vivid, eco)
  lgmon app [NAME]               list apps, or launch one (youtube, netflix...)
  lgmon notify TEXT              show a toast on the monitor
  lgmon discover                 find webOS monitors/TVs on the network
  lgmon use IP                   pin a specific device

The first command pairs with the monitor: accept the prompt on screen.
State lives in ~/.config/lgmon (pairing key, last known IP and MAC).
"""
import asyncio
import json
import os
import re
import socket
import sys
import time
from pathlib import Path
from urllib.parse import unquote

from bscpylgtv import WebOsClient

CONFIG_DIR = Path(os.environ.get("LGMON_CONFIG", Path.home() / ".config" / "lgmon"))
KEY_FILE = CONFIG_DIR / "key.sqlite"
DEVICE_FILE = CONFIG_DIR / "device.json"


class LgmonError(Exception):
    pass


# discovery ------------------------------------------------------------------

def discover(timeout=3.0):
    """SSDP search. Returns [{ip, name, mac}] for every webOS device found."""
    msg = ('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
           'MAN: "ssdp:discover"\r\nMX: 1\r\nST: {}\r\n\r\n')
    targets = ["urn:lge-com:service:webos-second-screen:1", "upnp:rootdevice",
               "urn:dial-multiscreen-org:service:dial:1"]
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(0.3)
    found = {}
    start = time.time()
    end = start + timeout
    sent = 0
    while time.time() < end:
        # UDP gets lost and webOS sometimes ignores back-to-back searches: resend a few times
        if sent < 3 and time.time() >= start + sent:
            for st in targets:
                s.sendto(msg.format(st).encode(), ("239.255.255.250", 1900))
            sent += 1
        try:
            data, (ip, _) = s.recvfrom(4096)
        except socket.timeout:
            continue
        text = data.decode(errors="ignore")
        headers = {}
        for line in text.splitlines()[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        dev = found.setdefault(ip, {"ip": ip, "name": None, "mac": None, "webos": False})
        if "webos-second-screen" in headers.get("st", ""):
            dev["webos"] = True
        if "dlnadevicename.lge.com" in headers:
            dev["name"] = unquote(headers["dlnadevicename.lge.com"])
        m = re.search(r"MAC=([0-9a-fA-F:]{17})", headers.get("wakeup", ""))
        if m:
            dev["mac"] = m.group(1).lower()
    return [d for d in found.values() if d["webos"]]


def load_device():
    if os.environ.get("LGMON_HOST"):
        return {"ip": os.environ["LGMON_HOST"]}
    try:
        return json.loads(DEVICE_FILE.read_text())
    except (OSError, ValueError):
        return {}


def save_device(dev):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    DEVICE_FILE.write_text(json.dumps(dev, indent=2))


def find_device(pinned=None):
    """Rediscover the device (IP changed, first run). Prefers the pinned MAC/name."""
    devices = discover()
    if not devices:
        raise LgmonError("No LG webOS device found on the network. "
                         "Is the monitor on and on the same network as this Mac?")
    if pinned:
        for d in devices:
            if (pinned.get("mac") and d["mac"] == pinned["mac"]) or \
               (pinned.get("name") and d["name"] == pinned["name"]):
                return d
    if len(devices) > 1 and not pinned:
        listing = "\n".join(f"  {d['ip']}  {d['name'] or ''}" for d in devices)
        raise LgmonError(f"Found several webOS devices, pick one with `lgmon use IP`:\n{listing}")
    return devices[0]


# connection -----------------------------------------------------------------

async def _connect(ip):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    client = await WebOsClient.create(ip, key_file_path=str(KEY_FILE), ping_interval=None,
                                      states=[], connect_retry_attempts=1)
    await client.connect()
    return client


async def connect():
    dev = load_device()
    if dev.get("ip"):
        try:
            return await _connect(dev["ip"])
        except Exception:
            if os.environ.get("LGMON_HOST"):
                raise LgmonError(f"Cannot reach {dev['ip']}")
    new = find_device(dev or None)
    save_device({**dev, **{k: v for k, v in new.items() if v and k != "webos"}})
    try:
        return await _connect(new["ip"])
    except Exception as e:
        raise LgmonError(f"Cannot connect to {new['ip']}: {e}")


def wake_on_lan(mac):
    payload = bytes.fromhex("ff" * 6 + mac.replace(":", "") * 16)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    for port in (9, 7):
        s.sendto(payload, ("255.255.255.255", port))


# commands -------------------------------------------------------------------

def clamp_value(arg, current):
    v = current + int(arg) if arg[0] in "+-" else int(arg)
    return max(0, min(100, v))


def _norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower()).replace("displayport", "dp")


def match_input(name, inputs):
    want = _norm(name)
    for i in inputs:
        if _norm(i["id"]) == want or _norm(i["id"]).rstrip("1") == want or _norm(i["label"]) == want:
            return i
    hits = [i for i in inputs if _norm(i["id"]).startswith(want)]
    if len(hits) == 1:
        return hits[0]
    raise LgmonError(f"Unknown input '{name}'. Available: " + ", ".join(i["id"] for i in inputs))


async def status(c):
    pic = await c.get_picture_settings(keys=["backlight", "contrast"])
    return {"brightness": int(pic["backlight"]), "volume": await c.get_volume(),
            "muted": await c.get_muted(), "input": await c.get_input()}


async def run(args, out=print):
    if args and args[0] in ("-h", "--help", "help"):
        return out(__doc__.strip())
    cmd, rest = (args[0], args[1:]) if args else ("status", [])

    if cmd == "discover":
        devices = discover()
        if not devices:
            return out("No LG webOS device found.")
        for d in devices:
            out(f"{d['ip']:<16} {d['name'] or '(unknown)':<30} {d['mac'] or ''}")
        return
    if cmd == "use" and rest:
        dev = next((d for d in discover() if d["ip"] == rest[0]), {"ip": rest[0]})
        save_device({k: v for k, v in dev.items() if v and k != "webos"})
        return out(f"Using {rest[0]}")
    if cmd == "on":
        mac = load_device().get("mac")
        if not mac:
            raise LgmonError("MAC address unknown: run `lgmon discover` while the monitor is on.")
        wake_on_lan(mac)
        return out("Wake-on-LAN sent")

    c = await connect()
    try:
        if cmd == "status":
            s = await status(c)
            out(f"brightness {s['brightness']}  volume {s['volume']}"
                f"{' (muted)' if s['muted'] else ''}  input {s['input'].split('.')[-1]}")
        elif cmd in ("brightness", "b"):
            cur = int((await c.get_picture_settings(keys=["backlight"]))["backlight"])
            if not rest:
                return out(cur)
            v = clamp_value(rest[0], cur)
            await c.set_settings("picture", {"backlight": v})
            out(f"brightness {v}")
        elif cmd in ("volume", "v"):
            cur = await c.get_volume()
            if not rest:
                return out(cur)
            v = clamp_value(rest[0], cur)
            await c.set_volume(v)
            out(f"volume {v}")
        elif cmd == "mute":
            m = not await c.get_muted()
            await c.set_mute(m)
            out("muted" if m else "unmuted")
        elif cmd == "input":
            inputs = await c.get_inputs()
            if not rest:
                current = await c.get_input()
                for i in inputs:
                    mark = "*" if i["appId"] == current else " "
                    state = "connected" if i.get("connected") else ""
                    out(f"{mark} {i['id']:<14} {i['label']:<12} {state}")
                return
            i = match_input(rest[0], inputs)
            await c.set_input(i["id"])
            out(f"input {i['id']}")
        elif cmd == "screen" and rest and rest[0] in ("on", "off"):
            if rest[0] == "off":
                await c.turn_screen_off()
            else:
                await c.turn_screen_on()
            out(f"screen {rest[0]}")
        elif cmd == "off":
            await c.power_off()
            out("standby")
        elif cmd == "mode":
            if not rest:
                s = await c.get_system_settings("picture", ["pictureMode"])
                return out(s["settings"]["pictureMode"])
            await c.set_current_picture_mode(rest[0])
            out(f"picture mode {rest[0]}")
        elif cmd == "app":
            apps = await c.get_apps()
            if not rest:
                for a in apps:
                    out(f"{a['title']:<28} {a['id']}")
                return
            q = " ".join(rest).lower()
            hits = [a for a in apps if q == a["id"].lower() or q in a["title"].lower()]
            if not hits:
                raise LgmonError(f"No app matching '{q}'")
            await c.launch_app(hits[0]["id"])
            out(f"launched {hits[0]['title']}")
        elif cmd == "notify" and rest:
            await c.send_message(" ".join(rest))
            out("sent")
        else:
            raise LgmonError(f"Unknown command. Try `lgmon help`.")
    finally:
        await c.disconnect()


def main():
    try:
        asyncio.run(run(sys.argv[1:]))
    except LgmonError as e:
        sys.exit(f"lgmon: {e}")
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
