# AUTHOR

Dobrica Pavlinusic

Modified by Ichinose Shogo <shogo82148@gmail.com>

# SYNOPSIS

    ## Defaults to $ENV{REDIS_SERVER} or 127.0.0.1:6379
    my $redis = Redis->new;

    my $redis = Redis->new(server => 'redis.example.com:8080');

    ## Set the connection name (requires Redis 2.6.9)
    my $redis = Redis->new(
      server => 'redis.example.com:8080',
      name => 'my_connection_name',
    );
    my $generation = 0;
    my $redis = Redis->new(
      server => 'redis.example.com:8080',
      name => sub { "cache-$$-".++$generation },
    );

    ## Use UNIX domain socket
    my $redis = Redis->new(sock => '/path/to/socket');

    ## Enable auto-reconnect
    ## Try to reconnect every 500ms up to 60 seconds until success
    ## Die if you can't after that
    my $redis = Redis->new(reconnect => 60);

    ## Try each 100ms upto 2 seconds (every is in milisecs)
    my $redis = Redis->new(reconnect => 2, every => 100);

    ## Disable the automatic utf8 encoding => much more performance
    ## !!!! This will be the default after 2.000, see ENCODING below
    my $redis = Redis->new(encoding => undef);

    ## Use all the regular Redis commands, they all accept a list of
    ## arguments
    ## See http://redis.io/commands for full list
    $redis->get('key');
    $redis->set('key' => 'value');
    $redis->sort('list', 'DESC');
    $redis->sort(qw{list LIMIT 0 5 ALPHA DESC});

    ## Add a coderef argument to run a command in the background
    $redis->sort(qw{list LIMIT 0 5 ALPHA DESC}, sub {
      my ($reply, $error) = @_;
      die "Oops, got an error: $error\n" if defined $error;
      print "$_\n" for @$reply;
    });
    long_computation();
    $redis->wait_all_responses;
    ## or
    $redis->wait_one_response();

    ## Or run a large batch of commands in a pipeline
    my %hash = _get_large_batch_of_commands();
    $redis->hset('h', $_, $hash{$_}, sub {}) for keys %hash;
    $redis->wait_all_responses;

    ## Publish/Subscribe
    $redis->subscribe(
      'topic_1',
      'topic_2',
      sub {
        my ($message, $topic, $subscribed_topic) = @_

          ## $subscribed_topic can be different from topic if
          ## you use psubscribe() with wildcards
      }
    );
    $redis->psubscribe('nasdaq.*', sub {...});

    ## Blocks and waits for messages, calls subscribe() callbacks
    ##  ... forever
    my $timeout = 10;
    $redis->wait_for_messages($timeout) while 1;

    ##  ... until some condition
    my $keep_going = 1; ## other code will set to false to quit
    $redis->wait_for_messages($timeout) while $keep_going;

    $redis->publish('topic_1', 'message');



# DESCRIPTION

