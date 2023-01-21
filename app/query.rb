#https://stackoverflow.com/questions/67404041/arel-wth-lateral-table-in-the-from-clause
# arel: 9.0.0
require "yaml"
require "arel"
require "active_record"
require "pg_query"
require_relative "extension"

class OperationMapper
  OPS = {
    "!=": "not_eq",
    "=": "eq",
    ">": "gt",
    "<": "lt",
    ">=": "gteq",
    "<=": "lteq",
    "notIn": "not_in",
    "notNull": "not_null",
    "notBetween": "not_between",
    #"beginsWith": "begins_with",
    "doesNotContain": "does_not_contain",
    "doesNotBeginWith": "does_not_begin_with",
    "beginsWith": "contains",
  }

  attr_reader :mapper

  def initialize(m = OPS)
    @mapper = m
  end

  def []=(key, mapping)
    @mapper[key] = mapping
    self
  end

  def [](k)
    @mapper[k.to_sym] || k.to_sym
  end
end

class Lexer
  OPS_NOT = [
    "exists",
  ]
  attr_reader :mapper

  def initialize(m = nil)
    @mapper = m || OperationMapper.new
  end

  def process(arr, cha)
    if arr.length === 1
      return visit(arr[0])
    end

    if arr.length >= 2
      return [cha, process(arr[1..-1], cha), visit(arr[0])]
    end
  end

  def visit(node)
    if node.is_a?(Array)
      return visit({
               "rules": node,
               "combinator": "and",
             })
    end
    if OPS_NOT.include?(node[:operator])
      op = node[:operator] unless node[:not]
      op = "not_#{node[:operator]}" if node[:not]
      return [op, node]
    end
    if !node[:rules]
      value = node[:value] || node[:right]
      operator = node[:operator]
      op = @mapper[operator.to_sym] if @mapper[operator.to_sym]

      return [op, node[:field] || node[:left], value]
    end
    is_not = true?(node[:not])
    cha = node[:combinator] #true?(node[:not]) ? "#{node[:combinator]}_not" : node[:combinator]
    rules = node[:rules]
    return visit(rules[0]) if rules.length == 1
    # return [cha, visit(rules[0]), visit(rules[1])] if rules.length == 2
    return process(rules, cha) if !is_not
    return ["not", process(rules, cha)]
  end

  def iter(tree)
    tmp = visit(tree)
    tmp.each
  end
end

