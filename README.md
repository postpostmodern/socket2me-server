# Socket2Me

A simple Ruby-based HTTPS-to-local tunnel using a Rack WebSocket server and a Ruby client.

> [!WARNING]
> This is a nacent experiment. There may be security issues. Use at your own risk.

## Server

A single [Falcon](https://github.com/socketry/falcon) reactor process in a
container, deployed with [Kamal](https://kamal-deploy.org) behind the shared
kamal-proxy, which terminates TLS with one Let's Encrypt cert per user
subdomain. There is no nginx and no certbot. See `docs/kamal-deploy.md`.

- Usernames live in `config/users.yml` (committed, opaque handles — they are
  public via Certificate Transparency); tokens arrive as the `S2M_USERS` secret.
  The app refuses to serve if the two disagree (the deploy fails its
  healthcheck). Mint a user with `bin/new-user`.
- Routing is by `Host` only. The proxy health-checks `/_s2m/up`.

Deploy:

```bash
bin/check-roster     # roster valid, deploy.yml hosts match, S2M_USERS matches
bin/kamal deploy
```

Local development, without Kamal (tokens from the gitignored `config/server.yml`):

```bash
bundle exec falcon serve --bind http://127.0.0.1:5050 --count 1
```

## Client

The socket2me client can be found at https://github.com/postpostmodern/socket2me

- Configure `config/client.yml` with your username, key, server, and local target.

Run:

```bash
./socket2me
```

## Flow

- nginx terminates TLS and proxies `https://{username}.socket2me.dev/*` to the server.
- Server relays the HTTP request over WebSocket to the client.
- Client forwards to local server and returns the response.

## Notes

- Auth via shared token on WebSocket `ready` message.
- 503 if no client connected. 504 on client timeout.
- Max request body: 10MB (override `S2M_MAX_BODY`).
