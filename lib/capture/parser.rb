module WOW::Capture
  class Parser
    module FormatVersions
      V2_1 = 0x201
      V2_2 = 0x202
      V3_0 = 0x300
      V3_1 = 0x301
    end

    module Errors
      class FormatError < StandardError; end
      class UnsupportedClientError < StandardError; end
    end

    PKT_MAGIC_HEADER = 'PKT'
    CLIENT_BUILDS = [20490, 20444, 20338, 20253]
    DIRECTIONS = ['CMSG', 'SMSG']

    MIN_START_TIME = Time.utc(2005, 1, 1, 0, 0, 0)
    MAX_START_TIME = Time.utc(2020, 12, 31, 23, 59, 59)

    attr_reader :type, :client_build, :client_locale, :packet_index

    def initialize(path, opts = {})
      file_name = path.split('/').last
      file_extension = file_name.split('.').last.downcase.strip

      if file_extension == 'bin'
        @type = :bin
      else
        @type = :pkt
      end

      @file = File.open(path, 'rb')

      setup_storage

      @headerless = true

      @magic = nil
      @format_version = nil
      @sniffer_id = nil

      @client_build = nil
      @client_locale = nil

      @session_key = nil
      @start_time = nil
      @start_tick = nil

      @sniffer_hello = nil

      @packet_index = 0

      @subscriptions = {}

      read_pkt_header if @type == :pkt
      guess_build if headerless?

      validate_start_time

      select_definitions
    end

    # Returns a stub to the module appropriate for the client build of this capture.
    def definitions
      @definitions
    end
    alias_method :defs, :definitions

    # Returns the instance of ObjectStorage used by this parser instance.
    def objects
      @objects
    end

    def session
      @session
    end

    def combat_sessions
      @combat_sessions
    end

    private def setup_storage
      @objects = ObjectStorage.new(self)
      @session = SessionStorage.new
      @combat_sessions = CombatSessionStorage.new(self)
    end

    def on(event_name, filters = {}, &block)
      if !@subscriptions.has_key?(event_name)
        @subscriptions[event_name] = []
      end

      @subscriptions[event_name] << [block, filters]
    end

    def publish(event_name, payload = nil, filters = {})
      return if !@subscriptions.has_key?(event_name)

      matching_subscriptions = @subscriptions[event_name].select { |s| s[1].empty? || s[1] == filters }

      matching_subscriptions.each do |subscription|
        if payload.nil?
          subscription[0].call
        else
          subscription[0].call(payload)
        end
      end
    end

    def next_packet
      read_packet
    end

    def close
      @file.close
    end

    def eof?
      @file.eof?
    end

    # Drives the parser across all packets within the capture. Useful when relying on event
    # subscriptions to process the capture.
    def replay!
      next_packet while !eof?
    end

    def rewind!
      @file.pos = @packet_start

      # Wipe storage since we're presumably going to run through packets again.
      setup_storage
    end

    def headerless?
      @headerless == true
    end

    # Checks if the capture's build is in the set of supported client builds.
    private def ensure_supported_client
      if !CLIENT_BUILDS.include?(@client_build)
        raise Errors::UnsupportedClientError.new("Unsupported client build: #{@client_build}")
      end
    end

    # Identifies a stub to a module appropriate for the client build of this capture. May not be an
    # exact match if the definitions didn't change between builds -- as is common with hotfix
    # releases.
    private def select_definitions
      @definitions = WOW::Definitions.for_build(@client_build, merged: true)
      raise "Unable to identify appropriate definitions: #{@client_build}" if @definitions.nil?
    end

    # Read a .pkt file header.
    private def read_pkt_header
      @magic = read_char(3)

      # Headerless capture.
      if @magic != PKT_MAGIC_HEADER
        @packet_start = 0
        @headerless = true

        rewind!

        return
      end

      @headerless = false

      @format_version = read_uint16

      @sniffer_id = read_char(1)
      @client_build = read_uint32
      @client_locale = read_char(4)
      @session_key = read_char(40)
      @start_time = Time.at(read_uint32)
      @start_tick = read_uint32

      hello_length = read_uint32
      @sniffer_hello = read_char(hello_length)

      @packet_start = @file.pos
    end

    # Read a single packet.
    private def read_packet
      case @type
      when :pkt
        read_pkt_packet
      else
        read_bin_packet
      end
    end

    private def read_pkt_packet
      case @format_version
      when FormatVersions::V2_1
        read_pkt_v2_1_packet
      when FormatVersions::V2_2
        read_pkt_v2_2_packet
      when FormatVersions::V3_0
        read_pkt_v3_0_packet
      when FormatVersions::V3_1
        read_pkt_v3_1_packet
      else
        read_pkt_default_packet
      end
    end

    private def read_pkt_v3_1_packet
      direction = read_char(4)
      connection_index = read_int32
      tick = read_uint32
      elapsed_time = ((tick - @start_tick) / 1000.0)
      time = @start_time + elapsed_time
      extra_length = read_int32
      length = read_int32
      read_char(extra_length)
      opcode = read_int32
      data = read_char(length - 4)

      packet_class, opcode_entry = lookup_opcode(direction, opcode)
      packet = packet_class.new(self, opcode_entry, @packet_index, direction, connection_index, tick, time, elapsed_time, data)

      @packet_index += 1

      publish(:packet, packet, direction: direction.to_sym, opcode: packet_class.to_s.split('::').last.to_sym)

      packet
    end

    private def read_pkt_default_packet
      opcode = read_uint16
      length = read_int32
      direction = ['CMSG', 'SMSG'][read_byte]
      time = Time.at(read_int64)
      data = read_char(length)

      connection_index = nil
      tick = nil
      elapsed_time = nil

      packet_class, opcode_entry = lookup_opcode(direction, opcode)
      packet = packet_class.new(self, opcode_entry, @packet_index, direction, connection_index, tick, time, elapsed_time, data)

      @packet_index += 1

      packet
    end

    private def read_char(length)
      @file.read(length)
    end

    def read_byte
      @file.read(1).ord
    end

    def read_int64
      @file.read(8).unpack('q<').first
    end

    private def read_uint32
      @file.read(4).unpack('V').first
    end

    private def read_int32
      @file.read(4).unpack('i<').first
    end

    private def read_uint16
      @file.read(2).unpack('s<').first
    end

    private def read_float
      @file.read(4).unpack('e').first
    end

    private def read_string
      string = ''

      loop do
        character = @file.read(1)
        break if character == "\x00" || character.nil?
        string << character
      end

      string
    end

    private def valid_direction?(direction)
      DIRECTIONS.include?(direction)
    end

    private def lookup_opcode(direction, opcode)
      return [Packets::Invalid, nil] if !valid_direction?(direction)
      return [Packets::Unhandled, nil] if defs.nil?

      opcode_entry = defs.opcodes[direction.downcase][opcode]

      if opcode_entry.nil? || opcode_entry.value == :Unhandled
        packet_module = Packets
        packet_class_name = Packets::UNHANDLED_PACKET_CLASS_NAME
      else
        packet_module = Packets.const_get(direction)
        packet_class_name = opcode_entry.value
      end

      packet_class = packet_module.const_get(packet_class_name)

      [packet_class, opcode_entry]
    end

    # Based on the timestamp of the first packet, guess which client build produced this capture.
    private def guess_build
      packet_specimen = read_packet
      captured_at = packet_specimen.time
      @start_time = captured_at

      # Find the client build known to have been in use at the capture time.
      guessed_build = WOW::ClientBuilds.in_use_at(captured_at)
      @client_build = guessed_build

      # Reset the file position to 0.
      rewind!
    end

    # Ensure the capture start time appears within a valid range.
    private def validate_start_time
      if @start_time < MIN_START_TIME || @start_time > MAX_START_TIME
        raise Errors::FormatError.new("Capture file has packet timestamp outside of expected" <<
          " range: #{@start_time}")
      end
    end
  end
end
