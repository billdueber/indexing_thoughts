require_relative 'generic_capsule'

module GedankenETL
  class MARCCapsule < SimpleDelegator
    include GenericCapsuleInclude

    # Same as the generic, but let's forward everything
    # to the input record to make life a little easier
    #
    # Also pass in an extract_marc factory, which we'll assume will
    # create a lambda based on the extract_marc_spec and memoize it
    # across the whole run. Obviously, this is just one way to do
    # this.
    def initialize(input_record, extract_marc_memoizer:)
      super
      __setobj__(self.input_record)
      @extract_marcs = extract_marc_memoizer
    end

    def extract_marc(extract_marc_spec, post_process: [], &blk)
      callable = extract_marcs[extract_marc_spec]
      value = callable.call(record)


    end

  end
end