module ValueParser
  include ExternalHelpers

  def get_col(d)
    return nil unless d

    if !d.is_a?(Hash) and !d.is_a?(Array)
      return Arel.sql(sanitize(d.to_s))
    end
    is_operator = d[:operator]
    #return Arel.sql(sanitize(d[:field].to_s)) if d[:field]
    field = d[:field]
    if field and !is_operator
      tt = Arel.sql(sanitize(field.to_s))
      if d[:as] || d[:alias]
        tt = as(tt, Arel.sql(sanitize(d[:as] || d[:alias])))
      end
      return tt
    end
    if d[:value] and !is_operator
      tt = sanitize(d[:value].to_s)
      if d[:as] || d[:alias]
        tt = Arel.sql("'#{tt}'::#{sanitize(d[:as] || d[:alias])}")
      else
        tt = quoted(tt)
      end
      return tt
    end
    return Query.new.(d[:query]) if d[:query]

    op = d[:operator].to_sym
    operation = "visit_#{op}"
    puts "OP: #{op}"
    if respond_to?(operation)
      tmp = send "visit_#{op}", d
    else
      tmp = send "visit_external", op, d
    end

    return get_alias(tmp, d[:alias]) #if d[:alias]
  end

  def get_when(args)
    Predicate.new(:test).call(args)
  end

  def visit_external(op, node)
    if node[:args]
      args = node[:args] || []
      nargs = args.map do |r|
        get_col(r)
      end
      puts "#{op} #{node}"
      Arel::Nodes::NamedFunction.new(op, nargs, node[:alias]) if node[:alias]
      Arel::Nodes::NamedFunction.new(op, nargs)
    else
      Arel::Nodes::InfixOperation.new(op, get_col(node[:left]), get_col(node[:right]))
    end
  end

  def get_alias(node, alia = nil)
    return node.as(alia) if alia
    node
  end

  def visit_case(node)
    tmp = Arel::Nodes::Case.new
    args = node[:args]
    #default_type = node[:cast] || "varchar"
    args.each do |r|
      tmp = tmp.when(get_when(r[:when])).then(get_col(r[:then]))
    end
    tmp = tmp.else(get_col(node[:else])) if node[:else]
    tmp
  end

  def visit_generate_series(node)
    args = node[:args]
    puts "ARGS #{args}"
    raise "Need from, start and optinal range args" unless (args.is_a?(Array) and args.length >= 2)
    from = get_col(args[0])
    to = get_col(args[1])
    by = get_col(args[2])
    options = { as: node[:alias] } if node[:alias]
    series(from, to, by, options || {})
  end

  def visit_date_trunc(node)
    args = node[:args]
    day = get_col(args[0])
    field = get_col(args[1])
    options = { as: node[:alias] } if node[:alias]
    date_trunc(day, field, options)
  end

  def visit_aggregator(node, aggop)
    is_distinct = true?(node[:distinct])
    args = node[:args]
    args = [args] if args.is_a?(Hash)

    if is_distinct and args.is_a?(Array)
      tmp = get_col(args[0]).send(aggop, is_distinct)
    else
      tmp = get_col(args[0]).send(aggop)
    end

    if node[:filter] and node[:filter][:where]
      fil = node[:filter][:where]
      ff = Predicate.new(node[:alias] || :test).(fil)
      tmp = Arel.sql("#{tmp.to_sql} FILTER(WHERE #{ff.to_sql})")
    end

    return tmp
  end

  def visit_sum(node)
    visit_aggregator(node, :sum)
  end

  def visit_sum_if(node, args)
    visit_aggregator(node, :sum_if)
  end

  def visit_min(node)
    visit_aggregator(node, :minimum)
  end

  def visit_max(node)
    visit_aggregator(node, :maximum)
  end

  def visit_avg(node)
    visit_aggregator(node, :average)
  end

  def visit_count(node)
    visit_aggregator(node, :count)
  end

  def process_args(n, default_key)
    if n&.fetch(default_key).present?
      return n[default_key]
    end
    if n&.fetch(:args).present?
      args = n[:args]
      query = args if args.is_a?(Hash)
      query = args[0] if args.is_a?(Array) and args.length >= 1
    end
    query || []
  end
end

