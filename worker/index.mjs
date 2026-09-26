import { DurableObject } from "cloudflare:workers";
import QRCode from "qrcode";

const COLORS = ["#ff5c7a", "#58d6ff", "#ffd15c", "#8cf28a", "#b88cff", "#ff995c"];

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "access-control-allow-origin": "*"
    }
  });
}

function randomToken(bytes = 18) {
  const values = new Uint8Array(bytes);
  crypto.getRandomValues(values);
  return btoa(String.fromCharCode(...values)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function randomRoomCode() {
  const values = new Uint8Array(3);
  crypto.getRandomValues(values);
  return [...values].map((value) => value.toString(16).padStart(2, "0")).join("").toUpperCase();
}

function roomStub(env, code) {
  return env.ROOMS.get(env.ROOMS.idFromName(code.toUpperCase()));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-methods": "GET,POST,OPTIONS",
          "access-control-allow-headers": "content-type"
        }
      });
    }

    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, runtime: "cloudflare-workers" });
    }

    if (request.method === "POST" && url.pathname === "/api/rooms") {
      for (let attempt = 0; attempt < 5; attempt += 1) {
        const code = randomRoomCode();
        const hostToken = randomToken();
        const response = await roomStub(env, code).fetch("https://room.internal/initialize", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ code, hostToken })
        });
        if (response.status === 201) {
          return json({
            roomCode: code,
            hostToken,
            joinUrl: `${url.origin}/?room=${code}`
          }, 201);
        }
      }
      return json({ error: "Could not allocate a room" }, 503);
    }

    const roomMatch = url.pathname.match(/^\/api\/rooms\/([A-Za-z0-9]{6})$/);
    if (request.method === "GET" && roomMatch) {
      const response = await roomStub(env, roomMatch[1]).fetch("https://room.internal/state");
      if (response.status === 404) return json({ error: "Room not found" }, 404);
      return response;
    }

    const qrMatch = url.pathname.match(/^\/api\/rooms\/([A-Za-z0-9]{6})\/qr\.svg$/);
    if (request.method === "GET" && qrMatch) {
      const code = qrMatch[1].toUpperCase();
      const state = await roomStub(env, code).fetch("https://room.internal/state");
      if (state.status === 404) return json({ error: "Room not found" }, 404);
      const svg = await QRCode.toString(`${url.origin}/?room=${code}`, {
        type: "svg",
        margin: 1,
        width: 320,
        color: { dark: "#101522", light: "#ffffff" }
      });
      return new Response(svg, {
        headers: { "content-type": "image/svg+xml", "cache-control": "no-store" }
      });
    }

    if (url.pathname === "/ws") {
      const code = (url.searchParams.get("room") || "").toUpperCase();
      if (!/^[A-Z0-9]{6}$/.test(code)) return json({ error: "Invalid room" }, 400);
      return roomStub(env, code).fetch(request);
    }

    return env.ASSETS.fetch(request);
  }
};

