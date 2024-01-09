child :logging, :Logging do
    def_on :error do |cb = nil, &block|
        SCNR::Engine::UI::Output.on_error( &block_or_method( cb, &block ) )
    end

    def_on :exception do |cb = nil, &block|
        SCNR::Engine::Error.on_new( &block_or_method( cb, &block ) )
    end
end
