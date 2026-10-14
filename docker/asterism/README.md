# Compose overlays for Asterism

Overlays for the zenohd router of the simulation (`docker-compose.yml` at
the repository root) and the containers that join it: the Zenoh router
opened to the LAN or to browsers, a relay to a second router over mutual
TLS, ROS 2 and the MuJoCo rover. The background is in
`fmruby-core/doc/ruby_asterism/`; each file's header comment has the
details.

**Always run from the repository root, with `docker-compose.yml` as the
first `-f`.** Compose resolves every relative path (`./docker/...`,
`./asterism-console/...`, build contexts) against the directory of the
first file, so the paths in these overlays are written from the root. Bring
a stack down with the same `-f` set it was brought up with, or containers
of the overlays are left behind.

| File | What it is for |
|---|---|
| `docker-compose.zenoh-lan.yml` | Publishes zenohd's 7447 on the LAN (not only loopback), so a board on WiFi can reach it. REST (8000) stays on loopback. |
| `docker-compose.zenoh-ws.yml` | Adds a `ws/` listener (7449, loopback) for the browser build (wasm). Put it after `zenoh-lan`. |
| `docker-compose.zenoh-wss.yml` | A Caddy proxy (`zenohd-wss`, 7450) that ends TLS for pages served over https and hands the WebSocket to the `ws/` listener. Needs `ZENOH_WSS_HOST`; put it after `zenoh-ws`. |
| `docker-compose.relay.yml` | Makes zenohd the home router and connects it over mTLS to `zenohd-cloud` (tls/7448, ACL per certificate), with `ros2-cloud` on a network of its own. Certificates come from `asterism-console` (`script/relay_certs`). Not with `zenoh-ws` / `zenoh-wss`. |
| `docker-compose.ros2.yml` | A ROS 2 Jazzy shell (`ros2`, rmw_zenoh) joined to zenohd. Builds `fmruby-ros2-jazzy-zenoh:local`, which `relay`'s `ros2-cloud` also uses. |
| `docker-compose.mujoco.yml` | The MuJoCo two-wheeled rover over ROS 2 (`mujoco`, built from `docker/mujoco/`). Driving it and its topics: `docker/mujoco/README.md`. |
| `docker-compose.mujoco-wslg.yml` | The MuJoCo viewer window on WSLg (GPU through WSL's D3D12). Only on top of `mujoco`. |

None of them is used alone: each one adds to or changes services of
`docker-compose.yml` (zenohd above all). The simulation itself is brought
up by `sim_up` (or `docker compose up` with `.env`); `sim_up` recreates
zenohd from `docker-compose.yml` alone, so run an overlay's line again
afterwards.

## Combinations

```
B="-f docker-compose.yml"
A=docker/asterism

# a board on WiFi reaches the router
docker compose $B -f $A/docker-compose.zenoh-lan.yml up -d zenohd

# the browser build (http, on this computer); with a board as well
docker compose $B -f $A/docker-compose.zenoh-ws.yml up -d zenohd
docker compose $B -f $A/docker-compose.zenoh-lan.yml \
  -f $A/docker-compose.zenoh-ws.yml up -d zenohd

# the browser build over https from another computer
ZENOH_WSS_HOST=<host> docker compose $B -f $A/docker-compose.zenoh-lan.yml \
  -f $A/docker-compose.zenoh-ws.yml -f $A/docker-compose.zenoh-wss.yml \
  up -d zenohd zenohd-wss

# ROS 2 (add zenoh-lan for a board)
docker compose $B -f $A/docker-compose.zenoh-lan.yml \
  -f $A/docker-compose.ros2.yml up -d zenohd ros2

# the relay (certificates first: (cd asterism-console && script/relay_certs))
docker compose $B -f $A/docker-compose.zenoh-lan.yml \
  -f $A/docker-compose.ros2.yml -f $A/docker-compose.relay.yml \
  up -d zenohd zenohd-cloud ros2 ros2-cloud

# the MuJoCo rover, headless or with the viewer on WSLg
docker compose $B -f $A/docker-compose.zenoh-lan.yml \
  -f $A/docker-compose.mujoco.yml up -d zenohd mujoco
docker compose $B -f $A/docker-compose.mujoco.yml \
  -f $A/docker-compose.mujoco-wslg.yml up -d zenohd mujoco

# down: the same -f set as the up
docker compose $B -f $A/docker-compose.zenoh-lan.yml \
  -f $A/docker-compose.ros2.yml down
```

`COMPOSE_FILE` saves retyping a set (the separator is `:`), e.g.
`export COMPOSE_FILE=docker-compose.yml:docker/asterism/docker-compose.zenoh-lan.yml:docker/asterism/docker-compose.ros2.yml`.

The General MIDI output overlay of the simulation is in `docker/midi/`.
