class Multi
module Crawler

    def self.included( _ )
        SCNR::Engine::Framework.class_eval do

            def audit_page( page )
                ap "CRAWLING: #{page.dom.url}"

                # Us for just crawling.
                r = super( page )

                # Try to find an idle auditor to receive each page.
                idle_auditor_url = self.done_signals.first
                auditor = self.auditors.find { |auditor| auditor.url == idle_auditor_url }

                # All auditors are busy.
                if !auditor
                    # Rotate auditors to keep distribution even.
                    auditor = self.auditors.first
                    self.auditors.delete( auditor )
                    self.auditors << auditor
                end

                signal_not_done auditor.url

                auditor.multi.push_page( page.to_rpc_data ) {}

                r
            end

            def audit
                if !@auditor_urls
                    @auditor_urls = Set.new( self.auditors.map(&:url) )

                    # Start with setting all auditors to idle.
                    self.done_signals.merge @auditor_urls
                end

                SCNR::Engine::HTTP::Client.on_new_cookies do |cookies, _|
                    self.auditors.each do |auditor|
                        auditor.multi.update_cookies( cookies.map(&:to_rpc_data) ) {}
                    end
                end

                super

                # Crawling done, now wait for the auditors to complete as well.
                sleep 0.1 while self.done_signals.size != self.auditors.size
            end

            def clean_up
                return if self.done_signals.size != self.auditors.size

                self.auditors.each do |auditor|
                    auditor.multi.clean_up { auditor.shutdown }
                end

                super
            end

            def auditors
                @peers ||= []
            end

            def signal_done( instance_url )
                self.done_signals << instance_url
                clean_up
            end

            def signal_not_done( instance_url )
                self.done_signals.delete instance_url
                nil
            end

            def done_signals
                @done_signals ||= Set.new
            end

        end
    end

    def log_issue( issue )
        SCNR::Engine::Data.issues << SCNR::Engine::Issue.from_rpc_data( issue )
        nil
    end

    def update_sitemap( entry )
        SCNR::Engine::Data.framework.update_sitemap entry
        nil
    end

    def signal_done( instance_url )
        framework.signal_done instance_url
        nil
    end

    def signal_not_done( instance_url )
        framework.signal_not_done instance_url
        nil
    end

    def set_auditors( auditors )
        auditors.each do |auditor_info|
            framework.auditors << SCNR::Application.connect( auditor_info )
        end

        nil
    end

end
end
