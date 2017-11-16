module GedankenETL

  # The simplest of stores: #get, #set, #append, #drop
  class SimpleStore
    def initialize
      @raw = {}
    end

    def set(key, value)
      @raw[key] = value
    end

    def get(key)
      @raw[key]
    end

    def append(key, value)
      @raw[key] = Array(@raw[key]).push value
    end

    def drop(key)
      @raw.delete(key)
    end
    alias_method :delete, :drop
  end

  module GenericCapsuleInclude
    attr_reader :input_record, :output_record, :rawcache

    # Create a new object with the input/output/cache. Note that we'll probably
    # violate the crap out of the Law of Demeter, but I feel ok about that.
    #
    # Note how easy it would be to replace the output record with, say, a dedicated
    # solr document or something.

    attr_reader :input_record, :output_record, :cache
    def initialize(input_record,
                   output_record_factory: ->(_input_record) { GedankenETL::SimpleStore.new },
                   cache: GedankenETL::SimpleStore.new)
      @input_record  = input_record
      @output_record = output_record_factory.(input_record)
      @cache = cache
    end

    alias_method :ir, :input_record
    alias_method :or, :output_record
  end

  class GenericCapsule
    include GenericCapsuleInclude
  end

end
