module RESTProxy
def self.registered( app )

    app.get '/progress' do
        session[params[:instance]] ||= {
          seen_issues:  [],
          seen_errors:  0,
          seen_sitemap: 0
        }

        data = instance_for( params[:instance] ) do |instance|
            instance.engine.progress(
              with:    [
                         :issues,
                         errors:  session[params[:instance]][:seen_errors],
                         sitemap: session[params[:instance]][:seen_sitemap]
                       ],
              without: [
                         issues: session[params[:instance]][:seen_issues]
                       ]
            )
        end

        data['issues'].each do |issue|
            session[params[:instance]][:seen_issues] << issue['digest']
        end

        session[params[:instance]][:seen_errors]  += data['errors'].size
        session[params[:instance]][:seen_sitemap] += data['sitemap'].size

        json data
    end

end
end
