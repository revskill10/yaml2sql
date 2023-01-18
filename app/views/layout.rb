require "pygments"

class App
  module Views
    class Layout < Mustache
      def title
        @title || "YAML -> SQL"
      end

      def styles
        Pygments.css
      end

      def apply(fname, *args)
        
      end

      def links
        [
          { href: "/docs", title: "Docs" },
          { href: "/", title: "Simple values" },
          { href: "/complex", title: "Complex" },
          { href: "/aggregation", title: "Aggregation" },
        ]
      end
    end
  end
end
