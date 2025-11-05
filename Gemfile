# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in solid_mcp.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "minitest", "~> 5.16"

# Allow testing against different Rails versions via RAILS_VERSION env var
if ENV["RAILS_VERSION"]
  gem "activerecord", ENV["RAILS_VERSION"]
  gem "railties", ENV["RAILS_VERSION"]
  gem "activejob", ENV["RAILS_VERSION"]
end
