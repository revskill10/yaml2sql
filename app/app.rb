#$:.unshift(__FILE__, ".")
require "sinatra/base"
require "mustache"
require "mustache/sinatra"
require_relative "query"
require "pygments"
require "rdiscount"
require_relative "views/yaml"

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
    view_name = params[:view] || "simple"
    puts "View #{view_name}"
    @y = File.read(__dir__ + "/queries/#{view_name.to_sym}.yml")

    c = @y.gsub(/on:/, "where:")

    r = Psych.safe_load(c, aliases: true, symbolize_names: true, permitted_classes: [Date])
    puts "SSS: #{r}"
    v = YamlView.new
    v.process(r)
    begin
      @h = settings.runner.run!(v.ctx)
      mustache :simple
    rescue => e
      e.message
      e.backtrace
    end
  end
  get "/" do
    view_name = params[:view] || "simple"
    puts "View #{view_name}"
    @y = File.read(__dir__ + "/queries/#{view_name.to_sym}.yml")

    c = @y.gsub(/on:/, "where:")

    r = Psych.safe_load(c, aliases: true, symbolize_names: true, permitted_classes: [Date])
    v = YamlView.new
    v.process(r)
    begin
      @h = settings.runner.run!(v.ctx)
      mustache :simple
    rescue => e
      e.message
      e.backtrace
    end
  end
end
