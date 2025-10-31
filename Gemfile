# frozen_string_literal: true

source "https://rubygems.org"

# Shared gems (used by both client and server)
gem "async", "~> 2.34"
gem "async-websocket"
gem "oj"
gem "base64"

# Server-only gems
group :server do
  gem "rack"
  gem "puma", "~> 7.1"
end

# Client-only gems
group :client do
  gem "faraday"
  gem "faraday-multipart"
end
