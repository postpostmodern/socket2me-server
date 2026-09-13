# frozen_string_literal: true

require "yaml"
require "openssl"
require "digest"

module Socket2Me
  module Auth
    module_function

    # Token source, in precedence order:
    #   1. S2M_USERS env — "user:token,user:token" — how Kamal injects the secret.
    #   2. config/server.yml — local development only.
    def load_users(config_path = File.expand_path("../../config/server.yml", __dir__))
      env = ENV["S2M_USERS"]
      @users =
        if env && !env.strip.empty?
          parse_env(env)
        else
          data = YAML.load_file(config_path)
          (data["users"] || {}).transform_keys(&:to_s).transform_values(&:to_s)
        end
    end

    def parse_env(str)
      str.split(",").each_with_object({}) do |pair, users|
        pair = pair.strip
        next if pair.empty?

        user, token = pair.split(":", 2)
        if user.nil? || token.nil? || user.empty? || token.empty?
          raise ArgumentError, "S2M_USERS entry #{pair.inspect} must be user:token"
        end
        raise ArgumentError, "S2M_USERS lists user #{user.inspect} more than once" if users.key?(user)

        users[user] = token
      end
    end

    def users
      @users ||= load_users
    end

    def reset!
      @users = nil
    end

    def valid_user?(username)
      users.key?(username)
    end

    # Fail fast on roster drift: the deployed token set must equal the committed
    # roster exactly. A roster user with no token would be refused at login; a
    # token for a user not in the roster is a credential for a subdomain that
    # kamal-proxy has no cert or route for. Both are deploy bugs, so raise at
    # load rather than run half-configured: the Falcon worker never serves and
    # the deploy fails its healthcheck.
    def verify_roster!(names)
      have = users.keys.sort
      want = Array(names).map(&:to_s).sort
      return true if have == want

      problems = []
      missing = want - have
      extra = have - want
      problems << "roster users without tokens: #{missing.join(", ")}" unless missing.empty?
      problems << "tokens for users not in roster: #{extra.join(", ")}" unless extra.empty?
      raise ArgumentError, "S2M_USERS does not match config/users.yml — #{problems.join("; ")}"
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
