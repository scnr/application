child :input, :Input do
    def_values do |cb = nil, &block|
        SCNR::Engine::Options.input.filler( &block_or_method( cb, &block ) )
    end
end
