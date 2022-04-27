class RPCProxy

    # # Recommended usage
    #
    #   Please request from the method only the things you are going to actually
    #   use, otherwise you'll just be wasting bandwidth.
    #   In addition, ask to **not** be served data you already have, like issues
    #   or error messages.
    #
    #   To be kept completely up to date on the progress of a scan (i.e. receive
    #   new issues and error messages asap) in an efficient manner, you will need
    #   to keep track of the issues and error messages you already have and
    #   explicitly tell the method to not send the same data back to you on
    #   subsequent calls.
    #
    # ## Retrieving errors (`:errors` option) without duplicate data
    #
    #   This is done by telling the method how many error messages you already
    #   have and you will be served the errors from the error-log that are past
    #   that line.
    #   So, if you were to use a loop to get fresh progress data it would look
    #   like so:
    #
    #     error_cnt = 0
    #     i = 0
    #     while sleep 1
    #         # Test method, triggers an error log...
    #         instance.error_test "BOOM! #{i+=1}"
    #
    #         # Only request errors we don't already have
    #         errors = instance.progress( with: { errors: error_cnt } )[:errors]
    #         error_cnt += errors.size
    #
    #         # You will only see new errors
    #         puts errors.join("\n")
    #     end
    #
    # ## Retrieving issues without duplicate data
    #
    #   In order to be served only new issues you will need to let the method
    #   know which issues you already have. This is done by providing a list
    #   of {Issue#digest digests} for the issues you already know about.
    #
    #     issue_digests = []
    #     while sleep 1
    #         issues = instance.progress(
    #                      with: :issues,
    #                      # Only request issues we don't already have
    #                      without: { issues: issue_digests  }
    #                  )[:issues]
    #
    #         issue_digests |= issues.map { |issue| issue['digest'] }
    #
    #         # You will only see new issues
    #         issues.each do |issue|
    #             puts "  * #{issue['name']} in '#{issue['vector']['type']}' input '#{issue['vector']['affected_input_name']}' at '#{issue['vector']['action']}'."
    #         end
    #     end
    #
    # @param  [Hash]  options
    #   Options about what progress data to retrieve and return.
    # @option options [Array<Symbol, Hash>]  :with
    #   Specify data to include:
    #
    #   * :issues -- Discovered issues as {Engine::Issue#to_h hashes}.
    #   * :errors -- Errors and the line offset to use for {#errors}.
    #     Pass as a hash, like: `{ errors: 10 }`
    # @option options [Array<Symbol, Hash>]  :without
    #   Specify data to exclude:
    #
    #   * :statistics -- Don't include runtime statistics.
    #   * :issues -- Don't include issues with the given {Engine::Issue#digest digests}.
    #     Pass as a hash, like: `{ issues: [...] }`
    #
    # @return [Hash]
    #   * `statistics` -- General runtime statistics (merged when part of Grid)
    #       (enabled by default)
    #   * `status` -- {#status}
    #   * `busy` -- {#busy?}
    #   * `issues` -- Discovered issues as {Engine::Issue#to_h hashes}.
    #       (disabled by default)
    #   * `errors` -- {#errors} (disabled by default)
    #   * `sitemap` -- {#sitemap} (disabled by default)
    def progress( options = {}, &block )
        # keep track based on session
        p = progress_handler( options )

        framework = SCNR::Engine::Framework.unsafe
        if framework.respond_to?( :auditors )
            cp = p.dup
            cp.delete :sitemap
            cp.delete :issues

            p[:multi] = {
                crawler:  cp,
                auditors: {}
            }

            if framework.auditors.any?
                count = 0

                framework.auditors.values.each do |auditor|
                    auditor.scan.progress( without: [:sitemap, :issues] ) do |auditor_progress|
                        count += 1
                        p[:multi][:auditors][auditor.url] = auditor_progress

                        if count == framework.auditors.size
                            block.call calculate_median_progress( p )
                        end
                    end
                end
            else
                block.call p
            end
        else
            block.call p
        end
    end

    # @param    [Integer]   from_index
    #   Get sitemap entries after this index.
    #
    # @return   [Hash<String=>Integer>]
    def sitemap( from_index = 0 )
        scan.sitemap from_index
    end

    # @return  [Array<Hash>]
    #   Issues as {Engine::Issue#to_rpc_data RPC data}.
    #
    # @private
    def issues( without = [] )
        scan.issues( without ).map(&:to_rpc_data)
    end

    # @return   [Array<Hash>]
    #   {#issues} as an array of Hashes.
    #
    # @see #issues
    def issues_as_hash( without = [] )
        scan.issues( without ).map(&:to_h)
    end

    # @param    [Integer]   starting_line
    #   Sets the starting line for the range of errors to return.
    #
    # @return   [Array<String>]
    def errors( starting_line = 0 )
        # return [] if Cuboid::UI::Output.error_buffer.empty?
        #
        # error_strings = Cuboid::UI::Output.error_buffer
        #
        # if starting_line != 0
        #     error_strings = error_strings[starting_line..-1]
        # end
        #
        # error_strings

        scan.errors( starting_line )
    end

    private

    def progress_handler( options = {} )
        options = options.my_symbolize_keys

        with    = Cuboid::RPC::Server::Instance.parse_progress_opts( options, :with )
        without = Cuboid::RPC::Server::Instance.parse_progress_opts( options, :without )

        options = {
          as_hash:    options[:as_hash],
          issues:     with.include?( :issues ),
          statistics: !without.include?( :statistics )
        }

        if with.include?( :errors )
            options[:errors] = with[:errors]
        end

        if with.include?( :sitemap )
            options[:sitemap] = with[:sitemap]
        end

        data = scan_progress( options )

        if data[:issues]
            if without[:issues].is_a? Array
                data[:issues].reject! do |i|
                    without[:issues].include?( i[:digest] || i['digest'] )
                end
            end
        end

        data
    end

    # Provides aggregated progress data.
    #
    # @param    [Hash]  opts
    #   Options about what data to include:
    # @option opts [Bool] :slaves   (true)
    #   Slave statistics.
    # @option opts [Bool] :issues   (true)
    #   Issue summaries.
    # @option opts [Bool] :statistics   (true)
    #   Master/merged statistics.
    # @option opts [Bool, Integer] :errors   (false)
    #   Logged errors. If an integer is provided it will return errors past that
    #   index.
    # @option opts [Bool, Integer] :sitemap   (false)
    #   Scan sitemap. If an integer is provided it will return entries past that
    #   index.
    # @option opts [Bool] :as_hash  (false)
    #   If set to `true`, will convert issues to hashes before returning them.
    #
    # @return    [Hash]
    #   Progress data.
    def scan_progress( opts = {} )
        include_statistics = opts[:statistics].nil? ? true : opts[:statistics]
        include_issues     = opts[:issues].nil?     ? true : opts[:issues]
        include_sitemap    = opts.include?( :sitemap ) ?
                               (opts[:sitemap] || 0) : false
        include_errors     = opts.include?( :errors ) ?
                               (opts[:errors] || 0) : false

        as_hash = opts[:as_hash] ? true : opts[:as_hash]

        data = {
          status:  scan.status,
          running: scan.running?,
          seed:    SCNR::Engine::Utilities.random_seed,
        }

        if include_issues
            data[:issues] = as_hash ? issues_as_hash : issues
        end

        if include_statistics
            data[:statistics] = scan.statistics
        end

        if include_sitemap
            data[:sitemap] = sitemap( include_sitemap )
        end

        if include_errors
            data[:errors] =
              errors( include_errors.is_a?( Integer ) ? include_errors : 0 )
        end

        data.merge( messages: scan.status_messages )
    end

    def calculate_median_progress( progress )
        arr = [
          progress[:multi][:crawler][:statistics],
          progress[:multi][:auditors].map { |_, p| p['statistics'].my_symbolize_keys }
        ].flatten
        progress[:statistics] = merge_statistics( arr )
        progress
    end

    def merge_statistics( stats )
        merged_statistics = stats.pop.dup

        return {} if !merged_statistics || merged_statistics.empty?
        return merged_statistics if stats.empty?

        merged_statistics[:current_pages] = []

        if merged_statistics[:current_page]
            merged_statistics[:current_pages] << merged_statistics[:current_page]
        end

        stats.each do |instats|
            merged_statistics[:audited_pages] += instats[:audited_pages]
        end

        sum = [
          :request_count,
          :response_count,
          :time_out_count,
          :total_responses_per_second,
          :burst_response_time_sum,
          :burst_response_count,
          :burst_responses_per_second,
          :max_concurrency
        ]

        average = [
          :burst_average_response_time,
          :total_average_response_time
        ]

        integers = [:max_concurrency, :request_count, :response_count, :time_out_count,
                    :burst_response_count]

        begin
            stats.each do |instats|
                (sum | average).each do |k|
                    merged_statistics[:http][k] += Float( instats[:http][k] )
                end

                merged_statistics[:current_pages] << instats[:current_page] if instats[:current_page]
            end

            average.each do |k|
                merged_statistics[:http][k] /= Float( stats.size + 1 )
                merged_statistics[:http][k] = Float( sprintf( '%.2f', merged_statistics[:http][k] ) )
            end

            integers.each do |k|
                merged_statistics[:http][k] = merged_statistics[:http][k].to_i
            end
        rescue => e
            ap e
            ap e.backtrace
        end

        average = [:seconds_per_job]
        sum = [
          :total_job_time, :queued_job_count, :completed_job_count, :time_out_count
        ]
        integers = [:total_job_time, :queued_job_count, :completed_job_count, :time_out_count]
        begin
            stats.each do |instats|
                (sum | average).each do |k|
                    merged_statistics[:browser_pool][k] += Float( instats[:browser_pool][k] )
                end

                merged_statistics[:current_pages] << instats[:current_page] if instats[:current_page]
            end

            average.each do |k|
                merged_statistics[:browser_pool][k] /= Float( stats.size + 1 )
                merged_statistics[:browser_pool][k] = Float( sprintf( '%.2f', merged_statistics[:browser_pool][k] ) )
            end

            integers.each do |k|
                merged_statistics[:browser_pool][k] = merged_statistics[:browser_pool][k].to_i
            end
        rescue => e
            ap e
            ap e.backtrace
        end

        merged_statistics.delete :current_page
        merged_statistics[:current_pages].uniq!

        merged_statistics
    end

    def scan
        SCNR::Application.api.scan
    end

end
