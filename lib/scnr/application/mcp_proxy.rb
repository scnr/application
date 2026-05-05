require 'mcp'
require 'json'

# json-schema (transitive dep of `mcp` for MCP::Tool input/output
# schema validation) emits a one-time deprecation notice the first
# time it validates anything unless we opt out of its MultiJson
# backend up-front. Has to run BEFORE the MCP::Tool subclasses below
# define their input_schemas — otherwise the warning fires at class-
# definition time. Cuboid's MCP server file does the same on its
# load path.
require 'json-schema'
JSON::Validator.use_multi_json = false

module SCNR
class Application

# MCP service handler — analog of `RESTProxy` but exposing scan
# operations as MCP tools instead of Sinatra routes. Mounted via
# `mcp_service_for :scan, MCPProxy` on the Application class.
#
# Each tool's `call` receives a `server_context:` Hash from
# `Cuboid::MCP::Server::Dispatcher` containing `:instance` (the
# resolved RPC client for the engine instance the request is targeting),
# `:instance_id`, and `:service`. Tool methods drive the engine via
# `instance.scan.<rpc method>` — same pattern as
# `instance_for(...) { |instance| instance.scan.foo }` in `RESTProxy`.
module MCPProxy

    # Helper: every tool wraps its body in `instrumented_call`. Catches
    # raw exceptions from the underlying RPC client and returns them as
    # an MCP error response so a misbehaving engine doesn't take the
    # whole MCP server down.
    def self.instrumented_call( server_context )
        instance = server_context[:instance]
        result = yield( instance )
        ::MCP::Tool::Response.new(
            [{ type: 'text', text: result.is_a?(String) ? result : JSON.pretty_generate(result) }]
        )
    rescue => e
        ::MCP::Tool::Response.new(
            [{ type: 'text', text: "error: #{e.class}: #{e.message}" }],
            error: true
        )
    end

    # ── Read-only tools ──────────────────────────────────────────

    # Engine progress — mirrors REST `/progress`: status + statistics +
    # issues + errors + sitemap by default. Caller passes back what
    # it has already seen via `issues_since` / `errors_since` /
    # `sitemap_since` to get only deltas; high-cadence pollers can opt
    # out of any block via `without_*: true`.
    class Progress < ::MCP::Tool
        tool_name   'progress'
        description 'Returns the current scan: status + statistics + issues + errors + sitemap. Pass `issues_since` (digests), `errors_since` (offset), `sitemap_since` (offset) to receive only deltas you have not already seen. Use `without_issues / without_errors / without_sitemap / without_statistics: true` to drop a block entirely.'
        input_schema(
            properties: {
                issues_since: {
                    type:  'array',
                    items: { type: ['integer', 'string'] },
                    description: 'Digests of issues already seen (32-bit ints, but numeric strings are accepted too). When present the `issues` field contains only the new ones.'
                },
                errors_since: {
                    type:    'integer',
                    minimum: 0,
                    description: 'Errors offset. When present the response includes only errors past this index.'
                },
                sitemap_since: {
                    type:    'integer',
                    minimum: 0,
                    description: 'Sitemap offset. When present the response includes only sitemap entries past this index.'
                },
                without_issues:     { type: 'boolean', default: false, description: 'Skip the `issues` field entirely (overrides `issues_since`).' },
                without_errors:     { type: 'boolean', default: false, description: 'Skip the `errors` field entirely (overrides `errors_since`).' },
                without_sitemap:    { type: 'boolean', default: false, description: 'Skip the `sitemap` field entirely (overrides `sitemap_since`).' },
                without_statistics: { type: 'boolean', default: false, description: 'Omit the (large) `statistics` block from the response — useful for high-cadence pollers that only need status + deltas.' }
            }
        )

        def self.call( server_context:,
                       issues_since: nil, errors_since: 0, sitemap_since: 0,
                       without_issues: false, without_errors: false,
                       without_sitemap: false, without_statistics: false, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                with    = []
                without = []

                unless without_issues
                    with << :issues
                    without << { issues: issues_since.map( &:to_i ) } if issues_since
                end

                with << { errors:  errors_since.to_i  } unless without_errors
                with << { sitemap: sitemap_since.to_i } unless without_sitemap

                without << :statistics if without_statistics

                opts = {}
                opts[:with]    = with    if with.any?
                opts[:without] = without if without.any?

                instance.scan.progress(opts)
            end
        end
    end

    # Full report (issues + sitemap + statistics) as a Hash. Useful for
    # an MCP client that wants to ingest the whole result set in one go.
    class Report < ::MCP::Tool
        tool_name   'report'
        description 'Returns the full scan report (issues, sitemap, statistics) as JSON.'
        input_schema(properties: {})

        def self.call( server_context:, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                instance.scan.generate_report_as_hash
            end
        end
    end

    # Sitemap (URLs the engine has crawled), optionally paginated from
    # `from_index` for callers tailing long runs.
    class Sitemap < ::MCP::Tool
        tool_name   'sitemap'
        description 'Returns the sitemap (crawled URLs) discovered so far. Pass `from_index` to page.'
        input_schema(
            properties: {
                from_index: { type: 'integer', minimum: 0, default: 0 }
            }
        )

        def self.call( from_index: 0, server_context:, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                instance.scan.sitemap( from_index )
            end
        end
    end

    # Issues found, optionally filtering out digests the caller has
    # already seen — same shape as the RESTProxy progress payload's
    # `without: { issues: [digests] }`. Engine digests are 32-bit
    # `xxh32` integers; JSON-RPC clients commonly stringify large
    # numbers, so the schema accepts integers *or* strings and we
    # coerce to Integer before handing them to the engine — without
    # the coercion the engine's `==` comparison silently misses every
    # filter and re-emits the full set on each call.
    class Issues < ::MCP::Tool
        tool_name   'issues'
        description 'Returns issues found so far. Pass `without` (array of digests already seen, integers or numeric strings) to skip those.'
        input_schema(
            properties: {
                without: {
                    type:  'array',
                    items: { type: ['integer', 'string'] }
                }
            }
        )

        def self.call( server_context:, without: [], ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                instance.scan.issues_as_hash( without.map( &:to_i ) )
            end
        end
    end

    # Errors emitted by the engine, optionally tail-from `index` for
    # callers that want incremental polling.
    class Errors < ::MCP::Tool
        tool_name   'errors'
        description 'Returns engine error messages. Pass `index` to get errors from that offset onwards.'
        input_schema(
            properties: {
                index: { type: 'integer', minimum: 0, default: 0 }
            }
        )

        def self.call( server_context:, index: 0, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                instance.scan.errors( index )
            end
        end
    end

    # ── Mutator tools ────────────────────────────────────────────
    # Pause/resume are safe and reversible. Abort terminates the run —
    # whoever can call it controls scan lifecycle, so once auth lands
    # this is the obvious gate point.

    class Pause < ::MCP::Tool
        tool_name   'pause'
        description 'Pause the running scan (use `resume` to continue).'
        input_schema(properties: {})

        def self.call( server_context:, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                instance.scan.pause!
                'paused'
            end
        end
    end

    class Resume < ::MCP::Tool
        tool_name   'resume'
        description 'Resume a paused scan.'
        input_schema(properties: {})

        def self.call( server_context:, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                instance.scan.resume!
                'resumed'
            end
        end
    end

    class Abort < ::MCP::Tool
        tool_name   'abort'
        description 'Abort the scan. Terminates the run — irreversible. Use `pause` if you might want to resume.'
        input_schema(properties: {})

        def self.call( server_context:, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                instance.scan.abort!
                'aborted'
            end
        end
    end

    TOOLS = [
        Progress,
        Report,
        Sitemap,
        Issues,
        Errors,
        Pause,
        Resume,
        Abort
    ].freeze

    # Cuboid::MCP::Server::Dispatcher reads `handler.tools` to populate
    # MCP::Server.new(tools: …).
    def self.tools
        TOOLS
    end

end

end
end
