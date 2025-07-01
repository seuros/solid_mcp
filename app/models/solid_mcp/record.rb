# frozen_string_literal: true

module SolidMCP
  class Record < ActiveRecord::Base
    self.abstract_class = true

    # Use primary database connection by default
    # Can be overridden with connects_to in production if needed
  end
end