# Party Motion

Party Motion is a no-download, local multiplayer party game built around phone movement. The game runs on the shared screen, while each player joins from a mobile browser and uses their phone's motion controls to control the game.

Live phone controller: [party.citradox.com](https://party.citradox.com)

## Current prototype

- A Godot host application for a shared screen
- Browser-based phone controllers with accelerometer and gyroscope input
- QR-code and six-character room joining
- Three minigames
- A permanent Cloudflare Worker relay and Durable Object room service
- A local Node.js relay for development

The desktop host remains the authority for game state and scoring. Phones send motion data and party commands.

## How it works

```text
Player phones
  browser motion sensors
         │
         │ HTTPS + WebSocket
         ▼
Cloudflare Worker at party.citradox.com
  static controller site + one Durable Object per room
         │
         │ WebSocket
         ▼
Godot host
  lobby + minigames + scoring + shared display
```

## Project layout

```text
party-motion/
├── controller/             Phone website frontend
│   ├── index.html          Page structure
│   ├── styles.css          Visual design and responsive layout
│   └── app.js              Joining, sensors, leader UI, and WebSocket client
├── godot/                  Shared-screen game
│   ├── project.godot       Godot project configuration
│   ├── main.tscn           Main scene
│   └── scripts/main.gd     Lobby, rounds, minigames, scoring, and relay client
├── worker/
│   └── index.mjs           Production Cloudflare Worker and Durable Object relay
├── server/
│   ├── src/                Local Node.js relay
│   └── test/               Node relay tests
├── wrangler.jsonc          Cloudflare deployment configuration
└── package.json            Development scripts and dependencies
```

If you are changing the public website, start in `controller/`. If you are changing gameplay or the shared-screen interface, start in `godot/`. If you are changing rooms, connections, or authorization, inspect `worker/index.mjs`. Keep the local relay behavior in sync where appropriate.

## Requirements

- Node.js 20 or newer
- npm
- Godot 4.7 or newer
- A modern iPhone or Android phone with motion sensors

## Run the current production-backed game

The Godot project uses `https://party.citradox.com` by default, so no local web server is required for a normal playtest.

1. Open `godot/project.godot` in Godot.
2. Run the project.
3. Select **Create Room** on the shared screen.
4. Scan the QR code with each phone or visit the displayed URL.
5. Allow motion access and calibrate the phone when prompted.
6. The first phone to join receives the party-leader controls.

Refresh an already-open phone page after deploying controller changes so it loads the newest frontend assets.

## Local development

Install dependencies:

```powershell
npm install
```

Start the local Node relay:

```powershell
npm start
```

Then point Godot to it before launching Godot from the same terminal:

```powershell
$env:PARTY_RELAY_URL = "http://localhost:8787"
godot --path godot
```

Open `http://localhost:8787/?room=ROOMCODE` to test the controller on the same computer. Mouse or touch dragging can simulate tilt for basic UI testing.

Real phone motion testing requires a secure HTTPS origin because mobile browsers restrict motion sensors on insecure pages. The production Cloudflare deployment already provides HTTPS. If testing a local relay from a physical phone, use an HTTPS tunnel that supports WebSocket upgrades and set both the relay's public URL and Godot's relay URL accordingly.

```powershell
$env:PUBLIC_URL = "https://your-tunnel.example"
npm start
```

In a second terminal:

```powershell
$env:PARTY_RELAY_URL = "https://your-tunnel.example"
godot --path godot
```

## Cloudflare development and deployment

The production service is configured in `wrangler.jsonc`. It serves the files in `controller/`, handles REST and WebSocket routes in `worker/index.mjs`, and stores each active room in a Durable Object.

Run the Workers version locally:

```powershell
npm run cf:dev
```

Deploy the current branch:

```powershell
npm run deploy
```

Deployment updates the live controller and relay at `party.citradox.com`. Only deploy reviewed changes: active rooms can be interrupted by relay changes, and frontend changes become public immediately.

