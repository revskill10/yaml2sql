require "active_support/core_ext/hash/keys"

class App
  module Views
    class Docs < Layout
      def content
        @docs
      end
    end
  end
end
