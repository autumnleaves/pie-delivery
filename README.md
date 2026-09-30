# pie-delivery

A reusable GitHub Action that deploys a directory from your repo to a Raspberry Pi over [Tailscale](https://tailscale.com/). No port forwarding and no public SSH.

On each run it:

1. Joins your tailnet as an **ephemeral** node, using [`tailscale/github-action`](https://github.com/tailscale/github-action). The node is removed automatically after the job ends.
2. Connects to the Pi over SSH. It retries while the tailnet settles.
3. Runs your `pre-deploy` script on the Pi, if you set one.
4. `rsync`s `source/` into `target/` on the Pi.
5. Runs your `post-deploy` script on the Pi, if you set one. For example, restarting a service.

## Quick start

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    concurrency: deploy-pi
    steps:
      - uses: actions/checkout@v5
      - uses: YOUR-GITHUB-USER/pie-delivery@v1
        with:
          tailscale-oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          tailscale-oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          host: raspberrypi
          ssh-key: ${{ secrets.PI_SSH_KEY }}
          known-hosts: ${{ secrets.PI_KNOWN_HOSTS }}
          source: app
          target: /home/pi/app
          post-deploy: sudo systemctl restart myapp
```

For a fuller example with path filters, a dry-run toggle and excludes, see [examples/deploy-to-pi.yml](examples/deploy-to-pi.yml).

## One-time setup

### 1. Tailscale

In the [admin console](https://login.tailscale.com/admin/acls), add a tag for CI and allow it to reach the Pi on SSH. Also tag the Pi (`sudo tailscale up --advertise-tags=tag:pi`) or reference it by host.

```jsonc
{
  "tagOwners": {
    "tag:ci": ["autogroup:admin"],
    "tag:pi": ["autogroup:admin"]
  },
  "grants": [
    { "src": ["tag:ci"], "dst": ["tag:pi"], "ip": ["tcp:22"] }
  ]
}
```

Then create an **OAuth client** under *Settings → OAuth clients*. Give it the **Auth Keys: write** scope with tag `tag:ci`. Store the client ID and secret as repo secrets `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET`.

> An auth key works too (`tailscale-authkey`). Make it reusable, ephemeral and pre-approved. OAuth clients don't expire the way auth keys do, so they're the better choice for CI.

### 2. SSH access to the Pi

You have two options.

**Option A: a normal SSH key.** This is the simplest.

```bash
ssh-keygen -t ed25519 -f pi_deploy -N "" -C "github-actions"
```

```bash
ssh-copy-id -i pi_deploy.pub pi@raspberrypi
```

Save the contents of `pi_deploy` (the private key) as the secret `PI_SSH_KEY`.

**Option B: Tailscale SSH.** With this option you don't need a key. Run `sudo tailscale up --ssh` on the Pi and add an SSH rule to your policy. Then leave `ssh-key` empty.

```jsonc
"ssh": [
  { "action": "accept", "src": ["tag:ci"], "dst": ["tag:pi"], "users": ["pi"] }
]
```

### 3. Pin the Pi's host key (recommended)

From any machine on your tailnet:

```bash
ssh-keyscan raspberrypi
```

Save the output as the secret `PI_KNOWN_HOSTS`. If you skip this step, the action trusts the host key the first time it connects and logs a warning.

### 4. On the Pi

- `rsync` must be installed. Install it with `sudo apt install rsync`.
- The SSH user needs write access to `target`.
- If `post-deploy` uses `sudo`, give the user passwordless sudo for exactly those commands. For example, add this to `/etc/sudoers.d/deploy`:
  ```
  pi ALL=(root) NOPASSWD: /usr/bin/systemctl restart myapp
  ```

## Inputs

| Input | Default | Description |
|---|---|---|
| `tailscale-oauth-client-id` | | Tailscale OAuth client ID |
| `tailscale-oauth-secret` | | Tailscale OAuth client secret |
| `tailscale-authkey` | | Auth key. Use this instead of OAuth |
| `tailscale-tags` | `tag:ci` | Tags the runner advertises. OAuth requires at least one tag |
| `host` | **required** | The Pi's MagicDNS name or `100.x` IP |
| `user` | `pi` | SSH user |
| `ssh-port` | `22` | SSH port |
| `ssh-key` | | Private key. Leave empty for Tailscale SSH |
| `known-hosts` | | `known_hosts` lines for the Pi |
| `source` | `.` | Directory in the workspace to deploy. Its *contents* are copied |
| `target` | **required** | Destination directory on the Pi. It's created if it doesn't exist |
| `delete` | `false` | Remove files on the Pi that aren't in `source`. Excluded paths are kept |
| `exclude` | `.git` | rsync exclude patterns, one per line |
| `rsync-args` | | Extra rsync arguments, for example `--checksum --chmod=D755,F644` |
| `pre-deploy` | | Script to run on the Pi in `target` before the sync |
| `post-deploy` | | Script to run on the Pi in `target` after the sync |
| `dry-run` | `false` | Show what would change without changing anything. Hooks are skipped |
| `connect-attempts` | `10` | Number of SSH connection attempts. They're 3 seconds apart |

Hook scripts run with `bash` and `set -euo pipefail`. If any command fails, the deploy fails. Hooks can span several lines.

## Deploying to several Pis

Use a matrix:

```yaml
strategy:
  matrix:
    host: [pi-kitchen, pi-garage]
steps:
  - uses: actions/checkout@v5
  - uses: YOUR-GITHUB-USER/pie-delivery@v1
    with:
      host: ${{ matrix.host }}
      # ...
```

## Testing

The integration tests run `scripts/deploy.sh` against a throwaway SSH server in Docker. They use real `ssh` and `rsync`, and don't need a Pi or Tailscale. CI runs them on every push. To run them locally, start Docker and then run:

```bash
bash test/integration/run.sh
```

## Releasing this action

Consumers reference a tag. After you push changes:

```bash
git tag -a v1.0.0 -m "v1.0.0"
```

```bash
git tag -f v1
```

```bash
git push origin v1.0.0 v1 --force
```

## Notes

- This action only runs on Linux runners, such as `ubuntu-latest`.
- `delete: true` is powerful. Point `target` at a directory used only for this deploy. Use `dry-run: true` the first time.
- For stricter supply-chain hygiene, fork this action or pin it, and `tailscale/github-action`, to a commit SHA.
