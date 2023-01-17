require "active_support/core_ext/hash/keys"

class Hash
  def fetch_path(*parts)
    parts.reduce(self) do |memo, key|
      memo[key.to_s] if memo
    end
  end
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
    @origin = ct
    @ct = ct
    nested_hash_value(@ct, :apply)
    puts "CT: #{@ct}"
  end

  def nested_hash_value(obj, key)
    if obj.respond_to?(:key?) && obj.key?(key)
      obj.merge!(apply(obj, key))
    elsif obj.respond_to?(:each)
      obj.each do |ob|
        nested_hash_value(ob, key)
      end
    end
  end

  def apply(obj, key)
    main, *args = obj[key]
    fname = main.to_sym
    fn = @ct[:declare][fname]
    args.each_with_index do |arg, idx|
      ptr = "$#{(idx + 1).to_s}"
      recursive_gsub!(ptr, arg, fn)
    end
    obj.delete key
    fn
  end
end
