child :plugins, :Plugins do
    def_on :initialize do |cb = nil, &block|
        SCNR::Engine::UnsafeFramework.plugins.on_initialize &block_or_method( cb, &block )
    end

    def_on :prepare do |cb = nil, &block|
        SCNR::Engine::UnsafeFramework.plugins.on_prepare &block_or_method( cb, &block )
    end

    def_on :run do |cb = nil, &block|
        SCNR::Engine::UnsafeFramework.plugins.on_run &block_or_method( cb, &block )
    end

    def_on :clean_up do |cb = nil, &block|
        SCNR::Engine::UnsafeFramework.plugins.on_clean_up &block_or_method( cb, &block )
    end

    def_on :done do |cb = nil, &block|
        SCNR::Engine::UnsafeFramework.plugins.on_done &block_or_method( cb, &block )
    end

    def_as do |shortname, info = {}, m = nil, &block|
        shortname = shortname.to_s

        plugin = Class.new( SCNR::Engine::Plugin::Base )
        plugin.shortname = shortname

        if m
            plugin.define_method :run, m.is_a?( Symbol ) ? method( m ) : m
        else
            plugin.define_method :run, &block
        end

        plugin.define_singleton_method :info, &proc { info }

        SCNR::Engine::UnsafeFramework.plugins.on_load plugin
        SCNR::Engine::UnsafeFramework.plugins[shortname] = plugin
    end
end
