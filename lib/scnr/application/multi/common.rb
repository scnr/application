class Multi
module Common

    def self_url
        Cuboid::Options.rpc.url
    end

    def framework
        SCNR::Engine::Framework.unsafe
    end

end
end
