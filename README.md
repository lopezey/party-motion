# Party Motion

A working vertical slice for a no-download, phone-as-controller party game. Phones join a room in the browser, send calibrated accelerometer/gyro data over WebSockets, and steer colored players in a Godot arena.

## What is included

- A Godot 4 desktop host and playable tilt arena
- A responsive phone controller with motion permission, calibration, touch fallback, wake lock, and boost button
- A Node.js room relay using standard WebSockets
- Six-character room codes and generated QR codes
- Reconnection-safe room/player messages and basic rate reduction on the controller
- Unit tests for room lifecycle behavior

## Run locally

Requirements: Node.js 20+ and Godot 4.3+.

```powershell
npm install
npm start
```

Open `godot/project.godot` in Godot and run the project. Select **Create room**.

For desktop-only UI testing, open `http://localhost:8787/?room=ROOMCODE`. A mouse or touch can drag the controller pad even when motion sensors are unavailable.

## Test with real phones

Motion sensor APIs require a secure HTTPS page. Deploy this server behind HTTPS or expose it through an HTTPS development tunnel, then set the public address before starting the relay:

```powershell
$env:PUBLIC_URL = "https://your-public-controller.example"
npm start
```

Point the Godot host at the same relay:

```powershell
$env:PARTY_RELAY_URL = "https://your-public-controller.example"
godot --path godot
```

The HTTPS provider must support WebSocket upgrades. `PUBLIC_URL` determines the controller link encoded in the QR code. `PARTY_RELAY_URL` tells Godot where to create rooms and connect its host socket.

## Hosted relay

The included `render.yaml` deploys the Dockerized relay to Render with HTTPS, secure WebSockets, and `/health` monitoring. After deployment, launch Godot with the permanent service URL:

```powershell
$env:PARTY_RELAY_URL = "https://party-motion-lopezey.onrender.com"
godot --path godot
```

If Render assigns a different hostname, use the exact URL displayed in the Render dashboard. Free Render instances may sleep when inactive, so open the controller URL once before starting a party session or move the service to an always-on instance.

## Architecture

```text
Phone browser(s) ── WSS ──> Node room relay <── WSS ── Godot host
   motion + touch              room routing             game authority
```

The relay intentionally keeps room state in memory. Restarting it closes all rooms. For a production service with multiple relay instances, introduce shared room discovery and sticky routing before adding a database.

## Protocol

Controllers send at most about 30 motion packets per second:

```json
{"type":"motion","seq":42,"time":1727361820123,"tilt":[0.2,-0.7],"rotation":[2.4,0.1,-1.0]}
```

The relay attaches the trusted `playerId` before forwarding the packet to Godot. Controllers can also send an action:

```json
{"type":"action","action":"boost"}
```

## Next milestones

1. Test sensor axes and permission flows across physical iPhones and Android phones.
2. Add automatic host reconnect and short-lived controller resume tokens.
3. Record anonymized motion traces to tune gesture recognition.
4. Add collisions, rounds, scoring, sound, and a win condition to Tilt Arena.
5. Extract reusable lobby and minigame interfaces after the first playtest.
