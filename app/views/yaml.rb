require "active_support/core_ext/hash/keys"

class Hash
  def fetch_path(*parts)
    parts.reduce(self) do |memo, key|
      memo[key.to_s] if memo
    end
  end
end

def deep_copy(o)
  Marshal.load(Marshal.dump(o))
end

def recursive_gsub!(search, replace, value)
  case value
  when String
    value.gsub!(search, replace)
  when Array, Hash
    value.each { |v| recursive_gsub!(search, replace, v) }
  end
end

class YamlView
  def ctx
    @ct
  end

  def process(ct)
    @origin = ct[:declare].clone
    @ct = ct
    nested_hash_value(@ct, :apply)
    puts "CT: #{@ct}"
  end

  def nested_hash_value(obj, key)
    if obj.respond_to?(:key?) && obj.key?(key)
      new_obj = apply(obj, key)
      obj.merge!(new_obj)
      #@origin[:declare][]
    elsif obj.respond_to?(:each)
      obj.each do |ob|
        nested_hash_value(ob, key)
      end
    end
  end

  def apply(obj, key)
    main, *args = obj[key]
    fname = main.to_sym
    str_args = args.map(&:to_s)
    fn = deep_copy(@origin)[fname]
    str_args.each_with_index do |arg, idx|
      ptr = "$#{(idx + 1).to_s}"
      recursive_gsub!(ptr, arg, fn)
    end
    fn
  end
end
