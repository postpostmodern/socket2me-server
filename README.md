# socket2me

A simple Ruby-based HTTPS-to-local tunnel using a Rack WebSocket server and a Ruby client.

> [!WARNING]
> This is a nacent experiment. There may be security issues. Use at your own risk.

## Server

- Runs on port 5050 behind nginx. See `server/nginx.example.conf`.
- Configure users in `config/server.yml`.

Start (from `server/`):

```bash
puma -p 5050
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
