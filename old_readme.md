# What would a more-generic `traject` pipeline look like?

## Thought #1: pass around `capsules`

_`traject` bases its computational units on procs that take 2-3 arguments: the input record,
an initially-empty accumulator (just an array), and a context object that holds the output
object as well as random cached data. Let's collapse that into a single object we'll
call a **capsule**_

`traject` passes around separate objects that, semantically, are tightly coupled. Let's just go ahead and
package them together into a single object called a _capsule_ (the things that buzz around in 
pneumatic tubes are often called capsules). A `capsule` is a composed object that might have
parts like this:

  * `#input_object` 
    * should we just say it has to implement a `unique_id` method to make life
      easier for the very very very common case? It should be easy enough for folks
      to wrap a caching `uuid` call if need be.  
  * `#output_object`, which responds to
    * `#set_field(field, value)` (upsert)
    * `#append_to_field(field, value_or_values, flatten: true)` # always ends up as an array
    * `#delete_field(field)`
    * `#get_field(field)`
    * `#merge(other_output_object)`, for map/reduce  -- someday.  
  * `#cache_put(key, value)`
  * `#cache_get(key)`
  * `#cache_delete(key)`

[Need to think about thread-safety semantics for all the capsule components. I think I'll
start with "no guarantees" and add in thread safety if it looks like we might want to share
individual capsules across multiple threads (as opposed to having multiple threads that
work on disjoint sets of capsules)] 


## Thought #2: Pipelines are composed of _steps_

_Simplify the processing interface to just be a call that takes in a capsule
and outputs a capsule_

A _step_ is anything that has a method `#call(capsule) -> capsule`. If we wanted to,
the `traject` macro `to_field` (which appends any values in a passed accumulator to a field)
could be rewritten (and over-simplified) to look something like

```ruby
def to_field(name, blk)
  ->(capsule) {
    acc  = []
    blk.call(capsule.input_object, acc)
    unless acc.empty?
      capsule.append_to_field(name, acc, flatten: true)
    end
    capsule
  }
end

```


## Thought #3: Pipelines are chainable and pass around CapsuleStreams

_`traject` has no good, clean way to batch operations across a set of input records
(to, for example, allow making one database call per N records instead of one
for **each** record). Provide a structure that simplifies working on batches._

A **capsule stream** is a rewindable enumerable (probably mostly an array)
that yields individual capsules. We can bundle steps into subpipes that
work take in a capsule stream and output the same, making it easier to batch 
things up.

[Side note: I'd like to generalize the capstream as a stream, but that means
a lot of by-hand rewinding. If the implementation is actually an array, well,
all that is kind of unnecessary confusion. Maybe need to wrap capstream-level
operations in a subpipe into `setup` or implement `each_cap_then_rewind` or some
damn thing.]

One can imagine a syntax like this:

```ruby

subpipe(:some_arbitrary_name) do |capstream|
  
  # Cache stuff from the caps for later?
  let(:ids) { capstream.map{|cap| cap.get_field(:id) }
  
  # Do one sql query
  let(:id_holdings_map) { MySqlQueryThing.get_holdings(ids: ids) }
  to_field(:holdings) {|cap| id_holdings_map[c.cache[:id]]} 
  
  # Clean up after ourselves, although probably counterproductive in this situation
 capstream.each do |c|
   c.cache_delete(:id) 
 end  
end

```

Note, however, that a CapStream is just an enumerable object. You can create your own
with your own methods, which would probably be nicer.

```ruby
class MyCapStream < CapStream
  def id_holdings_map
    self.rewind
    return @id_holdings_map if defined? @id_holdings_map
    ids = self.map{|cap| cap.record.id}
    self.rewind      
    @id_holdings_map = MySqlQueryThing.get_holdings_map(ids: ids)
  end
  
  def holidings_for(id)
    id_holdings_map[id]
  end
end

subpipe(:holdings_stuff) do |capstream|
  to_field(:holdings) {|cap| capstream.holdings_for(cap.get_field(:id))}
end


```

## Thought #4: Bags and Subpipes (argh! Complexity!)

In addition to being chainable, subpipes could have a variety of other characteristics
to make building the flow easier. One obvious one is whether or not to  guarantee that 
the steps (or sub-subpipes) will be executed in order.

A _subpipe_ is order-guaranteed; a _bag_ is assumed to be full of independent operations
and can be executed in any order (or even in parallel) without trouble.

