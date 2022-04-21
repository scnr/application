require_relative 'multi/common'
require_relative 'multi/crawler'
require_relative 'multi/auditor'

class Multi
    include Common

    def make_crawler
        self.class.include Crawler
        nil
    end

    def make_auditor( url, token )
        self.class.include Auditor

        @crawler = Cuboid::Application.connect( url: url, token: token )

        nil
    end

end
