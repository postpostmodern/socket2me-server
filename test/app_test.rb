# frozen_string_literal: true

require "test_helper"
require "rack/mock"
require_relative "../app"

# Ingress routing and the health endpoint, exercised through Rack directly.
# No WebSocket client is registered, so any request that reaches username
# routing must end in 503 — which is exactly what makes "was this routed by
# Host, or by a header?" observable.
class AppTest < Minitest::Test
  def setup
    @saved_env = ENV.delete("S2M_USERS")
    @app = Socket2Me::App.new
    @rack = Rack::MockRequest.new(@app)
  end

  def teardown
    ENV["S2M_USERS"] = @saved_env if @saved_env
  end

  def test_health_endpoint_answers_without_a_user_host
    res = @rack.get("/_s2m/up", "HTTP_HOST" => "172.17.0.3:5050")
    assert_equal 200, res.status
    assert_equal "ok", res.body
  end

  def test_health_endpoint_ignores_host_entirely
    res = @rack.get("/_s2m/up", "HTTP_HOST" => "k7x2pq9wz3ma.socket2me.dev")
    assert_equal 200, res.status
  end

  def test_unknown_user_host_is_503
    res = @rack.get("/webhooks/x", "HTTP_HOST" => "k7x2pq9wz3ma.socket2me.dev")
    assert_equal 503, res.status
  end

  def test_x_s2m_username_header_is_not_trusted
    # Header names a syntactically valid user but Host does not; if the header
    # were still honored this would attempt to route to it rather than fail on Host.
    res = @rack.get("/webhooks/x",
      "HTTP_HOST" => "not-a-user-host.example",
      "HTTP_X_S2M_USERNAME" => "k7x2pq9wz3ma")
    assert_equal 503, res.status
  end

  def test_extract_username_requires_three_labels
    assert_nil extract("socket2me.dev")
    assert_nil extract("localhost")
  end

  def test_extract_username_strips_port_and_downcases
    assert_equal "k7x2pq9wz3ma", extract("K7X2PQ9WZ3MA.socket2me.dev:443")
  end

  def test_extract_username_rejects_non_opaque_labels
    assert_nil extract("jason.socket2me.dev")
    assert_nil extract("k7x2-pq9wz3ma.socket2me.dev")
    assert_nil extract("_s2m.socket2me.dev")
  end

  def test_boot_verifies_roster_when_s2m_users_is_set
    ENV["S2M_ROSTER_PATH"] = File.expand_path("fixtures/users.yml", __dir__)
    ENV["S2M_USERS"] = "k7x2pq9wz3ma:a" # m4q9zt2rv8nb has no token
    Socket2Me::Auth.reset!
    err = assert_raises(ArgumentError) { Socket2Me::App.new }
    assert_match(/without tokens: m4q9zt2rv8nb/, err.message)
  ensure
    ENV.delete("S2M_ROSTER_PATH")
    ENV.delete("S2M_USERS")
    Socket2Me::Auth.reset!
  end

  private

  def extract(host)
    @app.send(:extract_username_from_host, host)
  end
end
