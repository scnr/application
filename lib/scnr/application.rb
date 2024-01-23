require 'cuboid'

module SCNR
class Application < ::Cuboid::Application

    require_relative 'application/api'
    require_relative 'application/rpc_proxy'
    require_relative 'application/multi'
    require_relative 'application/rest_proxy'

    # Let's say one for the scanner and another for the browsers.
    provision_cores  2
    provision_memory 1.5 * 1024 * 1024 * 1024
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

        @api = API.new
    end

    def run
        if @multi[:instances].to_i > 1

            # One for the crawler.
            @multi[:instances] -= 1

            crawler = self.class.connect(
                url:   Cuboid::Options.rpc.url,
                token: Cuboid::Options.datastore.token
            )

            crawler.multi.make_crawler

            agent = Processes::Agents.connect( Cuboid::Options.agent.url )

            auditors = []
            @multi[:instances].times do |i|
                instance_info = agent.spawn
                if !instance_info
                    print_info "No more available slots for auditors."
                    break
                end

                auditors << instance_info

                instance = self.class.connect( instance_info )
                instance.multi.make_auditor( crawler.url, crawler.token, instance.url )
            end

            if auditors.empty?
                print_error "No available slots for auditors at all."
                return
            end

            # We don't want the auditors to perform anr type of crawl related stuff.
            auditor_options = SCNR::Engine::Options.to_rpc_data.deep_clone
            auditor_options['scope']['restrict_paths'].clear
            auditor_options['scope']['extend_paths'].clear

            @auditors = []
            auditors.each do |instance_info|
                auditor = self.class.connect( instance_info )
                @auditors << auditor
                auditor.run( auditor_options )
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
        SCNR::Engine::HTTP::Client.reset
        true
    rescue Engine::Options::Error
        false
    end

    def errors
        @errors
    end

    def shutdown
        return if !@auditors

        @auditors.each do |auditor|
            auditor.shutdown {}
        end
    end

    def generate_report
        report( @api.scan.generate_report ) unless data.report
        super
    end

    def do_pause
        @auditors.each { |auditor| auditor.pause! {} } if @auditors
        @api.scan.pause!
    end

    def do_resume
        @auditors.each { |auditor| auditor.resume! {} } if @auditors
        @api.scan.resume!
    end

    def do_abort
        @api.scan.abort!
        report @api.scan.generate_report
    end

    # Override Cuboid instead of handling the event.
    def suspend!
        fail 'Cannot suspend when in multi mode.' if @auditors

        @api.scan.suspend!

        # Change Cuboid's state to mirror the scanner's.
        state.suspended

        snapshot_path
    end

    def snapshot_path
        fail 'Cannot suspend when in multi mode.' if @auditors

        @api.scan.snapshot_path
    end

    # Override Cuboid instead of handling the event.
    def restore!( ses )
        fail 'Cannot restore when in multi mode.' if @auditors

        @api.scan.restore! ses
    end

end
end
