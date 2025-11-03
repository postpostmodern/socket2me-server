# frozen_string_literal: true

require "monitor"

module Socket2Me
  # Correlates HTTP requests with responses arriving over WebSocket.
  class RequestBroker
    Entry = Struct.new(:response, :cond)

    def initialize
      @lock = Monitor.new
      @entries = {}
    end

    def register(id)
      @lock.synchronize do
        @entries[id] = Entry.new(nil, @lock.new_cond)
      end
    end

    def await_response(id, timeout_seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds.to_f
      entry = @lock.synchronize { @entries[id] }
      return nil unless entry

      @lock.synchronize do
        while entry.response.nil?
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          entry.cond.wait(remaining)
        end
        entry.response
      ensure
        @entries.delete(id)
      end
    end

    def deliver_response(id, payload)
      @lock.synchronize do
        entry = @entries[id]
        return false unless entry

        entry.response = payload
        entry.cond.broadcast
        true
      end
    end
  end
end


