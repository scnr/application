source 'https://rubygems.org'

if File.exist? '../engine'
    gem 'scnr-engine', path: '../engine'
end

if File.exist? '../../ecsypno/license-client'
    gem 'ecsypno-license-client', path: '../../ecsypno/license-client'
else
    gem 'ecsypno-license-client'
end

if File.exist? '../license-client'
    gem 'scnr-license-client', path: '../license-client'
end

# Specify your gem's dependencies in application.gemspec
gemspec
