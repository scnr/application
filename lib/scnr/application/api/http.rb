child :http, :HTTP do
    def_on :request do |cb = nil, &block|
        SCNR::Engine::HTTP::Client.on_queue( &block_or_method( cb, &block ) )
    end

    def_on :response do |cb = nil, &block|
        SCNR::Engine::HTTP::Client.on_complete( &block_or_method( cb, &block ) )
    end

    def_on :cookies do |cb = nil, &block|
        SCNR::Engine::HTTP::Client.on_new_cookies( &block_or_method( cb, &block ) )
    end

    def_after :run do |cb = nil, &block|
        SCNR::Engine::HTTP::Client.after_each_run( &block_or_method( cb, &block ) )
    end
end
