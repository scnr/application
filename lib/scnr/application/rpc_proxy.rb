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
    def progress( options = {} )
        progress_handler( options )
    end

    # @param    [Integer]   from_index
    #   Get sitemap entries after this index.
    #
    # @return   [Hash<String=>Integer>]
    def sitemap_entries( from_index = 0 )
        return {} if framework.sitemap.size <= from_index + 1

        Hash[framework.sitemap.to_a[from_index..-1] || {}]
    end

    # @return  [Array<Hash>]
    #   Issues as {Engine::Issue#to_rpc_data RPC data}.
    #
    # @private
    def issues
        SCNR::Engine::Data.issues.sort.map(&:to_rpc_data)
    end

    # @return   [Array<Hash>]
    #   {#issues} as an array of Hashes.
    #
    # @see #issues
    def issues_as_hash
        SCNR::Engine::Data.issues.sort.map(&:to_h)
    end

    # @param    [Integer]   starting_line
    #   Sets the starting line for the range of errors to return.
    #
    # @return   [Array<String>]
    def errors( starting_line = 0 )
        return [] if Cuboid::UI::Output.error_buffer.empty?

        error_strings = Cuboid::UI::Output.error_buffer

        if starting_line != 0
            error_strings = error_strings[starting_line..-1]
        end

        error_strings
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

        data = framework_progress( options )

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
    def framework_progress( opts = {} )
        include_statistics = opts[:statistics].nil? ? true : opts[:statistics]
        include_issues     = opts[:issues].nil?     ? true : opts[:issues]
        include_sitemap    = opts.include?( :sitemap ) ?
                               (opts[:sitemap] || 0) : false
        include_errors     = opts.include?( :errors ) ?
                               (opts[:errors] || 0) : false

        as_hash = opts[:as_hash] ? true : opts[:as_hash]

        data = {
          status: framework.status,
          busy:   framework.running?,
          seed:   SCNR::Engine::Utilities.random_seed,
        }

        if include_issues
            data[:issues] = as_hash ? issues_as_hash : issues
        end

        if include_statistics
            data[:statistics] = framework.statistics
        end

        if include_sitemap
            data[:sitemap] = sitemap_entries( include_sitemap )
        end

        if include_errors
            data[:errors] =
              errors( include_errors.is_a?( Integer ) ? include_errors : 0 )
        end

        data.merge( messages: framework.status_messages )
    end

    def framework
        SCNR::Application.framework
    end

end
