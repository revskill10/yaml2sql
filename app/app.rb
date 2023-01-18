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

module AppHelpers
  def app_dir
    __dir__
  end

  def get_query(view_name)
    app_dir + "/queries/#{view_name.to_sym}.yml"
  end

  def get_docs_template(view_name)
    app_dir + "/templates/docs/#{view_name.to_sym}.md"
  end

  def self.static_routes(base_path = __dir__ + "/queries")
    res = Dir[base_path].each do |path|
      "/play/#{File.basename(path)}"
    end
    # res = %w(complex aggregation join generate_series simple values_select).map do |i|
    #   "/play/#{i}"
    # end
    res + ["/", "/docs"]
  end
end

class App < Sinatra::Base
  include AppHelpers
  register Mustache::Sinatra

  require_relative "views/layout"

  set :public_folder, __dir__ + "/static"

  set :mustache, {
    views: "app/views",
    templates: "app/templates",
    namespace: App,
  }

  #set :show_exceptions, false
  set :runner, PgQueryRunner.new
  error NotImplementedError do
    content_type :json
    status 400 # or whatever

    e = env["sinatra.error"]
    { :result => "error", :message => e.message }.to_json
  end
  get "/docs" do
    view_name = params[:view] || "hello"
    f = File.read(get_docs_template(view_name))
    @docs = RDiscount.new(f).to_html
    mustache :docs
  end

  get ["/", "/play/:view?"] do
    view_name = params[:view] || "simple"
    @y = File.read(get_query(view_name))

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
