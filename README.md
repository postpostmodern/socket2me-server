# Socket2Me

A simple Ruby-based HTTPS-to-local tunnel using a Rack WebSocket server and a Ruby client.

> [!WARNING]
> This is a nacent experiment. There may be security issues. Use at your own risk.

## Server

- Runs as a single [Falcon](https://github.com/socketry/falcon) reactor process on
  `127.0.0.1:5050` behind nginx. See `nginx/nginx.example.conf` and
  `deploy/socket2me.service`.
- Configure users in `config/server.yml`.

Start (from the repo root):

```bash
bundle exec falcon serve --bind http://127.0.0.1:5050 --count 1
```

One Falcon process handles all connections; there is no port pool. The server
binds to loopback only — all public traffic must arrive via nginx (which
terminates TLS and sets the trusted `X-S2M-Username` header). Keep the firewall
denying the app port from the internet.

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
