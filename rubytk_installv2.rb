#!/usr/bin/env ruby
# rubytk_install.rb by CufeHaco
# Installs and patches Ruby/Tk for Ruby 2.4+ with Tcl/Tk 8.6 (dynamic detection)
# Repurposed from RubianFileUtils::DynamicUtils
# Updated 2026-03-24 — Linux Mint / Ubuntu x86_64 path fix, lock-wait, non-destructive cleanup
# https://github.com/CufeHaco/Tk_Patch

require 'rbconfig'
require 'fileutils'

module TkInstaller
  class DynamicTkUtils
    SUPPORTED_VERSION = '8.6'
    LOCK_PATH         = '/var/lib/dpkg/lock-frontend'
    LOCK_WAIT_SECS    = 60
    LOCK_POLL_SECS    = 5

    def initialize
      @os              = RbConfig::CONFIG['host_os']
      @arch            = `uname -m 2>/dev/null`.strip          # e.g. x86_64 or aarch64
      @multiarch       = `dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null`.strip
      @multiarch       = "#{@arch}-linux-gnu" if @multiarch.empty?  # fallback
      @tcltk_version   = nil
      @tcl_config_path = nil
      @tk_config_path  = nil
      @tcl_lib_path    = nil
      @tk_lib_path     = nil
      @tcl_include_path = nil
      @tk_include_path  = nil
      @log_file        = 'tk_installer.log'
      @temp_log        = '/tmp/tk_installer_apt.log'
      log "Starting Tk Installer at #{Time.now} on #{@os} (arch=#{@arch}, multiarch=#{@multiarch})"
    end

    # ── Logging ────────────────────────────────────────────────────────────────

    def log(message)
      File.open(@log_file, 'a') { |f| f.puts "[#{Time.now}] #{message}" }
      puts message
    end

    # ── dpkg lock wait ─────────────────────────────────────────────────────────
    # Prevents the "held by process N (aptk)" race between consecutive runs.

    def wait_for_dpkg_lock
      waited = 0
      while File.exist?(LOCK_PATH) && waited < LOCK_WAIT_SECS
        log "dpkg lock held — waiting #{LOCK_POLL_SECS}s (#{waited}/#{LOCK_WAIT_SECS}s elapsed)..."
        sleep LOCK_POLL_SECS
        waited += LOCK_POLL_SECS
      end
      if File.exist?(LOCK_PATH)
        log "ERROR: dpkg lock still held after #{LOCK_WAIT_SECS}s. Kill the blocking process or reboot."
        log "  Run: sudo lsof #{LOCK_PATH}"
        cleanup_and_exit(1)
      end
    end

    # ── File detection ─────────────────────────────────────────────────────────
    # glob → match → dispatch  (Kestówv pattern)
    #
    # One pass over /usr. All six target files resolved simultaneously.
    # Each found path is tested against a dispatch table — the first versioned
    # match for each slot wins and the ivar is set. No repeated syscalls.
    #
    # Dispatch table maps a match pattern → the ivar it populates.
    # Truth match: path must contain the version string (dir-level match for
    # config files whose names carry no version themselves).

    TCLTK_TARGETS = {
      /tclConfig\.sh$/i   => :@tcl_config_path,
      /tkConfig\.sh$/i    => :@tk_config_path,
      /libtcl.*\.so/i     => :@tcl_lib_path,
      /libtk.*\.so/i      => :@tk_lib_path,
      /\/tcl\.h$/i        => :@tcl_include_path,
      /\/tk\.h$/i         => :@tk_include_path,
    }.freeze

    def detect_tcltk_files(search_paths)
      ver     = @tcltk_version || SUPPORTED_VERSION
      ver_re  = /#{Regexp.escape(ver)}/

      # Tier 1 — targeted glob across known paths
      candidates = search_paths.flat_map { |p| Dir.glob("#{p}/**/*", File::FNM_CASEFOLD) }.uniq

      # Tier 2 — full /usr sweep if tier 1 came up short
      if candidates.empty?
        log "Tier 1 empty — falling back to full /usr glob..."
        candidates = Dir.glob("/usr/**/*", File::FNM_CASEFOLD).uniq
      end

      # Tier 3 — system find as last resort
      if candidates.empty?
        log "Tier 2 empty — running system find /usr..."
        candidates = `find /usr -type f 2>/dev/null`.lines.map(&:chomp).reject(&:empty?)
      end

      log "Candidate pool: #{candidates.size} paths"

      # Single match pass — glob → match → dispatch
      # Each candidate is tested against every unresolved slot in the table.
      unresolved = TCLTK_TARGETS.keys.to_a

      candidates.each do |path|
        next unless File.exist?(path)
        next unless (path + File.dirname(path)).match?(ver_re)   # truth match: version present

        unresolved.delete_if do |pattern|
          next false unless path.match?(pattern)
          ivar = TCLTK_TARGETS[pattern]
          next false if instance_variable_get(ivar)              # already resolved, skip
          instance_variable_set(ivar, File.dirname(path))
          log "Resolved #{ivar} → #{path}"
          true                                                    # remove from unresolved
        end

        break if unresolved.empty?                               # all slots filled, stop early
      end

      missing = TCLTK_TARGETS.values.select { |v| instance_variable_get(v).nil? }
      if missing.any?
        log "ERROR: Unresolved Tcl/Tk slots: #{missing.inspect}"
        log "  Run: dpkg -L tcl#{SUPPORTED_VERSION}-dev tk#{SUPPORTED_VERSION}-dev"
        log "  Run: find /usr -name tclConfig.sh 2>/dev/null"
        return false
      end

      true
    end

    # ── Tcl/Tk version detection ───────────────────────────────────────────────

    def get_tcltk_version
      return nil unless system('which tclsh > /dev/null 2>&1')
      version = `printf 'puts [info patchlevel]\nexit\n' | tclsh 2>/dev/null`.strip
      return nil if version.empty?
      log "Detected Tcl/Tk version: #{version}"
      version
    end

    # ── Requirements check ─────────────────────────────────────────────────────

    def check_requirements
      log "Checking requirements"
      unless system('which gem > /dev/null 2>&1')
        log 'ERROR: RubyGems not found. Please install Ruby.'
        cleanup_and_exit(1)
      end
      if @os =~ /linux/ && !system('sudo -v > /dev/null 2>&1')
        log 'ERROR: sudo required. Please run as a user with sudo privileges.'
        cleanup_and_exit(1)
      end
      unless system('which X > /dev/null 2>&1') || system('which Xorg > /dev/null 2>&1')
        log 'WARNING: X11 not found. Tk requires a graphical environment.'
        log '  Install with: sudo apt-get install xorg'
      end
    end

    # ── Dependency installation ────────────────────────────────────────────────

    def install_dependencies
      log "Installing Tcl/Tk #{SUPPORTED_VERSION} dependencies"
      case @os
      when /linux/
        wait_for_dpkg_lock
        system 'sudo apt-get update -qq'
        pkgs = "ruby-dev tcl#{SUPPORTED_VERSION}-dev tk#{SUPPORTED_VERSION}-dev libx11-dev"
        unless system("sudo apt-get install -y #{pkgs} > #{@temp_log} 2>&1")
          log "apt installation failed. Output:\n#{safe_read_temp}"
          cleanup_and_exit(1)
        end
        log "Packages installed: #{pkgs}"
      when /darwin/
        unless system('which brew > /dev/null 2>&1')
          log 'ERROR: Homebrew not found. Install from https://brew.sh or install Tcl/Tk 8.6 manually.'
          cleanup_and_exit(1)
        end
        unless system("brew install tcl-tk@#{SUPPORTED_VERSION}")
          log "ERROR: brew install tcl-tk@#{SUPPORTED_VERSION} failed."
          cleanup_and_exit(1)
        end
      when /mswin|mingw/
        log 'Please install ActiveTcl 8.6 from https://www.activestate.com/products/activetcl.'
        exit 1 unless Dir.exist?('C:/ActiveTcl')
        %i[@tcl_config_path @tk_config_path @tcl_lib_path @tk_lib_path
           @tcl_include_path @tk_include_path].each { |v| instance_variable_set(v, 'C:/ActiveTcl') }
      else
        log "Unsupported OS: #{@os}. Please install Tcl/Tk #{SUPPORTED_VERSION} manually."
        cleanup_and_exit(1)
      end
      @tcltk_version = get_tcltk_version&.split('.')&.first(2)&.join('.') || SUPPORTED_VERSION
    end

    # ── Detection ──────────────────────────────────────────────────────────────

    def detect_tcltk
      log "Detecting Tcl/Tk"
      existing = get_tcltk_version
      if existing
        major_minor = existing.split('.').first(2).join('.')
        if major_minor == SUPPORTED_VERSION
          @tcltk_version = major_minor
          log "Compatible Tcl/Tk version #{@tcltk_version} detected. Proceeding."
        else
          log "Detected Tcl/Tk #{existing}; need #{SUPPORTED_VERSION}. Installing..."
          install_dependencies
          retry_detection
        end
      else
        log "Tcl/Tk not found. Installing #{SUPPORTED_VERSION}..."
        install_dependencies
        retry_detection
      end

      # ── Build an exhaustive, arch-aware search path list ──────────────────
      ver = @tcltk_version
      search_paths = case @os
                     when /linux/
                       [
                         # Standard Debian/Ubuntu/Mint layout
                         "/usr/lib/tcl#{ver}",
                         "/usr/lib/tk#{ver}",
                         "/usr/share/tcltk/tcl#{ver}",
                         "/usr/share/tcltk/tk#{ver}",
                         # Multiarch  (x86_64-linux-gnu  OR  aarch64-linux-gnu)
                         "/usr/lib/#{@multiarch}",
                         "/usr/lib/#{@multiarch}/tcl#{ver}",
                         "/usr/lib/#{@multiarch}/tk#{ver}",
                         # Legacy / upstream install locations
                         "/usr/local/lib/tcl#{ver}",
                         "/usr/local/lib/tk#{ver}",
                         "/usr/local/lib",
                         "/usr/lib",
                         "/usr/lib/x86_64-linux-gnu",   # explicit for mixed-arch systems
                         "/usr/lib/aarch64-linux-gnu",
                         # Include headers
                         "/usr/include/tcl#{ver}",
                         "/usr/include/tk#{ver}",
                         "/usr/include",
                         "/usr/local/include",
                       ]
                     when /darwin/
                       [
                         "/opt/homebrew/opt/tcl-tk@#{ver}",
                         "/opt/homebrew/Cellar/tcl-tk@#{ver}",
                         "/usr/local/opt/tcl-tk",
                         "/Library/Frameworks/Tcl.framework",
                         "/Library/Frameworks/Tk.framework",
                       ]
                     when /mswin|mingw/
                       ['C:/ActiveTcl', 'C:/Tcl']
                     else
                       []
                     end

      cleanup_and_exit(1) unless detect_tcltk_files(search_paths)
    end

    # ── Retry after install ────────────────────────────────────────────────────

    def retry_detection
      log 'Retrying Tcl/Tk detection after installation...'
      3.times do |attempt|
        delay = (attempt + 1) * 5
        sleep delay
        @tcltk_version = get_tcltk_version&.split('.')&.first(2)&.join('.') || SUPPORTED_VERSION
        break if @tcltk_version
        log "Retry #{attempt + 1}/3 failed after #{delay}s."
      end
      unless @tcltk_version
        log 'ERROR: Tcl/Tk still not detected after 3 retries. Check PATH or install manually.'
        cleanup_and_exit(1)
      end
      log "Retry successful. Tcl/Tk #{@tcltk_version}"
    end

    # ── Symlinks ───────────────────────────────────────────────────────────────

    def create_symlinks
      return unless @os =~ /linux/
      ver = @tcltk_version
      log "Creating symlinks for Tcl/Tk #{ver}"

      symlinks = [
        ["#{@tcl_config_path}/tclConfig.sh",           '/usr/lib/tclConfig.sh'],
        ["#{@tk_config_path}/tkConfig.sh",             '/usr/lib/tkConfig.sh'],
        ["#{@tcl_lib_path}/libtcl#{ver}.so.0",         "/usr/lib/libtcl#{ver}.so.0"],
        ["#{@tk_lib_path}/libtk#{ver}.so.0",           "/usr/lib/libtk#{ver}.so.0"],
      ]

      # Also try the .so without .0 suffix if the .0 variant doesn't exist
      symlinks.map! do |src, dest|
        alt_src = src.sub(/\.so\.0$/, '.so')
        src = alt_src if !File.exist?(src) && File.exist?(alt_src)
        [src, dest]
      end

      symlinks.each do |src, dest|
        if File.exist?(dest) || File.symlink?(dest)
          log "Symlink/file already exists: #{dest}"
        elsif File.exist?(src)
          result = system("sudo ln -s #{src} #{dest}")
          log result ? "Created symlink: #{src} -> #{dest}" : "WARNING: Failed to create symlink: #{src} -> #{dest}"
        else
          log "WARNING: Source not found for symlink: #{src}"
          # Non-fatal — gem install flags provide the paths directly
        end
      end
    end

    # ── Gem install ────────────────────────────────────────────────────────────

    def install_tk_gem
      log 'Installing tk gem'
      ver = @tcltk_version
      case @os
      when /linux/
        cmd = [
          'sudo gem install tk --',
          "--with-tcltkversion=#{ver}",
          "--with-tcl-lib=#{@tcl_lib_path}",
          "--with-tk-lib=#{@tk_lib_path}",
          "--with-tcl-include=#{@tcl_include_path}",
          "--with-tk-include=#{@tk_include_path}",
          '--enable-pthread',
        ].join(' ')
        log "gem install command: #{cmd}"
        unless system(cmd)
          log "ERROR: tk gem installation failed. (exit status: #{$?.exitstatus})"
          cleanup_and_exit(1)
        end
      when /darwin/
        short = ver.delete('.')
        cmd = "sudo gem install tk -- --with-tcl-dir=#{@tcl_lib_path} --with-tk-dir=#{@tk_lib_path} " \
              "--with-tcllib=tcl#{short} --with-tklib=tk#{short}"
        unless system(cmd)
          log 'ERROR: tk gem installation failed.'
          cleanup_and_exit(1)
        end
      when /mswin|mingw/
        unless system("gem install tk -- --with-tcl-dir=#{@tcl_lib_path} --with-tk-dir=#{@tk_lib_path}")
          log 'ERROR: tk gem installation failed.'
          cleanup_and_exit(1)
        end
      end
    end

    # ── Smoke test ─────────────────────────────────────────────────────────────

    def test_tk
      log 'Testing Tk gem'
      begin
        require 'tk'
        log "Tk version: #{Tk::TK_PATCHLEVEL}"
        root = TkRoot.new { title 'CufeHaco Tk Installer Test' }
        root['geometry'] = '400x200'
        TkLabel.new(root)  { text 'Tk Installer Successful!'; pack }
        TkButton.new(root) { text 'EXIT'; command { exit }; pack }
        Tk.mainloop
        log 'Tk test passed!'
      rescue LoadError => e
        log "ERROR: Failed to load tk gem — #{e.message}"
        cleanup_and_exit(1)
      rescue => e
        log "ERROR during Tk test: #{e.message}"
        cleanup_and_exit(1)
      end
    end

    # ── Cleanup ────────────────────────────────────────────────────────────────
    # Changed from original: cleanup no longer REMOVES packages on failure.
    # Removing the dev packages on failure left the system in a worse state
    # and triggered dpkg lock contention on the next run.
    # Instead we log what to do manually and exit cleanly.

    def cleanup_and_exit(exit_code)
      log "Cleanup initiated due to failure (exit code: #{exit_code})"
      case @os
      when /linux/
        log "No packages removed. To clean up manually if desired:"
        log "  sudo apt-get remove ruby-dev tcl#{SUPPORTED_VERSION}-dev tk#{SUPPORTED_VERSION}-dev libx11-dev"
        log "  sudo apt-get autoremove --purge"
        log "  sudo rm -f /usr/lib/tclConfig.sh /usr/lib/tkConfig.sh"
        log ""
        log "To diagnose the Tcl/Tk file layout on this machine:"
        log "  dpkg -L tcl#{SUPPORTED_VERSION}-dev tk#{SUPPORTED_VERSION}-dev"
        log "  find /usr -name tclConfig.sh 2>/dev/null"
      when /darwin/
        log "To clean up: brew uninstall tcl-tk@#{SUPPORTED_VERSION}"
      when /mswin|mingw/
        log 'No automatic cleanup for Windows. Uninstall ActiveTcl 8.6 manually if needed.'
      end
      FileUtils.rm_f(@temp_log)
      log 'Exiting.'
      exit exit_code
    end

    # ── Entry point ────────────────────────────────────────────────────────────

    def run
      check_requirements
      detect_tcltk
      create_symlinks
      install_tk_gem
      begin
        test_tk
        log "Tk Installer completed successfully at #{Time.now}"
      rescue StandardError => e
        log "Installation failed during test phase: #{e.message}"
        cleanup_and_exit(1)
      end
    end

    private

    def safe_read_temp
      File.exist?(@temp_log) ? File.read(@temp_log) : '(no output file)'
    end
  end
end

TkInstaller::DynamicTkUtils.new.run
