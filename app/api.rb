require_relative "app"

module ApiJSON
  def getBody(req)
    ## Rewind the body in case it has already been read
    req.body.rewind
    ## parse the body
    return JSON.parse(req.body.read)
  end
end

class App
  include ApiJSON

  post "/api/sqlql" do
    body = getBody(request)
    query = body["query"]
    variables = body["variables"]

  end
end
