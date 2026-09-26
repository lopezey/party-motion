const { randomBytes } = require("node:crypto");

const COLORS = ["#ff5c7a", "#58d6ff", "#ffd15c", "#8cf28a", "#b88cff", "#ff995c"];

function token(bytes = 18) {
  return randomBytes(bytes).toString("base64url");
}

class RoomRegistry {
  constructor({ roomTtlMs = 6 * 60 * 60 * 1000 } = {}) {
    this.rooms = new Map();
    this.roomTtlMs = roomTtlMs;
  }

  create() {
    let code;
    do {
      code = randomBytes(3).toString("hex").toUpperCase().slice(0, 6);
    } while (this.rooms.has(code));

    const room = {
      code,
      hostToken: token(),
      hostSocket: null,
      players: new Map(),
      createdAt: Date.now(),
      lastActiveAt: Date.now()
    };
    this.rooms.set(code, room);
    return room;
  }

  get(code) {
    return this.rooms.get(String(code || "").toUpperCase());
  }

  addPlayer(room, name, socket) {
    const id = token(8);
    const player = {
      id,
      name: String(name || "Player").trim().slice(0, 18) || "Player",
      color: COLORS[room.players.size % COLORS.length],
      socket,
      joinedAt: Date.now()
    };
    room.players.set(id, player);
    room.lastActiveAt = Date.now();
    return player;
  }

  removePlayer(room, id) {
    const removed = room.players.delete(id);
    room.lastActiveAt = Date.now();
    return removed;
  }

  cleanup(now = Date.now()) {
    for (const [code, room] of this.rooms) {
      const empty = !room.hostSocket && room.players.size === 0;
      if (empty && now - room.lastActiveAt > this.roomTtlMs) this.rooms.delete(code);
    }
  }
}

module.exports = { RoomRegistry, COLORS };
