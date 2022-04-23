class Multi
module Crawler

    def self.included( _ )
        SCNR::Engine::Framework.class_eval do

            def audit_page( page )
                # ap "[#{Cuboid::Options.rpc.url}] CRAWLING: #{page.dom.url}"

                # Us for just crawling.
                r = super( page )

                # We have a specific request by an auditor, must need its page
                # buffer replenished.
                if (auditor_url = @crawl_wakeup.pop)
                    auditor = auditor_by_url( auditor_url )

                # Clean slate, find the best one by other means.
                else
                    auditor = self.preferred_auditor
                end

                signal_working auditor.url
                auditor.multi.push_page(
                  deduplicate_page_elements( page ).to_rpc_data
                ) {}

                r
            end

            def audit
                # Used to block the crawl in order to not produce excessive
                # audit workload.
                #
                # No sense in pages being retrieved unless we can do something
                # with them.
                @crawl_wakeup = Queue.new

                # Amount of pages to retrieve every time an auditor completes.
                #
                # It's nice to have a few in the buffer to reduce blocking
                # when we want something to audit.
                @crawl_buffer = 5

                # Start with setting all auditors to idle.
                self.auditors.keys.each { |url| signal_idle( url ) }

                # Transmit new cookie vectors to auditors.
                SCNR::Engine::HTTP::Client.on_new_cookies do |cookies, _|
                    self.auditors.values.each do |auditor|
                        auditor.multi.update_cookies( cookies.map(&:to_rpc_data) ) {}
                    end
                end

                super

                # Crawling done, now wait for the auditors to complete as well.
                sleep 0.1 while self.idle_signals.size != self.auditors.size
            end

            def clean_up( *args )
                self.auditors.values.each do |auditor|
                    auditor.multi.clean_up { auditor.shutdown {} }
                end

                @crawl_wakeup.clear
                self.auditors.clear
                self.idle_signals.clear

                super( *args )
            end

            def preferred_auditor
                # Prefer an idle auditor...
                auditor = auditor_by_url( self.idle_signals.first )

                # ...however if all auditors are busy...
                if !auditor
                    # ...rotate them to keep distribution even.
                    url, auditor = self.auditors.first
                    self.auditors.delete( url )
                    self.auditors[url] = auditor
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
                @auditors ||= {}
            end

            def auditor_by_url( url )
                self.auditors[url]
            end

            def signal_idle( instance_url )
                self.idle_signals << instance_url
                @crawl_buffer.times { wake_up_crawler }
                nil
            end

            def wake_up_crawler( auditor_url = nil )
                @crawl_wakeup << auditor_url
            end

            def signal_working( instance_url )
                self.idle_signals.delete instance_url
                nil
            end

            def idle_signals
                @idle_signals ||= Set.new
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

    def replenish_page_buffer( auditor_url )
        framework.wake_up_crawler( auditor_url )
        nil
    end

    def signal_idle( instance_url )
        framework.signal_idle instance_url
        nil
    end

    def set_auditors( auditors )
        auditors.each do |auditor_info|
            framework.auditors[auditor_info['url']] =
              SCNR::Application.connect( auditor_info )
        end

        nil
    end

end
end
