# frozen_string_literal: true

module SolidMCP
  module Logger
    class << self
      def logger
        SolidMCP.configuration.logger
      end

      def tagged(*tags, &block)
        logger.tagged(*tags, &block)
      end

      def debug(message = nil, &block)
        logger.debug(message, &block)
      end

      def info(message = nil, &block)
        logger.info(message, &block)
      end

      def warn(message = nil, &block)
        logger.warn(message, &block)
      end

      def error(message = nil, &block)
        logger.error(message, &block)
      end

      def fatal(message = nil, &block)
        logger.fatal(message, &block)
      end
    end
  end
end