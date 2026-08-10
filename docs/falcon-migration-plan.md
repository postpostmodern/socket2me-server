# Falcon migration plan

Status: **proposed** (branch `falcon-migration`, off `security-hardening`)

## Why

`async-websocket` is designed for **Falcon**, a fiber/reactor server. We currently run it
under **Puma**, which is thread-per-request. Straddling the two models is the root cause of
the server's fragility:

1. **Thread-blocking wait.** HTTP ingress calls `RequestBroker#await_response`, which does a
   `Monitor` condition-variable wait that **blocks a Puma worker thread** for up to 30s
   (`app.rb`). With `PUMA_THREADS=5`, five slow/absent-client requests to one subdomain
   saturate that instance — a trivial denial-of-service, made worse because nginx
   `hash $host consistent` pins each user to a single backend.
2. **Cross-thread socket writes.** `write_to_client` writes into a WebSocket connection from
   the ingress **thread**, while the WS read loop reads the same connection object from a
   different thread/fiber (`app.rb`). The `@write_locks` mutex only serializes writers against
   each other; it does not protect against the concurrent reader, and `protocol-websocket`'s
   frame buffers are not documented thread-safe. Under load, frames can interleave/corrupt.
   The recent commits ("trying lock for pongs", "flushing after writing") were symptoms of
   fighting this.

Under Falcon, every request and the WebSocket both run as **fibers on one reactor thread**
(per worker process). Fibers are cooperatively scheduled, so we can:

- replace the thread-blocking `Monitor` wait with a fiber suspend (`Async::Promise`), making
  in-flight requests cheap and killing the thread-exhaustion DoS; and
- funnel all writes to a connection through a single writer fiber, eliminating the write race
  and the mutex entirely.

## Target architecture

```
             ┌──────────────── one Falcon worker process (single reactor thread) ────────────────┐
 nginx ──────┤  /ws  fiber:  read loop  ── enqueue ──▶ outbound Async::Queue ──▶ writer fiber ──▶ socket
 (TLS,       │                                   ▲                                                 │
  X-S2M-     │  ingress fiber: build request ── enqueue ─┘   then  await promise (with_timeout)    │
  Username)  │                                                          ▲                          │
             │  RequestBroker: id ▶ Async::Promise ──── deliver_response resolves it ──────────────┘
             └───────────────────────────────────────────────────────────────────────────────────┘
```

Key: reads happen in the `/ws` read-loop fiber; **all** writes to a connection (ready, pong,
relayed requests) go through that connection's outbound queue, drained by one writer fiber.
Request/response correlation is a per-id `Async::Promise`.

### Scaling decision (needs Jason's call — see Open questions)

The current 4-process pool (ports 5050–5053) + `hash $host consistent` exists because Puma
threads are scarce. **Falcon does not have that limit** — one reactor handles thousands of
concurrent connections. So there are two viable shapes:

- **Option A — single process (recommended).** One Falcon process on `127.0.0.1:5050`. nginx
  proxies to a single upstream; drop the pool and consistent hashing. Simplest, and the
  in-memory `ConnectionRegistry`/`RequestBroker` are trivially correct because there's one
  process. Right choice for single-VPS hobby scale.
- **Option B — keep the pool.** Run N Falcon processes (`--count 1` each) on N ports, keep
  nginx `hash $host consistent`. Only worth it for multi-core throughput. In-memory state
  stays per-process, so the per-user pinning invariant must hold (as today). Going beyond
  this — true horizontal scale — would require shared state (e.g. Redis pub/sub for the
  registry + response routing), which is out of scope here.

The rest of this plan assumes **Option A** and notes where B differs.

## Concurrency invariant (important)

Dropping the locks is only safe if each worker's reactor is **single-threaded**. Falcon's
default forked container gives exactly that (one reactor thread per forked process). **Do not
use `--threaded` or `--hybrid`**, which put multiple reactor threads in one process and would
reintroduce data races on `@entries`/`@by_user`. We keep a lightweight `Mutex` around the
registry/broker hash mutations anyway (uncontended under the forked model) so a future
config change can't silently corrupt state.

## Code changes (file by file)

