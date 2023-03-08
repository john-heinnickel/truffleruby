# frozen_string_literal: true

# Copyright (c) 2015, 2023 Oracle and/or its affiliates. All rights reserved. This
# code is released under a tri EPL/GPL/LGPL license. You can use it,
# redistribute it and/or modify it under the terms of the:
#
# Eclipse Public License version 2.0, or
# GNU General Public License version 2, or
# GNU Lesser General Public License version 2.1.

# Copyright (c) 2007-2015, Evan Phoenix and contributors
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
# * Redistributions in binary form must reproduce the above copyright notice
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
# * Neither the name of Rubinius nor the names of its contributors
#   may be used to endorse or promote products derived from this software
#   without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

class IO

  include Enumerable

  module WaitReadable; end
  module WaitWritable; end

  class EAGAINWaitReadable < Errno::EAGAIN
    include WaitReadable
  end

  class EAGAINWaitWritable < Errno::EAGAIN
    include WaitWritable
  end

  # EAGAIN and EWOULDBLOCK are checked to be the same in posix.rb
  EWOULDBLOCKWaitReadable = EAGAINWaitReadable
  EWOULDBLOCKWaitWritable = EAGAINWaitWritable

  class EINPROGRESSWaitReadable < Errno::EINPROGRESS
    include WaitReadable
  end

  class EINPROGRESSWaitWritable < Errno::EINPROGRESS
    include WaitWritable
  end

  # Import platform constants

  SEEK_SET = Truffle::Config['platform.io.SEEK_SET']
  SEEK_CUR = Truffle::Config['platform.io.SEEK_CUR']
  SEEK_END = Truffle::Config['platform.io.SEEK_END']

  # SEEK_DATA and SEEK_HOLE are nonstandard extensions also present
  # in Solaris, FreeBSD, and DragonFly BSD;
  %i[SEEK_DATA SEEK_HOLE].each do |name|
    if value = Truffle::Config.lookup("platform.io.#{name}")
      const_set name, value
    end
  end

  # InternalBuffer provides a sliding window into a region of bytes.
  # The buffer is filled to the +used+ indicator, which is
  # always less than or equal to +total+. As bytes are taken
  # from the buffer, the +start+ indicator is incremented by
  # the number of bytes taken. Once +start+ == +used+, the
  # buffer is +empty?+ and needs to be refilled.
  #
  # 0 <= @start <= @used <= @total
  #
  # This description should be independent of the "direction"
  # in which the buffer is used. As a read buffer, +fill_from+
  # appends at +used+, but not exceeding +total+. When +used+
  # equals total, no additional bytes will be filled until the
  # buffer is emptied.
  #
  # IO presents a stream of input. Buffer presents buckets of
  # input. IO's task is to chain the buckets so the user sees
  # a stream. IO explicitly requests that the buffer be filled
  # (on input) and then determines how much of the input to take
  # (e.g. by looking for a separator or collecting a certain
  # number of bytes). Buffer decides whether or not to go to the
  # source for more data or just present what is already in the
  # buffer.
  class InternalBuffer
    SIZE = 32768
    DEFAULT_READ_SIZE = 16384

    def initialize
      @storage = Truffle::ByteArray.new(SIZE)
      @start = 0
      @used = 0
      @total = SIZE
      @eof = false
    end

    # Returns the number of bytes available in the buffer.
    def size
      @used - @start
    end

    # Returns +true+ if the buffer can be filled.
    def empty?
      @start == @used
    end

    # Returns the number of bytes of capacity remaining in the buffer.
    # This is the number of additional bytes that can be added to the
    # buffer before it is full.
    def unused
      @total - @used
    end

    # Returns +true+ if the buffer is filled to capacity.
    def full?
      @used == @total
    end

    # Returns +true+ if the buffer is empty and cannot be filled further.
    def exhausted?
      @eof and empty?
    end

    # Resets the buffer state so the buffer can be filled again.
    def reset!
      @start = 0
      @used = 0
      @eof = false
    end

    def fill(io, max = DEFAULT_READ_SIZE)
      io = io.to_io unless Primitive.object_kind_of?(io, IO)

      count = Primitive.min(unused, max)

      total_read = 0
      Truffle::POSIX.read_to_buffer_at_least_one_byte(io, count) do |pointer, bytes_read|
        # Detect if another thread has updated the buffer
        # and now there isn't enough room for this data.
        if bytes_read > unused
          raise RuntimeError, 'internal implementation error - IO buffer overrun'
        end
        Primitive.pointer_read_bytes_to_byte_array(@storage, @used, pointer.address, bytes_read)
        @used += bytes_read
        total_read += bytes_read
      end
      total_read
    end

    # A request to the buffer to have data. The buffer decides whether
    # existing data is sufficient, or whether to read more data from the
    # +IO+ instance. Any new data causes this method to return.
    #
    # Returns the number of bytes in the buffer.
    def fill_from(io, skip = nil, max = DEFAULT_READ_SIZE)
      TruffleRuby.synchronized(self) do
        discard skip if skip

        if empty?
          reset!
          if fill(io, max) == 0
            @eof = true
          end
          size
        else
          Primitive.min(size, max)
        end
      end
    end

    # Advances the beginning-of-buffer marker past any number
    # of contiguous characters == +skip+. For example, if +skip+
    # is ?\n and the buffer contents are "\n\n\nAbc...", the
    # start marker will be positioned on 'A'.
    def discard(skip)
      while @start < @used
        break unless @storage[@start] == skip
        @start += 1
      end
    end

    # Returns the number of bytes to fetch from the buffer up-to-
    # and-including +pattern+. Returns +nil+ if pattern is not found.
    def find(pattern, discard = nil)
      if count = @storage.locate(pattern, @start, @used)
        count - @start
      end
    end

    def unseek!(io)
      TruffleRuby.synchronized(self) do
        unless empty?
          amount = @start - @used
          r = Truffle::POSIX.lseek(io.fileno, amount, IO::SEEK_CUR)
          Errno.handle if r == -1
        end
        reset!
      end
    end

    # Returns +count+ bytes from the +start+ of the buffer as a new String.
    # If +count+ is +nil+, returns all available bytes in the buffer.
    def shift(count = nil, encoding = Encoding::BINARY)
      TruffleRuby.synchronized(self) do
        total = size
        total = count if count and count < total

        str = String.from_bytearray @storage, @start, total, encoding
        @start += total

        str
      end
    end

    PEEK_AHEAD_LIMIT = 16

    def read_to_char_boundary(io, str)
      str.force_encoding(io.external_encoding || Encoding.default_external)
      return IO.read_encode(io, str) if str.valid_encoding?

      peek_ahead = 0
      while size > 0 and peek_ahead < PEEK_AHEAD_LIMIT
        str.force_encoding Encoding::BINARY
        str << @storage[@start]
        @start += 1
        peek_ahead += 1

        str.force_encoding(io.external_encoding || Encoding.default_external)
        if str.valid_encoding?
          return IO.read_encode io, str
        end
      end

      IO.read_encode io, str
    end

    # Returns one Integer as the start byte.
    def getbyte(io)
      return if size == 0 and fill_from(io) == 0

      TruffleRuby.synchronized(self) do
        byte = @storage[@start]
        @start += 1
        byte
      end
    end

    # TODO: fix this when IO buffering is re-written.
    def getchar(io)
      return if size == 0 and fill_from(io) == 0

      TruffleRuby.synchronized(self) do
        char = +''
        while size > 0
          char.force_encoding Encoding::BINARY
          char << @storage[@start]
          @start += 1

          char.force_encoding(io.external_encoding || Encoding.default_external)
          if Primitive.string_chr_at(char, 0)
            return IO.read_encode io, char
          end
        end
      end
    end

    # Prepends the bytes of string +str+ to the internal buffer,
    # so that future reads will return them.
    def put_back(str)
      length = str.bytesize
      # A simple case, which is common and can be done efficiently
      if @start >= length
        @start -= length
        str.bytes.each_with_index do |byte, i|
          @storage[@start+i] = byte
        end
      else
        @storage = @storage.prepend(str)
        @total += length
        @start = 0
        @used += length
      end
    end

    def inspect # :nodoc:
      content = (@start...@used).map { |i| @storage[i].chr(Encoding::BINARY) }.join.inspect
      "#{super[0...-1]} #{content}>"
    end
  end

  private def mode_read_only?
    (@mode & FMODE_READWRITE) == FMODE_READABLE
  end

  private def mode_write_only?
    (@mode & FMODE_READWRITE) == FMODE_WRITABLE
  end

  private def force_read_only
    @mode = (@mode | FMODE_READABLE) & ~FMODE_WRITABLE
  end

  private def force_write_only
    @mode = (@mode | FMODE_WRITABLE) & ~FMODE_READABLE
  end

  def self.binread(file, length = nil, offset = 0)
    raise ArgumentError, "Negative length #{length} given" if !Primitive.nil?(length) && length < 0

    File.open(file, 'r', encoding: 'ascii-8bit:-') do |f|
      f.seek(offset)
      f.read(length)
    end
  end

  def self.binwrite(file, string, offset = nil, **options)
    default_mode = File::CREAT | File::RDWR | File::BINARY
    default_mode |= File::TRUNC unless offset

    mode, _binary, external, _internal, _autoclose, perm = IO.normalize_options(nil, nil, options, default_mode)

    File.open(file, mode, encoding: (external || 'ASCII-8BIT'), perm: perm) do |f|
      f.seek(offset) if offset
      f.write(string)
    end
  end

  class StreamCopier
    def initialize(from, to, length, offset)
      @length = length
      @offset = offset

      @from_io, @from = to_io(from, 'rb')
      @to_io, @to = to_io(to, 'wb')

      @method = read_method @from
    end

    def to_io(obj, mode)
      if Primitive.object_kind_of?(obj, IO)
        flag = true
        io = obj
      else
        flag = false

        if Primitive.object_kind_of?(obj, String)
          io = File.open obj, mode
        elsif obj.respond_to? :to_path
          path = Truffle::Type.coerce_to obj, String, :to_path
          io = File.open path, mode
        else
          io = obj
        end
      end

      [flag, io]
    end

    def read_method(obj)
      if obj.respond_to? :readpartial
        :readpartial
      else
        :read
      end
    end

    def run
      @from.__send__ :ensure_open_and_readable if Primitive.object_kind_of?(@from, IO)
      @to.__send__ :ensure_open_and_writable if Primitive.object_kind_of?(@to, IO)

      if @offset
        if @from_io && !@from.instance_variable_get(:@pipe)
          saved_pos = @from.pos
        else
          saved_pos = 0
        end

        @from.seek @offset, IO::SEEK_CUR
      end

      size = @length || InternalBuffer::DEFAULT_READ_SIZE
      bytes = 0

      begin
        # Use the buffer form here like MRI, since read/readpartial might be defined by the user
        while data = @from.__send__(@method, size, +'')
          @to.write data
          @to.flush if Primitive.object_kind_of?(@to, IO)
          bytes += data.bytesize

          break if @length && bytes >= @length
        end
      rescue EOFError
        nil # done reading
      end

      @to.flush if Primitive.object_kind_of?(@to, IO)
      bytes
    ensure
      if @from_io
        @from.pos = saved_pos if @offset
      else
        @from.close if Primitive.object_kind_of?(@from, IO)
      end

      @to.close if !@to_io and Primitive.object_kind_of?(@to, IO)
    end
  end

  def self.copy_stream(from, to, max_length = nil, offset = nil)
    StreamCopier.new(from, to, max_length, offset).run
  end

  def self.foreach(name, separator = undefined, limit = undefined, **options, &block)
    return to_enum(:foreach, name, separator, limit, **options) unless block

    name = Truffle::Type.coerce_to_path name

    separator = $/ if Primitive.undefined?(separator)
    case separator
    when Integer
      limit = separator
      separator = $/
    when nil
      # do nothing
    else
      separator = StringValue(separator)
    end

    limit = nil if Primitive.undefined?(limit)
    case limit
    when Integer, nil
      # do nothing
    else
      limit = Primitive.rb_num2long(limit)
    end
    limit = nil if limit && limit < 0
    chomp = Primitive.as_boolean(options[:chomp])

    if name[0] == ?|
      io = IO.popen(name[1..-1], 'r')
      return nil unless io
    else
      options[:mode] = 'r' unless options.key? :mode
      io = File.open(name, **options)
    end

    each_reader = io.__send__ :create_each_reader, separator, limit, chomp, true

    begin
      each_reader&.each(&block)
    ensure
      io.close
    end

    nil
  end

  def self.readlines(name, separator = undefined, limit = undefined, **options)
    lines = []
    foreach(name, separator, limit, **options) { |l| lines << l }

    lines
  end

  def self.read_encode(io, str)
    internal = io.internal_encoding
    external = io.external_encoding || Encoding.default_external

    if external.equal? Encoding::BINARY
      str.force_encoding external
    elsif internal and external
      ec = Encoding::Converter.new external, internal
      ec.convert str
    else
      str.force_encoding external
    end
  end

  def self.write(file, string, offset = nil, **options)
    if Primitive.nil?(options[:open_args])
      default_mode = File::CREAT | File::WRONLY
      default_mode |= File::TRUNC unless offset

      mode, _binary, external, _internal, _autoclose, perm = IO.normalize_options(nil, nil, options, default_mode)

      open_args = [mode]
      open_kw = { encoding: (external || 'ASCII-8BIT'), perm: perm }
    else
      open_args = options[:open_args]
      open_kw = Primitive.object_kind_of?(open_args.last, Hash) ? open_args.pop : {}
    end

    File.open(file, *open_args, **open_kw) do |f|
      f.seek(offset) if offset
      f.write(string)
    end
  end

  def self.for_fd(fd, mode = nil, **options)
    new fd, mode, **options
  end

  def self.read(name, length = nil, offset = 0, **options)
    offset = 0 if Primitive.nil? offset
    name = Truffle::Type.coerce_to_path name

    offset = Primitive.rb_to_int(offset || 0)
    raise Errno::EINVAL, 'offset must not be negative' if offset < 0

    unless Primitive.nil?(length)
      length = Primitive.rb_to_int(length)
      raise ArgumentError, 'length must not be negative' if length < 0
    end

    if Primitive.nil?(options[:open_args])
      file_new_args = [name]
      file_new_options = options
    else
      file_new_args = [name] + options[:open_args]
      file_new_options = Primitive.object_kind_of?(file_new_args.last, Hash) ? file_new_args.pop : {}
    end

    # Detect pipe mode
    if name[0] == ?|
      io = IO.popen(name[1..-1], 'r')
      return nil unless io # child process
    else
      io = File.new(*file_new_args, **file_new_options)
    end

    str = nil
    begin
      io.seek(offset) unless offset == 0

      if Primitive.nil?(length)
        str = io.read
      else
        str = io.read length
      end
    ensure
      io.close
    end

    str
  end

  def self.try_convert(obj)
    Truffle::Type.rb_check_convert_type obj, IO, :to_io
  end

  def self.normalize_options(mode, perm, options, default_mode = nil)
    autoclose = true

    if mode
      mode = (Truffle::Type.try_convert(mode, Integer, :to_int) or
              Truffle::Type.coerce_to(mode, String, :to_str))
    end

    if options
      if optmode = options[:mode]
        optmode = (Truffle::Type.try_convert(optmode, Integer, :to_int) or
                   Truffle::Type.coerce_to(optmode, String, :to_str))
      end

      if mode && optmode
        raise ArgumentError, 'mode specified twice'
      end

      mode ||= optmode
      mode ||= default_mode

      if flags = options[:flags]
        flags = Truffle::Type.rb_convert_type(flags, Integer, :to_int)

        if Primitive.nil?(mode)
          mode = flags
        elsif Primitive.object_kind_of?(mode, Integer)
          mode |= flags
        else # it's a String
          mode = Truffle::IOOperations.parse_mode(mode)
          mode |= flags
        end
      end

      if optperm = options[:perm]
        optperm = Truffle::Type.try_convert(optperm, Integer, :to_int)
      end

      if perm
        raise ArgumentError, 'perm specified twice' if optperm
      else
        perm = optperm
      end

      autoclose = Primitive.as_boolean(options[:autoclose]) if options.key?(:autoclose)
    end

    mode ||= default_mode

    if Primitive.object_kind_of?(mode, String)
      mode, external, internal = mode.split(':', 3)
      raise ArgumentError, 'invalid access mode' unless mode

      binary = true  if mode.include?(?b)
      binary = false if mode.include?(?t)
    elsif mode
      binary = true  if (mode & BINARY) != 0
    end

    if options
      if options[:textmode] and options[:binmode]
        raise ArgumentError, 'both textmode and binmode specified'
      end

      if Primitive.nil? binary
        binary = options[:binmode]
      elsif options.key?(:textmode) or options.key?(:binmode)
        raise ArgumentError, 'text/binary mode specified twice'
      end

      if !external and !internal
        external = options[:external_encoding]
        internal = options[:internal_encoding]
      elsif options[:external_encoding] or options[:internal_encoding] or options[:encoding]
        raise ArgumentError, 'encoding specified twice'
      end

      if !external and !internal
        encoding = options[:encoding]

        if Primitive.object_kind_of?(encoding, Encoding)
          external = encoding
        elsif !Primitive.nil?(encoding)
          encoding = StringValue(encoding)
          external, internal = encoding.split(':', 2)
        end
      end
    end
    external = Encoding::BINARY if binary and !external and !internal
    perm ||= 0666
    [mode, binary, external, internal, autoclose, perm]
  end

  def self.open(*args, **options)
    io = new(*args, **options)

    return io unless block_given?

    begin
      yield io
    ensure
      begin
        io.close unless io.closed?
      rescue StandardError
        nil # nothing, just swallow them.
      end
    end
  end

  def self.pipe(external = nil, internal = nil, **options)
    lhs, rhs = Truffle::IOOperations.create_pipe(self, self, external, internal)

    if block_given?
      begin
        yield lhs, rhs
      ensure
        lhs.close unless lhs.closed?
        rhs.close unless rhs.closed?
      end
    else
      [lhs, rhs]
    end
  end

  def self.popen(*args)
    if env = Truffle::Type.try_convert(args.first, Hash, :to_hash)
      args.shift
    end

    if io_options = Truffle::Type.try_convert(args.last, Hash, :to_hash)
      args.pop
    end

    if args.size > 2
      raise ArgumentError, "#{__method__}: given #{args.size}, expected 1..2"
    end

    cmd, mode = args
    mode ||= 'r'

    if Primitive.object_kind_of?(cmd, Array)
      if sub_env = Truffle::Type.try_convert(cmd.first, Hash, :to_hash)
        env = sub_env unless env
        cmd.shift
      end

      if exec_options = Truffle::Type.try_convert(cmd.last, Hash, :to_hash)
        cmd.pop
      end
    end

    mode, binary, external, internal, _autoclose, _perm = IO.normalize_options(mode, nil, io_options)
    mode_int = Truffle::IOOperations.parse_mode mode

    readable = false
    writable = false

    if mode_int & IO::RDWR != 0
      readable = true
      writable = true
    elsif mode_int & IO::WRONLY != 0
      writable = true
    else # IO::RDONLY
      readable = true
    end

    # We only need the Bidirectional pipe if we're reading and writing.
    # Otherwise, we can just return the IO object for the proper half.
    read_class = (readable && writable) ? IO::BidirectionalPipe : self

    pa_read, ch_write = Truffle::IOOperations.create_pipe(read_class, self) if readable
    ch_read, pa_write = pipe if writable

    if readable and writable
      pipe = pa_read
      Primitive.object_ivar_set pipe, :@write, pa_write
    elsif readable
      pipe = pa_read
    elsif writable
      pipe = pa_write
    else
      raise ArgumentError, 'IO is neither readable nor writable'
    end

    pipe.binmode if binary
    pipe.set_encoding(external, internal)

    if cmd == '-'
      Kernel.fork # will throw an error
      raise 'unreachable'
    else
      options = {}
      options[:in] = ch_read.fileno if ch_read
      options[:out] = ch_write.fileno if ch_write

      if io_options
        io_options.delete_if do |key, _|
          [:mode, :external_encoding, :internal_encoding,
            :encoding, :textmode, :binmode, :autoclose
          ].include? key
        end

        options.merge! io_options
      end

      if exec_options
        options.merge! exec_options
      end

      pid = Truffle::ProcessOperations.spawn(env || {}, *cmd, options)
    end

    Primitive.object_ivar_set pipe, :@pid, pid

    ch_write.close if readable
    ch_read.close  if writable

    return pipe unless block_given?

    begin
      yield pipe
    ensure
      pipe.close unless pipe.closed?
    end
  end

  #
  # +select+ examines the IO object Arrays that are passed in
  # as +readables+, +writables+, and +errorables+ to see if any
  # of their descriptors are ready for reading, are ready for
  # writing, or have an exceptions pending respectively. An IO
  # may appear in more than one of the sets. Any of the three
  # sets may be +nil+ if you are not interested in those events.
  #
  # If +timeout+ is not nil, it specifies the number of seconds
  # to wait for events (maximum.) The number may be fractional,
  # conceptually up to a microsecond resolution.
  #
  # A +timeout+ of 0 indicates that each descriptor should be
  # checked once only, effectively polling the sets.
  #
  # Leaving the +timeout+ to +nil+ causes +select+ to block
  # infinitely until an event transpires.
  #
  # If the timeout expires without events, +nil+ is returned.
  # Otherwise, an [readable, writable, errors] Array of Arrays
  # is returned, only, with the IO objects that have events.
  #
  # @compatibility  MRI 1.8 and 1.9 require the +readables+ Array,
  #                 Rubinius does not.
  #
  def self.select(readables = nil, writables = nil, errorables = nil, timeout = nil)
    if timeout
      unless Primitive.object_kind_of? timeout, Numeric
        raise TypeError, 'Timeout must be numeric'
      end

      raise ArgumentError, 'timeout must be positive' if timeout < 0

      # Microseconds, rounded down
      timeout = remaining_timeout = Integer(timeout * 1_000_000)
    else
      remaining_timeout = -1
    end

    if readables
      readables = Truffle::Type.coerce_to(readables, Array, :to_ary).dup
      readable_ios = readables.map do |obj|
        io = Truffle::Type.coerce_to(obj, IO, :to_io)
        raise IOError, 'closed stream' if io.closed?
        return [[obj], [], []] unless io.__send__(:buffer_empty?)
        io
      end
    else
      readables = []
      readable_ios = []
    end

    if writables
      writables = Truffle::Type.coerce_to(writables, Array, :to_ary).dup
      writable_ios = writables.map do |obj|
        io = Truffle::Type.coerce_to(obj, IO, :to_io)
        raise IOError, 'closed stream' if io.closed?
        io
      end
    else
      writables = []
      writable_ios = []
    end

    if errorables
      errorables = Truffle::Type.coerce_to(errorables, Array, :to_ary).dup
      errorable_ios = errorables.map do |obj|
        io = Truffle::Type.coerce_to(obj, IO, :to_io)
        raise IOError, 'closed stream' if io.closed?
        io
      end
    else
      errorables = []
      errorable_ios = []
    end

    Truffle::IOOperations.select(
        readables, readable_ios,
        writables, writable_ios,
        errorables, errorable_ios,
        timeout, remaining_timeout)
  end

  ##
  # Opens the given path, returning the underlying file descriptor as an Integer.
  #  IO.sysopen("testfile")   #=> 3
  def self.sysopen(path, mode = nil, perm = nil)
    path = Truffle::Type.coerce_to_path path
    mode = Truffle::IOOperations.parse_mode(mode || 'r')
    perm ||= 0666

    fd = Truffle::POSIX.open(path, mode, perm)
    Errno.handle(path) if fd == -1
    fd
  end

  #
  # Internally associate +io+ with the given descriptor.
  #
  # The +mode+ will be checked and set as the current mode if
  # the underlying descriptor allows it.
  #
  # The +sync+ attribute will also be set.
  #
  def self.setup(io, fd, mode, sync)
    if !Truffle::Boot.preinitializing? && Truffle::POSIX::NATIVE
      cur_mode = Truffle::POSIX.fcntl(fd, F_GETFL, 0)
      Errno.handle if cur_mode < 0
      cur_mode &= ACCMODE
    end

    if mode
      mode = Truffle::IOOperations.parse_mode(mode)
      mode &= ACCMODE

      if cur_mode and (cur_mode == RDONLY or cur_mode == WRONLY) and mode != cur_mode
        raise Errno::EINVAL, "Invalid mode #{cur_mode} for existing descriptor #{fd} (expected #{mode})"
      end
    else
      mode = cur_mode or raise 'No mode given for IO'
    end

    # Close old descriptor if there was already one associated
    io.close if Primitive.io_fd(io) != -1

    Primitive.io_set_fd(io, fd)
    Primitive.object_ivar_set io, :@mode, Truffle::IOOperations.translate_omode_to_fmode(mode)
    io.sync = sync
    io.autoclose  = true
    ibuffer = mode != WRONLY ? IO::InternalBuffer.new : nil
    Primitive.object_ivar_set io, :@ibuffer, ibuffer
    Primitive.object_ivar_set io, :@lineno, 0
  end

  #
  # Create a new IO associated with the given fd.
  #
  def initialize(fd, mode = nil, **options)
    if block_given?
      warn 'IO::new() does not take block; use IO::open() instead', uplevel: 1
    end
    @binmode = nil
    @internal = nil
    @external = nil
    @pid = nil

    mode, binary, external, internal, autoclose_tmp, _perm = IO.normalize_options(mode, nil, options)

    fd = Truffle::Type.coerce_to(fd, Integer, :to_int)
    sync = fd == 2 # stderr is always unbuffered, see setvbuf(3)
    IO.setup(self, fd, mode, sync)

    binmode if binary
    set_encoding external, internal

    @autoclose = autoclose_tmp
    @pipe = false
  end

  ##
  # Obtains a new duplicate descriptor for the current one.
  def initialize_copy(original) # :nodoc:
    fd = original.fileno

    # The 3rd argument is minimum acceptable descriptor value for the new FD.
    # We want to ensure newly allocated FDs never take the standard IO ones, even
    # if a STDIO stream is closed.
    Primitive.io_set_fd(self, Truffle::POSIX.fcntl(fd, F_DUPFD_CLOEXEC, 3))

    self.autoclose = true
  end

  def advise(advice, offset = 0, len = 0)
    raise IOError, 'stream is closed' if closed?
    raise TypeError, 'advice must be a Symbol' unless Primitive.object_kind_of?(advice, Symbol)

    unless [:normal, :sequential, :random, :noreuse, :dontneed, :willneed].include? advice
      raise NotImplementedError, "Unsupported advice: #{advice}"
    end

    _offset = Primitive.rb_num2long offset
    _len = Primitive.rb_num2long len

    # Primitive.io_advise self, advice, offset, len
    raise 'IO#advise not implemented'
  end

  # Autoclose really represents whether this IO object owns the
  # underlying file descriptor or not. If we are the owner of the fd
  # then we should have a finalizer that will close the fd if that
  # hasn't been done already, but conversely closing an IO object
  # which is not really the owner of the fd should not actually close
  # the fd.
  def autoclose?
    @autoclose
  end

  def autoclose=(autoclose)
    @autoclose = Primitive.as_boolean(autoclose)
  end

  def binmode
    ensure_open

    @binmode = true
    @external = Encoding::BINARY
    @internal = nil

    # HACK what to do?
    self
  end

  def binmode?
    ensure_open
    !Primitive.nil?(@binmode)
  end

  # Used to find out if there is buffered data available.
  private def buffer_empty?
    @ibuffer.nil? or @ibuffer.empty?
  end

  def close_on_exec=(value)
    if value
      fcntl(F_SETFD, fcntl(F_GETFD) | FD_CLOEXEC)
    else
      fcntl(F_SETFD, fcntl(F_GETFD) & ~FD_CLOEXEC)
    end
    nil
  end

  def close_on_exec?
    (fcntl(F_GETFD) & FD_CLOEXEC) != 0
  end

  def <<(obj)
    write(obj.to_s)
    self
  end

  ##
  # Closes the read end of a duplex I/O stream (i.e., one
  # that contains both a read and a write stream, such as
  # a pipe). Will raise an IOError if the stream is not duplexed.
  #
  #  f = IO.popen("/bin/sh","r+")
  #  f.close_read
  #  f.readlines
  # produces:
  #
  #  prog.rb:3:in `readlines': not opened for reading (IOError)
  #   from prog.rb:3
  def close_read
    if @mode & FMODE_WRITABLE != 0
      raise IOError, 'closing non-duplex IO for reading'
    end
    close
  end

  ##
  # Closes the write end of a duplex I/O stream (i.e., one
  # that contains both a read and a write stream, such as
  # a pipe). Will raise an IOError if the stream is not duplexed.
  #
  #  f = IO.popen("/bin/sh","r+")
  #  f.close_write
  #  f.print "nowhere"
  # produces:
  #
  #  prog.rb:3:in `write': not opened for writing (IOError)
  #   from prog.rb:3:in `print'
  #   from prog.rb:3
  def close_write
    if @mode & FMODE_READABLE != 0
      raise IOError, 'closing non-duplex IO for writing'
    end
    close
  end

  ##
  # Returns true if ios is completely closed (for duplex
  # streams, both reader and writer), false otherwise.
  #
  #  f = File.new("testfile")
  #  f.close         #=> nil
  #  f.closed?       #=> true
  #  f = IO.popen("/bin/sh","r+")
  #  f.close_write   #=> nil
  #  f.closed?       #=> false
  #  f.close_read    #=> nil
  #  f.closed?       #=> true
  def closed?
    Primitive.io_fd(self) == -1
  end

  # Argument matrix for IO#gets and IO#each:
  #
  #  separator / limit | nil | >= 0 | < 0
  # ===================+=====+======+=====
  #  String (nonempty) |  A  |  B   |  C
  #                    +-----+------+-----
  #  ""                |  D  |  E   |  F
  #                    +-----+------+-----
  #  nil               |  G  |  H   |  I
  #

  class EachReader
    def initialize(io, buffer, separator, limit, chomp)
      @io = io
      @buffer = buffer
      @separator = separator
      @limit = limit
      @skip = nil
      @chomp = chomp
    end

    def each(&block)
      if @separator
        if @separator.empty?
          @separator = "\n\n"
          @skip = 10
        end

        if @limit
          read_to_separator_with_limit(&block)
        else
          read_to_separator(&block)
        end
      else
        if @limit
          read_to_limit(&block)
        else
          read_all(&block)
        end
      end
    end

    # method A, D
    def read_to_separator
      str = +''

      until @buffer.exhausted?
        available = @buffer.fill_from @io, @skip
        break unless available > 0

        if count = @buffer.find(@separator)
          s = @buffer.shift(count)

          unless str.empty?
            s.prepend(str)
            str.clear
          end

          s = IO.read_encode(@io, s)

          s.chomp!(@separator) if @chomp
          $. = @io.__send__(:increment_lineno)
          @buffer.discard @skip if @skip

          yield s
        else
          str << @buffer.shift
        end
      end

      str << @buffer.shift
      str.chomp!(@separator) if @chomp
      yield_string(str) { |y| yield y }
    end

    # method B, E
    def read_to_separator_with_limit
      str = +''

      #TODO: implement ignoring encoding with negative limit
      wanted = limit = @limit.abs

      until @buffer.exhausted?
        available = @buffer.fill_from @io, @skip
        break unless available > 0

        if count = @buffer.find(@separator)
          bytes = Primitive.min(count, wanted)
          str << @buffer.shift(bytes)

          str = IO.read_encode(@io, str)

          str.chomp!(@separator) if @chomp
          $. = @io.__send__(:increment_lineno)
          @buffer.discard @skip if @skip

          yield str

          str = +''
          wanted = limit
        else
          if wanted < available
            str << @buffer.shift(wanted)

            str = @buffer.read_to_char_boundary(@io, str)

            str.chomp!(@separator) if @chomp
            $. = @io.__send__(:increment_lineno)
            @buffer.discard @skip if @skip

            yield str

            str = +''
            wanted = limit
          else
            str << @buffer.shift
            wanted -= available
          end
        end
      end

      str.chomp!(@separator) if @chomp
      yield_string(str) { |s| yield s }
    end

    # Method G
    def read_all
      str = +''
      unless @buffer.exhausted?
        tmp_str = @buffer.shift
        str << tmp_str unless tmp_str.empty?
      end

      while (tmp_str = Truffle::POSIX.read_string_at_least_one_byte(@io, InternalBuffer::DEFAULT_READ_SIZE))
        str << tmp_str
      end

      str.chomp!(DEFAULT_RECORD_SEPARATOR) if @chomp
      yield_string(str) { |s| yield s }
    end

    # Method H
    def read_to_limit
      str = +''
      wanted = limit = @limit.abs

      until @buffer.exhausted?
        available = @buffer.fill_from @io
        if wanted < available
          str << @buffer.shift(wanted)

          str = @buffer.read_to_char_boundary(@io, str)

          $. = @io.__send__(:increment_lineno)
          yield str

          str = +''
          wanted = limit
        else
          str << @buffer.shift
          wanted -= available
        end
      end

      yield_string(str) { |s| yield s }
    end

    def yield_string(str)
      unless str.empty?
        str = IO.read_encode(@io, str)
        $. = @io.__send__(:increment_lineno)
        yield str
      end
    end
  end

  private def increment_lineno
    @lineno += 1
  end

  ##
  # Return a string describing this IO object.
  def inspect
    if Primitive.io_fd(self) != -1
      "#<#{self.class}:fd #{Primitive.io_fd(self)}>"
    else
      "#<#{self.class}:(closed)>"
    end
  end

  private def create_each_reader(sep_or_limit = $/, limit = nil, chomp = false, raise_error)
    ensure_open_and_readable

    if limit
      limit = Primitive.rb_num2long(limit)
      sep = sep_or_limit ? StringValue(sep_or_limit) : nil
    else
      case sep_or_limit
      when String
        sep = sep_or_limit
      when nil
        sep = nil
      else
        unless sep = Truffle::Type.rb_check_convert_type(sep_or_limit, String, :to_str)
          sep = $/
          limit = Primitive.rb_num2long(sep_or_limit)
        end
      end
    end

    if limit == 0 && raise_error
      raise ArgumentError, "invalid limit: #{limit} for each"
    end

    return if @ibuffer.exhausted?

    EachReader.new(self, @ibuffer, sep, limit, chomp)
  end

  def each(sep_or_limit = $/, limit = nil, chomp: false, &block)
    return to_enum(:each, sep_or_limit, limit, chomp: chomp) unless block_given?

    each_reader = create_each_reader(sep_or_limit, limit, chomp, true)

    return if Primitive.nil? each_reader

    each_reader.each(&block)

    self
  end
  alias_method :each_line, :each

  def each_byte
    return to_enum(:each_byte) unless block_given?

    yield getbyte until eof?

    self
  end

  def each_char
    return to_enum :each_char unless block_given?
    ensure_open_and_readable

    while char = getc
      yield char
    end

    self
  end

  def each_codepoint
    return to_enum :each_codepoint unless block_given?
    ensure_open_and_readable

    while char = getc
      yield char.ord
    end

    self
  end

  ##
  # Returns true if ios is at end of file that means
  # there are no more data to read. The stream must be
  # opened for reading or an IOError will be raised.
  #
  #  f = File.new("testfile")
  #  dummy = f.readlines
  #  f.eof   #=> true
  # If ios is a stream such as pipe or socket, IO#eof?
  # blocks until the other end sends some data or closes it.
  #
  #  r, w = IO.pipe
  #  Thread.new { sleep 1; w.close }
  #  r.eof?  #=> true after 1 second blocking
  #
  #  r, w = IO.pipe
  #  Thread.new { sleep 1; w.puts "a" }
  #  r.eof?  #=> false after 1 second blocking
  #
  #  r, w = IO.pipe
  #  r.eof?  # blocks forever
  #
  # Note that IO#eof? reads data to a input buffer.
  # So IO#sysread doesn't work with IO#eof?.
  def eof?
    ensure_open_and_readable
    @ibuffer.fill_from self unless @ibuffer.exhausted?
    @ibuffer.exhausted?
  end
  alias_method :eof, :eof?

  private def ensure_open_and_readable
    ensure_open
    raise IOError, 'not opened for reading' if @mode & FMODE_READABLE == 0
  end

  private def ensure_open_and_writable
    ensure_open
    raise IOError, 'not opened for writing' if @mode & FMODE_WRITABLE == 0
  end

  def external_encoding
    ensure_open
    if @mode.anybits?(FMODE_WRITABLE)
      @external
    else
      @external || Encoding.default_external
    end
  end

  ##
  # Provides a mechanism for issuing low-level commands to
  # control or query file-oriented I/O streams. Arguments
  # and results are platform dependent. If arg is a number,
  # its value is passed directly. If it is a string, it is
  # interpreted as a binary sequence of bytes (Array#pack
  # might be a useful way to build this string). On Unix
  # platforms, see fcntl(2) for details. Not implemented on all platforms.
  def fcntl(command, arg = 0)
    ensure_open

    if !arg
      arg = 0
    elsif arg == true
      arg = 1
    elsif Primitive.object_kind_of?(arg, String)
      raise NotImplementedError, 'cannot handle String'
    else
      arg = Primitive.rb_to_int arg
    end

    command = Primitive.rb_to_int command
    Truffle::POSIX.fcntl Primitive.io_fd(self), command, arg
  end

  def internal_encoding
    ensure_open
    @internal
  end

  ##
  # Provides a mechanism for issuing low-level commands to
  # control or query file-oriented I/O streams. Arguments
  # and results are platform dependent. If arg is a number,
  # its value is passed directly. If it is a string, it is
  # interpreted as a binary sequence of bytes (Array#pack
  # might be a useful way to build this string). On Unix
  # platforms, see fcntl(2) for details. Not implemented on all platforms.
  def ioctl(command, arg = 0)
    ensure_open

    if !arg
      real_arg = 0
    elsif arg == true
      real_arg = 1
    elsif Primitive.object_kind_of?(arg, String)
      # This could be faster.
      buffer_size = arg.bytesize
      # On BSD and Linux, we could read the buffer size out of the ioctl value.
      # Most Linux ioctl codes predate the convention, so a fallback like this
      # is still necessary.
      buffer_size = 4096 if buffer_size < 4096
      buffer = Truffle::FFI::MemoryPointer.new(buffer_size)
      buffer.write_bytes(arg)
      real_arg = buffer.address
    else
      real_arg = Primitive.rb_to_int(arg)
    end

    command = Primitive.rb_to_int(command)
    ret = Truffle::POSIX.ioctl(Primitive.io_fd(self), command, real_arg)
    Errno.handle if ret < 0

    if buffer
      arg.replace buffer.read_string(buffer_size)
      buffer.free
    end
    ret
  end

  ##
  # Returns an integer representing the numeric file descriptor for ios.
  #
  #  $stdin.fileno    #=> 0
  #  $stdout.fileno   #=> 1
  def fileno
    ensure_open
    Primitive.io_fd(self)
  end
  alias_method :to_i, :fileno

  ##
  # Flushes any buffered data within ios to the underlying
  # operating system (note that this is Ruby internal
  # buffering only; the OS may buffer the data as well).
  #
  # This method does basically nothing since TruffleRuby does
  # not use write buffers, it only checks if the IO is not closed.
  def flush
    ensure_open
    self
  end

  ##
  # Immediately writes all buffered data in ios to disk. Returns
  # nil if the underlying operating system does not support fsync(2).
  # Note that fsync differs from using IO#sync=. The latter ensures
  # that data is flushed from Ruby's buffers, but does not guarantee
  # that the underlying operating system actually writes it to disk.
  def fsync
    flush
    err = Truffle::POSIX.fsync Primitive.io_fd(self)
    Errno.handle(+'fsync(2)') if err < 0
    err
  end

  def getbyte
    ensure_open_and_readable
    @ibuffer.getbyte(self)
  end

  ##
  # Gets the next 8-bit byte (0..255) from ios.
  # Returns nil if called at end of file.
  #
  #  f = File.new("testfile")
  #  f.getc   #=> 84
  #  f.getc   #=> 104
  def getc
    ensure_open_and_readable
    @ibuffer.getchar(self)
  end

  def gets(sep_or_limit = $/, limit = nil, chomp: false)
    line = nil
    each_reader = create_each_reader(sep_or_limit, limit, chomp, false)
    return line if Primitive.nil? each_reader

    each_reader.each do |l|
      line = l
      break
    end

    Primitive.io_last_line_set(Primitive.caller_special_variables, line) if line
    line
  end

  ##
  # Returns the current line number in ios. The
  # stream must be opened for reading. lineno
  # counts the number of times gets is called,
  # rather than the number of newlines encountered.
  # The two values will differ if gets is called with
  # a separator other than newline. See also the $. variable.
  #
  #  f = File.new("testfile")
  #  f.lineno   #=> 0
  #  f.gets     #=> "This is line one\n"
  #  f.lineno   #=> 1
  #  f.gets     #=> "This is line two\n"
  #  f.lineno   #=> 2
  def lineno
    ensure_open_and_readable
    @lineno
  end

  ##
  # Manually sets the current line number to the
  # given value. $. is updated only on the next read.
  #
  #  f = File.new("testfile")
  #  f.gets                     #=> "This is line one\n"
  #  $.                         #=> 1
  #  f.lineno = 1000
  #  f.lineno                   #=> 1000
  #  $. # lineno of last read   #=> 1
  #  f.gets                     #=> "This is line two\n"
  #  $. # lineno of last read   #=> 1001
  def lineno=(line_number)
    ensure_open_and_readable
    @lineno = Primitive.rb_num2int(line_number)
  end

  # Normally only provided by io/nonblock
  def nonblock?
    (fcntl(F_GETFL) & NONBLOCK) != 0
  end

  # Normally only provided by io/nonblock
  def nonblock(nonblock = true)
    prev_nonblock = self.nonblock?
    self.nonblock = nonblock
    begin
      yield self
    ensure
      self.nonblock = prev_nonblock
    end
  end

  # Normally only provided by io/nonblock
  def nonblock=(value)
    old_flags = fcntl(F_GETFL)
    new_flags = if value
                  old_flags | NONBLOCK
                else
                  old_flags & ~NONBLOCK
                end
    fcntl(F_SETFL, new_flags) unless old_flags == new_flags
    self
  end

  ##
  # FIXME
  # Returns the process ID of a child process
  # associated with ios. This will be set by IO::popen.
  #
  #  pipe = IO.popen("-")
  #  if pipe
  #    $stderr.puts "In parent, child pid is #{pipe.pid}"
  #  else
  #    $stderr.puts "In child, pid is #{$$}"
  #  end
  # produces:
  #
  #  In child, pid is 26209
  #  In parent, child pid is 26209
  def pid
    raise IOError, 'closed stream' if closed?
    @pid
  end

  def pos
    flush
    reset_buffering
    r = Truffle::POSIX.lseek(Primitive.io_fd(self), 0, SEEK_CUR)
    Errno.handle if r == -1
    r
  end
  alias_method :tell, :pos

  ##
  # Seeks to the given position (in bytes) in ios.
  #
  #  f = File.new("testfile")
  #  f.pos = 17
  #  f.gets   #=> "This is line two\n"
  def pos=(offset)
    seek Primitive.rb_num2long(offset), SEEK_SET
  end

  ##
  # Writes each given argument.to_s to the stream or $_ (the result of last
  # IO#gets) if called without arguments. Appends $\.to_s to output. Returns
  # nil.
  def print(*args)
    Truffle::IOOperations.print self, args, Primitive.caller_special_variables
  end

  ##
  # If obj is Numeric, write the character whose code is obj,
  # otherwise write the first character of the string
  # representation of obj to ios.
  #
  #  $stdout.putc "A"
  #  $stdout.putc 65
  # produces:
  #
  #  AA
  def putc(obj)
    if Primitive.object_kind_of? obj, String
      write Primitive.string_substring(obj, 0, 1)
    else
      byte = Truffle::Type.coerce_to(obj, Integer, :to_int) & 0xff
      write byte.chr
    end

    obj
  end

  ##
  # Writes the given objects to ios as with IO#print.
  # Writes a record separator (typically a newline)
  # after any that do not already end with a newline
  # sequence. If called with an array argument, writes
  # each element on a new line. If called without arguments,
  # outputs a single record separator.
  #
  #  $stdout.puts("this", "is", "a", "test")
  # produces:
  #
  #  this
  #  is
  #  a
  #  test
  def puts(*args)
    Truffle::IOOperations.puts(self, *args)
  end

  def printf(fmt, *args)
    fmt = StringValue(fmt)
    write sprintf(fmt, *args)
  end

  def read(length = nil, buffer = nil)
    ensure_open_and_readable
    buffer = StringValue(buffer) if buffer

    unless length
      str = IO.read_encode self, read_all
      return str unless buffer

      return buffer.replace(str)
    end

    if @ibuffer.exhausted?
      buffer.clear if buffer
      return nil
    end

    raise ArgumentError, 'length must not be negative' if length < 0

    str = +''
    needed = length
    while needed > 0 and not @ibuffer.exhausted?
      count = @ibuffer.fill_from(self, nil, needed)
      str << @ibuffer.shift(count)
      str = nil if str.empty?

      needed -= count
    end

    if str
      if buffer
        buffer.replace str.force_encoding(buffer.encoding)
      else
        str.force_encoding Encoding::BINARY
      end
    else
      buffer.clear if buffer
      nil
    end
  end

  ##
  # Reads all input until +#eof?+ is true. Returns the input read.
  # If the buffer is already exhausted, returns +""+.
  private def read_all
    str = +''
    unless @ibuffer.exhausted?
      if !(tmp_str = @ibuffer.shift).empty?
        str << tmp_str
      end
    end

    while (tmp_str = Truffle::POSIX.read_string_at_least_one_byte(self, InternalBuffer::DEFAULT_READ_SIZE))
      str << tmp_str
    end

    str
  end

  ##
  # Reads at most maxlen bytes from ios using read(2) system
  # call after O_NONBLOCK is set for the underlying file descriptor.
  #
  # If the optional outbuf argument is present, it must reference
  # a String, which will receive the data.
  #
  # read_nonblock just calls read(2). It causes all errors read(2)
  # causes: EAGAIN, EINTR, etc. The caller should care such errors.
  #
  # read_nonblock causes EOFError on EOF.
  #
  # If the read buffer is not empty, read_nonblock reads from the
  # buffer like readpartial. In this case, read(2) is not called.
  def read_nonblock(size, buffer = nil, exception: true)
    raise ArgumentError, 'illegal read size' if size < 0
    ensure_open_and_readable
    self.nonblock = true

    buffer = StringValue buffer if buffer

    return ''.b if size == 0

    if @ibuffer.size > 0
      return @ibuffer.shift(size)
    end

    str = Truffle::POSIX.read_string_nonblock(self, size, exception)

    case str
    when Symbol
      str
    when String
      buffer ? buffer.replace(str) : str
    else # EOF
      if exception
        raise EOFError, 'end of file reached'
      else
        nil
      end
    end
  end

  ##
  # Reads a character as with IO#getc, but raises an EOFError on end of file.
  def readchar
    char = getc
    raise EOFError, 'end of file reached' unless char
    char
  end

  def readbyte
    byte = getbyte
    raise EOFError, 'end of file reached' unless byte
    byte
  end

  ##
  # Reads a line as with IO#gets, but raises an EOFError on end of file.
  def readline(sep_or_limit = $/, limit = nil, chomp: false)
    out = gets(sep_or_limit, limit, chomp: chomp)
    raise EOFError, 'end of file' unless out
    out
  end

  ##
  # Reads all of the lines in ios, and returns them in an array.
  # Lines are separated by the optional sep_string. If sep_string
  # is nil, the rest of the stream is returned as a single record.
  # The stream must be opened for reading or an IOError will be raised.
  #
  #  f = File.new("testfile")
  #  f.readlines[0]   #=> "This is line one\n"
  def readlines(sep_or_limit = $/, limit = nil, **options)
    chomp = options.fetch(:chomp, false)
    each_reader = create_each_reader(sep_or_limit, limit, chomp, true)

    ret = []
    each_reader&.each { |line| ret << line }
    ret
  end

  ##
  # Reads at most maxlen bytes from the I/O stream. It blocks
  # only if ios has no data immediately available. It doesn't
  # block if some data available. If the optional outbuf argument
  # is present, it must reference a String, which will receive the
  # data. It raises EOFError on end of file.
  #
  # readpartial is designed for streams such as pipe, socket, tty,
  # etc. It blocks only when no data immediately available. This
  # means that it blocks only when following all conditions hold.
  #
  # the buffer in the IO object is empty.
  # the content of the stream is empty.
  # the stream is not reached to EOF.
  # When readpartial blocks, it waits data or EOF on the stream.
  # If some data is reached, readpartial returns with the data.
  # If EOF is reached, readpartial raises EOFError.
  #
  # When readpartial doesn't blocks, it returns or raises immediately.
  # If the buffer is not empty, it returns the data in the buffer.
  # Otherwise if the stream has some content, it returns the data in
  # the stream. Otherwise if the stream is reached to EOF, it raises EOFError.
  #
  #  r, w = IO.pipe           #               buffer          pipe content
  #  w << "abc"               #               ""              "abc".
  #  r.readpartial(4096)      #=> "abc"       ""              ""
  #  r.readpartial(4096)      # blocks because buffer and pipe is empty.
  #
  #  r, w = IO.pipe           #               buffer          pipe content
  #  w << "abc"               #               ""              "abc"
  #  w.close                  #               ""              "abc" EOF
  #  r.readpartial(4096)      #=> "abc"       ""              EOF
  #  r.readpartial(4096)      # raises EOFError
  #
  #  r, w = IO.pipe           #               buffer          pipe content
  #  w << "abc\ndef\n"        #               ""              "abc\ndef\n"
  #  r.gets                   #=> "abc\n"     "def\n"         ""
  #  w << "ghi\n"             #               "def\n"         "ghi\n"
  #  r.readpartial(4096)      #=> "def\n"     ""              "ghi\n"
  #  r.readpartial(4096)      #=> "ghi\n"     ""              ""
  # Note that readpartial behaves similar to sysread. The differences are:
  #
  # If the buffer is not empty, read from the buffer instead
  # of "sysread for buffered IO (IOError)".
  # It doesn't cause Errno::EAGAIN and Errno::EINTR. When readpartial
  # meets EAGAIN and EINTR by read system call, readpartial retry the system call.
  # The later means that readpartial is nonblocking-flag insensitive. It
  # blocks on the situation IO#sysread causes Errno::EAGAIN as if the fd is blocking mode.
  def readpartial(size, buffer = nil)
    raise ArgumentError, 'negative string size' unless size >= 0
    ensure_open_and_readable

    if buffer
      buffer = StringValue(buffer)

      Truffle::StringOperations.shorten!(buffer, buffer.bytesize)

      return buffer if size == 0

      if @ibuffer.size > 0
        data = @ibuffer.shift(size)
      else
        data = Truffle::POSIX.read_string_at_least_one_byte(self, size)
        raise EOFError if Primitive.nil? data
      end

      buffer.replace(data)
      buffer
    else
      return +'' if size == 0

      if @ibuffer.size > 0
        return @ibuffer.shift(size)
      end

      data = Truffle::POSIX.read_string_at_least_one_byte(self, size)
      raise EOFError if Primitive.nil? data
      data
    end
  end

  ##
  # Re-associates ios with the I/O stream given in other_IO or to
  # a new stream opened on path. This may dynamically change the
  # actual class of this stream.
  #
  #  f1 = File.new("testfile")
  #  f2 = File.new("testfile")
  #  f2.readlines[0]   #=> "This is line one\n"
  #  f2.reopen(f1)     #=> #<File:testfile>
  #  f2.readlines[0]   #=> "This is line one\n"
  def reopen(other, mode = undefined)
    if other.respond_to?(:to_io) # reopen(IO)
      flush

      if Primitive.object_kind_of?(other, IO)
        io = other
      else
        io = other.to_io
        unless Primitive.object_kind_of?(io, IO)
          raise TypeError, '#to_io must return an instance of IO'
        end
      end

      if Primitive.io_fd(self) != io.fileno
        io.__send__ :ensure_open
        io.__send__ :reset_buffering

        Truffle::IOOperations.dup2_with_cloexec(io.fileno, Primitive.io_fd(self))

        Primitive.vm_set_class self, io.class

        # We need to use that mode of other here like MRI, and not fcntl(), because fcntl(fd, F_GETFL)
        # gives O_RDWR for the 3 standard IOs, even though they are not bidirectional.
        @mode = other.instance_variable_get :@mode
        @ibuffer = (@mode & FMODE_READABLE != 0) ? IO::InternalBuffer.new : nil


        if io.respond_to?(:path)
          @path = io.path
        end
      end
    else # reopen(filename, mode)
      flush unless closed?

      # If a mode isn't passed in, use the mode that the IO is already in.
      if Primitive.undefined? mode
        mode = @mode
        # If this IO was already opened for writing, we should
        # create the target file if it doesn't already exist.
        if (mode & FMODE_WRITABLE != 0)
          mode |= FMODE_CREATE
        end
        mode = Truffle::IOOperations.translate_fmode_to_omode(mode)
      else
        mode = Truffle::IOOperations.parse_mode(mode)
      end

      path = Truffle::Type.coerce_to_path(other)
      reset_buffering

      if closed?
        Primitive.io_set_fd(self, IO.sysopen(path, mode))
      else
        File.open(path, mode) do |f|
          Truffle::IOOperations.dup2_with_cloexec(f.fileno, Primitive.io_fd(self))
        end
      end

      seek 0, SEEK_SET

      mode = Truffle::POSIX.fcntl(Primitive.io_fd(self), F_GETFL, 0)
      Errno.handle if mode < 0

      @mode = Truffle::IOOperations.translate_omode_to_fmode((mode & ACCMODE))
      @ibuffer = (@mode & FMODE_READABLE) != 0 ? IO::InternalBuffer.new : nil
    end

    self
  end

  ##
  # Internal method used to reset the state of the buffer, including the
  # physical position in the stream.
  private def reset_buffering
    @ibuffer.unseek! self if @ibuffer
  end

  ##
  # Positions ios to the beginning of input, resetting lineno to zero.
  #
  #  f = File.new("testfile")
  #  f.readline   #=> "This is line one\n"
  #  f.rewind     #=> 0
  #  f.lineno     #=> 0
  #  f.readline   #=> "This is line one\n"
  def rewind
    seek 0
    @lineno = 0
    0
  end

  ##
  # Seeks to a given offset +amount+ in the stream according to the value of whence:
  #
  # IO::SEEK_CUR  | Seeks to _amount_ plus current position
  # --------------+----------------------------------------------------
  # IO::SEEK_END  | Seeks to _amount_ plus end of stream (you probably
  #               | want a negative value for _amount_)
  # --------------+----------------------------------------------------
  # IO::SEEK_SET  | Seeks to the absolute location given by _amount_
  # Example:
  #
  #  f = File.new("testfile")
  #  f.seek(-13, IO::SEEK_END)   #=> 0
  #  f.readline                  #=> "And so on...\n"
  def seek(amount, whence = SEEK_SET)
    flush
    reset_buffering

    r = Truffle::POSIX.lseek(Primitive.io_fd(self), Primitive.rb_num2long(amount), whence)
    Errno.handle if r == -1
    0
  end

  # MRI: io_encoding_set
  #
  # Note that `enc` and `enc2` in MRI code,
  # despite the confusing comments on struct rb_io_enc_t's fields,
  # (see https://github.com/ruby/ruby/commit/f7bdac01c2)
  # seem to mean:
  # (enc=NULL, enc2=NULL) external = nil, internal = nil
  # (enc=e1,   enc2=NULL) external = e1,  internal = nil
  # (enc=e1,   enc2=e2  ) external = e2,  internal = e1
  # In other words,
  # enc  means internal if both are set, but external otherwise
  # enc2 means external if both are set, but nothing (or internal) otherwise
  # So a possible mapping is:
  # Both enc/enc2 set => enc is internal, enc2 is external
  # Otherwise         => enc is external, enc2 is internal
  #
  # We use the internal and external terminology only because enc/enc2 is so confusing.
  def set_encoding(external, internal = nil, **options)
    if !Primitive.nil?(internal)
      unless Primitive.nil?(external) || Primitive.object_kind_of?(external, Encoding)
        external = Truffle::IOOperations.parse_external_enc(self, StringValue(external))
      end

      unless Primitive.object_kind_of?(internal, Encoding)
        internal = StringValue(internal)
        if internal == '-' # Special case - "-" => no transcoding
          internal = nil
        else
          internal = Encoding.find(internal)
        end
      end

      if external == Encoding::BINARY # If external is BINARY, no transcoding
        internal = nil
      elsif internal == external # Special case => no transcoding
        internal = nil
      end
    else
      if Primitive.nil?(external) # Set to default encodings
        external, internal = Truffle::IOOperations.rb_io_ext_int_to_encs(@mode, nil, nil)
      else
        if !Primitive.object_kind_of?(external, Encoding) and
            external = StringValue(external) and external.encoding.ascii_compatible?
          external, internal = Truffle::IOOperations.parse_mode_enc(self, @mode, external)
        else
          external, internal = Truffle::IOOperations.rb_io_ext_int_to_encs(@mode, Encoding.find(external), nil)
        end
      end
    end

    @internal = internal
    @external = external
    self
  end

  def set_encoding_by_bom
    unless binmode?
      raise ArgumentError, 'ASCII incompatible encoding needs binmode'
    end

    if internal_encoding
      raise ArgumentError, 'encoding conversion is set'
    end

    if external_encoding && external_encoding != Encoding::BINARY
      raise ArgumentError, "encoding is set to #{external_encoding} already"
    end

    external = strip_bom
    if external
      @external = external
    end
  end

  private def strip_bom
    mode = Truffle::POSIX.truffleposix_fstat_mode(Primitive.io_fd(self))
    return unless Truffle::StatOperations.file?(mode)

    case b1 = getbyte
    when 0x00
      b2 = getbyte
      if b2 == 0x00
        b3 = getbyte
        if b3 == 0xFE
          b4 = getbyte
          if b4 == 0xFF
            return Encoding::UTF_32BE
          end
          ungetbyte b4
        end
        ungetbyte b3
      end
      ungetbyte b2

    when 0xFF
      b2 = getbyte
      if b2 == 0xFE
        b3 = getbyte
        if b3 == 0x00
          b4 = getbyte
          if b4 == 0x00
            return Encoding::UTF_32LE
          end
          ungetbyte b4
        else
          ungetbyte b3
          return Encoding::UTF_16LE
        end
        ungetbyte b3
      end
      ungetbyte b2

    when 0xFE
      b2 = getbyte
      if b2 == 0xFF
        return Encoding::UTF_16BE
      end
      ungetbyte b2

    when 0xEF
      b2 = getbyte
      if b2 == 0xBB
        b3 = getbyte
        if b3 == 0xBF
          return Encoding::UTF_8
        end
        ungetbyte b3
      end
      ungetbyt b2
    end

    ungetbyte b1
    nil
  end

  ##
  # Returns status information for ios as an object of type File::Stat.
  #
  #  f = File.new("testfile")
  #  s = f.stat
  #  "%o" % s.mode   #=> "100644"
  #  s.blksize       #=> 4096
  #  s.atime         #=> Wed Apr 09 08:53:54 CDT 2003
  def stat
    ensure_open
    File::Stat.fstat Primitive.io_fd(self)
  end

  ##
  # Returns the current "sync mode" of ios. When sync mode is true,
  # all output is immediately flushed to the underlying operating
  # system and is not buffered by Ruby internally. See also IO#fsync.
  #
  #  f = File.new("testfile")
  #  f.sync   #=> false
  def sync
    ensure_open
    @mode & FMODE_SYNC != 0
  end

  ##
  # Sets the "sync mode" to true or false. When sync mode is true,
  # all output is immediately flushed to the underlying operating
  # system and is not buffered internally. Returns the new state.
  # See also IO#fsync.
  def sync=(v)
    ensure_open
    if v
      @mode |= FMODE_SYNC
    else
      @mode &= ~FMODE_SYNC
    end
    v
  end

  ##
  # Reads integer bytes from ios using a low-level read and returns
  # them as a string. Do not mix with other methods that read from
  # ios or you may get unpredictable results. Raises SystemCallError
  # on error and EOFError at end of file.
  #
  #  f = File.new("testfile")
  #  f.sysread(16)   #=> "This is line one"
  #
  #  @todo  Improve reading into provided buffer.
  #
  def sysread(number_of_bytes, buffer = undefined)
    ensure_open_and_readable
    flush
    raise IOError unless @ibuffer.empty?

    str, errno = Truffle::POSIX.read_string(self, number_of_bytes)
    Errno.handle_errno(errno) unless errno == 0

    raise EOFError if Primitive.nil? str

    unless Primitive.undefined? buffer
      StringValue(buffer).replace str
    end
    str
  end

  ##
  # Seeks to a given offset in the stream according to the value
  # of whence (see IO#seek for values of whence). Returns the new offset into the file.
  #
  #  f = File.new("testfile")
  #  f.sysseek(-13, IO::SEEK_END)   #=> 53
  #  f.sysread(10)                  #=> "And so on."
  def sysseek(amount, whence = SEEK_SET)
    ensure_open
    raise IOError unless buffer_empty?

    r = Truffle::POSIX.lseek(Primitive.io_fd(self), Primitive.rb_num2long(amount), whence)
    Errno.handle if r == -1
    r
  end

  def to_io
    self
  end

  ##
  # Returns true if ios is associated with a terminal device (tty), false otherwise.
  #
  #  File.new("testfile").isatty   #=> false
  #  File.new("/dev/tty").isatty   #=> true
  def tty?
    ensure_open
    Truffle::POSIX.isatty(Primitive.io_fd(self)) == 1
  end
  alias_method :isatty, :tty?

  def syswrite(data)
    data = String data
    return 0 if data.empty?

    ensure_open_and_writable
    reset_buffering unless @mode & FMODE_SYNC != 0

    Truffle::POSIX.write_string(self, data, false)
  end

  def ungetbyte(obj)
    ensure_open_and_readable

    case obj
    when String
      str = obj
    when Integer
      str = (obj & 0xff).chr(Encoding::BINARY)
    when nil
      return
    else
      str = StringValue(obj)
    end

    @ibuffer.put_back(str)
    nil
  end

  def ungetc(obj)
    ensure_open_and_readable

    case obj
    when String
      str = obj
    when Integer
      str = obj.chr(external_encoding || Encoding.default_external)
    when nil
      return
    else
      str = StringValue(obj)
    end

    @ibuffer.put_back(str)
    nil
  end

  def write(*objects)
    bytes_written = 0

    objects.each do |object|
      string = Truffle::Type.rb_obj_as_string(object)
      next if string.empty?

      ensure_open_and_writable

      if external_encoding && external_encoding != string.encoding && external_encoding != Encoding::BINARY
        unless string.ascii_only? && external_encoding.ascii_compatible?
          string = string.encode(external_encoding)
        end
      end

      count = Truffle::POSIX.write_string self, string, true
      bytes_written += count
    end

    bytes_written
  end

  def write_nonblock(data, exception: true)
    ensure_open_and_writable

    data = String data
    return 0 if data.empty?

    reset_buffering unless @mode & FMODE_SYNC != 0

    self.nonblock = true

    begin
      Truffle::POSIX.write_string_nonblock(self, data)
    rescue Errno::EAGAIN
      if exception
        raise EAGAINWaitWritable
      else
        :wait_writable
      end
    end
  end

  def close
    return nil if closed?

    begin
      ensure_open # IO#flush but inlined, to not call user-defined #flush
    ensure
      fd = Primitive.io_fd(self)
      if fd >= 0
        # Need to set even if the instance is frozen
        Primitive.io_set_fd(self, -1)
        if fd >= 3 && autoclose?
          ret = Truffle::POSIX.close(fd)
          Errno.handle if ret < 0
        end
      end
    end

    if defined?(@pid) and @pid and @pid != 0
      begin
        Process.wait @pid
      rescue Errno::ECHILD
        nil # If the child already exited
      end
      @pid = nil
    end
    nil
  end

  # Correctly dump to YAML with Psych
  def encode_with coder
    # Do not save any state, like MRI
  end

