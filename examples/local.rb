#!/usr/bin/env ruby
require_relative '../lib/scnr/application'

application = SCNR::Application
application.options = {
    url:    'https://ginandjuice.shop/',
    audit:  {
      elements: [:links, :forms, :cookies, :headers, :jsons, :xmls, :ui_inputs, :ui_forms]
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
