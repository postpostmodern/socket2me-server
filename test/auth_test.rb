# frozen_string_literal: true

require "test_helper"
require "middleware/auth"

class AuthTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/server.yml", __dir__)

  def setup
    @saved_env = ENV.delete("S2M_USERS")
    Socket2Me::Auth.reset!
    Socket2Me::Auth.load_users(FIXTURE)
  end

  def teardown
    ENV["S2M_USERS"] = @saved_env if @saved_env
    ENV.delete("S2M_USERS") unless @saved_env
    Socket2Me::Auth.reset!
  end

  def test_valid_credentials
    assert Socket2Me::Auth.verify_token("jason", "supersecretkey")
  end

  def test_wrong_token
    refute Socket2Me::Auth.verify_token("jason", "nope")
  end

  # The bug this closes: an unconfigured username with no token used to compare
  # nil == nil and authenticate.
  def test_unknown_user_with_nil_token_is_rejected
    refute Socket2Me::Auth.verify_token("ghost", nil)
  end

  def test_unknown_user_with_token_is_rejected
    refute Socket2Me::Auth.verify_token("ghost", "anything")
  end

  def test_known_user_with_nil_token_is_rejected
    refute Socket2Me::Auth.verify_token("jason", nil)
  end

  def test_known_user_with_empty_token_is_rejected
    refute Socket2Me::Auth.verify_token("jason", "")
  end

  # --- S2M_USERS env source (how Kamal supplies tokens) ---

  def test_env_takes_precedence_over_file
    ENV["S2M_USERS"] = "k7x2pq9wz3ma:tok1,m4q9zt2rv8nb:tok2"
    Socket2Me::Auth.reset!
    Socket2Me::Auth.load_users(FIXTURE)

    assert Socket2Me::Auth.verify_token("k7x2pq9wz3ma", "tok1")
    assert Socket2Me::Auth.verify_token("m4q9zt2rv8nb", "tok2")
    refute Socket2Me::Auth.verify_token("jason", "supersecretkey"), "file user must not leak in when env is set"
  end

  def test_env_tolerates_whitespace_and_trailing_comma
    ENV["S2M_USERS"] = " k7x2pq9wz3ma:tok1 , m4q9zt2rv8nb:tok2 ,"
    Socket2Me::Auth.reset!
    assert_equal %w[k7x2pq9wz3ma m4q9zt2rv8nb], Socket2Me::Auth.users.keys
  end

  def test_env_token_may_contain_colons_after_the_first
    ENV["S2M_USERS"] = "k7x2pq9wz3ma:to:ken"
    Socket2Me::Auth.reset!
    assert Socket2Me::Auth.verify_token("k7x2pq9wz3ma", "to:ken")
  end

  def test_env_rejects_malformed_entry
    ENV["S2M_USERS"] = "k7x2pq9wz3ma"
    Socket2Me::Auth.reset!
    assert_raises(ArgumentError) { Socket2Me::Auth.users }
  end

  def test_env_rejects_duplicate_user
    ENV["S2M_USERS"] = "k7x2pq9wz3ma:a,k7x2pq9wz3ma:b"
    Socket2Me::Auth.reset!
    assert_raises(ArgumentError) { Socket2Me::Auth.users }
  end

  # --- roster drift (the boot-time check) ---

  def test_verify_roster_passes_when_sets_match
    ENV["S2M_USERS"] = "m4q9zt2rv8nb:b,k7x2pq9wz3ma:a"
    Socket2Me::Auth.reset!
    assert Socket2Me::Auth.verify_roster!(%w[k7x2pq9wz3ma m4q9zt2rv8nb])
  end

  def test_verify_roster_fails_on_missing_token
    ENV["S2M_USERS"] = "k7x2pq9wz3ma:a"
    Socket2Me::Auth.reset!
    err = assert_raises(ArgumentError) { Socket2Me::Auth.verify_roster!(%w[k7x2pq9wz3ma m4q9zt2rv8nb]) }
    assert_match(/without tokens: m4q9zt2rv8nb/, err.message)
  end

  def test_verify_roster_fails_on_extra_token
    ENV["S2M_USERS"] = "k7x2pq9wz3ma:a,zz9y8x7w6v5u:c"
    Socket2Me::Auth.reset!
    err = assert_raises(ArgumentError) { Socket2Me::Auth.verify_roster!(%w[k7x2pq9wz3ma]) }
    assert_match(/not in roster: zz9y8x7w6v5u/, err.message)
  end
end
