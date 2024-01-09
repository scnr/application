child :scope, :Scope do

    def_select :url do |cb = nil, &block|
        SCNR::Engine::URI::Scope.select( &block_or_method( cb, &block ) )
    end

    def_select :page do |cb = nil, &block|
        SCNR::Engine::Page::Scope.select( &block_or_method( cb, &block ) )
    end

    def_select :element do |cb = nil, &block|
        SCNR::Engine::Element::Capabilities::WithScope::Scope.select( &block_or_method( cb, &block ) )
    end

    def_select :event do |cb = nil, &block|
        SCNR::Engine::Browser::Parts::Events.select( &block_or_method( cb, &block ) )
    end


    def_reject :url do |cb = nil, &block|
        SCNR::Engine::URI::Scope.reject( &block_or_method( cb, &block ) )
    end

    def_reject :page do |cb = nil, &block|
        SCNR::Engine::Page::Scope.reject( &block_or_method( cb, &block ) )
    end

    def_reject :element do |cb = nil, &block|
        SCNR::Engine::Element::Capabilities::WithScope::Scope.reject( &block_or_method( cb, &block ) )
    end

    def_reject :event do |cb = nil, &block|
        SCNR::Engine::Browser::Parts::Events.reject( &block_or_method( cb, &block ) )
    end

end
