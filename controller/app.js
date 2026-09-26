const elements = {
  joinView: document.querySelector("#joinView"),
  controllerView: document.querySelector("#controllerView"),
  room: document.querySelector("#room"),
  name: document.querySelector("#name"),
  joinButton: document.querySelector("#joinButton"),
  joinError: document.querySelector("#joinError"),
  statusText: document.querySelector("#statusText"),
  roomBadge: document.querySelector("#roomBadge"),
  playerName: document.querySelector("#playerName"),
  motionPanel: document.querySelector("#motionPanel"),
  motionHint: document.querySelector("#motionHint"),
  bubble: document.querySelector("#bubble"),
  calibrateButton: document.querySelector("#calibrateButton"),
  actionButton: document.querySelector("#actionButton"),
  motionToggle: document.querySelector("#motionToggle")
};

const params = new URLSearchParams(location.search);
elements.room.value = (params.get("room") || "").toUpperCase();
elements.name.value = localStorage.getItem("party-motion-name") || "";

let socket;
let wakeLock;
let sequence = 0;
let motionEnabled = false;
let latest = { x: 0, y: 0, rx: 0, ry: 0, rz: 0 };
let baseline = { x: 0, y: 0 };
let filtered = { x: 0, y: 0 };
let lastSentAt = 0;

const clamp = (value, min = -1, max = 1) => Math.max(min, Math.min(max, value));

function normalizedAxes(x, y) {
  const angle = screen.orientation?.angle ?? window.orientation ?? 0;
  if (angle === 90) return { x: -y, y: x };
  if (angle === -90 || angle === 270) return { x: y, y: -x };
  if (Math.abs(angle) === 180) return { x: -x, y: -y };
  return { x, y };
}

function setBubble(x, y) {
  const maxX = elements.motionPanel.clientWidth * .32;
  const maxY = elements.motionPanel.clientHeight * .32;
  elements.bubble.style.transform = `translate(${x * maxX}px, ${y * maxY}px)`;
}

function sendMotion(now) {
  if (!socket || socket.readyState !== WebSocket.OPEN || now - lastSentAt < 33) return;
  lastSentAt = now;
  const x = clamp((filtered.x - baseline.x) / 4.5);
  const y = clamp((filtered.y - baseline.y) / 4.5);
  setBubble(x, y);
  socket.send(JSON.stringify({
    type: "motion",
    seq: ++sequence,
    time: Date.now(),
    tilt: [x, y],
    rotation: [latest.rx, latest.ry, latest.rz]
  }));
}

function onDeviceMotion(event) {
  if (!elements.motionToggle.checked) return;
  const source = event.accelerationIncludingGravity || event.acceleration;
  if (!source || source.x == null || source.y == null) return;
  const axes = normalizedAxes(source.x, source.y);
  filtered.x += (axes.x - filtered.x) * .22;
  filtered.y += (axes.y - filtered.y) * .22;
  latest = {
    x: axes.x,
    y: axes.y,
    rx: event.rotationRate?.alpha || 0,
    ry: event.rotationRate?.beta || 0,
    rz: event.rotationRate?.gamma || 0
  };
  sendMotion(performance.now());
}

async function enableMotion() {
  try {
    if (typeof DeviceMotionEvent !== "undefined" && typeof DeviceMotionEvent.requestPermission === "function") {
      const permission = await DeviceMotionEvent.requestPermission();
      if (permission !== "granted") throw new Error("Motion permission was not granted");
    }
    if (typeof DeviceMotionEvent !== "undefined") {
      window.addEventListener("devicemotion", onDeviceMotion, { passive: true });
      motionEnabled = true;
      elements.motionHint.textContent = "Move your phone to steer";
    } else {
      elements.motionToggle.checked = false;
      elements.motionHint.textContent = "Drag here to steer";
    }
  } catch (error) {
    elements.motionToggle.checked = false;
    elements.motionHint.textContent = "Motion blocked — drag here to steer";
  }
}

async function requestWakeLock() {
  try {
    if ("wakeLock" in navigator) wakeLock = await navigator.wakeLock.request("screen");
  } catch { /* optional enhancement */ }
}

function connect(room, name) {
  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const url = `${protocol}//${location.host}/ws?role=controller&room=${encodeURIComponent(room)}&name=${encodeURIComponent(name)}`;
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
    }
  });
  socket.addEventListener("close", () => {
    elements.statusText.textContent = "Disconnected";
    document.querySelector(".status-dot").style.background = "#ff5c7a";
  });
  socket.addEventListener("error", () => {
    elements.statusText.textContent = "Connection error";
  });
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
    localStorage.setItem("party-motion-name", name);
    await enableMotion();
    await requestWakeLock();
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
  elements.motionHint.textContent = "Calibrated!";
  setTimeout(() => elements.motionHint.textContent = motionEnabled ? "Move your phone to steer" : "Drag here to steer", 900);
});

elements.actionButton.addEventListener("pointerdown", () => {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: "action", action: "boost" }));
});

function touchSteer(event) {
  if (event.cancelable) event.preventDefault();
  const point = event.touches?.[0] || event;
  const rect = elements.motionPanel.getBoundingClientRect();
  const x = clamp(((point.clientX - rect.left) / rect.width - .5) * 2);
  const y = clamp(((point.clientY - rect.top) / rect.height - .5) * 2);
  filtered = { x: baseline.x + x * 4.5, y: baseline.y + y * 4.5 };
  sendMotion(performance.now() + 34);
}

elements.motionPanel.addEventListener("pointerdown", (event) => {
  elements.motionPanel.setPointerCapture(event.pointerId);
  touchSteer(event);
});
elements.motionPanel.addEventListener("pointermove", (event) => {
  if (elements.motionPanel.hasPointerCapture(event.pointerId)) touchSteer(event);
});
elements.motionPanel.addEventListener("pointerup", (event) => {
  elements.motionPanel.releasePointerCapture(event.pointerId);
  filtered = { ...baseline };
  sendMotion(performance.now() + 34);
  setBubble(0, 0);
});

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && !wakeLock?.released) requestWakeLock();
});