class Predicate
  include ValueParser

  attr_reader :collector
  attr_reader :alias

  # previous code up here
  def initialize(arel_table = nil)
    @collector = (arel_table.is_a?(Symbol) or arel_table.is_a?(String)) ? create_arel(arel_table.to_sym) : arel_table
    @alias = @collector.name if @collector
  end

  def create_arel(name, al = nil)
    tmp = Arel::Table.new(name)
    if al
      tmp.table_alias = al
    end
    tmp
  end

  def visit(node, collector = self.collector)
    op = node.next
    @collector = send "visit_#{op}", node, collector
  end

  def call(condition)
    res = Lexer.new.iter(condition)
    new_visitor = Predicate.new(create_arel(@alias))
    new_visitor.visit(res)
    xx = new_visitor.collector
    xx
  end

  def to_query
    @collector.to_sql
  end

  private

  def visit_and(node, collector)
    left = node.next.each
    right = node.next.each
    visit(left, collector).and(visit(right, collector))
  end

  def visit_or(node, collector)
    left = node.next.each
    right = node.next.each
    visit(left, collector).or(visit(right, collector))
  end

  def visit_not(node, collector)
    n = node.next.each
    visit(n, collector).not
  end

  def visit_eq(node, collector)
    field = get_col node.next
    value = get_col node.next
    field.eq(value)
  end

  def visit_between(node, collector)
    field = get_col node.next
    value = node.next
    values = []
    if value.is_a?(Array)
      values = [
        get_col(value[0]),
        get_col(value[1]),
      ]
    end
    if value.is_a?(String) and value.include?(",")
      values = value.split(",").map do |i|
        get_col(i)
      end
    end

    Arel::Nodes::Between.new(
      field,
      Arel::Nodes::And.new(values)
    )
  end

  def visit_not_eq(node, collector)
    field = get_col node.next
    value = get_col node.next
    field.is_distinct_from(value)
  end

  def visit_contains(node, collector)
    field = get_col node.next
    value = get_col node.next
    field.contains(value)
  end

  def visit_begins_with(node, collector)
    field = get_col node.next
    value = get_col node.next
    value = "#{value}%"
    field.matches_regexp(value)
  end

  def visit_does_not_begin_with(node, collector)
    field = get_col node.next
    value = get_col node.next
    value = "^#{value}"
    field.matches_regexp(value)
  end

  def visit_gt(node, collector)
    field = get_col node.next
    value = get_col node.next
    field.gt(value)
  end

  def visit_gteq(node, collector)
    field = get_col node.next
    value = get_col node.next
    field.gteq(value)
  end

  def visit_lt(node, collector)
    field = get_col node.next
    value = get_col node.next
    field.lt(value)
  end

  def visit_lteq(node, collector)
    field = get_col node.next
    value = get_col node.next
    field.lteq(value)
  end

  def visit_not_in(node, collector)
    field = get_col node.next
    value = get_col node.next
    field.not_in(value)
  end

  def visit_in(node, collector)
    field = get_col node.next
    value = get_col node.next
    field.in(value)
  end

  def visit_in(node, collector)
    field = get_col node.next
    value = get_col node.next
    field.in(value)
  end

  def visit_matches(node, collector)
    field = get_col node.next
    value = get_col node.next
    field.matches_regexp(value)
  end

  def visit_not_matches(node, collector)
    field = get_col node.next
    value = get_col node.next
    field.does_not_match(value)
  end

  def visit_exists(node, collector)
    n = node.next
    q = process_args(n, :query)
    Query.new.with_ctx(exists: true).(q)
  end

  def visit_not_exists(node, collector)
    n = node.next
    q = process_args(n, :query)
    Query.new.with_ctx({ not_exists: true }).(q)
  end
end

class Selector
  include ValueParser
  attr_reader :collector
  attr_reader :alias
  attr_reader :ctx

  # previous code up here
  def initialize(arel_table = nil)
    @collector = (arel_table.is_a?(Symbol) or arel_table.is_a?(String)) ? create_arel(arel_table.to_sym) : arel_table
    @alias = @collector.name if @collector
    @default_predicate = create_predicate(@alias) if @alias
  end

  def with_ctx(_ctx)
    @ctx = _ctx
  end

  def create_predicate(s)
    Predicate.new(s)
  end

  def create_arel(name)
    Arel::Table.new(name)
  end

  def visit(c, is_group = false)
    return @collector.project(Arel.star) if @collector and c.nil?

    d = { fields: c.dup } if c.is_a?(Array)
    d = c.dup if c.is_a?(Hash) and c[:fields]

    cols = d[:fields].map do |f|
      get_col(f)
    end
    return cols if !@collector
    if !is_group
      tmp = @collector.project(*cols)
      return tmp if c.is_a?(Hash) and !true?(c[:distinct])
      return tmp.distinct if c.is_a?(Hash) and true?(c[:distinct]) #if cols.length ==
      return tmp
    else
      return @collector.group(*cols)
    end
    #raise StandardError("Distinct on multiple columns error #{cols.inspect}")
  end

  def visit_extract(node, args)
    f = get_col(args[0])
    return f.extract(node[:from]) #, node[:alias] #get_alias(Arel.sql("EXTRACT(#{node[:from]} FROM #{f.to_sql})"))
  end

  def call(conf, is_group = false)
    Selector.new(@alias).visit(conf, is_group)
  end
end

