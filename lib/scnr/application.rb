require 'cuboid'
require 'scnr/engine/api'

require_relative 'application/rpc_proxy'
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

    instance_service_for :scan, RPCProxy
    rest_service_for     :scan, RESTProxy

    serialize_with Marshal

    attr_reader :api

    def initialize(*)
        super

        @api = Engine::API.new
    end

    def run
        @api.scan.run! { |r| report r }
    end

    def validate_options( options )
        @api.scan.options.set options
        true
    rescue Engine::Options::Error
        false
    end

    def do_pause
        @api.scan.pause!
    end

    def do_resume
        @api.scan.resume!
    end

    def do_abort
        @api.scan.abort!
    end

    # Override Cuboid instead of handling the event.
    def suspend!
        snapshot_path = nil
        @api.scan.suspend! { |sp| snapshot_path = sp }

        # Change Cuboid's state to mirror the scanner's.
        state.suspended

        snapshot_path
    end

    # Override Cuboid instead of handling the event.
    def restore!( ses )
        @api.scan.restore! ses
    end

end
end
