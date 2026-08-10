# frozen_string_literal: true

require "rack"
require "json"
require "async"
require "async/queue"
require "async/websocket"
require "async/websocket/adapters/rack"
require "securerandom"
require "base64"
require "logger"

require_relative "./lib/connection_registry"
require_relative "./lib/request_broker"
require_relative "./lib/middleware/auth"

module Socket2Me
  class App
    def initialize
      @registry = ConnectionRegistry.new
      @broker = RequestBroker.new
      @max_body_bytes = (ENV["S2M_MAX_BODY"] || (10 * 1024 * 1024)).to_i
      # How long an upgraded socket has to send a valid `ready`/auth message
      # before we drop it. Bounds slowloris-style pre-auth connection holding.
      @auth_timeout = Integer(ENV.fetch("S2M_AUTH_TIMEOUT", 10))
    end

    def call(env)
      req = Rack::Request.new(env)

      if req.path_info == "/ws"
        return handle_websocket(env)
      end

      handle_http_ingress(req)
    end

    private

    def logger
      return @logger if defined?(@logger)

      log_device =
        if ENV["LOG_FILE"]
          File.open(ENV["LOG_FILE"], "a")
        else
          $stdout
        end
      @logger = Logger.new(log_device)
      @logger.progname = "socket2me"
      @logger.formatter = proc do |severity, datetime, progname, msg|
        "[#{datetime.iso8601}][#{progname}][#{severity}] #{msg}\n"
      end
      @logger
    end

    def handle_websocket(env)
      logger.info "incoming /ws request"
      Async::WebSocket::Adapters::Rack.open(env) do |connection|
        logger.info "websocket upgraded"
        username = nil
        conn_info = nil
        writer = nil
        begin
          # Expect initial ready/auth message, bounded by an auth deadline so an
          # unauthenticated client cannot hold the connection open indefinitely.
          # Pre-auth writes below happen in this single fiber, so they are written
          # directly; concurrent writes only become possible once ingress fibers
          # start relaying requests, at which point everything goes via `outbound`.
          raw = Async::Task.current.with_timeout(@auth_timeout) { connection.read }

          ready = JSON.parse(raw)
          logger.info "received initial message from #{ready.fetch("username")}"
          if ready["type"] != "ready"
            connection.write(JSON.dump(type: "error", message: "expected ready"))
            connection.flush
            logger.warn "unexpected initial message type: #{ready["type"].inspect}"
            next
          end
          username = ready["username"]
          token = ready["token"]
          unless Auth.verify_token(username, token)
            connection.write(JSON.dump(type: "error", message: "unauthorized"))
            connection.flush
            logger.warn "unauthorized for user=#{username.inspect}"
            break
          end

          # A single writer fiber owns every write to this connection. Reads stay
          # in this fiber; ingress fibers and pong replies only enqueue, so frames
          # can never interleave and no write lock is needed.
          outbound = Async::Queue.new
          writer = Async::Task.current.async do
            while (data = outbound.dequeue)
              connection.write(data)
              connection.flush
            end
          end

          conn_info = { connection: connection, outbound: outbound }
          @registry.register(username, conn_info)
          outbound.enqueue(JSON.dump(type: "ready", ok: true))
          logger.info "user=#{username} registered and ready"

          # Main loop: receive responses from client
          while (message = connection.read)
            payload = JSON.parse(message)
            # Don't log full payloads: response messages carry base64 bodies
            # that may contain sensitive data. Log only type/id.
            logger.debug { "received message type=#{payload["type"].inspect} id=#{payload["id"].inspect}" }
            case payload["type"]
            when "response"
              @broker.deliver_response(payload["id"], payload)
            when "ping"
              # Respond to keep-alive ping
              outbound.enqueue(JSON.dump(type: "pong", id: payload["id"]))
            when "pong"
              # ignore for now
            else
              # ignore unknown
            end
          end
        rescue => e
          logger.error "websocket error: #{e.class}: #{e.message}"
        ensure
          @registry.deregister(username, conn_info) if username && conn_info
          writer&.stop
          logger.info "websocket closed for user=#{username.inspect}"
        end
      end
    rescue Async::WebSocket::ProtocolError
      logger.warn "protocol error: not a websocket upgrade"
      [426, { "content-type" => "application/json" }, [JSON.dump(error: "upgrade required")] ]
    end

    def handle_http_ingress(req)
      username = req.get_header("HTTP_X_S2M_USERNAME") || extract_username_from_host(req.host)

      conn_info = username && @registry.get(username)
      unless conn_info
        return [503, { "content-type" => "application/json" }, [JSON.dump(error: "No active socket2me client for user")] ]
      end

      id = SecureRandom.uuid

      # Reject oversized bodies by their declared length *before* buffering the
      # whole thing into memory. nginx's client_max_body_size is the first line
      # of defense; this guards the app if that limit is raised or absent.
      declared = req.content_length
      if declared && declared.to_i > @max_body_bytes
        return [413, { "content-type" => "application/json" }, [JSON.dump(error: "Request entity too large")]]
      end

      # Under Rack 3 / protocol-rack (Falcon), rack.input is nil when the request
      # has no body, so guard the read/rewind.
      body = (req.body&.read).to_s
      if body.bytesize > @max_body_bytes
        return [413, { "content-type" => "application/json" }, [JSON.dump(error: "Request entity too large")]]
      end
      req.body&.rewind
      payload = {
        type: "request",
        id: id,
        username: username,
        method: req.request_method,
        path: req.fullpath,
        headers: filtered_request_headers(req.env),
        http_version: req.get_header("SERVER_PROTOCOL"),
        body_b64: Base64.strict_encode64(body)
      }

      @broker.register(id)
      write_to_client(username, JSON.dump(payload))

      resp = @broker.await_response(id, 30)
      return [504, { "content-type" => "application/json" }, [JSON.dump(error: "Upstream client timeout")]] unless resp

      status = Integer(resp["status"] || 502) rescue 502
      headers = normalize_response_headers(resp["headers"]) || {}
      body_bytes = begin
        Base64.decode64(resp["body_b64"].to_s)
      rescue
        ""
      end
      [status, headers, [body_bytes]]
    end

    def extract_username_from_host(host)
      # Expecting {username}.socket2me.dev
      parts = host.to_s.split(".")
      parts.first if parts.length >= 3
    end

    def filtered_request_headers(env)
      headers = {}
      env.each do |k, v|
        next unless k.start_with?("HTTP_")
        # Rack canonical header name
        name = k.sub(/^HTTP_/, "").split("_").map(&:capitalize).join("-")
        headers[name] = v
      end
      # Add content headers if present
      if env["CONTENT_TYPE"]
        headers["Content-Type"] = env["CONTENT_TYPE"]
      end
      if env["CONTENT_LENGTH"]
        headers["Content-Length"] = env["CONTENT_LENGTH"]
      end
      headers
    end

    def normalize_response_headers(h)
      return {} unless h.is_a?(Hash)
      # Ensure values are strings
      h.transform_values { |v| Array(v).join(", ") }
    end

    def write_to_client(username, data)
      conn_info = @registry.get(username)
      return unless conn_info

      # Hand off to the connection's writer fiber; never write the socket directly.
      conn_info[:outbound].enqueue(data)
    end
  end
end


