#!/usr/bin/env ruby
require_relative '../lib/scnr/application'

application = SCNR::Application
application.options = {
    url:    'http://testhtml5.vulnweb.com',
    audit:  {
      elements: [:links, :forms, :cookies, :ui_forms, :ui_inputs]
    },
    checks: '*'
}

api = application.api

api.state.on :change do |state|
    pp state.status
end

api.data.sitemap.on :new do |entry|
    pp entry
end
api.data.issues.on :new do |issue|
    pp issue
end

application.run
pp application.generate_report
