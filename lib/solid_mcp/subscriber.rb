# frozen_string_literal: true

require "concurrent/atomic/atomic_boolean"

module SolidMCP
  class Subscriber
    def initialize(session_id, callbacks)
      @session_id = session_id
      @callbacks = callbacks
      @running = Concurrent::AtomicBoolean.new(false)
      @thread = nil
      @last_message_id = 0
    end

    def start
      return if @running.true?

      @running.make_true
      @thread = Thread.new { poll_loop }
    end

    def stop
      @running.make_false
      @thread&.join
    end

    private

    def poll_loop
      while @running.true?
        messages = fetch_new_messages
        
        if messages.any?
          process_messages(messages)
          mark_delivered(messages)
        else
          sleep SolidMCP.configuration.polling_interval
        end
      end
    rescue => e
      Rails.logger.error "SolidMCP::Subscriber error for session #{@session_id}: #{e.message}" if defined?(Rails)
      retry if @running.true?
    end

    def fetch_new_messages
      SolidMCP::Message
        .for_session(@session_id)
        .undelivered
        .after_id(@last_message_id)
        .order(:id)
        .limit(100)
        .to_a
    end

    def process_messages(messages)
      messages.each do |message|
        @callbacks.each do |callback|
          callback.call({
            event_type: message.event_type,
            data: message.data,
            id: message.id
          })
        rescue => e
          Rails.logger.error "SolidMCP callback error: #{e.message}" if defined?(Rails)
        end
        @last_message_id = message.id
      end
    end

    def mark_delivered(messages)
      SolidMCP::Message.mark_delivered(messages.map(&:id))
    end
  end
end