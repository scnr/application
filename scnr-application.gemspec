# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'scnr/application/version'

Gem::Specification.new do |spec|
    spec.name          = "scnr-application"
    spec.version       = Application::VERSION
    spec.authors       = ["Tasos Laskos"]
    spec.email         = ["tasos.laskos@gmail.com"]

    spec.summary       = %q{SCNR application.}
    spec.homepage      = "http://placeholder.com"

    spec.files         = Dir.glob( 'lib/**/**' )
    spec.files         = Dir.glob( 'bin/**/**' )

    spec.bindir        = "bin"
    spec.require_paths = ["lib"]

    if spec.respond_to?(:metadata)
      spec.metadata['allowed_push_host'] = "TODO: Set to 'http://mygemserver.com' to prevent pushes to rubygems.org, or delete to allow pushes to any server."
    end

    spec.add_dependency 'cuboid'
    spec.add_dependency 'scnr-engine', '~> 1.0dev'

    spec.add_development_dependency 'bundler'
    spec.add_development_dependency 'rake'
end
