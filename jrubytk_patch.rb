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

  # ─── CRuby Server Script ──────────────────────────────────────────────────────
  # Written to a tempfile, spawned as CRuby subprocess by JRuby.
  # CRuby side uses plain UNIXServer — MRI socket, no JEP-380 needed here.
  # Receives Tcl command bytes, dispatches to libtcl via Tk.tk_call,
  # returns result bytes. 4-byte big-endian length prefix framing.

  CRUBY_SERVER = <<~RUBY
    #!/usr/bin/env ruby
    # CRuby Tk dispatch server — spawned by JRuby via Tk_JRuby_Bridge
    # Plain MRI UNIXServer. Loads tk, evals Tcl at the dispatch chokepoint.

    require 'tk'
    require 'socket'

    SOCKET_PATH = '/tmp/tk_jruby_bridge.sock'
    File.delete(SOCKET_PATH) if File.exist?(SOCKET_PATH)

    server = UNIXServer.new(SOCKET_PATH)

    # Signal JRuby parent we are ready
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

          # Tcl dispatch — sits at same layer as Tcl_Eval in the C extension
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
      @client     = nil   # JRubySockets::Client after install
    end

    # ─── Logging ─────────────────────────────────────────────────────────────────

    def log(message)
      File.open(LOG_FILE, 'a') { |f| f.puts "[#{Time.now}] #{message}" }
      puts message
    end

    # ─── JEP-380 Install ─────────────────────────────────────────────────────────
    # Clone the full-prototype branch to a permanent location.
    # jruby_sockets.rb becomes part of socket — just require 'socket' after this.

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
      # require 'socket' first — JEP-380 builds on top of it
      require 'socket'
      # jruby_sockets becomes part of socket on the JRuby side
      require "#{JEP380_DIR}/lib/jruby_sockets"
      log "JRubySockets loaded (version #{JRubySockets::VERSION})"
    end

    # ─── Cache — shared with Tk_Installer.rb ─────────────────────────────────────

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

    # ─── Discovery — same logic as Tk_Installer.rb ───────────────────────────────

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

    # ─── Requirements ─────────────────────────────────────────────────────────────

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

    # ─── Symlinks — same as Tk_Installer.rb ──────────────────────────────────────

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
    # JRuby is the parent. CRuby child owns the Tk dispatch loop.
    # JRubySockets::Client connects to it — auto-reconnect and stale cleanup
    # are built in, no extra handling needed here.

    def spawn_cruby_server
      server_file = '/tmp/tk_cruby_server.rb'
      File.write(server_file, CRUBY_SERVER)
      log "Spawning CRuby Tk dispatch subprocess"

      # JRuby spawns CRuby — same parent/child pattern as Kestówv spawning MRI
      @cruby_io  = IO.popen("ruby #{server_file}", 'r+')
      @cruby_pid = @cruby_io.gets.to_i  # blocks until CRuby signals ready
      log "CRuby subprocess running (pid #{@cruby_pid})"

      # JRubySockets::Client — auto-reconnect, stale cleanup, signal handling
      # This is just require 'socket' — JEP-380 is already underneath on JRuby
      log "Connecting via JRubySockets::Client (JEP-380 UDS)"
      @client = JRubySockets::Client.new(SOCKET_PATH, auto_reconnect: true, max_retries: 5)
      log "JEP-380 UDS connection established: #{SOCKET_PATH}"
    end

    # ─── Tcl Dispatch — 4-byte length prefix framing ─────────────────────────────
    # JRubySockets handles socket I/O. We own the framing protocol.
    # Same 4-byte big-endian length prefix as Kestówv IPC.

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

      # Clone JEP-380 full-prototype branch, load jruby_sockets into socket
      install_jep380

      unless load_cache
        log "Attempting discovery..."
        unless discover_all
          log "Discovery incomplete. Ensure Tk_Installer.rb has been run first."
          cleanup_and_exit(1)
        end
        save_cache
      end

      create_symlinks
      spawn_cruby_server

      begin
        test_bridge
        log "Tk JRuby Bridge running at #{Time.now}"
        log "JRuby (pid #{Process.pid}) -> CRuby (pid #{@cruby_pid}) via JEP-380 UDS"
        log "require 'socket' — JRubySockets #{JRubySockets::VERSION} active"

        # JRuby is the parent. CRuby child lives with it.
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
