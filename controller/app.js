const elements = {
  joinView: document.querySelector("#joinView"), controllerView: document.querySelector("#controllerView"),
  room: document.querySelector("#room"), name: document.querySelector("#name"), joinButton: document.querySelector("#joinButton"),
  joinError: document.querySelector("#joinError"), statusText: document.querySelector("#statusText"),
  roomBadge: document.querySelector("#roomBadge"), playerName: document.querySelector("#playerName"),
  crowns: document.querySelector("#crowns"), points: document.querySelector("#points"), roundLabel: document.querySelector("#roundLabel"),
  gameTitle: document.querySelector("#gameTitle"), gameInstruction: document.querySelector("#gameInstruction"),
  motionPanel: document.querySelector("#motionPanel"), motionHint: document.querySelector("#motionHint"),
  bubble: document.querySelector("#bubble"), tiltMeter: document.querySelector("#tiltMeter"),
  shakeMeter: document.querySelector("#shakeMeter"), rotateMeter: document.querySelector("#rotateMeter"),
  calibrateButton: document.querySelector("#calibrateButton")
};

const params = new URLSearchParams(location.search);
elements.room.value = (params.get("room") || "").toUpperCase();
elements.name.value = localStorage.getItem("party-motion-name") || "";

let socket;
let wakeLock;
let sequence = 0;
let motionEnabled = false;
let joinedRoom = "";
let joinedName = "";
let reconnectTimer;
let latest = { x: 0, y: 0, z: 0, rx: 0, ry: 0, rz: 0, shake: 0 };
let previousGravity = { x: 0, y: 0, z: 0 };
let baseline = { x: 0, y: 0 };
let filtered = { x: 0, y: 0 };
let lastSentAt = 0;

const clamp = (value, min = -1, max = 1) => Math.max(min, Math.min(max, value));
const magnitude3 = (x, y, z) => Math.sqrt(x * x + y * y + z * z);
const resumeKey = (room) => `party-motion-resume:${room}`;

function normalizedAxes(x, y) {
  const angle = screen.orientation?.angle ?? window.orientation ?? 0;
  if (angle === 90) return { x: -y, y: x };
  if (angle === -90 || angle === 270) return { x: y, y: -x };
  if (Math.abs(angle) === 180) return { x: -x, y: -y };
  return { x, y };
}

function setBubble(x, y) {
  const maxX = elements.motionPanel.clientWidth * .29;
  const maxY = elements.motionPanel.clientHeight * .25;
  elements.bubble.style.transform = `translate(${x * maxX}px, ${y * maxY}px)`;
}

function setMeters(tilt, shake, rotate) {
  elements.tiltMeter.style.width = `${Math.round(clamp(tilt, 0, 1) * 100)}%`;
  elements.shakeMeter.style.width = `${Math.round(clamp(shake, 0, 1) * 100)}%`;
  elements.rotateMeter.style.width = `${Math.round(clamp(rotate, 0, 1) * 100)}%`;
}

function sendMotion(now) {
  if (!socket || socket.readyState !== WebSocket.OPEN || now - lastSentAt < 33) return;
  lastSentAt = now;
  const x = clamp((filtered.x - baseline.x) / 4.5);
  const y = clamp((filtered.y - baseline.y) / 4.5);
  const rotate = clamp(magnitude3(latest.rx, latest.ry, latest.rz) / 240, 0, 1);
  setBubble(x, y);
  setMeters(Math.hypot(x, y), latest.shake, rotate);
  socket.send(JSON.stringify({
    type: "motion", seq: ++sequence, time: Date.now(), tilt: [x, y],
    acceleration: [latest.x, latest.y, latest.z], shake: latest.shake,
    rotation: [latest.rx, latest.ry, latest.rz]
  }));
}

