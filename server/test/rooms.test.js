const test = require("node:test");
const assert = require("node:assert/strict");
const { RoomRegistry } = require("../src/rooms");

test("creates distinct rooms and finds codes case-insensitively", () => {
  const rooms = new RoomRegistry();
  const first = rooms.create();
  const second = rooms.create();
  assert.notEqual(first.code, second.code);
  assert.equal(rooms.get(first.code.toLowerCase()), first);
  assert.ok(first.hostToken.length > 20);
});

test("adds and removes sanitized players", () => {
  const rooms = new RoomRegistry();
  const room = rooms.create();
  const player = rooms.addPlayer(room, "  A very long player name that is trimmed  ", {});
  assert.equal(player.name, "A very long player");
  assert.equal(room.players.size, 1);
  assert.equal(rooms.removePlayer(room, player.id), true);
  assert.equal(room.players.size, 0);
});

test("cleans up inactive empty rooms", () => {
  const rooms = new RoomRegistry({ roomTtlMs: 10 });
  const room = rooms.create();
  room.lastActiveAt = 100;
  rooms.cleanup(111);
  assert.equal(rooms.get(room.code), undefined);
});
