class Multi
module Auditor

    def self.included( _ )
        SCNR::Engine::Options.scope.do_not_crawl
        SCNR::Engine::Data.issues.do_not_store

        SCNR::Engine::Framework.class_eval do

            attr_accessor :crawler

            def audit
                # The trainer would lead us into a crawl, we don't want that.
                @trainer.unhook!
                super
            end

            def audit_page( page )
                # ap "[#{Cuboid::Options.rpc.url}] AUDITING: #{page.dom.url}"

                # @current_url = page.dom.url.to_s
                r = super( page )
                # @current_url = page.dom.url.to_s

                @crawler.multi.replenish_page_buffer( Cuboid::Options.rpc.url ) {}

                r
            end

            def clean_up( from_rpc = false )
                return if !from_rpc
                super
            end

        end
    end

    def push_page( page )
        page = SCNR::Engine::Page.from_rpc_data( page )

        if !@cb_set
            SCNR::Engine::Data.issues.on_new do |issue|
                @crawler.multi.log_issue( issue.to_rpc_data ){}
            end

            SCNR::Engine::UI::Output.on_error do |error|
                @crawler.multi.log_error( error ){}
            end

            framework.crawler = @crawler

            @cb_set = true
        end

        if !framework.push_to_page_queue( page ) && !@auditing
            @crawler.multi.signal_idle( @self_url ) {}
            return
        end

        return if @auditing
        @auditing = true
        Thread.new do

            begin
                framework.audit
                @crawler.multi.signal_idle( @self_url ) do
                    @auditing = false
                end

            rescue => e
                ap e
                ap e.backtrace
            end
        end

        nil
    end

    def update_cookies( cookies )
        SCNR::Engine::HTTP::Client.update_cookies(
          cookies.map { |cookie| SCNR::Engine::Element::Cookie.from_rpc_data cookie }
        )
        nil
    end

    def clean_up
        framework.clean_up( true )
        nil
    end

end
end
