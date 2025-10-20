#!/usr/bin/env ruby
require_relative '../lib/scnr/application'
require_relative 'rest-http-helpers'

pid = SCNR::Application.spawn( :rest, daemonize: true, stdout: '/dev/null', stderr: '/dev/null' )
sleep 1 while request( :get ).code == 0
at_exit { Cuboid::Processes::Manager.kill pid }

# Create a new scanner Instance (process) and run a scan with the following options.
request :post, 'instances', {
  "url": "http://testphp.vulnweb.com/",
  "audit": {
    "parameter_values": true,
    "mode": "moderate",
    "links": true,
    "forms": true,
    "cookies": true,
    "headers": true,
    "ui_inputs": true,
    "ui_forms": true
  },
  "scope": {
    "directory_depth_limit": 3,
    "auto_redundant_paths": 5,
    "depth_limit": 5,
    "dom_depth_limit": 4,
    "redundant_path_patterns": {
      "crawl_me_4_times": 4
    }
  },
  "checks": [
    "active/*"
  ],
  "authorized_by": "darkinvader.io"
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
