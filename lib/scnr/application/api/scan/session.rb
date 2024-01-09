child :session, :Session do

    def_to :login do |cb = nil, &block|
        SCNR::Engine::UnsafeFramework.session.record_login_sequence &block_or_method( cb, &block )
    end

    def_to :check do |cb = nil, &block|
        SCNR::Engine::UnsafeFramework.session.record_login_check &block_or_method( cb, &block )
    end
end
