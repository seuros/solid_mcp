# frozen_string_literal: true

require "concurrent/map"
require "concurrent/array"

module SolidMCP
  class PubSub
    def initialize(options = {})
      @options = options
      @subscriptions = Concurrent::Map.new
      @listeners = Concurrent::Map.new
    end

    # Subscribe to messages for a specific session
    def subscribe(session_id, &block)
      # Atomically get or create callbacks array
      callbacks = @subscriptions.compute_if_absent(session_id) { Concurrent::Array.new }
      callbacks << block

      # Start a listener for this session if not already running
      ensure_listener_for(session_id)
    end

    # Unsubscribe from a session
    def unsubscribe(session_id)
      @subscriptions.delete(session_id)
      stop_listener_for(session_id)
    end

    # Broadcast a message to a session (uses MessageWriter for batching)
    def broadcast(session_id, event_type, data)
      MessageWriter.instance.enqueue(session_id, event_type, data)
    end

    # Shutdown all listeners
    def shutdown
      @listeners.each do |_, listener|
        listener.stop
      end
      @listeners.clear
      MessageWriter.instance.shutdown
    end

    private

    def ensure_listener_for(session_id)
      # Atomically create and start listener only once
      @listeners.compute_if_absent(session_id) do
        listener = Subscriber.new(session_id, @subscriptions[session_id])
        listener.start
        listener
      end
    end

    def stop_listener_for(session_id)
      listener = @listeners.delete(session_id)
      listener&.stop
    end
  end # class PubSub
end