class Query
  include ValueParser
  attr_reader :query, :selector, :predicator, :ctx

  def create_arel(name, al = nil)
    tmp = Arel::Table.new(name)
    if al
      tmp.table_alias = al
    end
    tmp
  end

  def with_ctx(_ctx)
    @ctx = @ctx ? @ctx.merge(_ctx) : _ctx
    self
  end

  def get_join_type(t)
    return Arel::Nodes::InnerJoin if t == "inner_join"
    return Arel::Nodes::OuterJoin if t == "outer_join"
    return Arel::Nodes::CrossJoin if t == "cross_join"
    return Arel::Nodes::LeftJoin if t == "left_join"
    return Arel::Nodes::CrossJoinLateral if t == "cross_join_lateral"
    return Arel::Nodes::LeftJoinLateral if t == "left_join_lateral"
    return Arel::Nodes::NormalJoin
  end

  def with_alias(al, q, with_name: al, is_materialized: false)
    cte_table = Arel::Table.new(with_name)
    cte_table.instance_variable_set(:@is_materialized, is_materialized)
    cte_table.instance_variable_set(:@cte_name, with_name)
    return cte_table, Arel::Nodes::As.new(cte_table, q)
  end

  def call(table, to_sql = false)
    if table.is_a?(Symbol)
      arel = create_arel(table, table[:alias])
    end
    if table[:from].is_a?(Symbol)
      arel = create_arel(table[:from], table[:alias])
    end
    if table[:from].is_a?(Hash) and table[:from][:select]
      #sub_query_from = call(table[:from])
      #return Query.new.(table[:from], to_sql)
      table[:from][:query] = table[:from]
      #al = table[:alias] || table[:from][:from]
      #sub_query_from = sub_query_from.as(al) if al
    end

    if !arel and table[:values].is_a?(Array)
      values = table[:values].map do |kk|
        [kk[:key], kk[:value]]
      end
      values_from = grouping(
        values_list(values),
      )
      return Arel.sql("#{values_from.to_sql}") #.as(table[:alias])
    end

    if table[:from].is_a?(Hash) and table[:from][:crosstab]
      cts = table[:from][:crosstab]
      q1 = Query.new.(cts[0])
      q2 = Query.new.(cts[1])
      al = table[:from][:alias]
      ct = table[:from][:fields]
      cross_tab_query = crosstab(q1, q2, al, ct)
       #= crt.to_sql if to_sql
      #puts "SSS: #{sub_query_from.to_sql}"
    end

    if table[:from].is_a?(Hash) and table[:from][:operator]
      operator_from = get_col(table[:from])

      if table[:alias]
        operator_from = as(operator_from, Arel.sql(table[:alias]))
      end
      #puts "FROM #{from.to_sql}"
      qu = Selector.new(table[:alias]).(table[:select])
      if qu.is_a?(Array)
        return Arel.sql("SELECT #{qu.map(&:to_sql).join(", ")} FROM #{operator_from.to_sql}") #.as(table[:alias])
      else
        return qu.from(operator_from)
      end
    end

    sym = table[:from]

    if !arel and sym.is_a?(Hash) and sym[:values].is_a?(Array)
      values = sym[:values].map do |kk|
        [kk[:key], kk[:value]]
      end
      values_from = as(grouping(
        values_list(values),
      ), Arel.sql("#{ct(table[:alias], table[:fields]).to_sql}"))
      qu = Selector.new(table[:alias]).(table[:select])
      if qu.is_a?(Array)
        return Arel.sql("SELECT #{qu.map(&:to_sql).join(", ")} FROM #{values_from.to_sql}") #.as(table[:alias])
      else
        return qu.from(values_from) #.as(table[:alias])
      end
    end

    #sub_query_from = nil
    if !arel and sym.is_a?(Hash) and sym[:query]
      sym[:alias] = sym[:alias] || sym[:query][:from]
      j = sym[:query]
      sub_query_from = Query.new.(j)
      sub_query_from = sub_query_from.as(sym[:alias]) if sym[:alias]
    end

    if !arel and sub_query_from
      from = sym[:query][:from]
      arel = create_arel(from, sym[:alias])
      @predicator = Predicate.new(from)
      @selector = Selector.new(from) #.collector.from(sub_query_from)
    else
      arel = create_arel(sym, table[:alias])
      arel.table_alias = table[:alias]
      @predicator = Predicate.new(arel)
      @selector = Selector.new(arel)
      #puts "QUERY: #{query.to_sql}"
    end
    query = arel
    sels = table[:select]
    query = @selector.(sels)

    if table[:distinct_where] and table[:distinct_where].is_a?(Array)
      colls = table[:distinct_where].map do |d|
        get_col(d)
      end
      query = query.distinct_on(*colls)
    end
    if table[:distinct]
      query = query.distinct      
    end
    query = query.from(sub_query_from) if sub_query_from
    query = query.from(arel) if !sub_query_from
    query = query.from(cross_tab_query) if cross_tab_query

    if table[:where]
      cond = @predicator.(table[:where])
      query = query.where(cond)
    end

    if table[:limit]
      query = query.take(table[:limit])
    end
    if table[:top]
      query = query.take(table[:top].to_i).skip(0)
    end
    if table[:offset]
      query = query.skip(table[:offset])
    end
    group_by = table[:group] || table[:group_by]
    if group_by
      cols = group_by.map do |c|
        get_col(c)
      end
      query = query.group(*cols)
    end

    if table[:having]
      query = query.having(@predicator.(table[:having]))
    end
    order_by = table[:order] || table[:order_by]
    if order_by.is_a?(Array) # && table[:order][:fields]
      orders = order_by.map do |o|
        o.delete(:apply) if o[:apply]
        t = o[:by]
        field = o[:field]
        next "#{field} #{t}" if field and t
        next "#{field}" if field
        next o if o.is_a?(String)
      end.join(",")
      query = query.order(Arel.sql(sanitize(orders)))
    end

    if table[:window]
      table[:window].each do |w|
        wi = query.window(w[:name])
        wi.frame(Arel.sql(w[:as]))
      end
    end

    if table[:intersect]
      table[:intersect].each do |j|
        j[:alias] = j[:alias] || j[:query][:from]
        tmp_query = Query.new.(j[:query])
        query = query.intersect(tmp_query)
      end
    end

    if table[:union] || table[:except]
      if table[:union]
        table[:union].each do |j|
          j[:alias] = j[:alias] || j[:query][:from]
          tmp_query = Query.new.(j[:query])
          if j[:all]
            query = Arel::Nodes::UnionAll.new(query, tmp_query)
          else
            query = query.union(tmp_query)
          end
        end
      end
      if table[:except]
        raise "Require Union or Intersect" if !table[:union] and !table[:intersect]

        table[:except].each do |j|
          j[:alias] = j[:alias] || j[:query][:from]
          tmp_query = Query.new.(j[:query])

          query = Arel::Nodes::Except.new(query, tmp_query)
        end
      end
    end

    withs = []
    if table[:with]
      table[:with].each do |j|
        #j1 = j.except(:alias)
        #jq = j1[:from] || j1[:query]
        tmp_query = Query.new.(j)
        alias_query = ct(j[:alias], j[:fields])
        alias_query = alias_query.to_sql unless alias_query.is_a?(String)
        #ori, al = with_alias(j[:alias], tmp_query, with_name: j[:alias], is_materialized: j[:materialized] || false)
        #al = ct(j[:alias], j[:fields])
        ori, al = with_alias(alias_query, tmp_query, with_name: j[:alias], is_materialized: j[:materialized] || false)
        #puts "AL: #{al}"
        if j[:recursive]
          withs << tmp_query.with(:recursive, al)
        else
          withs << al
        end
      end
    end
    if table[:join]
      table[:join].each do |j|
        jq = j[:from] || j[:query]
        if !jq.is_a?(Hash)
          ori = create_arel(jq, j[:alias])

          if j[:where]
            tmp_cond = Predicate.new(ori).(j[:where])
            #ori = ori.as(j[:alias]) if j[:alias]
            query = query.join(ori, get_join_type(j[:type])).on(tmp_cond)
            next
          else
            query = query.join(ori, get_join_type(j[:type]))
            next
          end
        end
        tmp_query = Query.new.(jq)

        alias_query = j[:alias] || jq
        ori, al = with_alias(j[:alias], tmp_query, with_name: j[:cte] || jq, is_materialized: j[:materialized] || false)

        tmp_cond = lit("true") if j[:where] and true?(j[:where])
        tmp_cond = Predicate.new(ori).(j[:where]) if !tmp_cond and j[:where] #: lit("true")
        tmp_cond = { using: j[:using] } if !tmp_cond and j[:using]

        if j[:lateral]
          j[:type] = "#{j[:type] || "left_outer"}_lateral"
        end
        query = query.join(tmp_query.as(alias_query), get_join_type(j[:type])).on(tmp_cond)
        # if !j[:cte]
        #   query = query.join(tmp_query.as(alias_query), get_join_type(j[:type])).on(tmp_cond)
        # else
        #   query = query.join(ori, get_join_type(j[:type])).on(tmp_cond)
        #   if j[:cte]
        #     if j[:recursive]
        #       query = query.with(:recursive, al)
        #     else
        #       withs << al
        #     end
        #   end
        # end
      end
    end

    if withs.length > 0
      query = query.with(withs)
    end

    if @ctx
      if @ctx[:exists]
        query = query.exists
      end
      if @ctx[:not_exists]
        query = query.exists.not
      end
      #   if @ctx && @ctx[:lateral]
      #     query = query.lateral(@ctx[:lateral])
      #     puts "lateral: #{query.to_sql}"
      #   end
    end

    return to_sql ? query.to_sql : query
  end