end

class IO::BidirectionalPipe < IO

  ##
  # Closes ios and flushes any pending writes to the
  # operating system. The stream is unavailable for
  # any further data operations; an IOError is raised
  # if such an attempt is made.
  #
  # If ios is opened by IO.popen, close sets $?.
  def close
    @write.close unless @write.closed?
    super unless closed?
    nil
  end

  def closed?
    super and @write.closed?
  end

  def close_read
    raise IOError, 'closed stream' if closed?
    close
  end

  def close_write
    raise IOError, 'closed stream' if @write.closed?
    @write.close
  end

  # Expand these out rather than using some metaprogramming because it's a fixed
  # set and it's faster to have them as normal methods because then InlineCaches
  # work right.
  #
  def <<(obj)
    @write << obj
  end

  def print(*args)
    @write.print(*args)
  end

  def printf(fmt, *args)
    @write.printf(fmt, *args)
  end

  def putc(obj)
    @write.putc(obj)
  end

  def puts(*args)
    @write.puts(*args)
  end

  def syswrite(data)
    @write.syswrite(data)
  end

  def write(data)
    @write.write(data)
  end

  def write_nonblock(data, **options)
    @write.write_nonblock(data, **options)
  end

end

Truffle::KernelOperations.define_hooked_variable(
  :$_,
  -> s { Primitive.io_last_line_get(s) },
  -> v, s { Primitive.io_last_line_set(s, v) })
