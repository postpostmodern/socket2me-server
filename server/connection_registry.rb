# frozen_string_literal: true

module Socket2Me
  # Tracks active WebSocket connections by username.
  class ConnectionRegistry
    def initialize
      @lock = Mutex.new
      @by_user = {}
    end

    def register(username, connection)
      @lock.synchronize do
        @by_user[username] = connection
      end
    end

    def deregister(username, connection)
      @lock.synchronize do
        @by_user.delete(username) if @by_user[username] == connection
      end
    end

    def get(username)
      @lock.synchronize { @by_user[username] }
    end

    def size
      @lock.synchronize { @by_user.size }
    end
  end
end


