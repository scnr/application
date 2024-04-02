#!/usr/bin/env ruby
require_relative '../lib/scnr/application'

agent    = SCNR::Application.spawn( :agent, daemonize: true, stdout: '/dev/null', stderr: '/dev/null' )
at_exit { Cuboid::Processes::Manager.kill agent.pid }

instance = SCNR::Application.connect( agent.spawn )
at_exit { instance.shutdown }

print 'Scanning.'
instance.run(
    url:    'https://ginandjuice.shop/',
    audit:  {
      elements: [:links, :forms, :cookies, :headers, :jsons, :xmls, :ui_inputs, :ui_forms]
    },
    checks: ['*']
)

while instance.busy?
    progress = instance.scan.progress(
      as_hash: true,
      with: [:issues, :sitemap, :errors]
    )
    # pp progress

    print '.'
    sleep 1
end
puts
pp report = instance.generate_report.data
pp report.finish_datetime - report.start_datetime
