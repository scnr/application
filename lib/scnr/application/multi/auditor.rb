class Multi
module Auditor

    def self.included( _ )
        SCNR::Engine::Options.scope.do_not_crawl
        SCNR::Engine::Data.issues.do_not_store

        SCNR::Engine::Framework.class_eval do

            def audit
                @trainer.unhook!
                super
            end

            def audit_page( page )
                ap "AUDITING: [#{Cuboid::Options.rpc.url}] #{page.dom.url}"

                super( page )
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

            SCNR::Engine::Data.framework.on_sitemap_entry do |entry|
                @crawler.multi.update_sitemap( entry ){}
            end

            @cb_set = true
        end

        framework.push_to_page_queue page

        return if @auditing
        @auditing = true
        Thread.new do
            framework.audit
            @crawler.multi.signal_done( self_url ) do
                @auditing = false
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
