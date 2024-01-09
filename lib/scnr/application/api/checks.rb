child :checks, :Checks do
    def_on :run do |cb = nil, &block|
        SCNR::Engine::UnsafeFramework.checks.on_run &block_or_method( cb, &block )
    end

    def_as do |shortname, info = {}, m = nil, &block|
        shortname = shortname.to_s

        check = Class.new( SCNR::Engine::Check::Base )
        check.shortname = shortname

        if m
            check.define_method :run, m.is_a?( Symbol ) ? method( m ) : m
        else
            check.define_method :run, &block
        end

        check.define_singleton_method :info, &proc { info }

        SCNR::Engine::UnsafeFramework.checks.on_load check
        SCNR::Engine::UnsafeFramework.checks[shortname] = check
    end
end
