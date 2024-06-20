#!/usr/bin/env ruby
require_relative '../lib/scnr/application'
require_relative 'rest-http-helpers'

pid = SCNR::Application.spawn( :rest, daemonize: true, stdout: '/dev/null', stderr: '/dev/null' )
sleep 1 while request( :get ).code == 0
at_exit { Cuboid::Processes::Manager.kill pid }

# Utility method that polls for progress and prints out the report once the scan is done.
def monitor_and_report( instance_id )
    print 'Scanning.'
    while sleep( 1 )
        request :get, "instances/#{instance_id}/scan/progress", {
          with: [:issues, :sitemap, :errors]
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
end

# Create a new scanner Instance (process) and run a scan with the following options.
request :post, 'instances', {

  # Scan this URL.
  url:    'https://ginandjuice.shop/',

  # Audit the following element types.
  audit:  {
    elements: [:links, :forms, :cookies, :headers, :jsons, :xmls, :ui_inputs, :ui_forms]
  },

  # Load all active checks.
  checks: ['*']
}

# The ID is used to represent that instance and allow us to manage it from here on out.
instance_id = response_data['id']

monitor_and_report( instance_id )

########################################################################################################################
# Get the location of the scan session file, to later restore it, in order to save loads of time on rescans by only
# checking for new input vectors.
########################################################################################################################
request :get, "instances/#{instance_id}/scan/session"
session = response_data['session']

# Shutdown the Instance.
request :delete, "instances/#{instance_id}"

#########################################################################################
# Create a new Instance and restore the previous session to check new input vectors only.
#########################################################################################
puts '-' * 88
puts 'RESCANNING'
puts '-' * 88

request :post, 'instances/restore', session: session
instance_id = response_data['id']

monitor_and_report( instance_id )

# Shutdown the Instance.
request :delete, "instances/#{instance_id}"
