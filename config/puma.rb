threads_count = Integer(ENV.fetch("PUMA_THREADS", 5))
threads threads_count, threads_count
workers Integer(ENV.fetch("PUMA_WORKERS", 0))

# Bind to loopback only. All public traffic must arrive via nginx (which
# terminates TLS and sets the trusted X-S2M-Username header). Binding to
# 0.0.0.0 would let anything that can reach the host on this port bypass
# nginx entirely and spoof X-S2M-Username. Keep the firewall as well.
bind "tcp://127.0.0.1:#{ENV.fetch('PORT', 5050)}"
environment ENV.fetch("RACK_ENV", "production")
directory File.expand_path(".")

# unique state/pid per instance via PORT so pumactl works cleanly
state_path "tmp/pids/puma-#{ENV.fetch('PORT','5050')}.state"
pidfile    "tmp/pids/puma-#{ENV.fetch('PORT','5050')}.pid"

prune_bundler
