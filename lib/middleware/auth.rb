# frozen_string_literal: true

require "yaml"
require "openssl"
require "digest"

module Socket2Me
  module Auth
    module_function

    def load_users(config_path = File.expand_path("../../config/server.yml", __dir__))
      data = YAML.load_file(config_path)
      @users = data["users"] || {}
    end

    def users
      @users ||= load_users
    end

    def valid_user?(username)
      users.key?(username)
    end

    def verify_token(username, token)
      expected = users[username]
      # Reject unknown users and missing/empty tokens outright. Without this a
      # request for an unconfigured username with no token would compare
      # nil == nil and authenticate successfully.
      return false if expected.nil?
      return false if token.nil? || token.to_s.empty?

      secure_equal?(expected.to_s, token.to_s)
    end

    # Constant-time comparison that does not leak length. Both sides are hashed
    # to a fixed 32 bytes first so fixed_length_secure_compare never raises on
    # differing lengths (which would itself be a timing/length side channel).
    def secure_equal?(a, b)
      OpenSSL.fixed_length_secure_compare(
        Digest::SHA256.digest(a),
        Digest::SHA256.digest(b),
      )
    end
  end
end


