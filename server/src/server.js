const http = require("node:http");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { URL } = require("node:url");
const { WebSocketServer, WebSocket } = require("ws");
const QRCode = require("qrcode");
const { RoomRegistry } = require("./rooms");

const PORT = Number(process.env.PORT || 8787);
const PUBLIC_URL = (process.env.PUBLIC_URL || "").replace(/\/$/, "");
const CONTROLLER_DIR = path.resolve(__dirname, "../../controller");
const rooms = new RoomRegistry();

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml"
};

function json(response, status, body) {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "access-control-allow-origin": "*"
  });
  response.end(JSON.stringify(body));
}

function publicBase(request) {
  if (PUBLIC_URL) return PUBLIC_URL;
  const proto = request.headers["x-forwarded-proto"] || "http";
  let host = request.headers["x-forwarded-host"] || request.headers.host;
  const hostname = String(host || "").split(":")[0].replace(/^\[|\]$/g, "");
  if (["localhost", "127.0.0.1", "0.0.0.0", "::1"].includes(hostname)) {
    const interfaces = os.networkInterfaces();
    const lanAddress = Object.values(interfaces)
      .flat()
      .find((address) =>
        address &&
        address.family === "IPv4" &&
        !address.internal &&
        !address.address.startsWith("169.254.") &&
        !address.address.startsWith("172.25.")
      );
    if (lanAddress) host = `${lanAddress.address}:${PORT}`;
  }
  return `${proto}://${host}`;
}

function send(socket, value) {
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(value));
}

function serveStatic(request, response, url) {
  const requested = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
  const filePath = path.resolve(CONTROLLER_DIR, requested);
  if (!filePath.startsWith(CONTROLLER_DIR + path.sep) && filePath !== path.join(CONTROLLER_DIR, "index.html")) {
    response.writeHead(403).end("Forbidden");
    return;
  }
  fs.readFile(filePath, (error, data) => {
    if (error) {
      response.writeHead(404, { "content-type": "text/plain; charset=utf-8" }).end("Not found");
      return;
    }
    response.writeHead(200, {
      "content-type": MIME[path.extname(filePath)] || "application/octet-stream",
      "cache-control": filePath.endsWith("index.html") ? "no-store" : "public, max-age=300"
    });
    response.end(data);
  });
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host || "localhost"}`);
  if (request.method === "OPTIONS") {
    response.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "content-type"
    }).end();
    return;
  }

  if (request.method === "GET" && url.pathname === "/health") {
    json(response, 200, { ok: true, rooms: rooms.rooms.size });
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/rooms") {
    const room = rooms.create();
    const joinUrl = `${publicBase(request)}/?room=${room.code}`;
    json(response, 201, { roomCode: room.code, hostToken: room.hostToken, joinUrl });
    return;
  }

  const roomMatch = url.pathname.match(/^\/api\/rooms\/([A-Za-z0-9]+)$/);
  if (request.method === "GET" && roomMatch) {
    const room = rooms.get(roomMatch[1]);
    if (!room) return json(response, 404, { error: "Room not found" });
    json(response, 200, { roomCode: room.code, open: true, playerCount: room.players.size });
    return;
  }

  const qrMatch = url.pathname.match(/^\/api\/rooms\/([A-Za-z0-9]+)\/qr\.svg$/);
  if (request.method === "GET" && qrMatch) {
    const room = rooms.get(qrMatch[1]);
    if (!room) return json(response, 404, { error: "Room not found" });
    const joinUrl = `${publicBase(request)}/?room=${room.code}`;
    try {
      const svg = await QRCode.toString(joinUrl, { type: "svg", margin: 1, width: 320, color: { dark: "#101522", light: "#ffffff" } });
      response.writeHead(200, { "content-type": "image/svg+xml", "cache-control": "no-store" });
      response.end(svg);
    } catch (error) {
      json(response, 500, { error: "Could not generate QR code" });
    }
    return;
  }

  if (request.method === "GET") return serveStatic(request, response, url);
  json(response, 404, { error: "Not found" });
});

const wss = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 });

server.on("upgrade", (request, socket, head) => {
  const url = new URL(request.url, `http://${request.headers.host || "localhost"}`);
  if (url.pathname !== "/ws") return socket.destroy();

  const room = rooms.get(url.searchParams.get("room"));
  const role = url.searchParams.get("role");
  if (!room || !["host", "controller"].includes(role)) return socket.destroy();
  if (role === "host" && url.searchParams.get("token") !== room.hostToken) return socket.destroy();

  wss.handleUpgrade(request, socket, head, (websocket) => {
    wss.emit("connection", websocket, request, { room, role, url });
  });
});

wss.on("connection", (socket, _request, context) => {
  const { room, role, url } = context;
  let player = null;
  room.lastActiveAt = Date.now();

  if (role === "host") {
    if (room.hostSocket && room.hostSocket !== socket) room.hostSocket.close(4001, "Host replaced");
    room.hostSocket = socket;
    send(socket, {
      type: "room_state",
      roomCode: room.code,
      players: [...room.players.values()].map(({ id, name, color }) => ({ id, name, color }))
    });
  } else {
    player = rooms.addPlayer(room, url.searchParams.get("name"), socket);
    send(socket, { type: "welcome", player: { id: player.id, name: player.name, color: player.color }, roomCode: room.code });
    send(room.hostSocket, { type: "player_joined", player: { id: player.id, name: player.name, color: player.color } });
  }

  socket.on("message", (buffer) => {
    room.lastActiveAt = Date.now();
    let message;
    try {
      message = JSON.parse(buffer.toString());
    } catch {
      return;
    }
    if (role !== "controller" || !player) return;

    if (message.type === "motion") {
      send(room.hostSocket, {
        type: "motion",
        playerId: player.id,
        seq: Number(message.seq) || 0,
        time: Number(message.time) || Date.now(),
        tilt: [Number(message.tilt?.[0]) || 0, Number(message.tilt?.[1]) || 0],
        rotation: [Number(message.rotation?.[0]) || 0, Number(message.rotation?.[1]) || 0, Number(message.rotation?.[2]) || 0]
      });
    } else if (message.type === "action") {
      send(room.hostSocket, { type: "action", playerId: player.id, action: String(message.action || "").slice(0, 24) });
    }
  });

  socket.on("close", () => {
    if (role === "host" && room.hostSocket === socket) room.hostSocket = null;
    if (player && rooms.removePlayer(room, player.id)) {
      send(room.hostSocket, { type: "player_left", playerId: player.id });
    }
  });
});

setInterval(() => rooms.cleanup(), 60_000).unref();

if (require.main === module) {
  server.listen(PORT, "0.0.0.0", () => {
    console.log(`Party Motion relay listening on http://localhost:${PORT}`);
  });
}

module.exports = { server, rooms };
