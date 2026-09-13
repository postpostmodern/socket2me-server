# Deploying with Kamal

The server runs as one Falcon container behind the **shared kamal-proxy** on the
same Linode as `exquisiteapp` and `apple_music_mcp`. There is no nginx and no
certbot: kamal-proxy terminates TLS with one Let's Encrypt cert per user
subdomain and renews them itself.

## How users, hosts, and certs fit together

```
config/users.yml  ──ERB──▶  proxy.hosts in config/deploy.yml  ──▶  one cert + one route per user
      │
      └── Auth.verify_roster! at boot: S2M_USERS keys must equal this list exactly
```

- **`config/users.yml`** (committed) is the single source of truth for which
  subdomains exist. Usernames are **opaque handles**: every per-host cert is
  published to Certificate Transparency, so this list is publicly enumerable and
  real names would publish the team roster.
- **`S2M_USERS`** (1Password → Kamal secret) is `user:token,user:token`. The app
  refuses to serve unless its keys equal the roster: `App.new` raises, the Falcon
  worker never comes up, kamal-proxy's healthcheck never sees a 200, and the
  deploy fails — the message is in `bin/kamal logs`. A user in one place but not
  the other is a deploy bug, not a runtime surprise.
- **kamal-proxy** only routes — and only requests certificates for — the listed
  hosts. An unlisted subdomain gets a proxy 404 and never touches Let's Encrypt.

## One-time setup

1. `cp .kamal/env.example .kamal/env` and fill in `DEPLOY_HOST`, `DEPLOY_DOMAIN`
   (`socket2me.dev`), `REGISTRY_USER`, `OP_ACCOUNT`, `OP_ITEM`.
2. Create the 1Password item with `KAMAL_REGISTRY_PASSWORD` (GitHub PAT,
   `write:packages`) and `S2M_USERS`.
3. DNS at Cloudflare: wildcard `A` `*.socket2me.dev → DEPLOY_HOST`, **DNS-only /
   grey-cloud**. If the host has a public AAAA, add the matching wildcard AAAA
   or Let's Encrypt validates against the wrong server. Cloudflare's proxy must
   stay off — with it on, Cloudflare terminates TLS and sees every token.
4. `bin/kamal setup` for the first deploy (subsequent ones are `bin/kamal deploy`).

## Adding a user

```
bin/new-user          # prints the users.yml line, the S2M_USERS fragment, and the client creds
```

1. Add the username to `config/users.yml`; commit.
2. Append `user:token` to `S2M_USERS` in 1Password.
3. `bin/check-roster` — confirms the roster is valid, renders `deploy.yml` and
   checks the hosts match, and (under `op run`) that `S2M_USERS` matches.
4. `bin/kamal deploy`. kamal-proxy issues the new subdomain's cert on its first
   TLS handshake, so the user's very first connection may stall once; the
   client's reconnect backoff absorbs it.
5. Give the user their username and token for the client's `config/client.yml`.

Removing a user is the reverse; remove the token from `S2M_USERS` in the same
change or the boot check fails.

## First deploy — prove multi-host TLS

Deploy with **at least two** users in the roster and open both subdomains. The
Kamal and kamal-proxy source both show multiple `--host` flags plus `--tls`
being emitted and accepted, but the server-side autocert wiring was not read;
two hosts each getting a valid cert is the proof.

## Rate limits

Let's Encrypt allows 50 new certs per registered domain per 7 days (refilling
one per ~202 minutes) and 5 per exact hostname per 7 days; **renewals via ARI
are exempt**, so steady state costs nothing. The only realistic way to get
burned is the per-hostname limit: kamal-proxy persists certs in its own
storage, so **never wipe that volume** and never run `kamal proxy reboot` on
this host — it recreates the shared proxy and drops every app's routing table.

## Cutover from the nginx box

1. Merge all three PRs; do not deploy anything before that.
2. `bin/kamal setup` on the Linode with the roster populated.
3. Point the wildcard A record at the new host (it is the same record — only the
   IP changes). TTL down beforehand if you want a quick flip.
4. Clients connect on their own; verify a real tunneled request per user.
5. Decommission the old box **and delete its Cloudflare API token** (the
   certbot DNS-01 credential). The new host needs no Cloudflare token at all.

## Operations

- `bin/kamal logs` — tail the app. `bin/kamal shell` — a shell in the container.
- Nothing is stateful; a container restart drops connected clients, which
  reconnect with backoff.
- Consider a Honeybadger uptime check on `https://<user>.socket2me.dev/up`
  (Kamal's default health path; the server answers it itself, so `/up` is
  reserved and never forwarded to a tunnel)
  — the team depends on this.