Pure perl bindings for [http://redis.io/](http://redis.io/)

This version supports protocol 2.x (multi-bulk) or later of Redis available at
[https://github.com/antirez/redis/](https://github.com/antirez/redis/).

This documentation lists commands which are exercised in test suite, but
additional commands will work correctly since protocol specifies enough
information to support almost all commands with same piece of code with a
little help of `AUTOLOAD`.



# PIPELINING

Usually, running a command will wait for a response.  However, if you're doing
large numbers of requests, it can be more efficient to use what Redis calls
_pipelining_: send multiple commands to Redis without waiting for a response,
then wait for the responses that come in.

To use pipelining, add a coderef argument as the last argument to a command
method call:

    $r->set('foo', 'bar', sub {});

Pending responses to pipelined commands are processed in a single batch, as
soon as at least one of the following conditions holds:

- A non-pipelined (synchronous) command is called on the same connection
- A pub/sub subscription command (one of `subscribe`, `unsubscribe`,
`psubscribe`, or `punsubscribe`) is about to be called on the same
connection.
- One of ["wait\_all\_responses"](#wait\_all\_responses) or ["wait\_one\_response"](#wait\_one\_response) methods is called
explicitly.

The coderef you supply to a pipelined command method is invoked once the
response is available.  It takes two arguments, `$reply` and `$error`.  If
`$error` is defined, it contains the text of an error reply sent by the Redis
server.  Otherwise, `$reply` is the non-error reply. For almost all commands,
that means it's `undef`, or a defined but non-reference scalar, or an array
ref of any of those; but see ["keys"](#keys), ["info"](#info), and ["exec"](#exec).

Note the contrast with synchronous commands, which throw an exception on
receipt of an error reply, or return a non-error reply directly.

The fact that pipelined commands never throw an exception can be particularly
useful for Redis transactions; see ["exec"](#exec).



# ENCODING

__This feature is deprecated and will be removed before 2.000__. You should
start testing your code with `encoding => undef` because that will be the
new default with 2.000.

Since Redis knows nothing about encoding, we are forcing utf-8 flag on all data
received from Redis. This change was introduced in 1.2001 version. __Please
note__ that this encoding option severely degrades performance.

You can disable this automatic encoding by passing an option to ["new"](#new): `encoding => undef`.

This allows us to round-trip utf-8 encoded characters correctly, but might be
problem if you push binary junk into Redis and expect to get it back without
utf-8 flag turned on.



# METHODS

## Constructors

### new

    my $r = Redis->new; # $ENV{REDIS_SERVER} or 127.0.0.1:6379

    my $r = Redis->new( server => '192.168.0.1:6379', debug => 0 );
    my $r = Redis->new( server => '192.168.0.1:6379', encoding => undef );
    my $r = Redis->new( sock => '/path/to/sock' );
    my $r = Redis->new( reconnect => 60, every => 5000 );
    my $r = Redis->new( password => 'boo' );
    my $r = Redis->new( on_connect => sub { my ($redis) = @_; ... } );
    my $r = Redis->new( name => 'my_connection_name' );
    my $r = Redis->new( name => sub { "cache-for-$$" });

The `server` parameter specifies the Redis server we should connect to,
via TCP. Use the 'IP:PORT' format. If no `server` option is present, we
will attempt to use the `REDIS_SERVER` environment variable. If neither of
those options are present, it defaults to '127.0.0.1:6379'.

Alternatively you can use the `sock` parameter to specify the path of the
UNIX domain socket where the Redis server is listening.

The `REDIS_SERVER` can be used for UNIX domain sockets too. The following
formats are supported:

- /path/to/sock
- unix:/path/to/sock
- 127.0.0.1:11011
- tcp:127.0.0.1:11011

The `encoding` parameter speficies the encoding we will use to decode all
the data we receive and encode all the data sent to the redis server. Due to
backwards-compatibility we default to `utf8`. To disable all this
encoding/decoding, you must use `encoding => undef`. __This is the
recommended option__.

__Warning__: this option has several problems and it is __deprecated__. A
future version might add other filtering options though.

The `reconnect` option enables auto-reconnection mode. If we cannot
connect to the Redis server, or if a network write fails, we enter retry mode.
We will try a new connection every `every` miliseconds (1000ms by
default), up-to `reconnect` seconds.

Be aware that read errors will always thrown an exception, and will not trigger
a retry until the new command is sent.

If we cannot re-establish a connection after `reconnect` seconds, an
exception will be thrown.

If your Redis server requires authentication, you can use the `password`
attribute. After each established connection (at the start or when
reconnecting), the Redis `AUTH` command will be send to the server. If the
password is wrong, an exception will be thrown and reconnect will be disabled.

You can also provide a code reference that will be immediatly after each
sucessfull connection. The `on_connect` attribute is used to provide the
code reference, and it will be called with the first parameter being the Redis
object.

You can also set a name for each connection. This can be very useful for
debugging purposes, using the `CLIENT LIST` command. To set a connection
name, use the `name` parameter. You can use both a scalar value or a
CodeRef. If the latter, it will be called after each connection, with the Redis
object, and it should return the connection name to use. If it returns a
undefined value, Redis will not set the connection name.

Please note that there are restrictions on the name you can set, the most
important of which is, no spaces. See the [CLIENT SETNAME documentation](http://redis.io/commands/client-setname) for all the juicy
details. This feature is safe to use with all versions of Redis servers. If `CLIENT SETNAME` support is not available (Redis servers 2.6.9 and above
only), the name parameter is ignored.

The `debug` parameter enables debug information to STDERR, including all
interactions with the server. You can also enable debug with the `REDIS_DEBUG`
environment variable.



## Connection Handling

### quit

    $r->quit;

Closes the connection to the server. The `quit` method does not support
pipelined operation.

### ping

    $r->ping || die "no server?";

The `ping` method does not support pipelined operation.

### client\_list

    @clients = $r->client_list;

Returns list of clients connected to the server. See [CLIENT LIST documentation](http://redis.io/commands/client-list) for a description of the
fields and their meaning.

### client\_getname

    my $connection_name = $r->client_getname;

Returns the name associated with this connection. See ["client\_setname"](#client\_setname) or the
`name` parameter to ["new"](#new) for ways to set this name.

### client\_setname

    $r->client_setname('my_connection_name');

Sets this connection name. See the [CLIENT SETNAME documentation](http://redis.io/commands/client-setname) for restrictions on the
connection name string. The most important one: no spaces.

## Pipeline management

### wait\_all\_responses

Waits until all pending pipelined responses have been received, and invokes the
pipeline callback for each one.  See ["PIPELINING"](#PIPELINING).

### wait\_one\_response

Waits until the first pending pipelined response has been received, and invokes
its callback.  See ["PIPELINING"](#PIPELINING).



## Transaction-handling commands

__Warning:__ the behaviour of these commands when combined with pipelining is
still under discussion, and you should __NOT__ use them at the same time just
now.

You can [follow the discussion to see the open issues with this](https://github.com/melo/perl-redis/issues/17).

### multi

    $r->multi;

### discard

    $r->discard;

### exec

    my @individual_replies = $r->exec;

`exec` has special behaviour when run in a pipeline: the `$reply` argument to
the pipeline callback is an array ref whose elements are themselves `[$reply,
$error]` pairs.  This means that you can accurately detect errors yielded by
any command in the transaction, and without any exceptions being thrown.



## Commands operating on string values

### set

    $r->set( foo => 'bar' );

    $r->setnx( foo => 42 );

### get

    my $value = $r->get( 'foo' );

### mget

    my @values = $r->mget( 'foo', 'bar', 'baz' );

### incr

    $r->incr('counter');

    $r->incrby('tripplets', 3);

### decr

    $r->decr('counter');

    $r->decrby('tripplets', 3);

### exists

    $r->exists( 'key' ) && print "got key!";

### del

    $r->del( 'key' ) || warn "key doesn't exist";

### type

    $r->type( 'key' ); # = string



## Commands operating on the key space

### keys

    my @keys = $r->keys( '*glob_pattern*' );
    my $keys = $r->keys( '*glob_pattern*' ); # count of matching keys

Note that synchronous `keys` calls in a scalar context return the number of
matching keys (not an array ref of matching keys as you might expect).  This
does not apply in pipelined mode: assuming the server returns a list of keys,
as expected, it is always passed to the pipeline callback as an array ref.

### randomkey

    my $key = $r->randomkey;

### rename

    my $ok = $r->rename( 'old-key', 'new-key', $new );

### dbsize

    my $nr_keys = $r->dbsize;



## Commands operating on lists

See also [Redis::List](http://search.cpan.org/perldoc?Redis::List) for tie interface.

### rpush

    $r->rpush( $key, $value );

### lpush

    $r->lpush( $key, $value );

### llen

    $r->llen( $key );

### lrange

    my @list = $r->lrange( $key, $start, $end );

### ltrim

    my $ok = $r->ltrim( $key, $start, $end );

### lindex

    $r->lindex( $key, $index );

### lset

    $r->lset( $key, $index, $value );

### lrem

    my $modified_count = $r->lrem( $key, $count, $value );

### lpop

    my $value = $r->lpop( $key );

### rpop

    my $value = $r->rpop( $key );



## Commands operating on sets

### sadd

    my $ok = $r->sadd( $key, $member );

### scard

    my $n_elements = $r->scard( $key );

### sdiff

    my @elements = $r->sdiff( $key1, $key2, ... );
    my $elements = $r->sdiff( $key1, $key2, ... ); # ARRAY ref

### sdiffstore

    my $ok = $r->sdiffstore( $dstkey, $key1, $key2, ... );

### sinter

    my @elements = $r->sinter( $key1, $key2, ... );
    my $elements = $r->sinter( $key1, $key2, ... ); # ARRAY ref

### sinterstore

    my $ok = $r->sinterstore( $dstkey, $key1, $key2, ... );

### sismember

    my $bool = $r->sismember( $key, $member );

### smembers

    my @elements = $r->smembers( $key );
    my $elements = $r->smembers( $key ); # ARRAY ref

### smove

    my $ok = $r->smove( $srckey, $dstkey, $element );

### spop

    my $element = $r->spop( $key );

### spop

    my $element = $r->srandmember( $key );

### srem

    $r->srem( $key, $member );

### sunion

    my @elements = $r->sunion( $key1, $key2, ... );
    my $elements = $r->sunion( $key1, $key2, ... ); # ARRAY ref

### sunionstore

    my $ok = $r->sunionstore( $dstkey, $key1, $key2, ... );

## Commands operating on hashes

Hashes in Redis cannot be nested as in perl, if you want to store a nested
hash, you need to serialize the hash first. If you want to have a named
hash, you can use Redis-hashes. You will find an example in the tests
of this module t/01-basic.t

### hset

Sets the value to a key in a hash.
  $r->hset('hashname', $key => $value); \#\# returns true on success



### hget
  

Gets the value to a key in a hash.

    my $value = $r->hget('hashname', $key);

### hexists
  

    if($r->hexists('hashname', $key) {
      ## do something, the key exists
    }
    else {
      ## the key does not exist
    }

### hdel

Deletes a key from a hash
  if($r->hdel('hashname', $key)) {
    \#\# key is deleted
  }
  else {
    \#\# oops
  }

### hincrby

Adds an integer to a value. The integer is signed, so a negative integer decrements.
  

    my $key = 'testkey';
    $r->hset('hashname', $key => 1); ## value -> 1
    my $increment = 1; ## has to be an integer
    $r->hincrby('hashname', $key => $increment); ## value -> 2
    $increment = 5;
    $r->hincrby('hashname', $key => $increment); ## value -> 7
    $increment = -1;
    $r->hincrby('hashname', $key => $increment); ## value -> 6

### hsetnx

Adds a key to a hash unless it is not already set.

    my $key = 'testnx';
    $r->hsetnx('hashname', $key => 1); ## returns true
    $r->hsetnx('hashname', $key => 2); ## returns false because key already exists

### hmset

Adds multiple keys to a hash.

    $r->hmset('hashname', 'key1' => 'value1', 'key2' => 'value2'); ## returns true on success



### hmget

Returns multiple keys of a hash.

    my @values = $r->hmget('hashname', 'key1', 'key2');

### hgetall

Returns the whole hash.

    my %hash = $r->hgetall('hashname');

### hkeys

Returns the keys of a hash.

    my @keys = $r->hkeys('hashname');

### hvals

Returns the values of a hash.

    my @values = $r->hvals('hashname');

### hlen

Returns the count of keys in a hash.

    my $keycount = $r->hlen('hashname');





## Sorting

### sort

    $r->sort("key BY pattern LIMIT start end GET pattern ASC|DESC ALPHA');



## Publish/Subscribe commands

When one of ["subscribe"](#subscribe) or ["psubscribe"](#psubscribe) is used, the Redis object will
enter _PubSub_ mode. When in _PubSub_ mode only commands in this section,
plus ["quit"](#quit), will be accepted.

If you plan on using PubSub and other Redis functions, you should use two Redis
objects, one dedicated to PubSub and the other for regular commands.

All Pub/Sub commands receive a callback as the last parameter. This callback
receives three arguments:

- The published message.
- The topic over which the message was sent.
- The subscribed topic that matched the topic for the message. With ["subscribe"](#subscribe)
these last two are the same, always. But with ["psubscribe"](#psubscribe), this parameter
tells you the pattern that matched.

See the [Pub/Sub notes](http://redis.io/topics/pubsub) for more information
about the messages you will receive on your callbacks after each ["subscribe"](#subscribe),
["unsubscribe"](#unsubscribe), ["psubscribe"](#psubscribe) and ["punsubscribe"](#punsubscribe).

### publish

    $r->publish($topic, $message);

Publishes the `$message` to the `$topic`.

### subscribe

    $r->subscribe(
        @topics_to_subscribe_to,
        sub {
          my ($message, $topic, $subscribed_topic) = @_;
          ...
        },
    );

Subscribe one or more topics. Messages published into one of them will be
received by Redis, and the specificed callback will be executed.

### unsubscribe

    $r->unsubscribe(@topic_list, sub { my ($m, $t, $s) = @_; ... });

Stops receiving messages for all the topics in `@topic_list`.

### psubscribe

    my @topic_matches = ('prefix1.*', 'prefix2.*');
    $r->psubscribe(@topic_matches, sub { my ($m, $t, $s) = @_; ... });

Subscribes a pattern of topics. All messages to topics that match the pattern
will be delivered to the callback.

### punsubscribe

    my @topic_matches = ('prefix1.*', 'prefix2.*');
    $r->punsubscribe(@topic_matches, sub { my ($m, $t, $s) = @_; ... });

Stops receiving messages for all the topics pattern matches in `@topic_list`.

### is\_subscriber

    if ($r->is_subscriber) { say "We are in Pub/Sub mode!" }

Returns true if we are in _Pub/Sub_ mode.

### wait\_for\_messages

    my $keep_going = 1; ## Set to false somewhere to leave the loop
    my $timeout = 5;
    $r->wait_for_messages($timeout) while $keep_going;

Blocks, waits for incoming messages and delivers them to the appropriate
callbacks.

Requires a single parameter, the number of seconds to wait for messages. Use 0
to wait for ever. If a positive non-zero value is used, it will return after
that ammount of seconds without a single notification.

Please note that the timeout is not a commitement to return control to the
caller at most each `timeout` seconds, but more a idle timeout, were control
will return to the caller if Redis is idle (as in no messages were received
during the timeout period) for more than `timeout` seconds.

The ["wait\_for\_messages"](#wait\_for\_messages) call returns the number of messages processed during
the run.



## Persistence control commands

### save

    $r->save;

### bgsave

    $r->bgsave;

### lastsave

    $r->lastsave;



## Scripting commands

### eval

    $r->eval($lua_script, $num_keys, $key1, ..., $arg1, $arg2);

Executes a Lua script server side.

Note that this commands sends the Lua script every time you call it. See
["evalsha"](#evalsha) and ["script\_load"](#script\_load) for an alternative.

### evalsha

    $r->eval($lua_script_sha1, $num_keys, $key1, ..., $arg1, $arg2);

Executes a Lua script cached on the server side by its SHA1 digest.

See ["script\_load"](#script\_load).

### script\_load

    my ($sha1) = $r->script_load($lua_script);

Cache Lua script, returns SHA1 digest that can be used with ["evalsha"](#evalsha).

### script\_exists

    my ($exists1, $exists2, ...) = $r->script_exists($scrip1_sha, $script2_sha, ...);

Given a list of SHA1 digests, returns a list of booleans, one for each SHA1,
that report the existence of each script in the server cache.

### script\_kill

    $r->script_kill;

Kills the currently running script.

### script\_flush

    $r->script_flush;

Flush the Lua scripts cache.



## Remote server control commands

### info

    my $info_hash = $r->info;

The `info` method is unique in that it decodes the server's response into a
hashref, if possible. This decoding happens in both synchronous and pipelined
modes.

### shutdown

    $r->shutdown;

The `shutdown` method does not support pipelined operation.



## Multiple databases handling commands

### select

    $r->select( $dbindex ); # 0 for new clients

### move

    $r->move( $key, $dbindex );

### flushdb

    $r->flushdb;

### flushall

    $r->flushall;



# ACKNOWLEDGEMENTS

The following persons contributed to this project (alphabetical order):

- Aaron Crane (pipelining and AUTOLOAD caching support)
- Dirk Vleugels
- Flavio Poletti
- Jeremy Zawodny
- sunnavy at bestpractical.com
- Thiago Berlitz Rondon
- Ulrich Habel
