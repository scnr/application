require 'cuboid'
require 'scnr/engine'

require_relative 'application/rpc_proxy'
require_relative 'application/rest_proxy'

module SCNR
class Application < ::Cuboid::Application

    # Let's say one for the scanner and another for the browsers.
    provision_cores  2
    provision_memory 1 * 1024 * 1024 * 1024
    provision_disk   2 * 1024 * 1024 * 1024

    validate_options_with :validate_options

    handler_for :pause,   :do_pause
    handler_for :resume,  :do_resume
    handler_for :abort,   :do_abort

    rpc_service_for  :proxy, RPCProxy
    rest_service_for :proxy, RESTProxy

    serialize_with Marshal

    attr_reader :framework

    def run
        Engine::Framework.safe do |f|
            # Hacky.
            @framework = f

            f.checks.load Engine::Options.checks

            f.plugins.load_defaults
            f.plugins.load Engine::Options.plugins.keys

            f.run

            report f.report
        end
    end

    def validate_options( options )
        Engine::Options.update options
        Engine::Options.validate
        true
    rescue Engine::Options::Error
        false
    end

    def do_pause
        @framework.pause!
    end

    def do_resume
        @framework.resume!
    end

    def do_abort
        @framework.abort!
    end

    # Override Cuboid instead of handling the event.
    def suspend!
        sp = @framework.suspend!
        @framework.clean_up

        # Change Cuboid's state to mirror the scanner's.
        state.suspended

        sp
    end

    # Override Cuboid.
    def snapshot_path
        @framework.snapshot_path
    end

    # Override Cuboid instead of handling the event.
    def restore!( ses )
        @framework.restore! ses
    end

end
end
