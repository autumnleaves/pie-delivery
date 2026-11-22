# Changelog

## v2.0.0

- **New: `pie-delivery/compose`**, for Docker Compose apps on a host set up once with `host/install.sh`. One shared `deploy` user and a root-owned `pie-deploy` script on the host replace each app's own deploy user, key, sudo rule and setup script. It loads images from the bundle, writes each project's `.env` with the app's secrets (sent on stdin), waits for containers and health URLs, rolls back on failure, keeps releases for `pie-deploy rollback`, and prunes old ones. See the README's Compose apps section.
- **Tailscale workload identity federation** in both actions: `tailscale-audience`, with a federated identity's client ID in `tailscale-oauth-client-id`, so CI needs no Tailscale secret.
- Both actions use `tailscale/github-action@v4` (was v3).
- The root action's inputs and behaviour are otherwise unchanged from v1.

## v1.0.0

- The rsync-over-Tailscale action: joins the tailnet as an ephemeral node, syncs a directory over SSH, runs pre- and post-deploy hooks.
