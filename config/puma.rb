threads_count = Integer(ENV.fetch("PUMA_THREADS", 5))
threads threads_count, threads_count
workers Integer(ENV.fetch("PUMA_WORKERS", 0))

port ENV.fetch("PORT", 5050)
environment ENV.fetch("RACK_ENV", "production")
directory File.expand_path(".")

# unique state/pid per instance via PORT so pumactl works cleanly
state_path "tmp/pids/puma-#{ENV.fetch('PORT','5050')}.state"
pidfile    "tmp/pids/puma-#{ENV.fetch('PORT','5050')}.pid"

prune_bundler