end

def pg_connection
  ActiveRecord::Base.establish_connection("postgres://lucky:password@localhost:6543/backend_development")
end

def sqlite_connection
  ActiveRecord::Base.establish_connection :adapter => "sqlite3",
                                          :database => "file::memory:?cache=shared",
                                          :flags => 70 # SQLite3::Constants::Open::READWRITE | CREATE | URI
end

def test
  pg_connection
  #sqlite_connection
  #template = Liquid::Template.parse(
  #  File.read(File.join(__dir__, "queries/get_active_users.yml"))
  #).render(
  #  grouped_field1: "groupedField1",
  #)
  #puts template
  #cnf = YAML::load_file(, aliases: true, symbolize_names: true)
  #file_path = File.expand_path("./queries/get_active_users.yml", __FILE__)
  #yaml_contents = File.read("./tutorials/1_find_duplicated_rows.yml")
  yaml_contents = File.read("./queries/simple.yml")
  r = Psych.safe_load(yaml_contents, aliases: true, symbolize_names: true)
  #src = YAML.parse(data)
  # src.select{ |node| node.is_a?(Psych::Nodes::Scalar) &&
  #%w(on off).include?(node.value) }
  #.each{|node| node.quoted = true }

  q = Query.new.(r[:main], true)

  puts q
  #validate_sql!(q)

  #   insert = Arel::Nodes::InsertStatement.new
  #   insert.relation = Arel::Table.new(:movies)
  #   cols = ["a", "b"]
  #   insert.columns = cols.map { |k| Arel::Table.new(:movies)[k] }
  #   puts Arel.sql(%Q{
  #     #{insert.to_sql}
  #     #{q}
  #   })
  #r = Psych.safe_load(yaml_contents2, aliases: true, symbolize_names: true)
  #q = Query.new.(r[:simple], true)
  #puts q
  #   columns = [:a, :b, :c]
  #   values = [[1, 2, 3], [4, 5, 6]]
  #   t = values_list(values)
  #   a = as(lit("p(a, b, c)"), grouping(t))
  #   puts a.to_sql
end

def executeQuery
  connection = ActiveRecord::Base.connection.raw_connection
connection.prepare('some_name', "DELETE FROM my_table WHERE id = $1")
st = connection.exec_prepared('some_name', [ id ])
end

class QueryRunner
  def run!(r)
    q = Query.new.(r[:main], true)
    puts "QUERY: #{q}"
    validate_sql!(q)
    q
  rescue => e
    puts "EEE: #{e}"
    e.message
    e.backtrace
  end
end
