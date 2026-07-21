"""Send Lua to the norns matron REPL over websocket and print the replies.

Usage:
  python matron_repl.py "print('hi')"          one-shot command
  python matron_repl.py --listen 20            just listen for N seconds
  python matron_repl.py --restart              re-run the current script

The matron REPL listens on ws://norns.local:5555 (maiden uses the same
socket), so anything printed by the running script shows up here too.
"""

import asyncio
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

import websockets

HOST = "ws://norns.local:5555"


async def main() -> None:
    args = sys.argv[1:]
    listen_secs = 6.0
    cmd = None
    if args and args[0] == "--listen":
        listen_secs = float(args[1]) if len(args) > 1 else 20.0
    elif args and args[0] == "--restart":
        cmd = "norns.script.load(norns.state.script)"
        listen_secs = 8.0
    elif args:
        cmd = args[0]

    async with websockets.connect(HOST, subprotocols=["bus.sp.nanomsg.org"]) as ws:
        if cmd:
            await ws.send(cmd + "\n")
        loop = asyncio.get_event_loop()
        deadline = loop.time() + listen_secs
        while True:
            remaining = deadline - loop.time()
            if remaining <= 0:
                break
            try:
                msg = await asyncio.wait_for(ws.recv(), timeout=remaining)
            except asyncio.TimeoutError:
                break
            text = msg.decode() if isinstance(msg, bytes) else msg
            print(text, end="" if text.endswith("\n") else "\n")


asyncio.run(main())