export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx = ctx;
  }

  async fetch(request) {
    const url = new URL(request.url);

    if (request.method === "POST" && url.pathname === "/initialize") {
      const existing = await this.ctx.storage.get("room");
      if (existing) return json({ error: "Room already exists" }, 409);
      const input = await request.json();
      await this.ctx.storage.put("room", {
        code: input.code,
        hostToken: input.hostToken,
        createdAt: Date.now()
      });
      return json({ ok: true }, 201);
    }

    const room = await this.ctx.storage.get("room");
    if (!room) return json({ error: "Room not found" }, 404);

    if (request.method === "GET" && url.pathname === "/state") {
      return json({
        roomCode: room.code,
        open: true,
        playerCount: this.ctx.getWebSockets("controller").length
      });
    }

    if (url.pathname !== "/ws" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "Not found" }, 404);
    }

    const role = url.searchParams.get("role");
    if (role !== "host" && role !== "controller") return json({ error: "Invalid role" }, 400);
    if (role === "host" && url.searchParams.get("token") !== room.hostToken) {
      return json({ error: "Unauthorized" }, 401);
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    if (role === "host") {
      for (const oldHost of this.ctx.getWebSockets("host")) oldHost.close(4001, "Host replaced");
      server.serializeAttachment({ role: "host" });
      this.ctx.acceptWebSocket(server, ["host"]);
      this.send(server, {
        type: "room_state",
        roomCode: room.code,
        players: this.players()
      });
    } else {
      let resumeToken = url.searchParams.get("resume") || "";
      const resumed = resumeToken ? await this.ctx.storage.get(`resume:${resumeToken}`) : null;
      let player;
      if (resumed?.player) {
        player = resumed.player;
        for (const oldSocket of this.ctx.getWebSockets(`player:${player.id}`)) oldSocket.close(4002, "Player reconnected");
      } else {
        const id = randomToken(8);
        const name = (url.searchParams.get("name") || "Player").trim().slice(0, 18) || "Player";
        const color = COLORS[this.ctx.getWebSockets("controller").length % COLORS.length];
        player = { id, name, color };
        resumeToken = randomToken(18);
        await this.ctx.storage.put(`resume:${resumeToken}`, { player, createdAt: Date.now() });
      }
      if (!room.leaderId) {
        room.leaderId = player.id;
        await this.ctx.storage.put("room", room);
      }
      const isLeader = room.leaderId === player.id;
      server.serializeAttachment({ role: "controller", player, resumeToken });
      this.ctx.acceptWebSocket(server, ["controller", `player:${player.id}`]);
      this.send(server, { type: "welcome", player, roomCode: room.code, resumeToken, isLeader });
      this.broadcastHosts({ type: "player_joined", player });
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  players() {
    return this.ctx.getWebSockets("controller")
      .map((socket) => socket.deserializeAttachment()?.player)
      .filter(Boolean);
  }

  send(socket, message) {
    try {
      socket.send(JSON.stringify(message));
    } catch {
      // A close event will clean up the connection.
    }
  }

  broadcastHosts(message) {
    for (const host of this.ctx.getWebSockets("host")) this.send(host, message);
  }

  async webSocketMessage(socket, rawMessage) {
    const attachment = socket.deserializeAttachment();
    let message;
    try {
      message = JSON.parse(typeof rawMessage === "string" ? rawMessage : new TextDecoder().decode(rawMessage));
    } catch {
      return;
    }

    if (attachment?.role === "host") {
      if (message.type !== "controller_state") return;
      const outgoing = {
        type: "controller_state",
        game: String(message.game || "lobby").slice(0, 24),
        roundLabel: String(message.roundLabel || "PARTY MOTION").slice(0, 40),
        title: String(message.title || "Get ready").slice(0, 60),
        instructions: String(message.instructions || "Watch the shared screen.").slice(0, 180),
        crowns: Number(message.crowns) || 0,
        points: Number(message.points) || 0,
        hostCommand: String(message.hostCommand || "").slice(0, 24),
        hostButtonLabel: String(message.hostButtonLabel || "").slice(0, 40),
        hostButtonEnabled: Boolean(message.hostButtonEnabled)
      };
      const playerId = String(message.playerId || "");
      const targets = playerId ? this.ctx.getWebSockets(`player:${playerId}`) : this.ctx.getWebSockets("controller");
      for (const target of targets) this.send(target, outgoing);
      return;
    }

    if (attachment?.role !== "controller") return;

    if (message.type === "party_command") {
      const room = await this.ctx.storage.get("room");
      const command = String(message.command || "");
      const allowed = ["start_party", "start_round", "next_round", "show_final", "play_again"];
      if (room?.leaderId === attachment.player.id && allowed.includes(command)) {
        this.broadcastHosts({ type: "party_command", playerId: attachment.player.id, command });
      }
      return;
    }

    if (message.type === "motion") {
      this.broadcastHosts({
        type: "motion",
        playerId: attachment.player.id,
        seq: Number(message.seq) || 0,
        time: Number(message.time) || Date.now(),
        tilt: [Number(message.tilt?.[0]) || 0, Number(message.tilt?.[1]) || 0],
        acceleration: [
          Number(message.acceleration?.[0]) || 0,
          Number(message.acceleration?.[1]) || 0,
          Number(message.acceleration?.[2]) || 0
        ],
        shake: Math.max(0, Math.min(1, Number(message.shake) || 0)),
        rotation: [
          Number(message.rotation?.[0]) || 0,
          Number(message.rotation?.[1]) || 0,
          Number(message.rotation?.[2]) || 0
        ]
      });
    } else if (message.type === "action") {
      this.broadcastHosts({
        type: "action",
        playerId: attachment.player.id,
        action: String(message.action || "").slice(0, 24)
      });
    }
  }

  async webSocketClose(socket) {
    const attachment = socket.deserializeAttachment();
    if (attachment?.role === "controller") await this.handleControllerDisconnect(socket, attachment);
  }

  async webSocketError(socket) {
    const attachment = socket.deserializeAttachment();
    if (attachment?.role === "controller") await this.handleControllerDisconnect(socket, attachment);
  }

  async handleControllerDisconnect(socket, attachment) {
    const replacements = this.ctx.getWebSockets(`player:${attachment.player.id}`)
      .filter((candidate) => candidate !== socket && candidate.readyState === WebSocket.OPEN);
    if (replacements.length > 0) return;
    this.broadcastHosts({ type: "player_left", playerId: attachment.player.id });

    const room = await this.ctx.storage.get("room");
    if (room?.leaderId !== attachment.player.id) return;
    const candidates = this.ctx.getWebSockets("controller")
      .filter((candidate) => candidate !== socket && candidate.readyState === WebSocket.OPEN);
    const nextLeader = candidates[0];
    const nextAttachment = nextLeader?.deserializeAttachment();
    room.leaderId = nextAttachment?.player?.id || "";
    await this.ctx.storage.put("room", room);
    if (nextLeader) this.send(nextLeader, { type: "leader_status", isLeader: true });
  }
}
