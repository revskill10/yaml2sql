require "sinatra/json"
require "jwt"

class JWTAuthorization
  def initialize(app)
    @app = app
  end

  def call(env)
    begin
      # env.fetch gets http header

      # bearer = env.fetch('HTTP_AUTHORIZATION', '').split(' ')[1]    # also work
      bearer = env.fetch("HTTP_AUTHORIZATION").slice(7..-1)           # gets JWT token
      key = OpenSSL::PKey::RSA.new ENV["PUBLIC_KEY"]                  # read public key pem file
      payload = JWT.decode bearer, key, true, { algorithm: "RS256" }   # decode and verify token with pub key
      claims = payload.first

      # current_user is defined by env[:user].
      # useful to define current_user if you are using pundit gem
      if claims["iss"] == "user"
        env[:user] = User.find_by_email(claims["email"])
      end

      # access your claims here...

      @app.call env
    rescue JWT::ExpiredSignature
      [403, { "Content-Type" => "text/plain" }, ["The token has expired."]]
    rescue JWT::DecodeError
      [401, { "Content-Type" => "text/plain" }, ["A token must be passed."]]
    rescue JWT::InvalidIssuerError
      [403, { "Content-Type" => "text/plain" }, ["The token does not have a valid issuer."]]
    rescue JWT::InvalidIatError
      [403, { "Content-Type" => "text/plain" }, ['The token does not have a valid "issued at" time.']]
      # useful only if using pundit gem
    rescue Pundit::NotAuthorizedError
      [401, { "Content-Type" => "text/plain" }, ["Unauthorized access."]]
    end
  end
end
