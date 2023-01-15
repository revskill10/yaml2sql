#$:.unshift(__FILE__, ".")
require "sinatra/base"
require "mustache"
require "mustache/sinatra"
require_relative "query"
require "pygments"
require "rdiscount"

class PgQueryRunner < QueryRunner
  pg_connection
end

class App < Sinatra::Base
  register Mustache::Sinatra
  require_relative "views/layout"
  set :public_folder, __dir__ + "/static"

  set :mustache, {
    views: "app/views",
    templates: "templates",
    namespace: App,
  }

  #set :show_exceptions, false
  set :runner, PgQueryRunner.new
  #   error NotImplementedError do
  #     content_type :json
  #     status 400 # or whatever

  #     e = env["sinatra.error"]
  #     { :result => "error", :message => e.message }.to_json
  #   end
  get "/docs" do
    view_name = params[:view] || "hello"
    f = File.read(__dir__ + "/../templates/docs/#{view_name.to_sym}.md")
    @docs = RDiscount.new(f).to_html
    mustache :docs
  end

  get "/play/:view?" do
    view_name = params[:view] || "values_select"
    #r = mustache view_name.to_sym, layout: false
    f = File.read(__dir__ + "/queries/#{view_name.to_sym}.yml")
    params[:fr] ||= "FR"
    r = Mustache.render(f, { params: OpenStruct.new(params) })
    begin
      @h, @y = settings.runner.run!(r)
      mustache :simple
    rescue => e
      e.message
    end
  end
  get "/" do
    view_name = "values_select"
    #r = mustache view_name.to_sym, layout: false
    f = File.read(__dir__ + "/queries/#{view_name.to_sym}.yml")
    params[:fr] ||= "FR"
    r = Mustache.render(f, { params: OpenStruct.new(params) })
    begin
      @h, @y = settings.runner.run!(r)
      mustache :simple
    rescue => e
      e.message
    end
  end
end
