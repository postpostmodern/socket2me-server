# frozen_string_literal: true

require "yaml"

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
      users[username] == token
    end
  end
end


