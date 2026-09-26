# Party Motion

A motion-only, no-download party game. Phones join in the browser and use accelerometer/gyro input across a three-round Godot party session with crowns, placement points, and a final champion.

## What is included

- A Godot 4 party host with lobby, tutorials, timed rounds, results, crowns, points, and final standings
- Three minigames: Tilt Treasure, Shake Sprint, and Reactor Spin
- A responsive motion-only phone controller with permission, calibration, live sensor meters, scoring, and wake lock
- A Node.js room relay using standard WebSockets
- A production Cloudflare Worker relay with Durable Object rooms at `party.citradox.com`
- Six-character room codes, generated QR codes, bidirectional controller instructions, and player resume tokens
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

## Hosted relay on Cloudflare

The production relay runs as a Cloudflare Worker with one Durable Object per room. The controller assets, REST endpoints, QR codes, and WebSockets share one HTTPS origin.

```powershell
npm install
npm run cf:dev   # local Workers-compatible development
npm run deploy   # deploy to Cloudflare
```

The Godot project uses the production relay by default:

```powershell
godot --path godot
```

Set `PARTY_RELAY_URL` only when you want to override that default. The original Node relay remains available through `npm start` for quick local testing. Cloudflare deployment uses `worker/index.mjs` and `wrangler.jsonc`.

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
