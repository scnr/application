child :dom, :DOM do
    def_before :load do |cb = nil, &block|
        SCNR::Engine::Browser::Parts::Navigation.before_load( &block_or_method( cb, &block ) )
    end

    def_before :event do |cb = nil, &block|
        SCNR::Engine::Browser::Parts::Events.before_event( &block_or_method( cb, &block ) )
    end

    def_on :event do |cb = nil, &block|
        SCNR::Engine::Browser::Parts::Events.on_event( &block_or_method( cb, &block ) )
    end

    def_after :load do |cb = nil, &block|
        SCNR::Engine::Browser::Parts::Navigation.after_load( &block_or_method( cb, &block ) )
    end

    def_after :event do |cb = nil, &block|
        SCNR::Engine::Browser::Parts::Events.after_event( &block_or_method( cb, &block ) )
    end
end
