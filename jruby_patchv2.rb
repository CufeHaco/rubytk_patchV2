#!/usr/bin/env jruby
# Tk_JRuby_Bridge.rb by CufeHaco
# JRuby-native Tk bridge via JEP-380 Unix domain socket IPC
# Installs jruby_sockets.rb from CufeHaco-JEP-380-full-prototype branch,
# which becomes part of socket on the JRuby side — just require 'socket'.
# JRuby spawns CRuby as a subprocess. CRuby loads tk gem, listens on UDS.
# JRuby connects via JRubySockets::Client — auto-reconnect, stale cleanup,
# signal handling all included. Tcl commands route through the socket to
# libtcl/libtk running in the CRuby child. Socket is invisible to calling code.
# Same discovery/cache logic as Tk_Installer.rb — filenames are only constants.
#
# NEW: Before running, writes the jrubytk gem source tree to /tmp/jrubytk_gem,
# builds the .gem with `jruby -S gem build`, and installs it with
# `jruby -S gem install`. The gem is then available for require in any JRuby
# script on this machine.
#
# https://github.com/CufeHaco/Tk_Patch

require 'rbconfig'
require 'fileutils'
require 'json'

module TkJRubyBridge
  CACHE_FILE   = 'tk_install_data.json'   # shared with Tk_Installer.rb
  LOG_FILE     = 'tk_jruby_bridge.log'
  SOCKET_PATH  = '/tmp/tk_jruby_bridge.sock'

  # JEP-380 repo — jruby_sockets.rb lives here
  JEP380_REPO   = 'https://github.com/CufeHaco/JRuby-jep-380'
  JEP380_BRANCH = 'CufeHaco-JEP-380-full-prototype'
  JEP380_DIR    = '/usr/local/lib/jruby-jep-380'  # permanent, not /tmp

  # Filenames — same constants as Tk_Installer.rb
  TCL_CONFIG      = 'tclConfig.sh'
  TK_CONFIG       = 'tkConfig.sh'
  TCL_HEADER      = 'tcl.h'
  TK_HEADER       = 'tk.h'
  TCL_LIB_PATTERN = 'libtcl*.so'
  TK_LIB_PATTERN  = 'libtk*.so'

  # ─── jrubytk gem file manifest ────────────────────────────────────────────────
  # All gem source files embedded as strings.
  # install_gem writes these to /tmp/jrubytk_gem, builds, and installs.
  # Keys are relative paths within the gem directory.

  GEM_BUILD_DIR = '/tmp/jrubytk_gem'

  GEM_FILES = {

    # ── gemspec ────────────────────────────────────────────────────────────────
    'jrubytk.gemspec' => <<~'GEMSPEC',
      # frozen_string_literal: true

      require_relative 'lib/jrubytk/version'

      Gem::Specification.new do |spec|
        spec.name          = 'jrubytk'
        spec.version       = JRubyTk::VERSION
        spec.authors       = ['Troy Mallory (Cufe Vpvnkedv / CufeHaco)']
        spec.email         = []

        spec.summary       = 'JRuby-native Tk — full widget library over JEP-380 UDS IPC'
        spec.description   = <<~DESC
          jrubytk provides a complete JRuby-native Tk widget library. CRuby owns
          libtcl/libtk and the Tk event dispatch; JRuby owns concurrency via native
          threads with no GVL. The two runtimes communicate over two dedicated
          JEP-380 Unix domain sockets: a command channel (JRuby->CRuby) and an event
          channel (CRuby->JRuby). Widget paths are managed internally as integer IDs.
          A full Tk-compatible API surface (TkRoot, TkLabel, TkButton, etc.) sits on
          top of the raw bridge so existing Tk code runs under JRuby unchanged.
        DESC

        spec.homepage = 'https://github.com/CufeHaco/Tk_Patch'
        spec.license  = 'MIT'

        spec.required_ruby_version = '>= 2.7.0'
        spec.platform = 'java'

        spec.metadata = {
          'source_code_uri' => 'https://github.com/CufeHaco/Tk_Patch',
          'bug_tracker_uri' => 'https://github.com/CufeHaco/Tk_Patch/issues',
        }

        spec.files         = Dir['lib/**/*.rb', '*.md']
        spec.require_paths = ['lib']

        spec.add_dependency 'json', '>= 2.0'
      end
    GEMSPEC

    # ── lib/jrubytk/version.rb ────────────────────────────────────────────────
    'lib/jrubytk/version.rb' => <<~'RUBY',
      # frozen_string_literal: true

      module JRubyTk
        VERSION = '0.1.0'
      end
    RUBY

    # ── lib/jrubytk/errors.rb ─────────────────────────────────────────────────
    'lib/jrubytk/errors.rb' => <<~'RUBY',
      # frozen_string_literal: true

      module JRubyTk
        class TclError   < StandardError; end
        class IPCError   < StandardError; end
        class BridgeError < StandardError; end
      end
    RUBY

    # ── lib/jrubytk/constants.rb ──────────────────────────────────────────────
    'lib/jrubytk/constants.rb' => <<~'RUBY',
      # frozen_string_literal: true

      module JRubyTk
        module Constants
          CMD_SOCKET_PATH    = '/tmp/jrubytk_cmd.sock'
          EVT_SOCKET_PATH    = '/tmp/jrubytk_evt.sock'
          FRAME_HEADER_SIZE  = 4
          FRAME_PACK         = 'N'
          TAG_REPLY_OK       = 'R'
          TAG_REPLY_ERR      = 'E'
          TAG_EVENT          = 'V'
          TAG_EVT_READY      = 'Y'
          CRUBY_SERVER_FILE  = '/tmp/jrubytk_server.rb'
          UPDATE_INTERVAL_MS = 16
        end
      end
    RUBY

    # ── lib/jrubytk/ipc/framing.rb ────────────────────────────────────────────
    'lib/jrubytk/ipc/framing.rb' => <<~'RUBY',
      # frozen_string_literal: true

      module JRubyTk
        module IPC
          module Framing
            include Constants

            def frame_encode(body)
              bytes = body.encode('UTF-8', invalid: :replace, undef: :replace)
              [bytes.bytesize].pack(FRAME_PACK) + bytes
            end

            def frame_read(io)
              header = io.read(FRAME_HEADER_SIZE)
              return nil unless header&.bytesize == FRAME_HEADER_SIZE
              length = header.unpack1(FRAME_PACK)
              return '' if length == 0
              body = io.read(length)
              return nil unless body&.bytesize == length
              body.encode('UTF-8', invalid: :replace, undef: :replace)
            end

            def frame_write(io, body)
              io.write(frame_encode(body))
              io.flush
            rescue IOError, Errno::EPIPE
              nil
            end
          end
        end
      end
    RUBY

    # ── lib/jrubytk/ipc/command_channel.rb ───────────────────────────────────
    'lib/jrubytk/ipc/command_channel.rb' => <<~'RUBY',
      # frozen_string_literal: true

      require 'socket'

      module JRubyTk
        module IPC
          class CommandChannel
            include Constants
            include Framing

            MAX_RETRIES = 5
            RETRY_DELAY = 0.1

            def initialize(socket_path = CMD_SOCKET_PATH)
              @socket_path = socket_path
              @socket      = nil
              @mutex       = Mutex.new
            end

            def tcl(cmd)
              @mutex.synchronize { dispatch(cmd) }
            end

            def connected?
              !@socket.nil? && !@socket.closed?
            end

            def close
              @mutex.synchronize do
                @socket&.close rescue nil
                @socket = nil
              end
            end

            private

            def dispatch(cmd)
              retries = 0
              begin
                ensure_connected!
                frame_write(@socket, cmd)
                reply = frame_read(@socket)
                raise IPCError, "Command channel closed mid-read" if reply.nil?
                parse_reply(reply)
              rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ENOENT, IOError => e
                @socket&.close rescue nil
                @socket = nil
                retries += 1
                if retries <= MAX_RETRIES
                  sleep RETRY_DELAY
                  retry
                end
                raise IPCError, "Command channel failed after #{MAX_RETRIES} retries: #{e.message}"
              end
            end

            def ensure_connected!
              return if connected?
              @socket = UNIXSocket.new(@socket_path)
            rescue Errno::ENOENT, Errno::ECONNREFUSED => e
              raise IPCError, "Cannot connect to CRuby command socket #{@socket_path}: #{e.message}"
            end

            def parse_reply(body)
              tag  = body[0]
              data = body[1..]
              case tag
              when TAG_REPLY_OK  then data
              when TAG_REPLY_ERR then raise TclError, data
              else raise IPCError, "Unknown reply tag: #{tag.inspect}"
              end
            end
          end
        end
      end
    RUBY

    # ── lib/jrubytk/ipc/event_channel.rb ─────────────────────────────────────
    'lib/jrubytk/ipc/event_channel.rb' => <<~'RUBY',
      # frozen_string_literal: true

      require 'socket'

      module JRubyTk
        module IPC
          class EventChannel
            include Constants
            include Framing

            def initialize(socket_path = EVT_SOCKET_PATH)
              @socket_path = socket_path
              @socket      = nil
              @thread      = nil
              @handlers    = {}
              @handler_mx  = Mutex.new
              @running     = false
            end

            def on(widget_id, event_name, &block)
              @handler_mx.synchronize do
                @handlers[widget_id]             ||= {}
                @handlers[widget_id][event_name] ||= []
                @handlers[widget_id][event_name] << block
              end
            end

            def remove_widget(widget_id)
              @handler_mx.synchronize { @handlers.delete(widget_id) }
            end

            def start
              @socket  = UNIXSocket.new(@socket_path)
              @running = true
              ready = frame_read(@socket)
              unless ready&.start_with?(TAG_EVT_READY)
                raise IPCError, "Event channel did not receive ready signal from CRuby"
              end
              @thread = Thread.new do
                Thread.current.name = 'jrubytk-event-listener'
                listen_loop
              end
              self
            rescue Errno::ENOENT, Errno::ECONNREFUSED => e
              raise IPCError, "Cannot connect to CRuby event socket #{@socket_path}: #{e.message}"
            end

            def stop
              @running = false
              @socket&.close rescue nil
              @thread&.join(2)
              @thread = nil
            end

            def running?
              @running && @thread&.alive?
            end

            private

            def listen_loop
              while @running
                body = frame_read(@socket)
                break if body.nil?
                next  unless body[0] == TAG_EVENT && body.bytesize >= 5
                widget_id  = body[1, 4].unpack1('N')
                event_name = body[5..]
                dispatch_event(widget_id, event_name)
              end
            rescue IOError, Errno::ECONNRESET
              nil
            ensure
              @running = false
            end

            def dispatch_event(widget_id, event_name)
              handlers = @handler_mx.synchronize do
                @handlers.dig(widget_id, event_name)&.dup
              end
              return unless handlers
              handlers.each { |h| Thread.new { h.call(widget_id, event_name) } }
            end
          end
        end
      end
    RUBY

    # ── lib/jrubytk/cruby_server.rb ───────────────────────────────────────────
    'lib/jrubytk/cruby_server.rb' => <<~'RUBY',
      # frozen_string_literal: true

      module JRubyTk
        module CRubyServerScript
          include Constants

          SCRIPT = <<~'SERVER'
            #!/usr/bin/env ruby
            # jrubytk CRuby dispatch server — spawned by JRubyTk::Bridge

            require 'socket'

            CMD_SOCKET_PATH = '/tmp/jrubytk_cmd.sock'
            EVT_SOCKET_PATH = '/tmp/jrubytk_evt.sock'
            FRAME_PACK      = 'N'
            FRAME_HDR       = 4
            TAG_OK          = 'R'
            TAG_ERR         = 'E'
            TAG_EVENT       = 'V'
            TAG_EVT_READY   = 'Y'

            TK_BACKEND = begin
              require 'tk'
              :tk_gem
            rescue LoadError
              begin
                require 'tcl'
                :tcl_gem
              rescue LoadError
                $stderr.puts "FATAL: No Tcl/Tk backend found in CRuby. Run: gem install tk"
                exit 1
              end
            end

            $stderr.puts "jrubytk CRuby server: backend=#{TK_BACKEND}"

            def tcl_eval(cmd)
              case TK_BACKEND
              when :tk_gem  then Tk.tk_call(*cmd.split(' '))
              when :tcl_gem then Tcl.eval(cmd)
              end.to_s
            end

            def frame_write(io, body)
              bytes = body.encode('UTF-8', invalid: :replace, undef: :replace)
              io.write([bytes.bytesize].pack(FRAME_PACK))
              io.write(bytes)
              io.flush
            rescue IOError, Errno::EPIPE
              nil
            end

            def frame_read(io)
              hdr = io.read(FRAME_HDR)
              return nil unless hdr&.bytesize == FRAME_HDR
              len  = hdr.unpack1(FRAME_PACK)
              return '' if len == 0
              body = io.read(len)
              return nil unless body&.bytesize == len
              body.encode('UTF-8', invalid: :replace, undef: :replace)
            end

            [CMD_SOCKET_PATH, EVT_SOCKET_PATH].each { |p| File.delete(p) if File.exist?(p) }

            cmd_server = UNIXServer.new(CMD_SOCKET_PATH)
            evt_server = UNIXServer.new(EVT_SOCKET_PATH)

            $stdout.puts Process.pid
            $stdout.flush

            evt_client = evt_server.accept
            frame_write(evt_client, TAG_EVT_READY)

            cmd_client = cmd_server.accept

            cleanup = proc do
              [cmd_server, evt_server, cmd_client, evt_client].each { |s| s.close rescue nil }
              [CMD_SOCKET_PATH, EVT_SOCKET_PATH].each { |p| File.delete(p) rescue nil }
              exit 0
            end
            trap('TERM', &cleanup)
            trap('INT',  &cleanup)

            def install_binding(path, event_name, widget_id, evt_client)
              id_bytes  = [widget_id.to_i].pack('N')
              tag_frame = TAG_EVENT + id_bytes + event_name
              case TK_BACKEND
              when :tk_gem
                TkBind.new(path, event_name) do
                  bytes = tag_frame.encode('UTF-8', invalid: :replace, undef: :replace)
                  evt_client.write([bytes.bytesize].pack('N'))
                  evt_client.write(bytes)
                  evt_client.flush rescue nil
                end
              end
            end

            loop do
              body = frame_read(cmd_client)
              break if body.nil?
              next  if body.empty?

              if body.start_with?("\x00BIND\x00")
                parts     = body[6..].split("\x00", 2)
                widget_id = parts[0][0, 4].unpack1('N')
                event_str = parts[0][4..]
                tk_path   = parts[1] || '.'
                begin
                  install_binding(tk_path, event_str, widget_id, evt_client)
                  frame_write(cmd_client, TAG_OK + 'bound')
                rescue => e
                  frame_write(cmd_client, TAG_ERR + e.message)
                end
                next
              end

              result = begin
                TAG_OK + tcl_eval(body)
              rescue => e
                TAG_ERR + e.message
              end
              frame_write(cmd_client, result)
            end

            cleanup.call
          SERVER

          def write_server_script
            File.write(CRUBY_SERVER_FILE, SCRIPT)
          end

          def cleanup_server_script
            File.delete(CRUBY_SERVER_FILE) if File.exist?(CRUBY_SERVER_FILE)
          end
        end
      end
    RUBY

    # ── lib/jrubytk/bridge.rb ─────────────────────────────────────────────────
    'lib/jrubytk/bridge.rb' => <<~'RUBY',
      # frozen_string_literal: true

      module JRubyTk
        class Bridge
          include Constants
          include CRubyServerScript

          attr_reader :cruby_pid

          def initialize
            @cmd_channel   = nil
            @evt_channel   = nil
            @cruby_pid     = nil
            @cruby_io      = nil
            @update_thread = nil
            @running       = false
            @next_id       = 0
            @widget_mx     = Mutex.new
            @started       = false
          end

          def start
            return self if @started
            check_cruby!
            write_server_script
            spawn_subprocess
            connect_channels
            start_update_loop
            @started = true
            self
          end

          def running?
            @running
          end

          def shutdown
            @running = false
            @update_thread&.join(2)
            @cmd_channel&.close
            @evt_channel&.stop
            if @cruby_pid
              Process.kill('TERM', @cruby_pid) rescue nil
              Process.wait(@cruby_pid)         rescue nil
            end
            cleanup_server_script
            [CMD_SOCKET_PATH, EVT_SOCKET_PATH].each { |p| File.delete(p) rescue nil }
            @started = false
          end

          alias stop shutdown

          def tcl(cmd)
            ensure_started!
            @cmd_channel.tcl(cmd)
          end

          def tk_call(*args)
            tcl(args.map(&:to_s).join(' '))
          end

          def next_widget_id
            @widget_mx.synchronize { @next_id += 1 }
          end

          def bind_widget(widget_id, tk_path, event_name, &block)
            @evt_channel.on(widget_id, event_name, &block)
            id_bytes = [widget_id].pack('N')
            payload  = "\x00BIND\x00#{id_bytes}#{event_name}\x00#{tk_path}"
            tcl(payload)
          end

          def unbind_widget(widget_id)
            @evt_channel.remove_widget(widget_id)
          end

          private

          def start_update_loop
            @running = true
            interval = UPDATE_INTERVAL_MS / 1000.0
            @update_thread = Thread.new do
              Thread.current.name = 'jrubytk-update-loop'
              while @running
                begin
                  @cmd_channel.tcl('update')
                rescue TclError, IPCError
                  @running = false
                  break
                end
                sleep interval
              end
            end
          end

          def spawn_subprocess
            write_server_script
            @cruby_io  = IO.popen("ruby #{CRUBY_SERVER_FILE}", 'r+')
            pid_line   = @cruby_io.gets
            @cruby_pid = pid_line.to_i
            raise BridgeError, "CRuby subprocess did not signal ready" if @cruby_pid == 0
            sleep 0.05
          end

          def connect_channels
            @evt_channel = IPC::EventChannel.new(EVT_SOCKET_PATH)
            @evt_channel.start
            @cmd_channel = IPC::CommandChannel.new(CMD_SOCKET_PATH)
          end

          def check_cruby!
            cruby = `which ruby 2>/dev/null`.strip
            raise BridgeError, "'ruby' not found on PATH" if cruby.empty?
            engine = `ruby -e "puts RUBY_ENGINE" 2>/dev/null`.strip
            unless engine == 'ruby'
              raise BridgeError, "'ruby' resolves to #{engine.inspect}, not MRI. Check PATH."
            end
          end

          def ensure_started!
            raise BridgeError, "Bridge not started. Call JRubyTk::Bridge#start first." unless @started
          end
        end
      end
    RUBY

    # ── lib/jrubytk/widgets/base.rb ───────────────────────────────────────────
    'lib/jrubytk/widgets/base.rb' => <<~'RUBY',
      # frozen_string_literal: true

      module JRubyTk
        module Widgets
          class Base
            include Constants

            attr_reader :widget_id, :tk_path, :parent

            class << self
              attr_accessor :bridge
              def tk_type(name = nil)
                @tk_type = name if name
                @tk_type
              end
            end

            def initialize(parent = nil, **opts, &block)
              @bridge    = self.class.bridge
              raise BridgeError, "No Bridge active. Call JRubyTk.start first." unless @bridge
              @parent    = parent
              @widget_id = @bridge.next_widget_id
              @tk_path   = build_path(parent)
              create_widget(opts)
              instance_eval(&block) if block
            end

            def configure(**opts)
              return self if opts.empty?
              args = opts.flat_map { |k, v| ["-#{k}", tcl_quote(v)] }.join(' ')
              @bridge.tcl("#{@tk_path} configure #{args}")
              self
            end
            alias config configure

            def cget(option)
              @bridge.tcl("#{@tk_path} cget -#{option}")
            end

            %i[text title width height bg fg font relief cursor].each do |attr|
              define_method(attr) do |val = :_get|
                val == :_get ? cget(attr) : configure(attr => val)
              end
            end

            def pack(**opts)
              args = opts.flat_map { |k, v| ["-#{k}", tcl_quote(v)] }.join(' ')
              @bridge.tcl("pack #{@tk_path} #{args}")
              self
            end

            def grid(**opts)
              args = opts.flat_map { |k, v| ["-#{k}", tcl_quote(v)] }.join(' ')
              @bridge.tcl("grid #{@tk_path} #{args}")
              self
            end

            def place(**opts)
              args = opts.flat_map { |k, v| ["-#{k}", tcl_quote(v)] }.join(' ')
              @bridge.tcl("place #{@tk_path} #{args}")
              self
            end

            def pack_forget
              @bridge.tcl("pack forget #{@tk_path}")
              self
            end

            def grid_forget
              @bridge.tcl("grid forget #{@tk_path}")
              self
            end

            def bind(event_spec, &block)
              @bridge.bind_widget(@widget_id, @tk_path, event_spec, &block)
              self
            end

            def destroy
              @bridge.unbind_widget(@widget_id)
              @bridge.tcl("destroy #{@tk_path}")
            end

            def focus
              @bridge.tcl("focus #{@tk_path}")
              self
            end

            def update
              @bridge.tcl('update')
              self
            end

            private

            def build_path(parent)
              if parent.nil? || parent.tk_path == '.'
                ".w#{@widget_id}"
              else
                "#{parent.tk_path}.w#{@widget_id}"
              end
            end

            def create_widget(opts)
              type = self.class.tk_type
              return unless type
              args = opts.flat_map { |k, v| ["-#{k}", tcl_quote(v)] }.join(' ')
              @bridge.tcl("#{type} #{@tk_path} #{args}")
            end

            def tcl_quote(val)
              s = val.to_s
              s.include?(' ') ? "{#{s}}" : s
            end
          end
        end
      end
    RUBY

    # ── lib/jrubytk/widgets/all.rb ────────────────────────────────────────────
    'lib/jrubytk/widgets/all.rb' => <<~'RUBY',
      # frozen_string_literal: true

      module JRubyTk
        module Widgets

          class TkRoot < Base
            def initialize(**opts, &block)
              @bridge    = self.class.bridge
              raise BridgeError, "No Bridge active. Call JRubyTk.start first." unless @bridge
              @parent    = nil
              @widget_id = 0
              @tk_path   = '.'
              configure(**opts) unless opts.empty?
              instance_eval(&block) if block
            end

            def title(val = :_get)
              val == :_get ? @bridge.tcl('wm title .') : @bridge.tcl("wm title . {#{val}}")
            end

            def geometry(val = :_get)
              val == :_get ? @bridge.tcl('wm geometry .') : @bridge.tcl("wm geometry . #{val}")
            end

            def resizable(w, h)
              @bridge.tcl("wm resizable . #{w ? 1 : 0} #{h ? 1 : 0}")
              self
            end

            def on_close(&block)
              bind('WM_DELETE_WINDOW', &block)
            end
          end

          class TkToplevel < Base
            tk_type 'toplevel'
            def title(val = :_get)
              val == :_get ? @bridge.tcl("wm title #{@tk_path}") : @bridge.tcl("wm title #{@tk_path} {#{val}}")
            end
            def geometry(val = :_get)
              val == :_get ? @bridge.tcl("wm geometry #{@tk_path}") : @bridge.tcl("wm geometry #{@tk_path} #{val}")
            end
          end

          class TkFrame       < Base; tk_type 'frame';      end
          class TkLabelFrame  < Base; tk_type 'labelframe'; end
          class TkLabel       < Base; tk_type 'label';      end

          class TkButton < Base
            tk_type 'button'
            def command(&block) = bind('command', &block)
            def invoke          = @bridge.tcl("#{@tk_path} invoke")
            def state(val = :_get)
              val == :_get ? cget(:state) : configure(state: val)
            end
          end

          class TkEntry < Base
            tk_type 'entry'
            def value        = @bridge.tcl("#{@tk_path} get")
            def value=(str)
              @bridge.tcl("#{@tk_path} delete 0 end")
              @bridge.tcl("#{@tk_path} insert 0 {#{str}}")
            end
            def clear        = @bridge.tcl("#{@tk_path} delete 0 end")
            def insert(i, s) = @bridge.tcl("#{@tk_path} insert #{i} {#{s}}")
            def on_return(&b)= bind('<Return>', &b)
          end

          class TkText < Base
            tk_type 'text'
            def value        = @bridge.tcl("#{@tk_path} get 1.0 end")
            def value=(str)
              @bridge.tcl("#{@tk_path} delete 1.0 end")
              @bridge.tcl("#{@tk_path} insert end {#{str}}")
            end
            def insert(i, s) = @bridge.tcl("#{@tk_path} insert #{i} {#{s}}")
            def append(s)    = insert('end', s)
            def clear        = @bridge.tcl("#{@tk_path} delete 1.0 end")
            def see(i)       = @bridge.tcl("#{@tk_path} see #{i}")
          end

          class TkCanvas < Base
            tk_type 'canvas'
            def create(type, *coords, **opts)
              args = opts.flat_map { |k, v| ["-#{k}", v] }.join(' ')
              @bridge.tcl("#{@tk_path} create #{type} #{coords.join(' ')} #{args}")
            end
            def create_line(*c, **o)    = create(:line,      *c, **o)
            def create_rect(*c, **o)    = create(:rectangle, *c, **o)
            def create_oval(*c, **o)    = create(:oval,      *c, **o)
            def create_text(x, y, **o)  = create(:text,     x, y, **o)
            def create_polygon(*c, **o) = create(:polygon,   *c, **o)
            def delete(id)  = @bridge.tcl("#{@tk_path} delete #{id}")
            def move(id, dx, dy) = @bridge.tcl("#{@tk_path} move #{id} #{dx} #{dy}")
          end

          class TkListbox < Base
            tk_type 'listbox'
            def insert(idx, *items)
              items.each { |i| @bridge.tcl("#{@tk_path} insert #{idx} {#{i}}") }
              self
            end
            def append(*items) = insert(:end, *items)
            def delete(f, l = nil) = @bridge.tcl("#{@tk_path} delete #{f}#{l ? " #{l}" : ''}")
            def get(idx)       = @bridge.tcl("#{@tk_path} get #{idx}")
            def curselection   = @bridge.tcl("#{@tk_path} curselection").split.map(&:to_i)
            def size           = @bridge.tcl("#{@tk_path} size").to_i
            def clear          = @bridge.tcl("#{@tk_path} delete 0 end")
            def on_select(&b)  = bind('<<ListboxSelect>>', &b)
          end

          class TkScrollbar < Base
            tk_type 'scrollbar'
            def attach_to(widget, axis: :y)
              case axis
              when :y
                @bridge.tcl("#{@tk_path} configure -command {#{widget.tk_path} yview}")
                @bridge.tcl("#{widget.tk_path} configure -yscrollcommand {#{@tk_path} set}")
              when :x
                @bridge.tcl("#{@tk_path} configure -command {#{widget.tk_path} xview}")
                @bridge.tcl("#{widget.tk_path} configure -xscrollcommand {#{@tk_path} set}")
              end
              self
            end
          end

          class TkMenu < Base
            tk_type 'menu'
            def add_command(label:, **opts, &block)
              @bridge.tcl("#{@tk_path} add command -label {#{label}}")
              if block
                idx = @bridge.tcl("#{@tk_path} index end")
                bind("<<MenuCommand-#{idx}>>", &block)
              end
              self
            end
            def add_separator          = @bridge.tcl("#{@tk_path} add separator") && self
            def add_cascade(label:, menu:)
              @bridge.tcl("#{@tk_path} add cascade -label {#{label}} -menu #{menu.tk_path}")
              self
            end
            def as_menubar(root)
              @bridge.tcl("#{root.tk_path == '.' ? '.' : root.tk_path} configure -menu #{@tk_path}")
              self
            end
          end

          class TkCheckButton < Base
            tk_type 'checkbutton'
            def checked?      = @bridge.tcl("#{@tk_path} instate selected") == '1'
            def check         = @bridge.tcl("#{@tk_path} select")   && self
            def uncheck       = @bridge.tcl("#{@tk_path} deselect") && self
            def toggle        = @bridge.tcl("#{@tk_path} toggle")   && self
            def on_toggle(&b) = bind('command', &b)
          end

          class TkRadioButton < Base
            tk_type 'radiobutton'
            def select        = @bridge.tcl("#{@tk_path} select") && self
            def on_select(&b) = bind('command', &b)
          end

          class TkScale < Base
            tk_type 'scale'
            def value       = @bridge.tcl("#{@tk_path} get").to_f
            def value=(v)   = @bridge.tcl("#{@tk_path} set #{v}")
            def on_change(&b) = bind('<Motion>', &b)
          end

          class TkSpinbox < Base
            tk_type 'spinbox'
            def value       = @bridge.tcl("#{@tk_path} get")
            def value=(v)   = @bridge.tcl("#{@tk_path} set {#{v}}")
            def range(from, to, inc = 1) = configure(from: from, to: to, increment: inc)
          end

        end
      end
    RUBY

    # ── lib/jrubytk/compat.rb ─────────────────────────────────────────────────
    'lib/jrubytk/compat.rb' => <<~'RUBY',
      # frozen_string_literal: true

      module JRubyTk
        module TkCompat
          def self.enable!(bridge)
            unless Object.const_defined?(:Tk)
              Object.const_set(:Tk, build_tk_module(bridge))
            end
            widget_map.each do |name, klass|
              Object.const_set(name, klass) unless Object.const_defined?(name)
            end
            widget_map.values.each { |klass| klass.bridge = bridge }
          end

          def self.widget_map
            {
              'TkRoot'        => Widgets::TkRoot,
              'TkToplevel'    => Widgets::TkToplevel,
              'TkFrame'       => Widgets::TkFrame,
              'TkLabelFrame'  => Widgets::TkLabelFrame,
              'TkLabel'       => Widgets::TkLabel,
              'TkButton'      => Widgets::TkButton,
              'TkEntry'       => Widgets::TkEntry,
              'TkText'        => Widgets::TkText,
              'TkCanvas'      => Widgets::TkCanvas,
              'TkListbox'     => Widgets::TkListbox,
              'TkScrollbar'   => Widgets::TkScrollbar,
              'TkMenu'        => Widgets::TkMenu,
              'TkCheckButton' => Widgets::TkCheckButton,
              'TkRadioButton' => Widgets::TkRadioButton,
              'TkScale'       => Widgets::TkScale,
              'TkSpinbox'     => Widgets::TkSpinbox,
            }
          end

          def self.build_tk_module(bridge)
            Module.new do
              define_singleton_method(:tk_call)  { |*a| bridge.tk_call(*a) }
              define_singleton_method(:mainloop) { bridge.tcl('update') while bridge.running? }
              define_singleton_method(:after)    { |ms, &b| bridge.tcl("after #{ms}"); b&.call }
              define_singleton_method(:update)   { bridge.tcl('update') }
              define_singleton_method(:exit)     { bridge.shutdown }
              define_singleton_method(:running?) { bridge.running? }
              define_singleton_method(:TK_PATCHLEVEL) do
                @_patchlevel ||= bridge.tcl('info patchlevel')
              end
            end
          end
          private_class_method :build_tk_module
        end
      end
    RUBY

    # ── lib/jrubytk.rb ────────────────────────────────────────────────────────
    'lib/jrubytk.rb' => <<~'RUBY',
      # frozen_string_literal: true
      # jrubytk — JRuby-native Tk widget library via JEP-380 UDS IPC
      # by Troy Mallory (Cufe Vpvnkedv / CufeHaco)

      unless defined?(JRUBY_VERSION)
        raise LoadError, "jrubytk requires JRuby. Detected: #{RUBY_ENGINE} #{RUBY_VERSION}."
      end

      require_relative 'jrubytk/version'
      require_relative 'jrubytk/errors'
      require_relative 'jrubytk/constants'
      require_relative 'jrubytk/ipc/framing'
      require_relative 'jrubytk/ipc/command_channel'
      require_relative 'jrubytk/ipc/event_channel'
      require_relative 'jrubytk/cruby_server'
      require_relative 'jrubytk/bridge'
      require_relative 'jrubytk/widgets/base'
      require_relative 'jrubytk/widgets/all'
      require_relative 'jrubytk/compat'

      module JRubyTk
        class << self
          def start(**opts)
            @bridge = Bridge.new
            @bridge.start
            TkCompat.enable!(@bridge)
            @bridge
          end

          def bridge
            @bridge
          end

          def mainloop
            raise BridgeError, "Call JRubyTk.start first" unless @bridge&.running?
            sleep 0.1 while @bridge.running?
          end

          def shutdown
            @bridge&.shutdown
            @bridge = nil
          end

          def running?
            @bridge&.running? || false
          end
        end
      end

      $LOADED_FEATURES << 'tk.rb' unless $LOADED_FEATURES.include?('tk.rb')
    RUBY

  }.freeze

  # ─── CRuby Server Script ──────────────────────────────────────────────────────
  # (unchanged from original — kept for the bridge's own spawn_cruby_server)

  CRUBY_SERVER = <<~RUBY
    #!/usr/bin/env ruby
    # CRuby Tk dispatch server — spawned by JRuby via Tk_JRuby_Bridge
    # Plain MRI UNIXServer. Loads tk, evals Tcl at the dispatch chokepoint.

    require 'tk'
    require 'socket'

    SOCKET_PATH = '/tmp/tk_jruby_bridge.sock'
    File.delete(SOCKET_PATH) if File.exist?(SOCKET_PATH)

    server = UNIXServer.new(SOCKET_PATH)

    $stdout.puts Process.pid
    $stdout.flush

    loop do
      client = server.accept
      begin
        loop do
          header = client.read(4)
          break unless header && header.bytesize == 4
          length = header.unpack1('N')
          break if length == 0

          tcl_cmd = client.read(length)
          break unless tcl_cmd && tcl_cmd.bytesize == length

          result = begin
            Tk.tk_call(*tcl_cmd.split(' '))
          rescue => e
            "ERROR: \#{e.message}"
          end

          result_bytes = result.to_s.encode('UTF-8')
          client.write([result_bytes.bytesize].pack('N'))
          client.write(result_bytes)
        end
      rescue => e
        $stderr.puts "Client error: \#{e.message}"
      ensure
        client.close rescue nil
      end
    end
  RUBY

  # ─── Bridge Class ─────────────────────────────────────────────────────────────

  class Bridge
    def initialize
      @os         = RbConfig::CONFIG['host_os']
      @version    = nil
      @paths      = {}
      @from_cache = false
      @cruby_pid  = nil
      @client     = nil
    end

    # ─── Logging ─────────────────────────────────────────────────────────────────

    def log(message)
      File.open(LOG_FILE, 'a') { |f| f.puts "[#{Time.now}] #{message}" }
      puts message
    end

    # ─── Gem Install ─────────────────────────────────────────────────────────────
    # Writes GEM_FILES to /tmp/jrubytk_gem, builds the .gem, installs it into
    # the running JRuby. Skipped if jrubytk is already installed.

    def install_gem
      if gem_installed?
        log "jrubytk gem already installed — skipping build"
        return
      end

      log "Writing jrubytk gem source to #{GEM_BUILD_DIR}"
      FileUtils.rm_rf(GEM_BUILD_DIR)
      FileUtils.mkdir_p(GEM_BUILD_DIR)

      GEM_FILES.each do |rel_path, content|
        dest = File.join(GEM_BUILD_DIR, rel_path)
        FileUtils.mkdir_p(File.dirname(dest))
        File.write(dest, content)
        log "  wrote #{rel_path}"
      end

      log "Building jrubytk gem"
      build_ok = Dir.chdir(GEM_BUILD_DIR) do
        system('jruby -S gem build jrubytk.gemspec 2>&1')
      end

      unless build_ok
        log "ERROR: gem build failed — check output above"
        return
      end

      gem_file = Dir["#{GEM_BUILD_DIR}/jrubytk-*.gem"].sort.last
      unless gem_file
        log "ERROR: .gem file not found after build"
        return
      end

      log "Installing #{File.basename(gem_file)}"
      install_ok = system("jruby -S gem install #{gem_file} --local --no-document 2>&1")

      if install_ok
        log "jrubytk gem installed successfully"
        log "Usage: require 'jrubytk'  — or —  JRubyTk.start"
      else
        log "ERROR: gem install failed — check output above"
      end
    end

    def gem_installed?
      result = `jruby -e "gem 'jrubytk'; puts 'yes'" 2>/dev/null`.strip
      result == 'yes'
    end

    # ─── JEP-380 Install ─────────────────────────────────────────────────────────

    def install_jep380
      if Dir.exist?(JEP380_DIR) && File.exist?("#{JEP380_DIR}/lib/jruby_sockets.rb")
        log "JEP-380 already installed at #{JEP380_DIR}"
        require_jep380
        return
      end

      log "Installing JEP-380 from #{JEP380_REPO} (#{JEP380_BRANCH})"

      unless system('which git > /dev/null 2>&1')
        log "Error: git not found. Install with: sudo apt-get install git"
        cleanup_and_exit(1)
      end

      system("sudo mkdir -p #{JEP380_DIR}")
      unless system("sudo git clone -b #{JEP380_BRANCH} #{JEP380_REPO} #{JEP380_DIR} 2>&1")
        log "Error: Failed to clone JEP-380 repo"
        cleanup_and_exit(1)
      end

      unless File.exist?("#{JEP380_DIR}/lib/jruby_sockets.rb")
        log "Error: jruby_sockets.rb not found in cloned repo at #{JEP380_DIR}/lib/"
        cleanup_and_exit(1)
      end

      log "JEP-380 installed at #{JEP380_DIR}"
      require_jep380
    end

    def require_jep380
      require 'socket'
      require "#{JEP380_DIR}/lib/jruby_sockets"
      log "JRubySockets loaded (version #{JRubySockets::VERSION})"
    end

    # ─── Cache ───────────────────────────────────────────────────────────────────

    def load_cache
      return false unless File.exist?(CACHE_FILE)
      begin
        data        = JSON.parse(File.read(CACHE_FILE))
        @version    = data['version']
        @paths      = data['paths'].transform_keys(&:to_sym)
        @from_cache = true
        log "Loaded cached paths (version #{@version})"
        true
      rescue => e
        log "Cache load failed (#{e.message}), running fresh discovery"
        false
      end
    end

    def save_cache
      File.write(CACHE_FILE, JSON.pretty_generate('version' => @version, 'paths' => @paths))
      log "Saved install data to #{CACHE_FILE}"
    rescue => e
      log "Warning: could not save cache — #{e.message}"
    end

    def clear_cache
      File.delete(CACHE_FILE) if File.exist?(CACHE_FILE)
      log "Cache cleared"
    end

    # ─── Discovery ───────────────────────────────────────────────────────────────

    def ldconfig_find(pattern)
      output  = `ldconfig -p 2>/dev/null`
      base    = pattern.gsub('*', '')
      matches = output.lines.select { |l| l.include?(base) && l.include?('.so') }
      log "ldconfig matches for #{pattern}: #{matches.map(&:strip).inspect}"
      matches.each do |line|
        if line =~ /=>\s+(.+\.so[\d.]*)$/
          full_path = $1.strip
          if File.basename(full_path) =~ /#{base.sub('lib', '')}([\d.]+)\.so/
            return [File.dirname(full_path), $1]
          end
        end
      end
      nil
    end

    def pkgconfig_var(package, variable)
      result = `pkg-config --variable=#{variable} #{package} 2>/dev/null`.strip
      result.empty? ? nil : result
    end

    def pkgconfig_version
      ver = `pkg-config --modversion tcl 2>/dev/null`.strip
      return if ver.empty?
      @version = ver.split('.')[0..1].join('.')
      log "Version from pkg-config: #{@version}"
    end

    def filesystem_find(filename)
      log "Filesystem search for #{filename}..."
      `find / -name '#{filename}' -not -path '/proc/*' -not -path '/sys/*' -not -path '/dev/*' 2>/dev/null`
        .lines.map(&:chomp).reject(&:empty?)
    end

    def locate_file(filename)
      pkg_map = {
        TCL_CONFIG => ['tcl', 'libdir'],
        TK_CONFIG  => ['tk',  'libdir'],
        TCL_HEADER => ['tcl', 'includedir'],
        TK_HEADER  => ['tk',  'includedir']
      }
      if (pkg = pkg_map[filename])
        path = pkgconfig_var(*pkg)
        if path && File.exist?("#{path}/#{filename}")
          log "pkg-config found #{filename} in #{path}"
          return path
        end
      end
      results  = filesystem_find(filename)
      return nil if results.empty?
      versioned = results.select { |p| p =~ /[\d]+\.[\d]+/ }
      chosen    = versioned.first || results.first
      log "Located #{filename} at #{chosen}"
      File.dirname(chosen)
    end

    def locate_lib(pattern)
      result = ldconfig_find(pattern)
      if result
        dir, ver = result
        if @version.nil? || pattern.include?('tcl')
          @version = ver
          log "Version extracted from ldconfig: #{@version}"
        end
        return dir
      end
      log "ldconfig found nothing for #{pattern}, falling back to filesystem find"
      results  = filesystem_find(pattern.gsub('*', ''))
      so_files = results.select { |p| p =~ /\.so/ && File.exist?(p) }
      return nil if so_files.empty?
      chosen = so_files.first
      base   = pattern.gsub('lib', '').gsub('*.so', '')
      if File.basename(chosen) =~ /#{base}([\d.]+)\.so/
        @version ||= $1
        log "Version extracted from filesystem find: #{@version}"
      end
      log "Located lib #{pattern} at #{chosen}"
      File.dirname(chosen)
    end

    def discover_all
      log "Starting full dynamic discovery"
      pkgconfig_version
      @paths[:tcl_lib]     = locate_lib(TCL_LIB_PATTERN)
      @paths[:tk_lib]      = locate_lib(TK_LIB_PATTERN)
      @paths[:tcl_config]  = locate_file(TCL_CONFIG)
      @paths[:tk_config]   = locate_file(TK_CONFIG)
      @paths[:tcl_include] = locate_file(TCL_HEADER)
      @paths[:tk_include]  = locate_file(TK_HEADER)
      missing = @paths.select { |_, v| v.nil? }.keys
      if missing.any?
        log "Discovery incomplete. Missing: #{missing.inspect}"
        return false
      end
      log "Discovery complete. Version: #{@version}"
      log "Paths: #{@paths.inspect}"
      true
    end

    # ─── Requirements ────────────────────────────────────────────────────────────

    def check_requirements
      log "Checking requirements"

      unless defined?(JRUBY_VERSION)
        log "Error: This bridge must run under JRuby. Detected: #{RUBY_ENGINE}"
        exit 1
      end
      log "JRuby #{JRUBY_VERSION} confirmed"

      cruby = `which ruby 2>/dev/null`.strip
      if cruby.empty? || cruby.include?('jruby')
        log "Error: CRuby (MRI) not found. Must have 'ruby' pointing to CRuby."
        exit 1
      end
      log "CRuby found at: #{cruby}"

      tk_check = `ruby -e "require 'tk'; puts Tk::TK_PATCHLEVEL" 2>/dev/null`.strip
      if tk_check.empty?
        log "Error: tk gem not found in CRuby. Run Tk_Installer.rb first."
        exit 1
      end
      log "CRuby tk gem confirmed. Tcl/Tk version: #{tk_check}"

      unless system('sudo -v > /dev/null 2>&1')
        log 'Warning: sudo not available. Symlink creation may fail.'
      end
    end

    # ─── Symlinks ────────────────────────────────────────────────────────────────

    def create_symlinks
      log "Creating symlinks for Tcl/Tk #{@version}"
      symlinks = [
        ["#{@paths[:tcl_config]}/#{TCL_CONFIG}",    '/usr/lib/tclConfig.sh'],
        ["#{@paths[:tk_config]}/#{TK_CONFIG}",       '/usr/lib/tkConfig.sh'],
        ["#{@paths[:tcl_lib]}/libtcl#{@version}.so", "/usr/lib/libtcl#{@version}.so"],
        ["#{@paths[:tk_lib]}/libtk#{@version}.so",   "/usr/lib/libtk#{@version}.so"]
      ]
      symlinks.each do |src, dest|
        unless File.exist?(src)
          log "Source not found, skipping: #{src}"
          next
        end
        if File.exist?(dest) || File.symlink?(dest)
          log "Already exists, skipping: #{dest}"
          next
        end
        if system("sudo ln -s #{src} #{dest}")
          log "Created symlink: #{src} -> #{dest}"
        else
          log "Failed to create symlink: #{src} -> #{dest}"
        end
      end
    end

    # ─── Spawn CRuby subprocess ───────────────────────────────────────────────────

    def spawn_cruby_server
      server_file = '/tmp/tk_cruby_server.rb'
      File.write(server_file, CRUBY_SERVER)
      log "Spawning CRuby Tk dispatch subprocess"

      @cruby_io  = IO.popen("ruby #{server_file}", 'r+')
      @cruby_pid = @cruby_io.gets.to_i
      log "CRuby subprocess running (pid #{@cruby_pid})"

      log "Connecting via JRubySockets::Client (JEP-380 UDS)"
      @client = JRubySockets::Client.new(SOCKET_PATH, auto_reconnect: true, max_retries: 5)
      log "JEP-380 UDS connection established: #{SOCKET_PATH}"
    end

    # ─── Tcl Dispatch ────────────────────────────────────────────────────────────

    def send_tcl(cmd)
      bytes  = cmd.encode('UTF-8')
      framed = [bytes.bytesize].pack('N') + bytes
      @client.send(framed)

      response = @client.recv(8192)
      return nil if response.nil? || response.bytesize < 4
      length = response[0, 4].unpack1('N')
      response[4, length]
    end

    # ─── Test ────────────────────────────────────────────────────────────────────

    def test_bridge
      log "Testing JEP-380 Tk bridge"

      result = send_tcl("info patchlevel")
      log "Tcl dispatch test — info patchlevel: #{result}"

      send_tcl("package require Tk")
      send_tcl("wm title . {CufeHaco JRuby-JEP-380 Tk Bridge}")
      send_tcl("wm geometry . 400x200")
      send_tcl("label .l -text {JRuby -> CRuby via JEP-380 UDS}")
      send_tcl("pack .l")
      send_tcl("button .b -text EXIT -command exit")
      send_tcl("pack .b")
      send_tcl("update")

      log "Bridge test passed. Tk window launched from JRuby via JEP-380 UDS."
      log "Tcl/Tk patchlevel: #{result}"
    end

    # ─── Cleanup ─────────────────────────────────────────────────────────────────

    def cleanup_and_exit(exit_code)
      log "Cleanup initiated (exit code: #{exit_code})"
      @client.close rescue nil
      if @cruby_pid
        Process.kill('TERM', @cruby_pid) rescue nil
        log "CRuby subprocess (pid #{@cruby_pid}) terminated"
      end
      File.delete('/tmp/tk_cruby_server.rb') if File.exist?('/tmp/tk_cruby_server.rb')
      JRubySockets.cleanup(SOCKET_PATH) rescue nil
      clear_cache if exit_code != 0
      log 'Exiting.'
      exit exit_code
    end

    # ─── Run ─────────────────────────────────────────────────────────────────────

    def run
      log "Starting Tk JRuby Bridge at #{Time.now} on #{@os}"
      check_requirements

      # ── Step 1: build + install jrubytk gem ──────────────────────────────────
      install_gem

      # ── Step 2: JEP-380 ──────────────────────────────────────────────────────
      install_jep380

      # ── Step 3: Tcl/Tk discovery ─────────────────────────────────────────────
      unless load_cache
        log "Attempting discovery..."
        unless discover_all
          log "Discovery incomplete. Ensure Tk_Installer.rb has been run first."
          cleanup_and_exit(1)
        end
        save_cache
      end

      # ── Step 4: symlinks ─────────────────────────────────────────────────────
      create_symlinks

      # ── Step 5: spawn CRuby + connect ────────────────────────────────────────
      spawn_cruby_server

      begin
        test_bridge
        log "Tk JRuby Bridge running at #{Time.now}"
        log "JRuby (pid #{Process.pid}) -> CRuby (pid #{@cruby_pid}) via JEP-380 UDS"
        log "require 'socket' — JRubySockets #{JRubySockets::VERSION} active"
        log "require 'jrubytk' — gem installed and ready"

        Process.wait(@cruby_pid)
      rescue Interrupt
        log "Bridge interrupted"
        cleanup_and_exit(0)
      rescue StandardError => e
        log "Bridge failed: #{e.message}"
        cleanup_and_exit(1)
      end
    end
  end
end

# Run the bridge
TkJRubyBridge::Bridge.new.run