function onDeviceMotion(event) {
  const gravity = event.accelerationIncludingGravity;
  if (!gravity || gravity.x == null || gravity.y == null) return;
  const axes = normalizedAxes(gravity.x, gravity.y);
  filtered.x += (axes.x - filtered.x) * .22;
  filtered.y += (axes.y - filtered.y) * .22;

  const linear = event.acceleration;
  const ax = linear?.x ?? gravity.x - previousGravity.x;
  const ay = linear?.y ?? gravity.y - previousGravity.y;
  const az = linear?.z ?? gravity.z - previousGravity.z;
  previousGravity = { x: gravity.x, y: gravity.y, z: gravity.z };
  const impulse = clamp((magnitude3(ax || 0, ay || 0, az || 0) - 1.5) / 11, 0, 1);
  latest = {
    x: ax || 0, y: ay || 0, z: az || 0,
    rx: event.rotationRate?.alpha || 0, ry: event.rotationRate?.beta || 0, rz: event.rotationRate?.gamma || 0,
    shake: Math.max(impulse, latest.shake * .78)
  };
  sendMotion(performance.now());
}

async function enableMotion() {
  if (motionEnabled) return;
  if (typeof DeviceMotionEvent === "undefined") throw new Error("This browser does not provide motion sensors.");
  if (typeof DeviceMotionEvent.requestPermission === "function") {
    const permission = await DeviceMotionEvent.requestPermission();
    if (permission !== "granted") throw new Error("Motion permission was not granted.");
  }
  window.addEventListener("devicemotion", onDeviceMotion, { passive: true });
  motionEnabled = true;
}

async function requestWakeLock() {
  try { if ("wakeLock" in navigator) wakeLock = await navigator.wakeLock.request("screen"); }
  catch { /* Optional enhancement. */ }
}

function applyControllerState(message) {
  elements.roundLabel.textContent = message.roundLabel || "PARTY MOTION";
  elements.gameTitle.textContent = message.title || "Get ready";
  elements.gameInstruction.textContent = message.instructions || "Watch the shared screen.";
  if (Number.isFinite(message.crowns)) elements.crowns.textContent = message.crowns;
  if (Number.isFinite(message.points)) elements.points.textContent = message.points;
  elements.motionPanel.dataset.mode = message.game || "lobby";
}

function connect(room, name) {
  clearTimeout(reconnectTimer);
  joinedRoom = room;
  joinedName = name;
  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const resume = localStorage.getItem(resumeKey(room)) || "";
  const url = `${protocol}//${location.host}/ws?role=controller&room=${encodeURIComponent(room)}&name=${encodeURIComponent(name)}&resume=${encodeURIComponent(resume)}`;
  socket = new WebSocket(url);
  socket.addEventListener("open", () => {
    elements.statusText.textContent = "Connected";
    document.querySelector(".status-dot").style.background = "#8cf28a";
  });
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.type === "welcome") {
      elements.playerName.textContent = message.player.name;
      elements.roomBadge.textContent = message.roomCode;
      document.documentElement.style.setProperty("--accent", message.player.color);
      if (message.resumeToken) localStorage.setItem(resumeKey(room), message.resumeToken);
    } else if (message.type === "controller_state") {
      applyControllerState(message);
    }
  });
  socket.addEventListener("close", () => {
    elements.statusText.textContent = "Reconnecting…";
    document.querySelector(".status-dot").style.background = "#ffd15c";
    reconnectTimer = setTimeout(() => connect(joinedRoom, joinedName), 1200);
  });
  socket.addEventListener("error", () => { elements.statusText.textContent = "Connection interrupted"; });
}

elements.joinButton.addEventListener("click", async () => {
  const room = elements.room.value.trim().toUpperCase();
  const name = elements.name.value.trim() || "Player";
  elements.joinError.textContent = "";
  if (!/^[A-Z0-9]{6}$/.test(room)) {
    elements.joinError.textContent = "Enter the six-character room code.";
    return;
  }
  elements.joinButton.disabled = true;
  try {
    const response = await fetch(`/api/rooms/${room}`);
    if (!response.ok) throw new Error("That room does not exist.");
    await enableMotion();
    await requestWakeLock();
    localStorage.setItem("party-motion-name", name);
    connect(room, name);
    elements.joinView.classList.add("hidden");
    elements.controllerView.classList.remove("hidden");
  } catch (error) {
    elements.joinError.textContent = error.message || "Could not join the room.";
    elements.joinButton.disabled = false;
  }
});

elements.calibrateButton.addEventListener("click", () => {
  baseline = { x: filtered.x, y: filtered.y };
  setBubble(0, 0);
  elements.motionHint.textContent = "Calibrated! Hold this position.";
  setTimeout(() => elements.motionHint.textContent = "Motion connected", 1000);
});

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && wakeLock?.released !== false) requestWakeLock();
});