### `Gemfile` / `Gemfile.lock`
- Add `gem "falcon"`. Remove `gem "puma"`.
- Consider bumping `async` to `>= 2.37` to get `Async::Promise#wait(timeout)` directly;
  otherwise wrap `promise.wait` in `Async::Task.current.with_timeout` (works on 2.34).
- `async-http`, `protocol-rack`, etc. are already transitive deps.

### `lib/request_broker.rb` — replace Monitor with Async::Promise
```ruby
require "async/promise"

module Socket2Me
  class RequestBroker
    def initialize
      @lock = Mutex.new           # guards @entries; uncontended under forked model
      @entries = {}               # id => Async::Promise
    end

    def register(id)
      @lock.synchronize { @entries[id] = Async::Promise.new }
    end

    def await_response(id, timeout_seconds)
      promise = @lock.synchronize { @entries[id] }
      return nil unless promise

      Async::Task.current.with_timeout(timeout_seconds) { promise.wait }
    rescue Async::TimeoutError
      nil
    ensure
      @lock.synchronize { @entries.delete(id) }
    end

    def deliver_response(id, payload)
      promise = @lock.synchronize { @entries[id] }
      return false unless promise

      promise.resolve(payload)
      true
    end
  end
end
```
No more `deadline`/`CLOCK_MONOTONIC` bookkeeping; the reactor handles the timeout. The wait
suspends a fiber instead of blocking a thread, so 10k concurrent in-flight requests cost
~nothing.

### `app.rb` — per-connection writer fiber, drop `@write_locks`
- In `initialize`, remove `@write_locks`.
- In `handle_websocket`, after upgrade, create an outbound queue and writer fiber:
  ```ruby
  Async::WebSocket::Adapters::Rack.open(env) do |connection|
    outbound = Async::Queue.new
    writer = Async::Task.current.async do
      while (data = outbound.dequeue)
        connection.write(data)
        connection.flush
      end
    end
    # ...auth (unchanged, still bounded by @auth_timeout via with_timeout)...
    conn_info = { connection: connection, outbound: outbound }
    @registry.register(username, conn_info)
    outbound.enqueue(JSON.dump(type: "ready", ok: true))
    # main read loop: pong replies also go via outbound.enqueue(...)
  ensure
    writer&.stop
    @registry.deregister(username, conn_info) if username
  end
  ```
- Rewrite `write_to_client` to enqueue instead of writing directly:
  ```ruby
  def write_to_client(username, data)
    conn_info = @registry.get(username)
    return unless conn_info
    conn_info[:outbound].enqueue(data)
  end
  ```
- Everything that previously did `connection.write(...); connection.flush` inside the WS
  handler (ready ok, pong) now enqueues to `outbound`. The read loop stays in its own fiber.
- The `Async::Task.current` fallback branch added for the auth timeout in the hardening pass
  becomes always-true under Falcon; leave it — harmless.

### `lib/connection_registry.rb`
- No API change. Values now carry `:outbound` alongside `:connection`. Keep the `Mutex`.

### `config/puma.rb`, `bin/puma`, `bin/pumactl`
- Remove. Replace with Falcon config (below).

### `config/falcon.rb` (new) — Option A
```ruby
#!/usr/bin/env -S falcon-host
# frozen_string_literal: true
require "falcon/environment/rack"

hostname = File.basename(__dir__)

service hostname do
  include Falcon::Environment::Rack
  count Integer(ENV.fetch("WEB_CONCURRENCY", 1))     # 1 = single reactor (Option A)
  port { Integer(ENV.fetch("PORT", 5050)) }
  endpoint do
    # Loopback + HTTP/1.1: nginx terminates TLS; WS upgrade needs HTTP/1.1.
    Async::HTTP::Endpoint
      .parse("http://127.0.0.1:#{port}")
      .with(protocol: Async::HTTP::Protocol::HTTP11)
  end
end
```
For quick runs without the host file: `falcon serve --bind http://127.0.0.1:5050 --count 1`.
(Plain `falcon serve` defaults to HTTPS with a self-signed localhost cert — we must pass
`http://` and bind loopback.) **Loopback bind is preserved** — same guarantee as the Puma
change in the hardening pass.

