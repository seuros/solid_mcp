# frozen_string_literal: true

require_relative "lib/solid_mcp/version"

Gem::Specification.new do |spec|
  spec.name          = "solid_mcp"
  spec.version       = SolidMCP::VERSION
  spec.authors       = ["Abdelkader Boudih"]
  spec.email         = ["terminale@gmail.com"]

  spec.summary       = "Streaming Pub/Sub transport for ActionMCP."
  spec.description   = <<~DESC
    SolidMCP implements a high-performance, bidirectional Pub/Sub transport for ActionMCP.
    Features optional Rust native extension with Tokio for async I/O, PostgreSQL LISTEN/NOTIFY
    support, and automatic fallback to pure Ruby when native extension is unavailable.
  DESC
  spec.homepage      = "https://github.com/seuros/solid_mcp"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  # Platform support
  spec.platform = Gem::Platform::RUBY
  # NOTE: This gem supports JRuby and TruffleRuby, but native features require MRI

  spec.metadata["homepage_uri"]     = spec.homepage
  spec.metadata["source_code_uri"]  = "https://github.com/seuros/solid_mcp"
  spec.metadata["changelog_uri"]    = "https://github.com/seuros/solid_mcp/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]  = "https://github.com/seuros/solid_mcp/issues"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["cargo_crate_name"] = "solid_mcp_native"
  spec.metadata["cargo_manifest_path"] = "ext/solid_mcp_native/ffi/Cargo.toml"

  # Specify which files should be added to the gem
  lib_files = Dir["lib/**/*"].reject { |path| path =~ /\.(bundle|so|dll)\z/ }
  spec.files = lib_files + Dir["sig/**/*"] + Dir["ext/**/*.{rb,rs,toml}"] + %w[LICENSE.txt README.md]
  spec.require_paths = ["lib"]

  # Add native extension (only on CRuby/TruffleRuby)
  spec.extensions = ["ext/solid_mcp_native/extconf.rb"] unless RUBY_ENGINE == "jruby"

  # Core dependencies
  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_dependency "railties", ">= 8.0"
  spec.add_dependency "activejob", ">= 8.0"
  spec.add_dependency "concurrent-ruby", "~> 1.0"
  spec.add_dependency "rb_sys", "~> 0.9" unless RUBY_ENGINE == "jruby"

  # Development dependencies
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "sqlite3", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rake-compiler", "~> 1.2"
end
