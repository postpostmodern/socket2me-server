# frozen_string_literal: true

require "test_helper"
require "middleware/auth"

class AuthTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/server.yml", __dir__)

  def setup
    Socket2Me::Auth.load_users(FIXTURE)
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
end
