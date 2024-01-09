child :options, :Options do

    describe 'Sets Engine options.'
    def_set do |*args|
        SCNR::Engine::Options.set *args
        SCNR::Engine::Options.validate
    end

end
