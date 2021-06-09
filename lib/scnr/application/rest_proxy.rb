module RESTProxy
def self.registered( app )

    app.get '/progress' do
        data = instance_for( params[:instance] ) do |instance|
            instance.proxy.progress
        end
        json data
    end

end
end
