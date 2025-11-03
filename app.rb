# frozen_string_literal: true

require "rack"
require "json"
require "async"
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
      @write_locks = Hash.new { |h, k| h[k] = Mutex.new }
      @max_body_bytes = (ENV["S2M_MAX_BODY"] || (10 * 1024 * 1024)).to_i
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
        begin
          # Expect initial ready/auth message
          raw = connection.read

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

          conn_info = { connection: connection }
          @registry.register(username, conn_info)
          connection.write(JSON.dump(type: "ready", ok: true))
          connection.flush
          logger.info "user=#{username} registered and ready"

          # Main loop: receive responses from client
          while (message = connection.read)
            payload = JSON.parse(message)
            logger.info "received message: #{payload.inspect}"
            case payload["type"]
            when "response"
              @broker.deliver_response(payload["id"], payload)
            when "ping"
              # Respond to keep-alive ping
              logger.info "ponging the ping"
              begin
                lock = @write_locks[username]
                lock.synchronize do
                  connection.write(JSON.dump(type: "pong", id: payload["id"]))
                  connection.flush
                end
                logger.info "pong sent successfully"
              rescue => e
                logger.error "failed to send pong: #{e.class}: #{e.message}"
                raise
              end
            when "pong"
              # ignore for now
            else
              # ignore unknown
            end
          end
        rescue => e
          logger.error "websocket error: #{e.class}: #{e.message}"
        ensure
          @registry.deregister(username, { connection: connection }) if username
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
      body = req.body.read.to_s
      if body.bytesize > @max_body_bytes
        return [413, { "content-type" => "application/json" }, [JSON.dump(error: "Request entity too large")]]
      end
      req.body.rewind
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
      lock = @write_locks[username]
      conn_info = @registry.get(username)
      return unless conn_info

      lock.synchronize do
        conn_info[:connection].write(data)
        conn_info[:connection].flush
      end
    end
  end
end