### `nginx/nginx.example.conf`
- **Option A:** replace the `upstream` block with a single `server 127.0.0.1:5050;` and drop
  `hash $host consistent`. Keep `client_max_body_size`, the WS upgrade headers, and the
  `X-S2M-Username` trust comment from the hardening pass.
- **Option B:** unchanged (keep the pool + hashing; run 4 Falcon processes on 5050–5053).

### `README.md`
- Update the "Server" section: `bundle exec falcon serve --bind http://127.0.0.1:5050`
  (or `falcon host config/falcon.rb`), and describe Option A vs B.

## Testing strategy

The repo has **no tests today**. Add a minimal Minitest suite; the async pieces are testable
in-process with `Sync {}`.

1. `test/request_broker_test.rb` — round trip: `register`, resolve from another fiber, assert
   `await_response` returns the payload; and timeout: no `deliver_response` → returns `nil`
   within the budget. Run inside `Sync { ... }`.
2. `test/auth_test.rb` — port the manual checks already run in the hardening pass (valid /
   wrong / unknown-user-no-token / known-user-nil / known-user-empty).
3. `test/allowed_paths_test.rb` — (client repo) already covered manually; formalize.
4. Optional integration smoke: boot the app with `falcon serve` on a random loopback port in
   a subprocess, connect a real `async-websocket` client that echoes a canned response, fire
   an HTTP request through ingress, assert the relayed response. High value but more setup;
   do it after the units are green.

Gate: `ruby -c` on all changed files + the Minitest suite before merge.

## Deployment / cutover

1. On the Linode, install the new bundle (adds `falcon`, drops `puma`).
2. Swap the process manager unit(s):
   - **overmind/Procfile:** `web: bundle exec falcon serve --bind http://127.0.0.1:5050 --count 1`
   - **systemd:** `ExecStart=/usr/bin/env bundle exec falcon serve --bind http://127.0.0.1:5050 --count 1`, run as a non-root service user, `WorkingDirectory` at the repo root.
3. Apply the nginx change (Option A: single upstream, no hashing) and `nginx -t && reload`.
4. Restart, connect the client, verify a real tunneled request end to end.
5. Confirm `ss -ltnp` shows the listener on `127.0.0.1` only, and ufw still default-deny.

## Rollback

- Branch-isolated. Keep `config/puma.rb` + `bin/puma*` in git history; reverting the Gemfile
  and switching the process-manager command back to `puma -p 5050` restores the old server
  with no data migration (state is in-memory only).
- Recommend validating on a staging port (e.g. 5060) alongside the running Puma before cutover.

## Risks

- **Lower than it looks:** Falcon is `async-websocket`'s native target, so the adapter path is
  the well-trodden one; we're removing an impedance mismatch, not adding one.
- **HTTP/1.1 required** for the WS upgrade — the endpoint must pin `HTTP11` (done above). A
  stray HTTP/2 endpoint would break upgrades.
- **Don't use threaded/hybrid containers** (see concurrency invariant).
- **`falcon serve` TLS default** — must pass `http://` + loopback, or it serves HTTPS with a
  self-signed cert and nginx's proxy_pass to `http://` fails.
- **Behavior parity:** the ingress response path, header normalization, body-size checks, and
  auth deadline all carry over unchanged; only the wait + write mechanics change.

## Open questions for Jason

1. **Option A (single Falcon process, drop nginx pool + hashing) or B (keep the 4-port
   pool)?** Recommend A for a single VPS unless you specifically want multi-core throughput.
2. **Process manager on the Linode — overmind/Procfile or systemd?** Determines which unit
   files this branch ships.
3. **Bump `async` to `>= 2.37`** (for `Async::Promise#wait(timeout)`) or stay on 2.34 and wrap
   with `with_timeout`? Either works; bumping is slightly cleaner.

## Acceptance criteria

- No thread-blocking waits; `await_response` suspends a fiber (thread-exhaustion DoS gone).
- All connection writes serialized through one writer fiber per connection; `@write_locks`
  removed; no cross-thread socket access.
- Puma fully removed; server runs under Falcon bound to loopback, HTTP/1.1.
- Minitest suite (broker + auth at minimum) green; `ruby -c` clean.
- End-to-end tunneled request verified on the VPS after cutover.
