child :scan, :Scan do
    import_many "#{File.dirname( SCNR.const_source_location( 'Application' ).first )}/application/api/scan/*"

    Kernel.at_exit do
        SCNR::Engine::UnsafeFramework.clean_up
        SCNR::Engine::UnsafeFramework.reset
    end

    def_before :page do |cb = nil, &block|
        SCNR::Engine::UnsafeFramework.before_page_audit( &block_or_method( cb, &block ) )
    end

    def_on :page do |cb = nil, &block|
        SCNR::Engine::UnsafeFramework.on_page_audit( &block_or_method( cb, &block ) )
    end

    def_after :page do |cb = nil, &block|
        SCNR::Engine::UnsafeFramework.after_page_audit( &block_or_method( cb, &block ) )
    end

    def_run! do |cb = nil, &block|
        SCNR::Engine::Framework.safe do |framework|
            framework.checks.load SCNR::Engine::Options.checks

            framework.plugins.load_defaults
            framework.plugins.load SCNR::Engine::Options.plugins.keys

            framework.run
            block_or_method( cb, &block ).call framework.report, framework.statistics
        end
    end

    def_run do
        SCNR::Engine::UnsafeFramework.checks.load SCNR::Engine::Options.checks

        SCNR::Engine::UnsafeFramework.plugins.load_defaults
        SCNR::Engine::UnsafeFramework.plugins.load SCNR::Engine::Options.plugins.keys

        SCNR::Engine::UnsafeFramework.run

        [SCNR::Engine::UnsafeFramework.report, SCNR::Engine::UnsafeFramework.statistics]
    end

    def_progress do
        {
          running:          running?,
          status:           status,
          status_messages:  status_messages,
          errors:           errors,
          sitemap:          sitemap,
          issues:           issues,
          statistics:       statistics
        }
    end

    def_session_progress do |session_id = nil|
        @session ||= {}
        @session[session_id] ||= {
          seen_issues:    Set.new,
          sitemap_offset: 0,
          error_offset:   0
        }

        progress = {
          running:          running?,
          status:           status,
          status_messages:  status_messages,
          errors:           errors( @session[session_id][:error_offset] ),
          sitemap:          sitemap( @session[session_id][:sitemap_offset] ),
          issues:           issues( @session[session_id][:seen_issues] ),
          statistics:       statistics
        }

        @session[session_id][:error_offset]   += progress[:errors].size
        @session[session_id][:sitemap_offset] += progress[:sitemap].size
        @session[session_id][:seen_issues]    |= progress[:issues].map(&:digest)

        progress
    end

    def_sitemap do |index = 0|
        return {} if SCNR::Engine::UnsafeFramework.sitemap.size <= index + 1
        Hash[SCNR::Engine::UnsafeFramework.sitemap.to_a[index..-1] || {}]
    end

    def_status do
        s = SCNR::Engine::UnsafeFramework.state.status
        s.nil? ? :nil : s
    end

    def_errors do |index = 0|
        SCNR::Application.errors[index..-1]
    end

    def_issues do |without = []|
        without = Set.new( without )
        SCNR::Engine::Data.issues.sort.
          reject { |i| without.include? i.digest }
    end

    %w(
        status_messages
        statistics
        running?
        scanning?
        pause! pausing? paused?
        resume!
        abort!
        suspend! suspending? suspended?
        snapshot_path
    ).each do |m|
        send( "def_#{m}", &proc { SCNR::Engine::UnsafeFramework.send( m ) } )
    end

    def_restore! do |snapshot|
        SCNR::Engine::UnsafeFramework.restore! snapshot
        nil
    end

    def_generate_report do
        SCNR::Engine::UnsafeFramework.report
    end

    def_generate_session_snapshot do
        fail 'Cannot generate session while scan is running.' if running?

        SCNR::Engine::Data.clear
        SCNR::Engine::State.browser_pool.clear
        SCNR::Engine::State.framework.clear

        snapshot_path = SCNR::Engine::UnsafeFramework.snapshot_path
        SCNR::Engine::Snapshot.dump snapshot_path
        snapshot_path
    end

end
