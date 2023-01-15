$:.unshift(__FILE__, ".")
require "app/app"

use Rack::ShowExceptions
run App.new
