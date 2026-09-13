# frozen_string_literal: true

source "https://rubygems.org"

gem "async", "~> 2.37"
gem "async-websocket"
gem "falcon"
gem "base64"
gem "rack"
gem "logger", "~> 1.7"

group :development do
  # Deploys the container [https://kamal-deploy.org]. A deploy tool, not a
  # runtime dependency, so it stays out of the production image. Also supplies
  # dotenv, which config/deploy.yml and bin/check-roster use to read .kamal/env.
  gem "kamal", require: false
end

group :test do
  gem "minitest", "~> 5.0"
  gem "rake"
end
