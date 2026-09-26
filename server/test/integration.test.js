const test = require("node:test");
const assert = require("node:assert/strict");
const { once } = require("node:events");
const WebSocket = require("ws");
const { server } = require("../src/server");

function nextJson(socket, expectedType) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${expectedType}`)), 2000);
    const onMessage = (data) => {
      const message = JSON.parse(data.toString());
      if (message.type !== expectedType) return;
      clearTimeout(timer);
      socket.off("message", onMessage);
      resolve(message);
    };
    socket.on("message", onMessage);
  });
}

test("relays identified controller motion to the Godot host", async (t) => {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;

  t.after(async () => {
    await new Promise((resolve) => server.close(resolve));
  });

  const roomResponse = await fetch(`${base}/api/rooms`, { method: "POST" });
  assert.equal(roomResponse.status, 201);
  const room = await roomResponse.json();

  const host = new WebSocket(`ws://127.0.0.1:${port}/ws?role=host&room=${room.roomCode}&token=${room.hostToken}`);
  const roomStatePromise = nextJson(host, "room_state");
  await once(host, "open");
  await roomStatePromise;

  const joinedPromise = nextJson(host, "player_joined");
  const controller = new WebSocket(`ws://127.0.0.1:${port}/ws?role=controller&room=${room.roomCode}&name=Sam`);
  await once(controller, "open");
  const joined = await joinedPromise;
  assert.equal(joined.player.name, "Sam");

  const motionPromise = nextJson(host, "motion");
  controller.send(JSON.stringify({ type: "motion", seq: 7, time: 1234, tilt: [0.25, -0.75], rotation: [1, 2, 3] }));
  const motion = await motionPromise;
  assert.equal(motion.playerId, joined.player.id);
  assert.deepEqual(motion.tilt, [0.25, -0.75]);
  assert.deepEqual(motion.rotation, [1, 2, 3]);

  controller.close();
  host.close();
  await Promise.all([once(controller, "close"), once(host, "close")]);
});
