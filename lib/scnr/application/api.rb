require 'scnr/engine'
require 'dsel'

module SCNR
class Application

    @errors ||= []
    SCNR::Engine::UI::Output.on_error do |error|
        @errors << error
    end
    class <<self
        def errors
            @errors
        end
    end

DSeL::DSL::Nodes::APIBuilder.build :API, namespace: self do

    class DSeL::API::Node
        def block_or_method( cb, &block )
            block || method( cb )
        end
    end

    import_relative_many 'api/*'
end

end
end
