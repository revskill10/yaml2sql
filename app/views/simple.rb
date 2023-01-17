require "active_support/core_ext/hash/keys"

class App
  module Views
    class Simple < Layout
      def initialzize(ct = nil)
        @ct = ct
      end

      def content
        @h
      end

      def ctx
        @pa.ctx
      end

      def yaml_content
        @y.gsub("---", "").gsub("\n\n", "")
      end
    end
  end
end
