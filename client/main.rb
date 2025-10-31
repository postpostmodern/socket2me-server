# frozen_string_literal: true

require "yaml"
require "json"
require "base64"
require "faraday"
require "async"
require "async/http/endpoint"
require "async/websocket/client"

require_relative "./message_protocol"
require_relative "./allowed_paths"

module Socket2Me
  class Client
    def initialize(config_path = File.expand_path("../config/client.yml", __dir__))
      @config = YAML.load_file(config_path)
      @username = @config.fetch("username")
      @token = @config.fetch("key")
      @server = @config.fetch("server")
      @local = @config.fetch("local")
      @allowed = AllowedPaths.new(@config["allowed_paths"] || [])
    end

    def run
      stop = false
      Signal.trap("INT") { stop = true }

      Async do |task|
        backoff = 1
        until stop
          url = websocket_url(@server)
          endpoint = Async::HTTP::Endpoint.parse(url)
          begin
            Async::WebSocket::Client.connect(endpoint) do |connection|
              backoff = 1
              send_ready(connection)

              # Heartbeat (start after ready)
              heartbeat = task.async do
                loop do
                  connection.write(JSON.dump(type: "ping", at: Time.now.to_i))
                  task.sleep 15
                end
              end

              while (raw = connection.read)
                msg = JSON.parse(raw)
                case msg["type"]
                when "request"
                  handle_request(connection, msg)
                when "ping"
                  puts "Received ping: #{msg}"
                  connection.write(JSON.dump(type: "pong", id: msg["id"]))
                end
              end
            ensure
              heartbeat&.stop
            end
          rescue StandardError => e
            puts "Error: #{e.message}"
            puts "Backing off for #{backoff} seconds"
            task.sleep(backoff)
            backoff = [backoff * 2, 30].min
          end
        end
      end
    end

    private

    def websocket_url(server)
      host = server.to_s
      return host if host.start_with?("ws://", "wss://")

      # If a port is present (e.g., localhost:5050) assume plain WS; otherwise WSS
      scheme = host.include?(":") ? "ws" : "wss"
      "#{scheme}://#{host}/ws"
    end

    def send_ready(connection)
      puts "Connecting to #{@server} as #{@username}"
      connection.write(JSON.dump({
        type: "ready",
        username: @username,
        token: @token
      }))
    end

    def handle_request(connection, msg)
      path = msg["path"]
      unless @allowed.allow?(path)
        puts "Path not allowed: #{path}"
        connection.write(JSON.dump(type: "response", id: msg["id"], status: 403, headers: {"Content-Type"=>"application/json"}, body_b64: Base64.strict_encode64(JSON.dump(error: "path not allowed"))))
        return
      end

      puts "Handling request: #{path}"
      url = "#{@local.fetch("protocol")}://#{@local.fetch("host")}:#{@local.fetch("port")}#{path}"
      method = msg["method"].to_s.downcase
      body = Base64.decode64(msg["body_b64"].to_s)
      headers = (msg["headers"] || {})

      response = Faraday.run_request(method.to_sym, url, body.empty? ? nil : body, headers)
      resp_body = response.body.to_s
      payload = {
        type: "response",
        id: msg["id"],
        status: response.status,
        headers: response.headers,
        body_b64: Base64.strict_encode64(resp_body)
      }
      connection.write(JSON.dump(payload))
    rescue StandardError => e
      err = { type: "response", id: msg["id"], status: 502, headers: {"Content-Type"=>"application/json"}, body_b64: Base64.strict_encode64(JSON.dump(error: e.message)) }
      connection.write(JSON.dump(err))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Socket2Me::Client.new.run
end


