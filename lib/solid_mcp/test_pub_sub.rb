# frozen_string_literal: true

require "concurrent/map"
require "concurrent/array"

module SolidMCP
  # Test implementation of PubSub for use in tests
  class TestPubSub
    attr_reader :subscriptions, :messages

    def initialize(options = {})
      @options = options
      @subscriptions = Concurrent::Map.new
      @messages = Concurrent::Array.new
    end

    def subscribe(session_id, &block)
      @subscriptions[session_id] ||= Concurrent::Array.new
      @subscriptions[session_id] << block
    end

    def unsubscribe(session_id)
      @subscriptions.delete(session_id)
    end

    def broadcast(session_id, event_type, data)
      message = { session_id: session_id, event_type: event_type, data: data }
      @messages << message
      
      callbacks = @subscriptions[session_id] || []
      callbacks.each do |callback|
        callback.call({ event_type: event_type, data: data })
      end
    end

    def shutdown
      @subscriptions.clear
      @messages.clear
    end
  end
end