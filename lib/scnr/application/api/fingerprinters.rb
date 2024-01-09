child :fingerprinters, :Fingerprinters do
    UnsafeFramework = SCNR::Engine::Framework.unsafe

    def_as do |shortname, m = nil, &block|
        shortname = shortname.to_s

        fingerprinter = Class.new( SCNR::Engine::Platform::Fingerprinter )

        if m
            fingerprinter.define_method :run, m.is_a?( Symbol ) ? method( m ) : m
        else
            fingerprinter.define_method :run, &block
        end

        fingerprinter.define_method :shortname, &proc{ shortname }

        SCNR::Engine::Platform::Manager.fingerprinters[shortname] =
          fingerprinter
    end
end
