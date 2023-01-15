require "active_record"

module Arel
  module Nodes
    class UsingNode < Arel::Nodes::Node
    end

    class CrossJoin < Arel::Nodes::Join
    end

    class LeftJoin < Arel::Nodes::Join
    end

    class CrossJoinLateral < Arel::Nodes::Join
    end

    class LeftJoinLateral < Arel::Nodes::Join
    end

    class NormalJoin < Arel::Nodes::Join
    end

    class WithMaterialized < Arel::Nodes::With
    end

    class WithNotMaterialized < Arel::Nodes::With
    end
  end

  class ValuesTable < Arel::Table
    def with_values(values)
      @mvalues_list = values
      self
    end
  end

  module Visitors
    class ToSql
      def visit_Arel_Nodes_On(o, collector)
        if o.expr.is_a?(Hash) and o.expr[:using]
          join_using = o.expr[:using].join(", ")
          collector << "USING #{grouping(lit(join_using)).to_sql} "
          collector
        else
          collector << "ON "
          visit o.expr, collector
        end
      end

      def visit_Arel_Nodes_CrossJoin(o, collector)
        collector << "CROSS JOIN "
        collector = visit o.left, collector
        if o.right
          collector << " "
          visit(o.right, collector)
        else
          collector
        end
      end

      def visit_Arel_Nodes_CrossJoinLateral(o, collector)
        collector << "CROSS JOIN LATERAL "
        collector = visit o.left, collector
        if o.right
          collector << " "
          visit(o.right, collector)
        else
          collector
        end
      end

      def visit_Arel_Nodes_LeftJoinLateral(o, collector)
        collector << "LEFT JOIN LATERAL "
        collector = visit o.left, collector
        if o.right
          collector << " "
          visit(o.right, collector)
        else
          collector
        end
      end

      def visit_Arel_Nodes_LeftJoin(o, collector)
        collector << "LEFT JOIN "
        collector = visit o.left, collector
        if o.right
          collector << " "
          visit(o.right, collector)
        else
          collector
        end
      end

      def visit_Arel_Nodes_NormalJoin(o, collector)
        collector << "JOIN "
        collector = visit o.left, collector
        if o.right
          collector << " "
          visit(o.right, collector)
        else
          collector
        end
      end

      def collect_ctes(children, collector)
        children.each_with_index do |child, i|
          collector << ", " unless i == 0

          case child
          when Arel::Nodes::As
            name = child.left.name
            is_materialized = child.left.instance_variable_get(:@is_materialized) || false
            relation = child.right
          when Arel::Nodes::TableAlias
            name = child.name
            relation = child.relation
          end

          collector << quote_table_name(name)
          collector << " AS NOT MATERIALIZED " if !is_materialized
          collector << " AS MATERIALIZED " if is_materialized
          visit relation, collector
        end

        collector
      end
    end
  end
end

def validate_sql!(sql)
  PgQuery.parse(sql)
end

def values_list(values)
  Arel::Nodes::ValuesList.new(values)
end

def as(a, b)
  Arel::Nodes::As.new(a, b)
end

def sql_literal(string)
  Arel::Nodes::SqlLiteral.new("'#{string}'")
end

def lit(string)
  Arel::Nodes::SqlLiteral.new(string)
end

def grouping(a)
  Arel::Nodes::Grouping.new(a)
end

def substring(field, value)
  named_function("SUBSTRING", field, value)
end

def plus(left, right)
  Arel::Nodes::InfixOperation.new("+", left, right)
end

def locate(field, string)
  named_function("LOCATE", field, sql_literal(string))
end

def named_function(function_name, args)
  Arel::Nodes::NamedFunction.new(function_name, args)
end

def quoted(val)
  # parser here
  Arel::Nodes::Quoted.new(val || " ")
end

def cast(pred, type)
  Arel::Nodes::NamedFunction.new "cast", [quoted(pred).as(type)]
end

def true?(obj)
  obj.to_s.downcase == "true"
end

def sanitize(value)
  ActiveRecord::Base.sanitize_sql(value)
end
