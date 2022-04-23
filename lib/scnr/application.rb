require 'cuboid'
require 'scnr/engine/api'

require_relative 'application/rpc_proxy'
require_relative 'application/multi'
require_relative 'application/rest_proxy'

module SCNR
class Application < ::Cuboid::Application

    # Let's say one for the scanner and another for the browsers.
    provision_cores  2
    provision_memory 4 * 1024 * 1024 * 1024
    provision_disk   4 * 1024 * 1024 * 1024

    validate_options_with :validate_options

    handler_for :pause,   :do_pause
    handler_for :resume,  :do_resume
    handler_for :abort,   :do_abort

    instance_service_for :scan,  RPCProxy

    instance_service_for :multi, Multi

    rest_service_for     :scan,  RESTProxy

    serialize_with Marshal

    attr_reader :api

    def initialize(*)
        super

        @api = Engine::API.new
    end

    def run
        if @multi[:processes].to_i > 1

            # One for the crawler.
            @multi[:processes] -= 1

            crawler = self.class.connect(
                url:   Cuboid::Options.rpc.url,
                token: Cuboid::Options.datastore.token
            )

            crawler.multi.make_crawler

            agent = Processes::Agents.connect( Cuboid::Options.agent.url )

            auditors = []
            @multi[:processes].times do |i|
                instance_info = agent.spawn
                auditors << instance_info

                instance = self.class.connect( instance_info )
                instance.multi.make_auditor( crawler.url, crawler.token, instance.url )
            end

            # We don't want the auditors to perform anr type of crawl related stuff.
            auditor_options = SCNR::Engine::Options.to_rpc_data.deep_clone
            auditor_options['scope']['restrict_paths'].clear
            auditor_options['scope']['extend_paths'].clear

            auditors.each do |instance_info|
                self.class.connect( instance_info ).run( auditor_options )
            end

            crawler.multi.set_auditors auditors

            # We're just the crawler, auditors will audit the pages.
            SCNR::Engine::Options.checks = []
            @api.scan.options.set SCNR::Engine::Options.to_h
        end

        report @api.scan.run.first
    end

    def validate_options( options )
        options = options.dup

        @multi = options.delete('multi')&.my_symbolize_keys || {}

        if !@multi.empty? && !Cuboid::Options.agent.url
            raise ArgumentError, 'Multi options set but without Agent.'
        end

        @api.scan.options.set options
        true
    rescue Engine::Options::Error
        false
    end

    def generate_report
        report( @api.scan.generate_report ) unless data.report
        super
    end

    def do_pause
        @api.scan.pause!
    end

    def do_resume
        @api.scan.resume!
    end

    def do_abort
        @api.scan.abort!
        report @api.scan.generate_report
    end

    # Override Cuboid instead of handling the event.
    def suspend!
        @api.scan.suspend!

        # Change Cuboid's state to mirror the scanner's.
        state.suspended

        snapshot_path
    end

    def snapshot_path
        @api.scan.snapshot_path
    end

    # Override Cuboid instead of handling the event.
    def restore!( ses )
        @api.scan.restore! ses
    end

end
end
