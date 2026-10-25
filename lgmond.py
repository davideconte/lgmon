"""lgmond: tiny local daemon that keeps the webOS connection open, so key
presses feel instant (~0.1 s instead of ~0.5 s for a fresh connection).

Listens on http://127.0.0.1:8765 (localhost only):
  GET /status            {"brightness": 60, "volume": 20, "muted": false}
  GET /brightness/40     absolute, or /brightness/+5, /brightness/-5
  GET /volume/25         absolute, or /volume/+2, /volume/-2
  GET /mute              toggle
  GET /inputs            [{"id": "HDMI_1", "label": "Mac", "connected": true, "current": true}, ...]
  GET /input/HDMI_2      switch input (remembers where you came from)
  GET /back              switch back to the input you were on before /input or /app
  GET /apps              [{"id": "youtube.leanback.v4", "title": "YouTube"}, ...]
  GET /app/ID            launch a monitor app
  GET /screen/off|on     panel off/on, audio keeps playing
  GET /standby           power off to standby
"""
import asyncio
import json
import os
import time

from lgmon import clamp_value, connect

PORT = int(os.environ.get("LGMON_PORT", 8765))
# after a write the monitor keeps reporting the old value for a moment:
# within this window we trust what we set instead of reading it back
TRUST_WRITES_FOR = 5


class Monitor:
    def __init__(self):
        self.client = None
        self.lock = asyncio.Lock()
        self.last = None
        self.last_at = 0.0
        self.home_input = None    # input to return to with /back
        self.screen_off = False

    async def _client(self):
        if self.client is None or not self.client.is_connected():
            self.client = await connect()
        return self.client

    async def run(self, op):
        async with self.lock:
            for attempt in (1, 2):
                try:
                    return await op(await self._client())
                except Exception:
                    # connection dropped (standby, Wi-Fi): reopen and retry once
                    self.client = None
                    if attempt == 2:
                        raise

    async def status(self, c):
        if self.last and time.monotonic() - self.last_at < TRUST_WRITES_FOR:
            return dict(self.last)
        pic = await c.get_picture_settings(keys=["backlight"])
        return {"brightness": int(pic["backlight"]), "volume": await c.get_volume(),
                "muted": await c.get_muted()}


async def remember_home(mon, c):
    """Before leaving, note which physical input we are on (an app is not a home)."""
    current = await c.get_input()
    if current in {i["appId"] for i in await c.get_inputs()}:
        mon.home_input = current


async def handle(mon, path):
    parts = [p for p in path.split("/") if p]
    cmd = parts[0] if parts else "status"
    arg = parts[1] if len(parts) > 1 else None

    async def op(c):
        if cmd == "inputs":
            current = await c.get_input()
            return [{"id": i["id"], "label": i["label"], "connected": bool(i.get("connected")),
                     "current": i["appId"] == current} for i in await c.get_inputs()]
        if cmd == "apps":
            return [{"id": a["id"], "title": a["title"]} for a in await c.get_apps()]
        if cmd == "input" and arg:
            await remember_home(mon, c)
            await c.set_input(arg)
            return {"input": arg}
        if cmd == "app" and arg:
            await remember_home(mon, c)
            await c.launch_app(arg)
            return {"app": arg}
        if cmd == "back":
            if mon.home_input:
                await c.launch_app(mon.home_input)   # input apps launch like any other app
                home, mon.home_input = mon.home_input, None
                return {"input": home}
            return {"input": None}
        if cmd == "screen" and arg in ("on", "off"):
            if arg == "off":
                await c.turn_screen_off()
            else:
                await c.turn_screen_on()
            mon.screen_off = arg == "off"
            return {"screen": arg}
        if cmd == "standby":
            await c.power_off()
            return {"power": "standby"}

        st = await mon.status(c)
        if cmd == "brightness" and arg:
            if mon.screen_off:
                # touching brightness wakes a panel turned off from here
                await c.turn_screen_on()
                mon.screen_off = False
            st["brightness"] = clamp_value(arg, st["brightness"])
            await c.set_settings("picture", {"backlight": st["brightness"]})
        elif cmd == "volume" and arg:
            st["volume"] = clamp_value(arg, st["volume"])
            st["muted"] = False
            await c.set_volume(st["volume"])
        elif cmd == "mute":
            st["muted"] = not st["muted"]
            await c.set_mute(st["muted"])
        elif cmd != "status":
            raise ValueError("unknown command")
        if cmd != "status":
            mon.last, mon.last_at = dict(st), time.monotonic()
        return st

    return await mon.run(op)


async def main():
    mon = Monitor()

    async def on_connection(reader, writer):
        try:
            line = (await reader.readline()).decode()
            while (await reader.readline()) not in (b"\r\n", b"\n", b""):
                pass
            path = line.split(" ")[1] if " " in line else "/"
            try:
                body, code = await handle(mon, path), "200 OK"
            except Exception as e:
                body, code = {"error": str(e) or type(e).__name__}, "503 Service Unavailable"
            data = json.dumps(body).encode()
            writer.write(f"HTTP/1.1 {code}\r\nContent-Type: application/json\r\n"
                         f"Content-Length: {len(data)}\r\nConnection: close\r\n\r\n".encode() + data)
            await writer.drain()
        finally:
            writer.close()

    server = await asyncio.start_server(on_connection, "127.0.0.1", PORT)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
