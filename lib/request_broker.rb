# frozen_string_literal: true

require "async"
require "async/promise"

module Socket2Me
  # Correlates HTTP requests with responses arriving over WebSocket.
  #
  # Each in-flight request gets an Async::Promise. The ingress fiber suspends on
  # `await_response` (no thread is blocked); the WebSocket read-loop fiber resolves
  # the promise via `deliver_response`. The Mutex guards only the entries hash and
  # is uncontended under Falcon's single-reactor-per-process model, but keeps state
  # correct if the container is ever run multi-threaded.
  class RequestBroker
    def initialize
      @lock = Mutex.new
      @entries = {}
    end

    def register(id)
      @lock.synchronize { @entries[id] = Async::Promise.new }
    end

    def await_response(id, timeout_seconds)
      promise = @lock.synchronize { @entries[id] }
      return nil unless promise

      Async::Task.current.with_timeout(timeout_seconds.to_f) { promise.wait }
    rescue Async::TimeoutError
      nil
    ensure
      @lock.synchronize { @entries.delete(id) }
    end

    def deliver_response(id, payload)
      promise = @lock.synchronize { @entries[id] }
      return false unless promise

      promise.resolve(payload)
      true
    end
  end
end
