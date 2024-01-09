child :state, :State do

    def_on :change do |cb = nil, &block|
        SCNR::Engine::UnsafeFramework.state.on_state_change( &block_or_method( cb, &block ) )
    end

end
