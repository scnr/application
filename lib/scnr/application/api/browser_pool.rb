child :browserpool, :BrowserPool do

    def_on :job do |cb = nil, &block|
        SCNR::Engine::BrowserPool.on_queue( &block_or_method( cb, &block ) )
    end

    def_on :job_done do |cb = nil, &block|
        SCNR::Engine::BrowserPool.on_job_done( &block_or_method( cb, &block ) )
    end

    def_on :result do |cb = nil, &block|
        SCNR::Engine::BrowserPool.on_result( &block_or_method( cb, &block ) )
    end

end
