require_relative 'multi/common'
require_relative 'multi/crawler'
require_relative 'multi/auditor'

class Multi
    include Common

    def make_crawler
        self.class.include Crawler
        nil
    end

    def make_auditor( crawler_url, token, self_url )
        self.class.include Auditor

        @crawler  = Cuboid::Application.connect( url: crawler_url, token: token )
        @self_url = self_url
        nil
    end

end