The problem with the multithreading is that there needs to be a valid `merge` operation
that can work on capstreams, and that seems...fraught. 


## Pseudocode playground

What might it look like if we were to define a flow similar to a traject flow?

* a reader pulls in a group of marc records and folds them into a capsule. 
* add a bunch of fields using `to_field`
* run through a subpipe where we do all the title nonsense (filing title, vtitle, etc.)
  since there are inter-dependencies among them
* Get a bunch of holdings information from a database
* add in some hathitrust info
* write to solr
* write some subset of stuff to a file, just to show we can


### Create a useful capsule

```ruby
# lib/my_trajectish/my_marc_capsule.rb

# Take a standard capsule, but provide an 'id' method on it
# just to show that we can.
# 
# And no, it's not clear to me that we wouldn't be better off using
# `Module.prepend` on the MARC::Record object, or writing
# a marc reader that actually lets you pass in a factory object, or
# maybe just using `extend` on the individual records. Will have to
# run benchmarks on all of those things if it seems important.
  
class MyMarcCapsule < Trajectish::Capsule
  def id
    @id = input_record['001'].value
  end
end

# ... and provide a factory for producing them. Again, this could
# be a lot more involved 
class MyMarcCapsule::Factory
  def from(input_record)
    MyMarcCapsule.new(input_record)
  end
end


# lib/my_trajectish/my_marc_reader.rb

# Change the default reader just enough that we can set the raw reader
# and provide a factory object that will turn raw input records into
# capsules. These are very simple, but need not be.
 
class MyMarcReader < Trajectish::GenericReader
  def initialize(settings)
    inputfile = settings['marcreader.input_file'] || settings['input_file']
    io = if inputfile
           File.open(inputfile)
         else
           $stdin    
        end
    self.raw_reader = MARC::Reader.new(io)
    self.capsule_factory = MyMarcCapsule::Factory.new
  end
end
 

```

### Set up to ues the capsule

```ruby
# readers/marcreader.rb

require 'my_traject/my_marc_reader'
settings do |s|
  provide "reader", MyMarcReader.new(s)
end

```

# OK. Let's imagine making a subpipe in the style a current traject

```ruby
# indexers/common.rb

subpipe(name: 'common') do 
  to_field :id, {|cap| cap.id}
  to_field :isbn, extract_marc('020a')
  # ... etc.
end

```

When that file is encountered as being used, it's instance-eval'd in the context
of the current (probably top-level) pipeline. The result of that evaluation is a lambda
that ...err...passes the capsule_stream internally to ....hmmmm. Better just go write the code
so I know what I'm getting at.

I *think* what I'm looking for is to end up with 
```ruby

def subpipe(name:, &blk)
  new_pipe = Trajectish::Pipe.new
  new_pipe.instance_eval &blk
  add_pipe(name, new_pipe)
end

```

...where a pipe defines `#call(capstream)`. But again, I'll have to code it up.  

```sh
# Command line invocation, like current traject: `-c` to load a config file,
# and `-s` to set a key/value that can be picked up by anyone via a settings object
#
# Major difference is that we don't assume data coming in from a file or anything --
# just define a reader that can pull other settings in
trajectish -I./lib 
  -c readers/marcreader.rb \
  -c indexers/common.rb \
  -c indexers/title.rb \
  -c indexers/holdings.rb
  -c indexers/hathitrust.rb \
  -c writers/write_to_solr.rb \
  -c writers/write_some_info_to_file.rb \
  -c settings/test_solr_settings.rb \
  -c settings/test_
  -s file_to_write_info_to=./myinfo.txt
  -s inputfile=/my/data/infile.mrc \

```  

```ruby

require 'all/sorts/of/stuff'





```





```ruby


Traject::Pipeline.new(reader: my_enumerable_reader, batch_size: 100) do
  include Traject::Pipeline::Macros::Marc21
  
  
  bag do |capset| # implies order-independent operations; could be parallized
    to_field 'id', extract_marc('001')
    to_field 'title', extract_marc_title
    # ...
  end
  
  let(:sql_holdings) { |capset| hydrate_holdings_from_sql(capset) }

  to_field 'holdings' do |capsule|
    sql_holdings[capsule.get('id')]
  end
  
  add_step MyStepOobject.new

```
   
    




