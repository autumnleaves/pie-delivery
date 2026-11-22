# pie-delivery

GitHub Actions that deploy over [Tailscale](https://tailscale.com/), with no port forwarding and no public SSH:

- **`pie-delivery`** deploys a directory from your repo to a Raspberry Pi (or any SSH host): rsync plus optional hooks. The rest of this section and [One-time setup](#one-time-setup) cover it.
- **`pie-delivery/compose`** deploys Docker Compose apps to a host you set up once with [`host/install.sh`](host/install.sh). Each app then needs nothing on the host: no user, key or setup script of its own. See [Compose apps](#compose-apps).

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
      - uses: YOUR-GITHUB-USER/pie-delivery@v2
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

**No Tailscale secret at all:** with [workload identity federation](https://tailscale.com/kb/1581/workload-identity-federation), Tailscale trusts GitHub's own short-lived OIDC token instead. Under *Settings → Trust credentials*, add a federated identity with issuer GitHub, a subject such as `repo:YOUR-GITHUB-USER/*:ref:refs/heads/main` (every repo of yours, `main` only), scope **Auth Keys: write** and tag `tag:ci`. Then pass its client ID and audience as `tailscale-oauth-client-id` and `tailscale-audience`, leave `tailscale-oauth-secret` empty, and give the job `permissions: id-token: write`. Neither value is secret: the identity only accepts tokens GitHub issues for the repos and branches it names.

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
| `tailscale-oauth-client-id` | | Client ID of a Tailscale federated identity or OAuth client |
| `tailscale-audience` | | Federated identity's audience (workload identity federation) |
| `tailscale-oauth-secret` | | OAuth client secret (OAuth clients only) |
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
  - uses: YOUR-GITHUB-USER/pie-delivery@v2
    with:
      host: ${{ matrix.host }}
      # ...
```

## Compose apps

`pie-delivery/compose` deploys Docker Compose apps to a host prepared once with `host/install.sh`. After that, an app needs no setup on the host: CI connects as one shared `deploy` user, and a fixed, root-owned script there, `pie-deploy`, does the rest.

On each run it:

1. Joins your tailnet as an ephemeral node (workload identity federation recommended, so there's no Tailscale secret).
2. Connects to the host as `deploy`, by Tailscale SSH or with an SSH key, and checks it runs `pie-deploy` 2.
3. rsyncs the bundle to `/var/lib/pie/incoming/<app>/<release>/`.
4. Runs `sudo pie-deploy deploy <app> <release>` with your `secrets` on stdin. That:
   - checks the bundle (`pie.json`, a Compose `name:` per project, paths that stay inside it) and the mounts it needs;
   - copies it to `/opt/apps/<app>/releases/<release>`, creates the app's persistent folders, and writes each project's `.env`;
   - loads `images/*.tar(.gz)`, pulls and builds the rest;
   - runs `docker compose up --wait` for each project, then polls the health URLs;
   - points `/opt/apps/<app>/current` at it if all is well, or brings the previous release back and fails;
   - keeps the newest few releases (and their loaded images) for rollback.

### Set up the host (once)

From a checkout of this repo on the host:

```bash
sudo bash host/install.sh
```

That installs `/usr/local/sbin/pie-deploy`, creates user `deploy` (who may sudo `pie-deploy` and nothing else) and the folders. Docker with the Compose plugin must already be installed. Re-run it after a new pie-delivery release to update `pie-deploy`; apps' workflows check the version and say so if the host is behind.

CI reaches the host with **Tailscale SSH** (`sudo tailscale set --ssh` on the host) and a rule in your tailnet policy:

```jsonc
"ssh": [
  { "action": "accept", "src": ["tag:ci"], "dst": ["tag:server"], "users": ["deploy"] }
]
```

Once Tailscale SSH is on, *all* SSH to the host's Tailscale address goes through the policy, yours included, so add a rule for your own login before turning it on. SSH to its LAN address is unaffected. If you'd rather not use Tailscale SSH, set the host up with a key instead (`sudo bash host/install.sh --ssh-key deploy.pub`, accepted only from Tailscale addresses), allow `tcp:22` from `tag:ci`, and pass the private key as `ssh-key`.

### The bundle

A directory in the workspace with a `pie.json`, the app's Compose project folders, and optionally `images/` with `docker save` output (`.tar` or `.tar.gz`) for images built in CI:

```
bundle/
├── pie.json
├── stack/
│   ├── compose.yaml        # must set a top-level name:
│   └── .env.example        # optional: non-secret settings
└── images/
    └── myapp.tar.gz        # optional
```

```jsonc
{
  "projects": ["stack"],                    // folders with a compose.yaml, started in this order
  "health": [                               // each must answer 2xx (polled from a container on that network)
    { "network": "myapp_default", "url": "http://web:8080/health" }
  ],
  "dirs": [                                 // persistent folders under /opt/apps/<app>/, made once
    { "path": "data", "owner": "1654:1654", "mode": "750" }
  ],
  "mounts": ["/mnt/media"],                 // must be mounted, or nothing is deployed
  "keep": 3,                                // releases kept for rollback (default 3)
  "timeout": 120                            // seconds for containers and health (default 120)
}
```

Only `projects` is required. Compose healthchecks count too: `up --wait` waits for them.

Each project's `.env` is its `.env.example`, then `APP_ROOT=/opt/apps/<app>` and `RELEASE=<release>`, then the `secrets` (each overriding a line of the same name). The file is root-only. Compose files use them as usual, for example `image: myapp:${RELEASE}` for an image from the bundle, or `${APP_ROOT}/data:/data` for persistent data. Values are written single-quoted, so `$` in a secret is literal; a value can't contain a newline or a single quote.

When the bundle has images, only images that are missing are pulled, so pin other images' tags rather than using `latest`. To pull private images, pass `PIE_REGISTRY` (default `ghcr.io`), `PIE_REGISTRY_USER` and `PIE_REGISTRY_TOKEN` in `secrets`: they're used for this deploy's pulls only, and not written to any `.env`.

### The workflow

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    concurrency: { group: deploy-myapp, cancel-in-progress: false }
    steps:
      - uses: actions/checkout@v5
      - run: |
          docker build -t myapp:${{ github.sha }} .
          mkdir -p bundle/images && cp -r stack pie.json bundle/
          docker save myapp:${{ github.sha }} | gzip >bundle/images/myapp.tar.gz
      - uses: YOUR-GITHUB-USER/pie-delivery/compose@v2
        with:
          tailscale-oauth-client-id: YOUR-FEDERATED-IDENTITY-CLIENT-ID
          tailscale-audience: YOUR-FEDERATED-IDENTITY-AUDIENCE
          host: myhost.tail1234.ts.net
          app: myapp
          bundle: bundle
          secrets: |
            API_TOKEN=${{ secrets.API_TOKEN }}
```

A fuller version is in [examples/compose-app.yml](examples/compose-app.yml).

| Input | Default | Description |
|---|---|---|
| `tailscale-oauth-client-id` | | Client ID of a Tailscale federated identity or OAuth client |
| `tailscale-audience` | | Federated identity's audience |
| `tailscale-oauth-secret` | | OAuth client secret (OAuth clients only) |
| `tailscale-authkey` | | Auth key, instead of the above |
| `tailscale-tags` | `tag:ci` | Tags the runner advertises |
| `host` | **required** | The host's MagicDNS name or `100.x` IP |
| `user` | `deploy` | SSH user (`install.sh --user`) |
| `ssh-port` | `22` | SSH port |
| `ssh-key` | | Private key, if the host was set up with `--ssh-key`. Empty for Tailscale SSH |
| `known-hosts` | | `known_hosts` lines, with `ssh-key` |
| `app` | **required** | App name: lowercase letters, digits and dashes. It lives in `/opt/apps/<app>` |
| `bundle` | **required** | The bundle directory |
| `release` | the commit SHA | Release name |
| `secrets` | | `KEY=VALUE` lines for the app's `.env`, sent on stdin |
| `connect-attempts` | `10` | SSH connection attempts, 3 seconds apart |

### On the host

```bash
sudo pie-deploy status                 # every app's releases; * marks the live one
sudo pie-deploy rollback myapp         # back to the newest release that isn't live
sudo pie-deploy rollback myapp <sha>   # or to a given one
```

Migrations and the like are the app's business; keep schema changes compatible with the previous release, since a failed deploy rolls back to it.

The `deploy` user can't do anything as root except run `pie-deploy`, but `pie-deploy` runs whatever Compose files it's given, and Docker access amounts to root on the host. Treat anything that can push to a deploying branch as having root there.

## Testing

The integration tests run `scripts/deploy.sh` against a throwaway SSH server in Docker. They use real `ssh` and `rsync`, and don't need a Pi or Tailscale. The host tests run `host/pie-deploy` against the local Docker daemon: real Compose projects, image loading, health checks, rollback, pruning and bad bundles, with a small Go app in a scratch image so nothing is pulled. CI runs both on every push. To run them locally, start Docker and then run:

```bash
bash test/integration/run.sh
sudo bash test/host/run.sh      # needs jq and go too
```

## Releasing this action

Consumers reference a tag. After you push changes:

```bash
git tag -a v2.0.1 -m "v2.0.1"
```

```bash
git tag -f v2
```

```bash
git push origin v2.0.1 v2 --force
```

A new major version gets a new moving tag (`v3`) and leaves the old one where it is. If `host/pie-deploy` changes in a way older workflows can't use, bump its `VERSION` and `HOST_VERSION` in `scripts/compose-deploy.sh` together. Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Notes

- This action only runs on Linux runners, such as `ubuntu-latest`.
- `delete: true` is powerful. Point `target` at a directory used only for this deploy. Use `dry-run: true` the first time.
- For stricter supply-chain hygiene, fork this action or pin it, and `tailscale/github-action`, to a commit SHA.
