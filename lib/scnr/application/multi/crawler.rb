class Multi
module Crawler

    def self.included( _ )
        SCNR::Engine::Framework.class_eval do

            def audit_page( page )
                ap "[#{Cuboid::Options.rpc.url}] CRAWLING: #{page.dom.url}"

                # Us for just crawling.
                r = super( page )

                auditor = self.preferred_auditor
                signal_not_done auditor.url
                auditor.multi.push_page(
                  deduplicate_page_elements( page ).to_rpc_data
                ) {}

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
                    auditor.multi.clean_up { auditor.shutdown {} }
                end

                super
            end

            def preferred_auditor
                # Try to find an idle auditor.
                idle_auditor_url = self.done_signals.first
                auditor = self.auditors.find { |auditor| auditor.url == idle_auditor_url }

                # All auditors are busy.
                if !auditor
                    # Rotate auditors to keep distribution even.
                    auditor = self.auditors.first
                    self.auditors.delete( auditor )
                    self.auditors << auditor
                end

                auditor
            end

            def deduplicate_page_elements( page )
                # Auditors don't share state so we may end up auditing identical
                # elements which appear in multiple pages from multiple Auditors.
                #
                # Ensure that this wont happen via whitelisting.

                @element_filter ||= SCNR::Engine::Support::Filter::Set.new(
                  hasher: :coverage_hash
                )

                page.elements_within_scope.each do |e|
                    # Element already seen, i.e. passed for an audit, ignore.
                    next if @element_filter.include? e

                    # New element, allow its audit...
                    page.update_element_audit_whitelist( e )
                    # ...once.
                    @element_filter << e
                end

                # No new elements for this page, don't audit any.
                if page.element_audit_whitelist.empty?
                    page.do_not_audit_elements
                end

                page
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

    def log_error( error )
        SCNR::Engine::UI::Output.error error
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
