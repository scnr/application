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
    # whole MCP server down. When the tool body returns a Hash/Array,
    # the response also carries `structuredContent` matching the
    # tool's `output_schema`; clients that opted in to typed outputs
    # consume that, clients that haven't keep using the JSON-encoded
    # `text` content.
    def self.instrumented_call( server_context )
        instance = server_context[:instance]
        result = yield( instance )

        if result.is_a?( String )
            ::MCP::Tool::Response.new(
                [{ type: 'text', text: result }]
            )
        else
            ::MCP::Tool::Response.new(
                [{ type: 'text', text: JSON.pretty_generate( result ) }],
                structured_content: result
            )
        end
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
        description <<~DESC.strip
            Returns the current scan: `status` + `statistics` + `issues` + `errors` + `sitemap` + `messages`.

            Two delta-arg shapes (different on purpose — they read different output blocks):
              * `*_seen`  — array of issue digests you have already received; the corresponding output field returns only items NOT in that set. The digest of an issue is the **key** under which it appears in the returned `issues` hash.
              * `*_since` — integer offset; the corresponding output field returns only items past that index.

            Drop a whole block by passing `without_*: true` (overrides any matching `*_seen` / `*_since`).
        DESC
        input_schema(
            properties: {
                issues_seen: {
                    type:  'array',
                    items: { type: ['integer', 'string'] },
                    description: 'Issue digests already received — the response\'s `issues` hash will exclude any with these digests as keys. Engine digests are 32-bit xxh32 integers; numeric strings are accepted too and coerced.'
                },
                errors_since: {
                    type:    'integer',
                    minimum: 0,
                    description: 'Errors offset (number of error entries already received). The response\'s `errors` array starts past this index.'
                },
                sitemap_since: {
                    type:    'integer',
                    minimum: 0,
                    description: 'Sitemap offset (number of sitemap entries already received). The response\'s `sitemap` array starts past this index.'
                },
                without_issues:     { type: 'boolean', default: false, description: 'Skip the `issues` field entirely (overrides `issues_seen`).' },
                without_errors:     { type: 'boolean', default: false, description: 'Skip the `errors` field entirely (overrides `errors_since`).' },
                without_sitemap:    { type: 'boolean', default: false, description: 'Skip the `sitemap` field entirely (overrides `sitemap_since`).' },
                without_statistics: { type: 'boolean', default: false, description: 'Omit the (large) `statistics` block from the response — useful for high-cadence pollers that only need status + deltas.' }
            }
        )
        output_schema(
            properties: {
                status:     { type: 'string', description: 'Scan lifecycle state. See `spectre://glossary` for the value enum.' },
                running:    { type: 'boolean', description: 'True while the engine is actively crawling/auditing; false once it has settled into `done` / `aborted` / `paused`.' },
                seed:       { type: ['string', 'null'], description: 'Engine RNG seed for the run — present so a snapshot/replay can reproduce mutation values.' },
                statistics: { type: 'object', description: 'Per-scan accounting (HTTP request counts, browser-cluster status, RAM/CPU). Absent when `without_statistics: true`.' },
                issues:     { type: 'object', description: 'Issues hash keyed by digest. Each value is an issue record (vector, severity, name, description, proof). Filtered by `issues_seen`.' },
                errors:     { type: 'array', items: { type: 'string' }, description: 'Engine error messages from `errors_since` onwards.' },
                sitemap:    { type: 'object', description: 'Crawled URLs from `sitemap_since` onwards (URL → HTTP status code).' },
                messages:   { type: 'array', items: { type: 'string' }, description: 'Human-readable status-message log from the engine.' }
            },
            required: ['status']
        )

        def self.call( server_context:,
                       issues_seen: nil, errors_since: 0, sitemap_since: 0,
                       without_issues: false, without_errors: false,
                       without_sitemap: false, without_statistics: false, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                with    = []
                without = []

                unless without_issues
                    with << :issues
                    without << { issues: issues_seen.map( &:to_i ) } if issues_seen
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
        description 'Returns the full scan report (issues, sitemap, statistics, plugins) as JSON. Heavier than `scan_progress`; use for the final post-mortem.'
        input_schema(properties: {})
        output_schema(
            properties: {
                issues:     { type: 'object', description: 'Issues hash keyed by digest.' },
                sitemap:    { type: 'object', description: 'All crawled URLs.' },
                statistics: { type: 'object', description: 'Final per-scan accounting.' },
                plugins:    { type: 'object', description: 'Per-plugin output blocks.' }
            }
        )

        def self.call( server_context:, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                instance.scan.generate_report_as_hash
            end
        end
    end

    # Sitemap (URLs the engine has crawled), optionally tailed from
    # `sitemap_since` for callers polling long runs.
    class Sitemap < ::MCP::Tool
        tool_name   'sitemap'
        description 'Returns the sitemap (crawled URLs) discovered so far. Pass `sitemap_since` (number of entries already received) to get only the tail past that offset.'
        input_schema(
            properties: {
                sitemap_since: {
                    type:    'integer',
                    minimum: 0,
                    default: 0,
                    description: 'Sitemap offset (number of sitemap entries already received). The response starts past this index.'
                }
            }
        )

        output_schema(
            properties: {
                sitemap: {
                    type:        'object',
                    description: 'Crawled URLs as a map of URL → HTTP status code. The map is ordered by discovery time; `sitemap_since: N` returns only the tail past entry N.'
                }
            },
            required: ['sitemap']
        )

        def self.call( sitemap_since: 0, server_context:, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                { sitemap: instance.scan.sitemap( sitemap_since ) }
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
        description 'Returns the issues hash discovered so far, keyed by digest. Pass `issues_seen` (array of digests already received) to exclude those. Engine digests are 32-bit xxh32 integers; numeric strings are accepted too.'
        input_schema(
            properties: {
                issues_seen: {
                    type:  'array',
                    items: { type: ['integer', 'string'] },
                    description: 'Issue digests already received — the returned hash excludes any with these digests as keys.'
                }
            }
        )

        output_schema(
            properties: {
                issues: {
                    type:        'object',
                    description: 'Issues hash keyed by digest. Each value is the issue record (vector, severity, name, description, proof). See `spectre://glossary` for what an issue carries.'
                }
            },
            required: ['issues']
        )

        def self.call( server_context:, issues_seen: [], ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                { issues: instance.scan.issues_as_hash( issues_seen.map( &:to_i ) ) }
            end
        end
    end

    # Errors emitted by the engine, optionally tailed from
    # `errors_since` for callers polling long runs.
    class Errors < ::MCP::Tool
        tool_name   'errors'
        description 'Returns engine error messages. Pass `errors_since` (number of error entries already received) to get only the tail past that offset.'
        input_schema(
            properties: {
                errors_since: {
                    type:    'integer',
                    minimum: 0,
                    default: 0,
                    description: 'Errors offset (number of error entries already received). The response starts past this index.'
                }
            }
        )

        output_schema(
            properties: {
                errors: {
                    type:        'array',
                    items:       { type: 'string' },
                    description: 'Engine error messages in chronological order, starting at `errors_since`.'
                }
            },
            required: ['errors']
        )

        def self.call( server_context:, errors_since: 0, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                { errors: instance.scan.errors( errors_since ) }
            end
        end
    end

    # ── Mutator tools ────────────────────────────────────────────
    # Pause/resume are safe and reversible. Abort terminates the run —
    # whoever can call it controls scan lifecycle, so once auth lands
    # this is the obvious gate point.

    LIFECYCLE_OUTPUT_SCHEMA = {
        properties: {
            status: {
                type:        'string',
                enum:        ['paused', 'resumed', 'aborted'],
                description: 'New scan lifecycle state after the call.'
            }
        },
        required: ['status']
    }.freeze

    class Pause < ::MCP::Tool
        tool_name   'pause'
        description 'Pause the running scan. Precondition: the scan must currently be running. Reverse with `scan_resume`.'
        input_schema(properties: {})
        output_schema(LIFECYCLE_OUTPUT_SCHEMA)

        def self.call( server_context:, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                instance.scan.pause!
                { status: 'paused' }
            end
        end
    end

    class Resume < ::MCP::Tool
        tool_name   'resume'
        description 'Resume a paused scan. Precondition: the scan must have been paused via `scan_pause`.'
        input_schema(properties: {})
        output_schema(LIFECYCLE_OUTPUT_SCHEMA)

        def self.call( server_context:, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                instance.scan.resume!
                { status: 'resumed' }
            end
        end
    end

    class Abort < ::MCP::Tool
        tool_name   'abort'
        description 'Abort the scan. Terminates the run — irreversible. Use `scan_pause` instead if you might want to resume.'
        input_schema(properties: {})
        output_schema(LIFECYCLE_OUTPUT_SCHEMA)

        def self.call( server_context:, ** )
            MCPProxy.instrumented_call(server_context) do |instance|
                instance.scan.abort!
                { status: 'aborted' }
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

    # ── MCP resources ────────────────────────────────────────────
    # Static, brand-namespaced documents an LLM client can pull via
    # `resources/list` + `resources/read`. The point is to make the
    # MCP surface self-sufficient — without these the only way to
    # know what `spawn_instance.options` accepts, or what an "issue"
    # actually means in this product, is to read the source.

    GLOSSARY = <<~MARKDOWN
        # Spectre — MCP glossary

        * **issue** — a finding produced by a check (XSS, SQLi, etc.).
          Each one has a `digest` (32-bit xxh32 integer key in the
          returned `issues` hash), a `vector` (where it was found —
          element type, input name, action URL), `severity`, `name`,
          `description`, and `proof` of the engine's payload/response
          evidence. Pass digests back as `issues_seen` to filter
          already-known findings out of subsequent polls.
        * **digest** — the deterministic 32-bit hash of an issue. The
          *key* under which the issue appears in the returned hash;
          NOT a field nested inside the value.
        * **status** — scan lifecycle. Common values: `:preparing`,
          `:scanning`, `:auditing`, `:paused`, `:done`, `:aborted`,
          `:cleanup`. Treat anything other than `:done` / `:aborted`
          as still in flight.
        * **sitemap** — array of crawled URLs. Order is the order the
          engine discovered them, so `sitemap_since: N` returns only
          the tail past the Nth entry.
        * **statistics** — large per-scan accounting block (HTTP request
          counts, browser-cluster status, audit progress, RAM/CPU,
          etc.). Useful for dashboards, noisy for poll loops — drop
          with `without_statistics: true`.
        * **check** — a vulnerability test (e.g. `xss`, `sql_injection`,
          `path_traversal`). Configured via `options.checks` — either
          a list of names or `*` for all.
        * **scope** — what the engine is allowed to crawl/audit.
          Bounds it via `options.scope`: `page_limit`, `directory_depth_limit`,
          `dom_depth_limit`, `include_subdomains`, etc.
        * **audit.elements** — which input surfaces are tested:
          `[:links, :forms, :cookies, :headers, :nested_cookies,
          :link_templates, :ui_inputs, :ui_forms, :jsons, :xmls]`.
    MARKDOWN

    OPTIONS_REFERENCE = <<~MARKDOWN
        # Spectre — `spawn_instance.options` reference

        Forwarded to `SCNR::Engine::Options#set`. Keys (Hash, all optional):

        * **`url`** *(string, required for a real scan)* — the target.
          Anything reachable via HTTP(S).
        * **`scope`** *(object)* — limits. Useful keys:
          - `page_limit` *(int)* — max pages to crawl.
          - `directory_depth_limit` *(int)* — directory hops from `url`.
          - `dom_depth_limit` *(int)* — DOM-tree depth in JS-rendered pages.
          - `include_subdomains` *(bool)* — follow subdomains (default false).
          - `exclude_path_patterns` *(string[])* — regex patterns; matching URLs
             are skipped.
        * **`audit`** *(object)* —
          - `elements` *(symbol[])* — which input surfaces to audit. See
             glossary entry "audit.elements". Omit to audit them all
             (CLI default).
        * **`checks`** *(string[])* — check names to load, or `["*"]` for
          all (CLI default). Pass a narrower list (e.g.
          `["xss*", "sql_injection*"]`) to restrict.
        * **`http`** *(object)* —
          - `request_concurrency` *(int)* — parallel HTTP requests.
          - `request_timeout` *(int, ms)* — per-request timeout.
        * **`browser_cluster`** *(object)* — DOM/JS audit settings:
          - `pool_size` *(int)* — number of browsers.
          - `job_timeout` *(int, sec)* — per-page browser job timeout.
        * **`plugins`** *(object)* — plugin name → its option hash.
        * **`authorized_by`** *(string)* — e-mail address of the authorising
          person, added to outbound requests' `From` header.

        Pass an empty `{}` only when also setting `start: false`. To run a
        scan, `url` is the minimum.
    MARKDOWN

    # Same coverage as the `spectre_scan` CLI default — all element
    # kinds, all checks, default plugins, no scope cap. Set
    # `scope.page_limit` (or other `scope.*` knobs) explicitly if you
    # want the run bounded.
    QUICK_SCAN_PRESET = {
        url:     '<TARGET URL>',
        checks:  ['*'],
        plugins: ['defaults/*']
    }.freeze

    RESOURCES = [
        ::MCP::Resource.new(
            uri:         'spectre://glossary',
            name:        'Spectre glossary',
            description: 'Domain terms the MCP surface uses (issue, digest, status, sitemap, statistics, check, scope, audit.elements). Read this once before driving a scan.',
            mime_type:   'text/markdown'
        ),
        ::MCP::Resource.new(
            uri:         'spectre://options/reference',
            name:        'spawn_instance.options reference',
            description: 'Concrete keys accepted by `spawn_instance.options` (url, scope, audit, checks, http, browser_cluster, plugins, authorized_by) with allowed values and quick-scan defaults.',
            mime_type:   'text/markdown'
        ),
        ::MCP::Resource.new(
            uri:         'spectre://option-presets/quick-scan',
            name:        'Quick-scan options preset',
            description: 'JSON template for `spawn_instance.options` that mirrors the `spectre_scan` CLI default — all element kinds, all checks, default plugins, no scope cap. Replace `<TARGET URL>`. Add `scope.page_limit` etc. yourself when you want a bounded run.',
            mime_type:   'application/json'
        )
    ].freeze

    def self.resources
        RESOURCES
    end

    def self.read_resource( uri )
        case uri
        when 'spectre://glossary'
            ::MCP::Resource::TextContents.new(
                uri: uri, mime_type: 'text/markdown', text: GLOSSARY
            )
        when 'spectre://options/reference'
            ::MCP::Resource::TextContents.new(
                uri: uri, mime_type: 'text/markdown', text: OPTIONS_REFERENCE
            )
        when 'spectre://option-presets/quick-scan'
            ::MCP::Resource::TextContents.new(
                uri: uri, mime_type: 'application/json',
                text: JSON.pretty_generate( QUICK_SCAN_PRESET )
            )
        end
    end

    # ── MCP prompts ──────────────────────────────────────────────
    # Canned conversational workflows. The client (Claude Desktop,
    # etc.) surfaces these as one-click templates the user can fire.

    class QuickScanPrompt < ::MCP::Prompt
        prompt_name 'quick_scan'
        description 'Run a Spectre scan using the quick-scan preset (all elements, all checks, default plugins), poll progress every 5 s, and report issues one line per finding when status: done. Optional args narrow checks, cap the crawl, identify the operator, or splice in extra options.'
        arguments [
            ::MCP::Prompt::Argument.new(
                name:        'url',
                description: 'Target URL (http:// or https://). Must be a host the operator is authorised to scan.',
                required:    true
            ),
            ::MCP::Prompt::Argument.new(
                name:        'page_limit',
                description: 'Cap on crawled pages (positive integer). Without it a real site can take hours; 30 = smoke test, 200 = representative, omit for full audit.',
                required:    false
            ),
            ::MCP::Prompt::Argument.new(
                name:        'checks',
                description: 'Comma-separated list of check globs to load instead of the default `*`. Examples: `xss*`, `sql_injection*,xss*`. Leave empty to load every check (CLI default).',
                required:    false
            ),
            ::MCP::Prompt::Argument.new(
                name:        'authorized_by',
                description: 'Operator email — added to outbound HTTP `From` headers so target-site admins can identify the scan. Polite on third-party targets.',
                required:    false
            ),
            ::MCP::Prompt::Argument.new(
                name:        'extra_options',
                description: 'JSON object merged into `options` after the preset. Use for anything not covered by the named args (e.g. `{"scope":{"include_subdomains":true},"http":{"request_concurrency":20}}`). Read `spectre://options/reference` for valid keys.',
                required:    false
            )
        ]

        def self.template( args, server_context: nil )
            url           = args[:url]            || args['url']
            page_limit    = args[:page_limit]     || args['page_limit']
            checks        = args[:checks]         || args['checks']
            authorized_by = args[:authorized_by]  || args['authorized_by']
            extra_options = args[:extra_options]  || args['extra_options']

            overrides = []
            overrides << "  - Set `scope.page_limit` to #{page_limit}." if page_limit && !page_limit.to_s.empty?
            overrides << "  - Replace `checks` with #{checks.to_s.split(',').map(&:strip).reject(&:empty?).inspect}." if checks && !checks.to_s.empty?
            overrides << "  - Set `authorized_by` to #{authorized_by.inspect}." if authorized_by && !authorized_by.to_s.empty?
            overrides << "  - Deep-merge the following JSON object into `options` (caller-supplied, treat as raw options): `#{extra_options}`. Read `spectre://options/reference` for valid keys before merging." if extra_options && !extra_options.to_s.empty?

            override_block = overrides.any? ? "\nApply these overrides on top of the preset before calling `spawn_instance`:\n#{overrides.join("\n")}\n" : ''

            ::MCP::Prompt::Result.new(
                description: 'Quick Spectre scan + summary',
                messages: [
                    ::MCP::Prompt::Message.new(
                        role:    'user',
                        content: ::MCP::Content::Text.new(
                            <<~PROMPT
                                Run a Spectre scan against #{url} via this MCP server.

                                1. Read `spectre://options/reference` once if you don't already know the options shape.
                                2. Build `options` from `spectre://option-presets/quick-scan`, substituting the URL above.
                                #{override_block}
                                3. Call `spawn_instance` with `start: true` and the resulting `options`.
                                4. Poll `scan_progress(instance_id, without_statistics: true)` every 5 seconds. Use `errors_since` / `sitemap_since` / `issues_seen` to fetch only deltas after the first poll.
                                5. When `status` is `done` or `aborted`, call `scan_issues(instance_id)` and summarise — one line per finding: `[<check>] <severity> — <vector.action> (<input name>)`.
                                6. Call `kill_instance(instance_id)` once you've reported.
                            PROMPT
                        )
                    )
                ]
            )
        end
    end

    PROMPTS = [ QuickScanPrompt ].freeze

    def self.prompts
        PROMPTS
    end

end

end
end
