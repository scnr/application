require 'mcp'
require 'json'

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
            true   # is_error
        )
    end

    # ── Read-only tools ──────────────────────────────────────────

    # Engine progress — issues so far, sitemap size, errors, statistics.
    # Mirrors `GET /progress` in RESTProxy but unbatched (callers can
    # ask repeatedly; we don't track seen-state per session here).
    class Progress < ::MCP::Tool
        tool_name   'progress'
        description 'Returns the current scan progress: status, issues, errors, sitemap size, statistics.'
        input_schema(properties: {})

        def self.call( server_context:, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                instance.scan.progress
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
    # `without: { issues: [digests] }`.
    class Issues < ::MCP::Tool
        tool_name   'issues'
        description 'Returns issues found so far. Pass `without` (array of digest strings) to skip those already seen.'
        input_schema(
            properties: {
                without: {
                    type:  'array',
                    items: { type: 'string' }
                }
            }
        )

        def self.call( server_context:, without: [], ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                instance.scan.issues_as_hash( without )
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
