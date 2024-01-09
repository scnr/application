#!/usr/bin/env ruby
require_relative '../lib/scnr/application'
require_relative 'rest-http-helpers'

pid = SCNR::Application.spawn( :rest, daemonize: true, stdout: '/dev/null', stderr: '/dev/null' )
sleep 1 while request( :get ).code == 0
at_exit { Cuboid::Processes::Manager.kill pid }

# Create a new scanner Instance (process) and run a scan with the following options.
request :post, 'instances', {

  # Scan this URL.
  url:    'http://testhtml5.vulnweb.com',

  # Audit the following element types.
  audit:  {
    elements: [:links, :forms, :cookies, :ui_inputs, :ui_forms]
  },

  # Load all active checks.
  checks: '*'
}

# The ID is used to represent that instance and allow us to manage it from here on out.
instance_id = response_data['id']

print 'Scanning.'
while sleep( 1 )
    request :get, "instances/#{instance_id}/scan/progress", {
      as_hash: true, with: [:issues, :sitemap, :errors]
    }
    # pp response_data

    print '.'

    # Continue looping while instance status is 'busy'.
    request :get, "instances/#{instance_id}"
    break if !response_data['busy']
end

puts

# Get the scan report.
request :get, "instances/#{instance_id}/scan/report.json"
# Print out the report.
pp response_data

# Shutdown the Instance.
request :delete, "instances/#{instance_id}"
