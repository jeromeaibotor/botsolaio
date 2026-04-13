"""
OMEGA DASHBOARD SERVER
=======================
Proxy ZMQ PUB → WebSocket
Le brain publie sur ZMQ port 5557 (PUB)
Ce serveur reçoit et broadcast vers le navigateur via WebSocket port 5558

Lancer : python dashboard_server.py
Ouvrir  : dashboard.html dans le navigateur
"""

import asyncio
import json
import zmq
import zmq.asyncio
import websockets
import logging
from datetime import datetime

logging.basicConfig(level=logging.INFO, format="%(asctime)s [DASH] %(message)s")
log = logging.getLogger("DASH_SERVER")

ZMQ_SUB_PORT = 5557   # reçoit du brain
WS_PORT      = 5558   # envoie au navigateur

clients = set()

async def zmq_receiver(broadcast):
    """Reçoit les états ZMQ et les broadcast aux clients WebSocket."""
    ctx = zmq.asyncio.Context()
    sub = ctx.socket(zmq.SUB)
    sub.connect(f"tcp://localhost:{ZMQ_SUB_PORT}")
    sub.setsockopt_string(zmq.SUBSCRIBE, "STATE ")
    log.info(f"ZMQ SUB connecté sur port {ZMQ_SUB_PORT}")

    while True:
        try:
            msg = await sub.recv_string()
            # Format : "STATE {json}"
            if msg.startswith("STATE "):
                payload = msg[6:]
                await broadcast(payload)
        except Exception as e:
            log.error(f"ZMQ recv error: {e}")
            await asyncio.sleep(1)

async def ws_handler(websocket):
    """Gère une connexion WebSocket client."""
    clients.add(websocket)
    log.info(f"Client connecté : {websocket.remote_address} | Total: {len(clients)}")
    try:
        await websocket.wait_closed()
    finally:
        clients.discard(websocket)
        log.info(f"Client déconnecté | Restants: {len(clients)}")

async def broadcast(payload: str):
    """Envoie à tous les clients connectés."""
    if not clients:
        return
    dead = set()
    for ws in clients:
        try:
            await ws.send(payload)
        except Exception:
            dead.add(ws)
    clients -= dead

async def main():
    log.info("="*50)
    log.info("  OMEGA DASHBOARD SERVER")
    log.info(f"  ZMQ SUB  : tcp://localhost:{ZMQ_SUB_PORT}")
    log.info(f"  WebSocket: ws://localhost:{WS_PORT}")
    log.info("="*50)

    ws_server = await websockets.serve(ws_handler, "localhost", WS_PORT)
    log.info(f"WebSocket server démarré sur port {WS_PORT}")
    log.info("Ouvrir dashboard.html dans le navigateur")

    await asyncio.gather(
        zmq_receiver(broadcast),
        ws_server.wait_closed(),
    )

if __name__ == "__main__":
    asyncio.run(main())
