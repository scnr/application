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

    # ── App-level catalog tool ───────────────────────────────────
    # Registered at the top-level `/mcp` endpoint via
    # `Cuboid::Application.mcp_app_tool` (see `lib/scnr/application.rb`)
    # so a client can enumerate checks WITHOUT needing to spawn an
    # instance first.
    class ListChecks < ::MCP::Tool
        tool_name   'list_checks'
        description 'Returns the catalog of vulnerability checks the engine ships — shortname, severity, elements audited, tags, description. Pass the resulting `shortname`s back as `spawn_instance.options.checks` to scope a run; if you don\'t pass `checks` the engine loads all of them.'

        input_schema(
            properties: {
                severities: {
                    type:        'array',
                    items:       { type: 'string', enum: %w(high medium low informational none) },
                    description: 'Optional filter — return only checks at these severity levels.'
                },
                tags: {
                    type:        'array',
                    items:       { type: 'string' },
                    description: 'Optional filter — return only checks tagged with at least one of these tags (e.g. `xss`, `sqli`, `injection`).'
                }
            }
        )

        output_schema(
            properties: {
                checks: {
                    type:        'array',
                    description: 'Sorted high-severity-first, then by name.',
                    items: {
                        type: 'object',
                        properties: {
                            shortname:   { type: 'string', description: 'Pass this in `options.checks`.' },
                            name:        { type: 'string', description: 'Human-readable label.' },
                            description: { type: 'string', description: 'What the check does, in prose.' },
                            severity:    { type: 'string', description: 'one of `high`, `medium`, `low`, `informational`, `none`.' },
                            elements:    { type: 'array', items: { type: 'string' }, description: 'Element types this check audits (links / forms / cookies / headers / …).' },
                            tags:        { type: 'array', items: { type: 'string' } },
                            platforms:   { type: 'array', items: { type: 'string' }, description: 'Platforms this check is relevant to (e.g. `php`, `mysql`); empty when platform-agnostic.' }
                        }
                    }
                }
            },
            required: ['checks']
        )

        SEVERITY_ORDER = %w(high medium low informational none).freeze

        def self.call( severities: nil, tags: nil, ** )
            MCPProxy.instrumented_call({}) do |_instance|
                mgr = ::SCNR::Engine::Framework.unsafe.checks
                mgr.load_all

                wanted_severities = severities && Array(severities).map(&:to_s).to_set
                wanted_tags       = tags       && Array(tags).map(&:to_s).to_set

                rows = mgr.values.map do |klass|
                    info = klass.info || {}
                    raw_tags = Array(info[:tags]) | Array(info.dig(:issue, :tags))
                    {
                        shortname:   klass.shortname.to_s,
                        name:        info[:name].to_s.strip,
                        description: info[:description].to_s.strip,
                        severity:    info.dig(:issue, :severity).to_s,
                        elements:    Array(info[:elements]).map(&:to_s),
                        tags:        raw_tags.map(&:to_s),
                        platforms:   Array(info[:platforms]).map(&:to_s)
                    }
                end

                if wanted_severities
                    rows.select! { |r| wanted_severities.include?( r[:severity] ) }
                end
                if wanted_tags
                    rows.select! { |r| (r[:tags].to_set & wanted_tags).any? }
                end

                rows.sort_by! do |r|
                    [SEVERITY_ORDER.index( r[:severity] ) || 99, r[:name]]
                end

                { checks: rows }
            end
        end
    end

    # Plugin catalog — mirror of `list_checks`. Lets a client see
    # which plugins are loadable without spawning an instance, and
    # what config keys each one accepts (mainly relevant for the
    # `plugins: { name: { ...config... } }` hash shape on
    # spawn_instance.options).
    class ListPlugins < ::MCP::Tool
        tool_name   'list_plugins'
        description 'Returns the catalog of plugins the engine ships — shortname, name, description, whether it auto-loads by default, and any per-plugin config options. Pass the resulting `shortname`s back as `spawn_instance.options.plugins` (array form) or `{ "<shortname>": { <config> } }` (hash form, with config keys drawn from the `options` array). Plugins with `default: true` are merged in automatically by the application even if you don\'t list them.'

        # Plugins meant for programmatic auto-attachment (the MCP
        # server attaches `live` itself when the session supports
        # notifications) — never returned by list_plugins because
        # passing them in `spawn_instance.options.plugins` would be
        # at best redundant, at worst breaks the auto-attach contract.
        EXCLUDED_SHORTNAMES = %w(live).to_set.freeze

        input_schema(properties: {})

        output_schema(
            properties: {
                plugins: {
                    type:        'array',
                    description: 'Sorted: default-loading plugins first, then alphabetical by name.',
                    items: {
                        type: 'object',
                        properties: {
                            shortname:   { type: 'string', description: 'Pass this in `options.plugins`.' },
                            name:        { type: 'string', description: 'Human-readable label.' },
                            description: { type: 'string', description: 'What the plugin does, in prose.' },
                            author:      { type: 'array', items: { type: 'string' }, description: 'Author(s).' },
                            version:     { type: 'string', description: 'Plugin version (independent of engine version).' },
                            priority:    { type: 'integer', description: 'Execution priority group — lowest runs first; nil if unset.' },
                            tags:        { type: 'array', items: { type: 'string' }, description: 'Free-form tags (when the plugin declares any).' },
                            default:     { type: 'boolean', description: 'true if the application auto-merges this plugin into every scan.' },
                            options: {
                                type:        'array',
                                description: 'Per-plugin config keys. Pass values via the hash-form `plugins: { <shortname>: { <option-name>: <value>, ... } }`.',
                                items: {
                                    type: 'object',
                                    properties: {
                                        name:        { type: 'string' },
                                        type:        { type: 'string', description: 'string / int / bool / url / port / address / path / multiple_choice / json / object.' },
                                        description: { type: 'string' },
                                        required:    { type: 'boolean' },
                                        default:     { description: 'Default value, if any.' },
                                        choices:     { type: 'array', items: { type: 'string' }, description: 'Allowed values when type is `multiple_choice`.' }
                                    }
                                }
                            }
                        }
                    }
                }
            },
            required: ['plugins']
        )

        def self.call( ** )
            MCPProxy.instrumented_call({}) do |_instance|
                mgr = ::SCNR::Engine::Framework.unsafe.plugins
                mgr.load_all

                default_set = mgr.default.map(&:to_s).to_set

                rows = mgr.values.map do |klass|
                    shortname = klass.shortname.to_s
                    next if EXCLUDED_SHORTNAMES.include?( shortname )

                    info = klass.info || {}
                    {
                        shortname:   shortname,
                        name:        info[:name].to_s.strip,
                        description: info[:description].to_s.strip,
                        author:      Array(info[:author]).map(&:to_s),
                        version:     info[:version].to_s,
                        priority:    info[:priority],
                        tags:        Array(info[:tags]).map(&:to_s),
                        default:     default_set.include?( shortname ),
                        options:     Array(info[:options]).map { |opt|
                            row = {
                                name:        opt.name.to_s,
                                type:        opt.type.to_s,
                                description: opt.description.to_s,
                                required:    opt.required?,
                                default:     opt.default
                            }
                            row[:choices] = Array(opt.choices).map(&:to_s) if opt.respond_to?( :choices ) && opt.choices
                            row
                        }
                    }
                end.compact

                rows.sort_by! { |r| [r[:default] ? 0 : 1, r[:name]] }

                { plugins: rows }
            end
        end
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
          a list of names or `*` for all. Call the `list_checks`
          tool for the full catalog (shortname, severity, elements,
          tags, description); the response's `shortname`s plug
          straight into `options.checks`.
        * **scope** — what the engine is allowed to crawl/audit.
          Bounds it via `options.scope`: `page_limit`, `directory_depth_limit`,
          `dom_depth_limit`, `include_subdomains`, etc.
        * **audit.elements** — which input surfaces are tested:
          `[:links, :forms, :cookies, :headers, :nested_cookies,
          :link_templates, :ui_inputs, :ui_forms, :jsons, :xmls]`.
    MARKDOWN

    OPTIONS_REFERENCE = <<~MARKDOWN
        # `options` reference
        
        The full option surface accepted by `spawn_instance.options`.
        Hash, all keys optional.
        
        The bare engine defaults leave every audit element OFF and every
        check unloaded; only `bin/spectre_scan` (and the option presets)
        enable them. If you build options from scratch, ship at least
        `url`, `audit.elements` (or per-element booleans), and `checks`,
        or use `spectre://option-presets/quick-scan`.
        
        ## Wire shape
        
        This is what gets sent as `spawn_instance.options` — a single
        nested JSON object, all groups optional, every leaf documented
        further down. Each
        top-level key is its own JSON object (`audit`, `scope`, `http`,
        `dom`, `device`, `input`, `session`, `timeout`); the
        top-level scalars (`url`, `checks`, `plugins`, `authorized_by`,
        `no_fingerprinting`) sit alongside.
        
        ```json
        {
          "url":     "http://example.com/",
          "checks":  ["*"],
          "plugins": {},
          "authorized_by":     "you@example.com",
          "no_fingerprinting": false,
        
          "audit": {
            "elements":             ["links","forms","cookies","headers","ui_inputs","ui_forms","jsons","xmls"],
            "link_templates":       [],
            "parameter_values":     true,
            "parameter_names":      false,
            "with_raw_payloads":    false,
            "with_extra_parameter": false,
            "with_both_http_methods": false,
            "cookies_extensively":  false,
            "mode":                 "moderate",
            "exclude_vector_patterns": [],
            "include_vector_patterns": []
          },
        
          "scope": {
            "page_limit":                  50,
            "depth_limit":                 10,
            "directory_depth_limit":       10,
            "dom_depth_limit":             4,
            "dom_event_limit":             500,
            "dom_event_inheritance_limit": 500,
            "include_subdomains":          false,
            "https_only":                  false,
            "include_path_patterns":       [],
            "exclude_path_patterns":       [],
            "exclude_content_patterns":    [],
            "exclude_file_extensions":     ["gif","mp4","pdf","js","css"],
            "exclude_binaries":            false,
            "restrict_paths":              [],
            "extend_paths":                [],
            "redundant_path_patterns":     {},
            "auto_redundant_paths":        15,
            "url_rewrites":                {}
          },
        
          "http": {
            "request_concurrency":     10,
            "request_queue_size":      50,
            "request_timeout":         20000,
            "request_redirect_limit":  5,
            "response_max_size":       500000,
            "request_headers":         {},
            "cookies":                 {},
            "cookie_jar_filepath":     "/path/to/cookies.txt",
            "cookie_string":           "name=value; Path=/",
            "authentication_username": "user",
            "authentication_password": "pass",
            "authentication_type":     "auto",
            "proxy":                   "host:port",
            "proxy_host":              "host",
            "proxy_port":              8080,
            "proxy_username":          "user",
            "proxy_password":          "pass",
            "proxy_type":              "auto",
            "ssl_verify_peer":         false,
            "ssl_verify_host":         false,
            "ssl_certificate_filepath":"/path/to/cert.pem",
            "ssl_certificate_type":    "pem",
            "ssl_key_filepath":        "/path/to/key.pem",
            "ssl_key_type":            "pem",
            "ssl_key_password":        "secret",
            "ssl_ca_filepath":         "/path/to/ca.pem",
            "ssl_ca_directory":        "/path/to/ca-dir/",
            "ssl_version":             "tlsv1_3"
          },
        
          "dom": {
            "engine":              "chrome",
            "pool_size":           4,
            "job_timeout":         120,
            "worker_time_to_live": 1000,
            "wait_for_timers":     false,
            "local_storage":       {},
            "session_storage":     {},
            "wait_for_elements":   {}
          },
        
          "device": {
            "visible":     false,
            "width":       1600,
            "height":      1200,
            "user_agent":  "...",
            "pixel_ratio": 1.0,
            "touch":       false
          },
        
          "input": {
            "values":           {},
            "default_values":   {},
            "without_defaults": false,
            "force":            false
          },
        
          "session": {
            "check_url":     "https://example.com/account",
            "check_pattern": "Logout"
          },
        
          "timeout": {
            "duration": 3600,
            "suspend":  false
          }
        }
        ```
        
        In the per-key sections below, **`group.key` is shorthand for the
        JSON path `{ "group": { "key": ... } }`** — `audit.elements`
        means the `elements` field of the `audit` object, not a literal
        key called `audit.elements`.
        
        ## Table of contents
        
        - [Top-level](#top-level)
          - [`url`](#url)
          - [`checks`](#checks)
          - [`plugins`](#plugins)
          - [`authorized_by`](#authorized_by)
          - [`no_fingerprinting`](#no_fingerprinting)
        - [`audit`](#audit) — what the engine traces
          - [`audit.elements`](#auditelements)
          - [Per-element toggles](#per-element-toggles)
          - [`audit.link_templates`](#auditlink_templates)
          - [`audit.parameter_values`](#auditparameter_values) / [`parameter_names`](#auditparameter_names)
          - [`audit.with_raw_payloads`](#auditwith_raw_payloads) / [`with_extra_parameter`](#auditwith_extra_parameter) / [`with_both_http_methods`](#auditwith_both_http_methods)
          - [`audit.cookies_extensively`](#auditcookies_extensively)
          - [`audit.mode`](#auditmode)
          - [`audit.exclude_vector_patterns`](#auditexclude_vector_patterns) / [`include_vector_patterns`](#auditinclude_vector_patterns)
        - [`scope`](#scope) — crawl bounds
          - [`scope.page_limit`](#scopepage_limit)
          - [`scope.depth_limit`](#scopedepth_limit) / [`directory_depth_limit`](#scopedirectory_depth_limit)
          - [`scope.dom_depth_limit`](#scopedom_depth_limit) / [`dom_event_limit`](#scopedom_event_limit) / [`dom_event_inheritance_limit`](#scopedom_event_inheritance_limit)
          - [`scope.include_subdomains`](#scopeinclude_subdomains) / [`https_only`](#scopehttps_only)
          - [`scope.include_path_patterns`](#scopeinclude_path_patterns) / [`exclude_path_patterns`](#scopeexclude_path_patterns) / [`exclude_content_patterns`](#scopeexclude_content_patterns)
          - [`scope.exclude_file_extensions`](#scopeexclude_file_extensions) / [`exclude_binaries`](#scopeexclude_binaries)
          - [`scope.restrict_paths`](#scoperestrict_paths) / [`extend_paths`](#scopeextend_paths)
          - [`scope.redundant_path_patterns`](#scoperedundant_path_patterns) / [`auto_redundant_paths`](#scopeauto_redundant_paths)
          - [`scope.url_rewrites`](#scopeurl_rewrites)
        - [`http`](#http) — HTTP client tuning
          - [Concurrency / queue / timeouts](#concurrency--queue--timeouts)
          - [Headers / cookies](#headers--cookies)
          - [HTTP authentication](#http-authentication)
          - [Proxy](#proxy)
          - [TLS / SSL](#tls--ssl)
        - [`dom`](#dom) — browser cluster + DOM crawl
        - [`device`](#device) — viewport / identity
        - [`input`](#input) — auto-fill rules
        - [`session`](#session) — login-session monitoring
        - [`timeout`](#timeout) — wall-clock cap
        
        ---
        
        ## Top-level
        
        ### `url`
        
        *(string, required for a real scan)*
        
        The target. Anything reachable over HTTP(S). Required for any
        `spawn_instance` with `start: true`; the only spawn path where
        it can be omitted is `start: false` (an idle instance set up
        to be configured later).
        
        ```json
        { "url": "http://example.com/" }
        ```
        
        ### `checks`
        
        *(string[], default: `[]` — no checks loaded)*
        
        Check shortnames or globs to load. Use `["*"]` for the full
        catalogue (the `bin/spectre_scan` default). Examples:
        
        - `["xss*", "sql_injection*"]` — XSS family + SQLi family.
        - `["xss"]` — exactly the `xss` check.
        
        Call the `list_checks` MCP tool (or `bin/spectre_scan
        --list-checks`) to enumerate the available shortnames + their
        severity / tags / element coverage.
        
        ```json
        { "checks": ["xss*", "sql_injection*"] }
        ```
        
        ### `plugins`
        
        *(object | string[] | string, default: `{}` — no plugins)*
        
        Plugins to load. Three accepted shapes:

        ```json
        { "plugins": {} }                                    // load nothing extra
        { "plugins": ["defaults/*"] }                        // array of names / globs
        { "plugins": { "webhook_notify": { "url": "..." } } } // hash with per-plugin options
        ```

        The application **always** merges its default-plugin set in
        first; this key is purely for extras / overrides.
        
        ### `authorized_by`
        
        *(string)*
        
        E-mail address of the authorising operator. Flows into outbound
        HTTP requests' `From` header so target-site admins can identify
        the scan. Polite on third-party targets.
        
        ```json
        { "authorized_by": "ops@example.com" }
        ```
        
        ### `no_fingerprinting`
        
        *(boolean, default: false)*
        
        Skip server / client tech fingerprinting. The fingerprint feeds
        `platforms` on each issue (`tomcat,java`, `php,mysql`, etc.) and
        narrows which checks run; turning it off speeds the start-up but
        loses platform-specific check skipping.
        
        ```json
        { "no_fingerprinting": true }
        ```
        
        ---
        
        ## `audit`
        
        What the engine traces. All keys nest under the top-level
        `"audit"` object:
        
        ```json
        { "audit": { "elements": ["links","forms"], "parameter_values": true } }
        ```
        
        ### `audit.elements`
        
        *(string[])*
        
        Shortcut for the per-element booleans below. Pick from:
        `links`, `forms`, `cookies`, `nested_cookies`, `headers`,
        `ui_inputs`, `ui_forms`, `jsons`, `xmls`. Equivalent to setting
        each named boolean to `true`.
        
        The presets ship the standard 8-element list (`links`, `forms`,
        `cookies`, `headers`, `ui_inputs`, `ui_forms`, `jsons`, `xmls`).
        `nested_cookies` is opt-in; `link_templates` is **not** an
        element — see below.
        
        ```json
        { "audit": { "elements": ["links","forms","cookies","headers","ui_inputs","ui_forms","jsons","xmls"] } }
        ```
        
        ### Per-element toggles
        
        `audit.links` / `audit.forms` / `audit.cookies` /
        `audit.headers` / `audit.jsons` / `audit.xmls` /
        `audit.ui_inputs` / `audit.ui_forms` / `audit.nested_cookies`
        
        *(boolean)*
        
        Equivalent to listing the element name in `audit.elements`.
        Default on each is unset (`nil`), which the engine treats as
        off; `bin/spectre_scan` flips them on for the default 8.
        
        ```json
        { "audit": { "links": true, "forms": true, "cookies": false } }
        ```
        
        ### `audit.link_templates`
        
        *(regex[], default: `[]`)*
        
        Regex patterns with named captures for extracting input info
        from REST-style paths. Example: `(?<id>\d+)` against
        `/users/42` lets the engine treat `42` as the value of an
        `id` input. **Not** a boolean toggle — putting `link_templates`
        in `audit.elements` is an error.
        
        ```json
        { "audit": { "link_templates": ["users/(?<id>\\d+)", "posts/(?<post_id>\\d+)"] } }
        ```
        
        ### `audit.parameter_values`
        
        *(boolean, default: true)*
        
        Inject payloads into parameter values. Turning this off limits
        auditing to parameter *names* (with `parameter_names: true`) or
        extra-parameter injection — rarely what you want.
        
        ### `audit.parameter_names`
        
        *(boolean, default: false)*
        
        Inject payloads into parameter names themselves. Catches
        mass-assignment / unintended-parameter classes of bug. Adds one
        extra mutation per known input.
        
        ### `audit.with_raw_payloads`
        
        *(boolean, default: false)*
        
        Send payloads in raw form (no HTTP encoding). Useful when you
        suspect the target has a decoder that mangles encoded bytes.
        
        ### `audit.with_extra_parameter`
        
        *(boolean, default: false)*
        
        Inject an additional, unexpected parameter into each element.
        Catches code paths that read undeclared parameters.
        
        ### `audit.with_both_http_methods`
        
        *(boolean, default: false)*
        
        Audit each link / form with both `GET` and `POST`. **Doubles
        audit time** — only enable when the target's behaviour is
        known to vary by method.
        
        ### `audit.cookies_extensively`
        
        *(boolean, default: false)*
        
        Submit every link and form along with each cookie permutation.
        **Severely increases scan time** — useful when cookie state
        gates application behaviour.
        
        ### `audit.mode`
        
        *(string, default: `"moderate"`)*
        
        Audit aggressiveness. Values: `light`, `moderate`, `aggressive`.
        Higher modes try more payload variants per input.
        
        ### `audit.exclude_vector_patterns`
        
        *(regex[], default: `[]`)*
        
        Skip input vectors whose name matches any pattern. Example:
        `["^csrf$", "^_token$"]` to leave anti-CSRF tokens alone.
        
        ### `audit.include_vector_patterns`
        
        *(regex[], default: `[]`)*
        
        Inverse of `exclude_vector_patterns` — only audit vectors whose
        name matches. Empty means "no whitelist."
        
        ---
        
        ## `scope`
        
        Crawl bounds. All keys nest under `"scope"`:
        
        ```json
        { "scope": { "page_limit": 50, "include_subdomains": false } }
        ```
        
        ### `scope.page_limit`
        
        *(int, default: nil — infinite)*
        
        Hard cap on crawled pages. The quick-scan preset sets this to
        `50`; the full-scan preset omits it.
        
        ### `scope.depth_limit`
        
        *(int, default: 10)*
        
        How deep to follow links from the seed. Counts every hop
        regardless of directory layout.
        
        ### `scope.directory_depth_limit`
        
        *(int, default: 10)*
        
        How deep to descend into the URL path tree.
        
        ### `scope.dom_depth_limit`
        
        *(int, default: 4)*
        
        How deep into the DOM tree of each JavaScript-rendered page.
        `0` disables browser analysis entirely.
        
        ### `scope.dom_event_limit`
        
        *(int, default: 500)*
        
        Max DOM events triggered per DOM depth. Caps crawl time on
        event-heavy SPAs.
        
        ### `scope.dom_event_inheritance_limit`
        
        *(int, default: 500)*
        
        How many descendant elements inherit a parent's bound events.
        
        ### `scope.include_subdomains`
        
        *(boolean, default: false)*
        
        Follow links to subdomains of the seed host.
        
        ### `scope.https_only`
        
        *(boolean, default: false)*
        
        Refuse plaintext HTTP follow-throughs.
        
        ### `scope.include_path_patterns`
        
        *(regex[], default: `[]`)*
        
        Whitelist patterns for path segments. Empty = include all.
        
        ### `scope.exclude_path_patterns`
        
        *(regex[], default: `[]`)*
        
        Blacklist patterns. Pages whose paths match are skipped.
        
        ```json
        { "scope": { "exclude_path_patterns": ["/logout", "/admin/.*"] } }
        ```
        
        ### `scope.exclude_content_patterns`
        
        *(regex[], default: `[]`)*
        
        Blacklist patterns for *response body* content. A page whose
        body matches gets dropped from the audit pool — useful for
        "don't audit /logout" via response-side pattern.
        
        ### `scope.exclude_file_extensions`
        
        *(string[])*
        
        Skip URLs ending in these extensions. Defaults to a long list
        of media / archive / executable / asset / document extensions
        (`gif`, `mp4`, `pdf`, `js`, `css`, …). Override if you need to
        audit something the default skips (e.g. force-include `js` for
        DOM analysis).
        
        ### `scope.exclude_binaries`
        
        *(boolean, default: false)*
        
        Skip non-text-typed responses. Cheaper than maintaining a
        content-type allowlist; can confuse passive checks that
        pattern-match on bodies.
        
        ### `scope.restrict_paths`
        
        *(string[], default: `[]`)*
        
        Use these paths INSTEAD of crawling. Pre-seeded path discovery
        — the engine audits exactly what's listed.
        
        ### `scope.extend_paths`
        
        *(string[], default: `[]`)*
        
        Add to whatever the crawler discovers. Useful for hidden URLs
        that aren't linked from anywhere.
        
        ### `scope.redundant_path_patterns`
        
        *(object: `{regex: int}`, default: `{}`)*
        
        Pages matching the regex are crawled at most `N` times. Stops
        infinite-calendar / infinite-page traps.
        
        ```json
        { "scope": { "redundant_path_patterns": { "calendar/\\d+": 1, "events/\\d+": 5 } } }
        ```
        
        ### `scope.auto_redundant_paths`
        
        *(int, default: 15)*
        
        Follow URLs with the same query-parameter-name combination at
        most `auto_redundant_paths` times. Catches the
        `?page=1&offset=10`, `?page=2&offset=20`, ... pattern without
        needing explicit `redundant_path_patterns`.
        
        ### `scope.url_rewrites`
        
        *(object: `{regex: string}`, default: `{}`)*
        
        Rewrite seed-discovered URLs before audit:
        
        ```json
        { "scope": { "url_rewrites": { "articles/(\\d+)": "articles.php?id=\\1" } } }
        ```
        
        ---
        
        ## `http`
        
        HTTP client tuning. All keys nest under `"http"`:
        
        ```json
        { "http": { "request_concurrency": 5, "request_timeout": 30000 } }
        ```
        
        ### Concurrency / queue / timeouts
        
        - **`http.request_concurrency`** *(int, default: 10)* — parallel
          requests in flight. The engine throttles down automatically if
          the target's response time degrades.
        - **`http.request_queue_size`** *(int, default: 50)* — max
          requests queued client-side. Larger queue = better network
          utilisation, more RAM.
        - **`http.request_timeout`** *(int, ms, default: 20000)* —
          per-request timeout.
        - **`http.request_redirect_limit`** *(int, default: 5)* — max
          redirects to follow on each request.
        - **`http.response_max_size`** *(int, bytes, default: 500000)* —
          don't download response bodies larger than this. Prevents
          runaway RAM on a target that streams large payloads.
        
        ### Headers / cookies
        
        - **`http.request_headers`** *(object, default: `{}`)* — extra
          headers on every request:
        
          ```json
          { "http": { "request_headers": { "X-API-Key": "abc123", "X-Debug": "1" } } }
          ```
        
        - **`http.cookies`** *(object, default: `{}`)* — preset cookies:
        
          ```json
          { "http": { "cookies": { "session_id": "abc", "auth": "xyz" } } }
          ```
        
        - **`http.cookie_jar_filepath`** *(string)* — path to a
          Netscape-format cookie jar file.
        - **`http.cookie_string`** *(string)* — raw cookie string,
          `Set-Cookie`-style:
        
          ```json
          { "http": { "cookie_string": "my_cookie=my_value; Path=/, other=other; Path=/test" } }
          ```
        
        ### HTTP authentication
        
        ```json
        { "http": {
            "authentication_username": "user",
            "authentication_password": "pass",
            "authentication_type":     "basic"
        } }
        ```
        
        - **`http.authentication_username`** / **`http.authentication_password`** *(string)*
        - **`http.authentication_type`** *(string, default: `"auto"`)* —
          explicit values: `basic`, `digest`, `ntlm`, `negotiate`, `any`,
          `anysafe`.
        
        ### Proxy
        
        ```json
        { "http": {
            "proxy":          "proxy.example.com:8080",
            "proxy_type":     "http",
            "proxy_username": "user",
            "proxy_password": "pass"
        } }
        ```
        
        - **`http.proxy`** *(string, `"host:port"` shortcut)*
        - **`http.proxy_host`** / **`http.proxy_port`** — split form,
          overrides `proxy` if set.
        - **`http.proxy_username`** / **`http.proxy_password`** *(string)*
        - **`http.proxy_type`** *(string, default: `"auto"`)* — `http`,
          `https`, `socks4`, `socks4a`, `socks5`, `socks5_hostname`.
        
        ### TLS / SSL
        
        - **`http.ssl_verify_peer`** / **`http.ssl_verify_host`**
          *(boolean, default: false)* — TLS peer / hostname verification.
          Off by default; both `true` for full chain validation.
        - **`http.ssl_certificate_filepath`** / **`http.ssl_certificate_type`**
          / **`http.ssl_key_filepath`** / **`http.ssl_key_type`** /
          **`http.ssl_key_password`** — client-cert auth. `*_type`
          values: `pem`, `der`, `eng`.
        - **`http.ssl_ca_filepath`** / **`http.ssl_ca_directory`** —
          custom CA bundle / directory for peer verification.
        - **`http.ssl_version`** *(string)* — pin a TLS version: `tlsv1`,
          `tlsv1_0`, `tlsv1_1`, `tlsv1_2`, `tlsv1_3`, `sslv2`, `sslv3`.
        
        ```json
        { "http": {
            "ssl_verify_peer":          true,
            "ssl_verify_host":          true,
            "ssl_ca_filepath":          "/etc/ssl/cert.pem",
            "ssl_certificate_filepath": "/path/to/client.pem",
            "ssl_key_filepath":         "/path/to/client.key",
            "ssl_version":              "tlsv1_3"
        } }
        ```
        
        ---
        
        ## `dom`
        
        Browser cluster + DOM crawl. All keys nest under `"dom"`:
        
        ```json
        { "dom": { "pool_size": 4, "job_timeout": 120, "wait_for_timers": true } }
        ```
        
        - **`dom.engine`** *(string, default: `"chrome"`)* — browser
          engine. Chrome is the only supported value.
        - **`dom.pool_size`** *(int, default: `min(cpu_count/2, 10) || 1`)* —
          number of browser workers in the pool. More workers = faster
          DOM crawl on JS-heavy targets, more RAM.
        - **`dom.job_timeout`** *(int, sec, default: 120)* — per-page
          browser job ceiling. Pages that don't settle are dropped from
          DOM-side analysis.
        - **`dom.worker_time_to_live`** *(int, default: 1000)* — re-spawn
          each browser after this many jobs. Caps memory leaks in
          long-lived headless instances.
        - **`dom.wait_for_timers`** *(boolean, default: false)* — wait
          for the longest `setTimeout()` on each page before considering
          DOM analysis "done". Catches lazy-mounted UI.
        - **`dom.local_storage`** / **`dom.session_storage`** *(object,
          default: `{}`)* — pre-seed key/value maps:
        
          ```json
          { "dom": {
              "local_storage":   { "user": "abc", "preferred_lang": "en" },
              "session_storage": { "csrf_token": "xyz" }
          } }
          ```
        
        - **`dom.wait_for_elements`** *(object: `{regex: css}`, default:
          `{}`)* — when navigating to a URL matching the key, wait for
          the CSS selector value to match before continuing:
        
          ```json
          { "dom": { "wait_for_elements": {
              "/dashboard":  "#main-app .ready",
              "/settings/.*": "#settings-form"
          } } }
          ```
        
        ---
        
        ## `device`
        
        Browser viewport / identity. All keys nest under `"device"`:
        
        ```json
        { "device": { "width": 375, "height": 812, "touch": true, "pixel_ratio": 3.0 } }
        ```
        
        - **`device.visible`** *(boolean, default: false)* — show the
          browser window (head-ful mode). Massively slower; primarily
          for debugging login flows / interactive traps.
        - **`device.width`** / **`device.height`** *(int)* — viewport
          dimensions in CSS pixels.
        - **`device.user_agent`** *(string)* — override the User-Agent
          header / JS API.
        - **`device.pixel_ratio`** *(float, default: 1.0)* — device
          pixel ratio. Bump for high-DPI sniffing (some sites serve
          different markup at `2.0`).
        - **`device.touch`** *(boolean, default: false)* — advertise as
          a touch device.
        
        ---
        
        ## `input`
        
        How inputs are auto-filled by the engine before mutation. All
        keys nest under `"input"`:
        
        ```json
        { "input": { "values": { "email": "scan@example.com" }, "force": true } }
        ```
        
        - **`input.values`** *(object: `{regex: string}`, default: `{}`)*
          — match an input's name against the regex key; use the value:
        
          ```json
          { "input": { "values": {
              "email":          "scan@example.com",
              "first_name":     "Scan",
              "creditcard|cc":  "4111111111111111"
          } } }
          ```
        
        - **`input.default_values`** *(object)* — layered under `values`
          — patterns the engine ships out of the box (`first_name` →
          "John", etc.).
        - **`input.without_defaults`** *(boolean, default: false)* —
          skip the shipped `default_values` table; only your `values`
          get used.
        - **`input.force`** *(boolean, default: false)* — fill even
          non-empty inputs (overwrites pre-populated form fields).
        
        ---
        
        ## `session`
        
        Login-session monitoring. The engine periodically checks the
        target is still logged in. All keys nest under `"session"`:
        
        ```json
        { "session": {
            "check_url":     "https://example.com/account",
            "check_pattern": "Logout"
        } }
        ```
        
        - **`session.check_url`** *(string)* — URL whose response body
          should match `check_pattern` while the session is valid.
        - **`session.check_pattern`** *(regex)* — matched against
          `check_url`'s body. Mismatch = session expired; the scan halts
          pending re-login.
        
        Both fields are required to enable session monitoring; setting
        only one is rejected at validation time.
        
        ---
        
        ## `timeout`
        
        Wall-clock cap on the run. All keys nest under `"timeout"`:
        
        ```json
        { "timeout": { "duration": 3600, "suspend": true } }
        ```
        
        - **`timeout.duration`** *(int, sec)* — stop the scan after this
          many seconds.
        - **`timeout.suspend`** *(boolean, default: false)* — when the
          timeout fires, suspend to a snapshot file (loadable later out
          of band). Without this the run is aborted.
        
        ---
        
    MARKDOWN

    # Bounded "spec a target" scan — every audit element, every
    # check, default plugins (auto-merged by the application — see
    # `spectre://options/reference`), capped at 50 crawled pages so
    # an MCP-driven smoke test on a real site finishes in minutes
    # rather than hours. Bump / remove `scope.page_limit` for a
    # representative or full audit (or use the
    # `spectre://option-presets/full-scan` preset, which omits the
    # cap).
    #
    # `audit.<element>: true` is set explicitly here because the
    # engine's bare defaults leave them all unset — only the CLI
    # turns them on. Without this an MCP-driven scan crawls but
    # audits nothing, surfacing only passive findings.
    QUICK_SCAN_PRESET = {
        url:    '<TARGET URL>',
        checks: ['*'],
        audit:  {
            # Same 8-element default the `spectre_scan` CLI applies
            # when the operator passes no `--audit-*` flags
            # (`ui/cli/engine.rb#audit_options`). `nested_cookies` is
            # opt-in; `link_templates` isn't a boolean toggle — its
            # setter expects regex patterns and would raise if added
            # here.
            elements: %w(links forms cookies headers ui_inputs ui_forms jsons xmls)
        },
        scope: {
            # Smoke-test default — first 50 crawled pages, then
            # audit completes against what was discovered. Drop the
            # whole `scope` block (or use `full-scan`) for an
            # uncapped run.
            page_limit: 50
        }
    }.freeze

    # Same coverage as `QUICK_SCAN_PRESET` minus the
    # `scope.page_limit` cap — every audit element, every check,
    # default plugins, no scope cap. Use this when an MCP client
    # explicitly wants a complete audit and is OK with a long run.
    FULL_SCAN_PRESET = {
        url:    '<TARGET URL>',
        checks: ['*'],
        audit:  {
            elements: %w(links forms cookies headers ui_inputs ui_forms jsons xmls)
        }
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
            description: 'Concrete keys accepted by `spawn_instance.options` (url, scope, audit, checks, http, dom, plugins, authorized_by). See `spectre://option-presets/quick-scan` (capped 50-page smoke test) and `spectre://option-presets/full-scan` (uncapped) for ready-made templates.',
            mime_type:   'text/markdown'
        ),
        ::MCP::Resource.new(
            uri:         'spectre://option-presets/quick-scan',
            name:        'Quick-scan options preset',
            description: 'JSON template for `spawn_instance.options` — every audit element, every check, default plugins (auto-merged by the application), capped at 50 crawled pages so a real-site smoke test finishes in minutes. Replace `<TARGET URL>`. Bump / drop `scope.page_limit` (or switch to `spectre://option-presets/full-scan`) for a longer run.',
            mime_type:   'application/json'
        ),
        ::MCP::Resource.new(
            uri:         'spectre://option-presets/full-scan',
            name:        'Full-scan options preset',
            description: 'Same shape as `spectre://option-presets/quick-scan` minus the `scope.page_limit` cap — every audit element, every check, default plugins, no scope cap. Use when you want a complete audit and accept a long run on a real site.',
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
        when 'spectre://option-presets/full-scan'
            ::MCP::Resource::TextContents.new(
                uri: uri, mime_type: 'application/json',
                text: JSON.pretty_generate( FULL_SCAN_PRESET )
            )
        end
    end

    # ── MCP prompts ──────────────────────────────────────────────
    # Canned conversational workflows. The client (Claude Desktop,
    # etc.) surfaces these as one-click templates the user can fire.

    class QuickScanPrompt < ::MCP::Prompt
        prompt_name 'quick_scan'
        description 'Run a Spectre scan using the quick-scan preset (all elements, all checks, default plugins, capped at 50 crawled pages), poll progress every 5 s, and report issues one line per finding when status: done. Optional args narrow checks, override the default page cap, identify the operator, or splice in extra options. For an uncapped run, use the `full_scan` prompt or `spectre://option-presets/full-scan` instead.'
        arguments [
            ::MCP::Prompt::Argument.new(
                name:        'url',
                description: 'Target URL (http:// or https://). Must be a host the operator is authorised to scan.',
                required:    true
            ),
            ::MCP::Prompt::Argument.new(
                name:        'page_limit',
                description: 'Override the preset\'s default cap of 50 crawled pages. 30 = smaller smoke test, 200 = representative, set to 0 / a very large value if you want effectively no cap (or use the `full_scan` prompt instead).',
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

    class FullScanPrompt < ::MCP::Prompt
        prompt_name 'full_scan'
        description 'Run a Spectre scan using the full-scan preset (all elements, all checks, default plugins, NO page cap), poll progress every 5 s, and report issues one line per finding when status: done. Same shape as `quick_scan` minus the 50-page default cap — use this when you want a complete audit and accept a long run on a real site. Optional args still let you narrow checks, identify the operator, or splice in extra options.'
        arguments [
            ::MCP::Prompt::Argument.new(
                name:        'url',
                description: 'Target URL (http:// or https://). Must be a host the operator is authorised to scan.',
                required:    true
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
            checks        = args[:checks]         || args['checks']
            authorized_by = args[:authorized_by]  || args['authorized_by']
            extra_options = args[:extra_options]  || args['extra_options']

            overrides = []
            overrides << "  - Replace `checks` with #{checks.to_s.split(',').map(&:strip).reject(&:empty?).inspect}." if checks && !checks.to_s.empty?
            overrides << "  - Set `authorized_by` to #{authorized_by.inspect}." if authorized_by && !authorized_by.to_s.empty?
            overrides << "  - Deep-merge the following JSON object into `options` (caller-supplied, treat as raw options): `#{extra_options}`. Read `spectre://options/reference` for valid keys before merging." if extra_options && !extra_options.to_s.empty?

            override_block = overrides.any? ? "\nApply these overrides on top of the preset before calling `spawn_instance`:\n#{overrides.join("\n")}\n" : ''

            ::MCP::Prompt::Result.new(
                description: 'Full Spectre scan + summary',
                messages: [
                    ::MCP::Prompt::Message.new(
                        role:    'user',
                        content: ::MCP::Content::Text.new(
                            <<~PROMPT
                                Run a full Spectre scan against #{url} via this MCP server. Heads-up: full scans on a real site can run for hours; expect a long polling loop.

                                1. Read `spectre://options/reference` once if you don't already know the options shape.
                                2. Build `options` from `spectre://option-presets/full-scan`, substituting the URL above. (No `scope.page_limit` — the run will crawl until exhaustion.)
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

    PROMPTS = [ QuickScanPrompt, FullScanPrompt ].freeze

    def self.prompts
        PROMPTS
    end

end

end
end
