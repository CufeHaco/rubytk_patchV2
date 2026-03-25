#!/usr/bin/env ruby
# Tk_Installer.rb by CufeHaco
# Installs and patches Ruby/Tk for Ruby 2.4+ with Tcl/Tk (fully dynamic detection)
# Repurposed from RubianFileUtils::DynamicUtils
# Updated 2026 — fully dynamic Linux path discovery via ldconfig/pkg-config/find
# No hardcoded paths. Filenames are the only constants.
# https://github.com/CufeHaco/Tk_Patch

require 'rbconfig'
require 'fileutils'
require 'json'

module TkInstaller
  CACHE_FILE = 'tk_install_data.json'
  LOG_FILE   = 'tk_installer.log'

  # Filenames we need to locate — these are the only constants
  # Version is extracted from whatever the system actually has
  TCL_CONFIG  = 'tclConfig.sh'
  TK_CONFIG   = 'tkConfig.sh'
  TCL_HEADER  = 'tcl.h'
  TK_HEADER   = 'tk.h'
  # .so patterns — version extracted from match
  TCL_LIB_PATTERN = 'libtcl*.so'
  TK_LIB_PATTERN  = 'libtk*.so'

  class DynamicTkUtils
    def initialize
      @os          = RbConfig::CONFIG['host_os']
      @version     = nil   # extracted from discovered filenames
      @paths       = {}    # all discovered paths live here
      @from_cache  = false
    end

    # ─── Logging ────────────────────────────────────────────────────────────────

    def log(message)
      File.open(LOG_FILE, 'a') { |f| f.puts "[#{Time.now}] #{message}" }
      puts message
    end

    # ─── Cache ──────────────────────────────────────────────────────────────────

    def load_cache
      return false unless File.exist?(CACHE_FILE)
      begin
        data = JSON.parse(File.read(CACHE_FILE))
        @version    = data['version']
        @paths      = data['paths'].transform_keys(&:to_sym)
        @from_cache = true
        log "Loaded cached install data (version #{@version})"
        log "Cached paths: #{@paths.inspect}"
        true
      rescue => e
        log "Cache load failed (#{e.message}), running fresh discovery"
        false
      end
    end

    def save_cache
      data = { 'version' => @version, 'paths' => @paths }
      File.write(CACHE_FILE, JSON.pretty_generate(data))
      log "Saved install data to #{CACHE_FILE}"
    rescue => e
      log "Warning: could not save cache — #{e.message}"
    end

    def clear_cache
      File.delete(CACHE_FILE) if File.exist?(CACHE_FILE)
      log "Cache cleared"
    end

    # ─── Core Discovery — ldconfig first, then pkg-config, then find ────────────

    # Find a shared library (.so) by pattern using ldconfig
    # Returns [full_path, extracted_version] or nil
    def ldconfig_find(pattern)
      # ldconfig -p dumps every known shared lib on the system
      output = `ldconfig -p 2>/dev/null`
      base   = pattern.gsub('*', '')  # e.g. "libtcl" from "libtcl*.so"

      # Find all matching lines
      matches = output.lines.select { |l| l.include?(base) && l.include?('.so') }
      log "ldconfig matches for #{pattern}: #{matches.map(&:strip).inspect}"

      matches.each do |line|
        # Line format: "  libtcl8.6.so.0 (libc6,x86-64) => /lib/x86_64-linux-gnu/libtcl8.6.so.0"
        if line =~ /=>\s+(.+\.so[\d.]*)$/
          full_path = $1.strip
          # Extract version from filename: libtcl8.6.so → "8.6"
          if File.basename(full_path) =~ /#{base.sub('lib', '')}([\d.]+)\.so/
            version = $1
            return [File.dirname(full_path), version]
          end
        end
      end
      nil
    end

    # Ask pkg-config for a path variable
    def pkgconfig_var(package, variable)
      result = `pkg-config --variable=#{variable} #{package} 2>/dev/null`.strip
      result.empty? ? nil : result
    end

    # Full filesystem find — last resort, no path hints
    def filesystem_find(filename)
      log "Filesystem search for #{filename}..."
      # Exclude /proc /sys /dev to avoid hangs
      result = `find / -name '#{filename}' -not -path '/proc/*' -not -path '/sys/*' -not -path '/dev/*' 2>/dev/null`.lines.map(&:chomp).reject(&:empty?)
      log "Filesystem find results for #{filename}: #{result.inspect}"
      result
    end

    # Locate a single exact filename, return its directory
    def locate_file(filename)
      # Stage 1: pkg-config (for config/include files)
      if filename == TCL_CONFIG
        path = pkgconfig_var('tcl', 'libdir')
        if path && File.exist?("#{path}/#{filename}")
          log "pkg-config found #{filename} in #{path}"
          return path
        end
      end

      if filename == TK_CONFIG
        path = pkgconfig_var('tk', 'libdir')
        if path && File.exist?("#{path}/#{filename}")
          log "pkg-config found #{filename} in #{path}"
          return path
        end
      end

      if filename == TCL_HEADER
        path = pkgconfig_var('tcl', 'includedir')
        if path && File.exist?("#{path}/#{filename}")
          log "pkg-config found #{filename} in #{path}"
          return path
        end
      end

      if filename == TK_HEADER
        path = pkgconfig_var('tk', 'includedir')
        if path && File.exist?("#{path}/#{filename}")
          log "pkg-config found #{filename} in #{path}"
          return path
        end
      end

      # Stage 2: filesystem find
      results = filesystem_find(filename)
      return nil if results.empty?

      # Prefer versioned paths, pick first valid file
      versioned = results.select { |p| p =~ /[\d]+\.[\d]+/ }
      chosen = versioned.first || results.first
      log "Located #{filename} at #{chosen}"
      File.dirname(chosen)
    end

    # Locate a .so by pattern — uses ldconfig first, then filesystem find
    # Also extracts and sets @version
    def locate_lib(pattern)
      # Stage 1: ldconfig
      result = ldconfig_find(pattern)
      if result
        dir, ver = result
        # Set version from first lib we find (tcl takes precedence)
        if @version.nil? || pattern.include?('tcl')
          @version = ver
          log "Version extracted from ldconfig: #{@version}"
        end
        return dir
      end

      # Stage 2: filesystem find with pattern
      log "ldconfig found nothing for #{pattern}, falling back to filesystem find"
      results = filesystem_find(pattern.gsub('*', ''))
      # Filter to actual .so files
      so_files = results.select { |p| p =~ /\.so/ && File.exist?(p) }
      return nil if so_files.empty?

      chosen = so_files.first
      # Extract version
      base = pattern.gsub('lib', '').gsub('*.so', '')
      if File.basename(chosen) =~ /#{base}([\d.]+)\.so/
        ver = $1
        @version ||= ver
        log "Version extracted from filesystem find: #{@version}"
      end
      log "Located lib #{pattern} at #{chosen}"
      File.dirname(chosen)
    end

    # ─── Full Discovery Run ──────────────────────────────────────────────────────

    def discover_all
      log "Starting full dynamic discovery"

      # Libs first — version comes from here
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

    # ─── Requirements & Install ──────────────────────────────────────────────────

    def check_requirements
      log "Checking requirements"
      unless system('which gem > /dev/null 2>&1')
        log 'Error: RubyGems not found. Please install Ruby.'
        cleanup_and_exit(1)
      end
      unless system('sudo -v > /dev/null 2>&1')
        log 'Error: sudo required. Please run as a user with sudo privileges.'
        cleanup_and_exit(1)
      end
      unless system('which X > /dev/null 2>&1')
        log 'Warning: X11 not found. Tk requires a graphical environment.'
        log 'Install with: sudo apt-get install xorg'
      end
    end

    def install_tcltk
      log "Installing Tcl/Tk development packages"
      system('sudo apt-get update')

      # Install without version pin — let the system resolve what's available
      cmd = "sudo apt-get install -y ruby-all-dev tcl-dev tk-dev libx11-dev 2>&1"
      output = `#{cmd}`
      success = $?.success?

      log output
      unless success
        log "Package installation failed"
        cleanup_and_exit(1)
      end
      log "Packages installed successfully"
    end

    # ─── Symlinks ────────────────────────────────────────────────────────────────

    def create_symlinks
      log "Creating symlinks for Tcl/Tk #{@version}"

      symlinks = [
        ["#{@paths[:tcl_config]}/#{TCL_CONFIG}",              '/usr/lib/tclConfig.sh'],
        ["#{@paths[:tk_config]}/#{TK_CONFIG}",                '/usr/lib/tkConfig.sh'],
        ["#{@paths[:tcl_lib]}/libtcl#{@version}.so",          "/usr/lib/libtcl#{@version}.so"],
        ["#{@paths[:tk_lib]}/libtk#{@version}.so",            "/usr/lib/libtk#{@version}.so"]
      ]

      symlinks.each do |src, dest|
        if !File.exist?(src)
          log "Source not found, skipping symlink: #{src}"
          next
        end
        if File.exist?(dest) || File.symlink?(dest)
          log "Already exists, skipping: #{dest}"
          next
        end
        result = system("sudo ln -s #{src} #{dest}")
        if result
          log "Created symlink: #{src} -> #{dest}"
        else
          log "Failed to create symlink: #{src} -> #{dest}"
        end
      end
    end

    # ─── Gem Install ─────────────────────────────────────────────────────────────

    def install_tk_gem
      log "Installing tk gem"
      cmd = "sudo gem install tk -- " \
            "--with-tcltkversion=#{@version} " \
            "--with-tcl-lib=#{@paths[:tcl_lib]} " \
            "--with-tk-lib=#{@paths[:tk_lib]} " \
            "--with-tcl-include=#{@paths[:tcl_include]} " \
            "--with-tk-include=#{@paths[:tk_include]} " \
            "--enable-pthread"
      log "Running: #{cmd}"
      unless system(cmd)
        log "Failed to install tk gem"
        cleanup_and_exit(1)
      end
      log "tk gem installed successfully"
    end

    # ─── Test ────────────────────────────────────────────────────────────────────

    def test_tk
      log 'Testing Tk gem'
      begin
        require 'tk'
        log "Tk version: #{Tk::TK_PATCHLEVEL}"
        root = TkRoot.new { title 'CufeHaco Tk Installer Test' }
        root['geometry'] = '400x200'
        TkLabel.new(root) { text 'Tk Installer Successful!' }.pack
        TkButton.new(root) { text 'EXIT'; command { exit } }.pack
        Tk.mainloop
        log 'Tk test passed!'
      rescue LoadError
        log 'Error: Failed to load tk gem. Check Tcl/Tk installation.'
        cleanup_and_exit(1)
      rescue => e
        log "Error during Tk test: #{e.message}"
        cleanup_and_exit(1)
      end
    end

    # ─── Cleanup ─────────────────────────────────────────────────────────────────

    def cleanup_and_exit(exit_code)
      log "Cleanup initiated (exit code: #{exit_code})"
      # Only remove packages if we installed them (not if discovery just failed)
      if exit_code != 0 && !@from_cache
        log 'Removing installed packages...'
        system "sudo apt-get remove -y tcl-dev tk-dev libx11-dev 2>&1"
        system "sudo apt-get autoremove -y --purge 2>&1"
        system "sudo rm -f /usr/lib/tclConfig.sh /usr/lib/tkConfig.sh " \
               "/usr/lib/libtcl#{@version}.so /usr/lib/libtk#{@version}.so"
      end
      clear_cache if exit_code != 0
      log 'Exiting.'
      exit exit_code
    end

    # ─── Run ─────────────────────────────────────────────────────────────────────

    def run
      log "Starting Tk Installer at #{Time.now} on #{@os}"
      check_requirements

      # Try cache first
      unless load_cache
        # Attempt discovery before installing
        log "Attempting discovery before install..."
        discovered = discover_all

        unless discovered
          log "Discovery incomplete — installing Tcl/Tk packages first"
          install_tcltk
          log "Re-running discovery after install..."
          discovered = discover_all
          unless discovered
            log "Discovery still incomplete after install. Cannot continue."
            cleanup_and_exit(1)
          end
        end

        # Save what we found — whether installed fresh or already present
        save_cache
      end

      create_symlinks
      install_tk_gem

      begin
        test_tk
        log "Tk Installer completed successfully at #{Time.now}"
      rescue StandardError => e
        log "Installation failed during test: #{e.message}"
        cleanup_and_exit(1)
      end
    end
  end
end

# Run the installer
TkInstaller::DynamicTkUtils.new.run
