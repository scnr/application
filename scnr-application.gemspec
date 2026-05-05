# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
    spec.name          = "scnr-application"
    spec.version       = IO.read( File.dirname( __FILE__ ) + '/lib/scnr/application/version' ).strip
    spec.authors       = ["Tasos Laskos"]
    spec.email         = ["tasos.laskos@gmail.com"]

    spec.summary       = %q{SCNR application.}
    spec.homepage      = "https://ecsypno.com"

    spec.require_paths = ["lib"]

    spec.files        << 'bin/.gitkeep'
    spec.files        += Dir.glob( 'examples/**/**' )
    spec.files        += Dir.glob( 'lib/**/**' )
    spec.test_files    = Dir.glob( 'spec/**/**' )

    spec.require_paths = ['lib']

    if spec.respond_to?(:metadata)
      spec.metadata['allowed_push_host'] = "TODO: Set to 'http://mygemserver.com' to prevent pushes to rubygems.org, or delete to allow pushes to any server."
    end

    spec.add_dependency 'cuboid',      '~> 0.3'
    spec.add_dependency 'scnr-license-client'
    spec.add_dependency 'scnr-engine', '~> 0.1'
    spec.add_dependency 'mcp',         '>= 0.15'

    spec.add_development_dependency 'bundler'
    spec.add_development_dependency 'rake'
end
