# frozen_string_literal: true

require_relative "lib/solid_mcp/version"

Gem::Specification.new do |spec|
  spec.name          = "solid_mcp"
  spec.version       = SolidMCP::VERSION
  spec.authors       = ["Abdelkader Boudih"]
  spec.email         = ["terminale@gmail.com"]

  spec.summary       = "Streaming Pub/Sub transport for ActionMCP."
  spec.description   = "SolidMCP implements a high-performance, bidirectional Pub/Sub transport for ActionMCP."
  spec.homepage      = "https://github.com/seuros/solid_mcp"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["homepage_uri"]     = spec.homepage
  spec.metadata["source_code_uri"]  = "https://github.com/seuros/solid_mcp"
  spec.metadata["changelog_uri"]    = "https://github.com/seuros/solid_mcp/blob/main/CHANGELOG.md"

  spec.files         = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      f.start_with?(*%w[test/ .git .github])
    end
  end

  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_dependency "railties", ">= 8.0"
  spec.add_dependency "activejob", ">= 8.0"
  spec.add_dependency "concurrent-ruby", "~> 1.0"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "sqlite3", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
