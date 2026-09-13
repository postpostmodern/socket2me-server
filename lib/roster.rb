# frozen_string_literal: true

require "yaml"

module Socket2Me
  # The committed list of tunnel usernames — the single source of truth for
  # which subdomains exist. config/deploy.yml derives kamal-proxy's host list
  # from it (one Let's Encrypt cert per user), and Auth.verify_roster! insists
  # the deployed token set matches it exactly, so a user present in one place
  # but not the other fails the deploy instead of producing a mystery 404.
  #
  # Usernames are opaque handles, not real names: every per-host certificate is
  # published to Certificate Transparency logs, so whatever appears here is
  # publicly enumerable. Mint them with bin/new-user.
  module Roster
    NAME = /\A[a-z0-9]{8,32}\z/
    DEFAULT_PATH = File.expand_path("../config/users.yml", __dir__)

    module_function

    def path
      ENV.fetch("S2M_ROSTER_PATH", DEFAULT_PATH)
    end

    def names(file = path)
      data = YAML.load_file(file) || {}
      list = Array(data["users"]).map(&:to_s)

      list.each do |name|
        unless name.match?(NAME)
          raise ArgumentError, "invalid username #{name.inspect} in #{file}: must match #{NAME.inspect}"
        end
      end

      dupes = list.tally.select { |_, count| count > 1 }.keys
      raise ArgumentError, "duplicate usernames in #{file}: #{dupes.join(", ")}" unless dupes.empty?

      list
    end

    def hosts(domain, file = path)
      names(file).map { |name| "#{name}.#{domain}" }
    end
  end
end
