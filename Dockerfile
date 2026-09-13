# syntax=docker/dockerfile:1
# check=error=true

# Production image, deployed with Kamal. Build and run by hand with:
#   docker build -t socket2me .
#   docker run -d -p 80:80 -e S2M_USERS=user:token --name socket2me socket2me

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /app

# jemalloc: glibc's allocator fragments under long-running Ruby processes and
# this one runs for weeks between deploys; preloading meaningfully lowers
# steady-state RSS.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RACK_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to keep native-extension toolchains out of the final image
FROM base AS build

# io-event and the openssl gem compile native extensions; libssl-dev is for the
# latter and libyaml-dev for psych.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libssl-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY . .

# Final stage for app image
FROM base

# ghcr.io reads this label on push: it surfaces the package on the repo page and
# lets package permissions inherit from the repo rather than being managed apart.
LABEL org.opencontainers.image.source="https://github.com/postpostmodern/socket2me-server"

# Run as a non-root user that owns only the runtime files
RUN groupadd --system --gid 1000 app && \
    useradd app --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

COPY --chown=app:app --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=app:app --from=build /app /app

# One reactor process on port 80 — Kamal's default app_port, so deploy.yml needs
# no override, and the same port the other apps on this host use (they bind it
# as uid 1000 too). 0.0.0.0 here is the container's own network namespace: the
# port is never published on the host and only kamal-proxy reaches it, which is
# the container equivalent of the old loopback bind. --count 1 keeps the
# in-memory connection registry correct.
EXPOSE 80
CMD ["bundle", "exec", "falcon", "serve", "--bind", "http://0.0.0.0:80", "--count", "1"]
