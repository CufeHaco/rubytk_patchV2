#!/usr/bin/env ruby
# Tk_Installer.rb by CufeHaco
# Installs and patches Ruby/Tk for Ruby 2.4+ with Tcl/Tk 8.6 (dynamic detection)
# Repurposed from RubianFileUtils::DynamicUtils
# Updated August 14, 2025 for tk gem 0.5.1 with uninstall cleanup on failure
# https://github.com/CufeHaco/Tk_Patch

require 'rbconfig'
require 'fileutils'

module TkInstaller
  class DynamicTkUtils
    def initialize
      @os = RbConfig::CONFIG['host_os']
      @tcltk_version = nil
      @supported_version = '8.6'
      @tcl_path = nil
      @tk_path = nil
      @log_file = 'tk_installer.log'
      @temp_log = 'tmp_apt_output'
      log "Starting Tk Installer at #{Time.now} on #{@os}"
    end

    def log(message)
      File.open(@log_file, 'a') { |f| f.puts "[#{Time.now}] #{message}" }
      puts message
    end

    # Adapted from rubian_boot to find Tcl/Tk files dynamically based on version
    def find_tcltk(file, search_paths)
      file_found = false
      search_paths.each do |path|
        Dir.glob("#{path}/**/#{file}").each do |found_path|
          if File.exist?(found_path)
            @tcl_path = File.dirname(found_path) unless @tcl_path
            @tk_path = File.dirname(found_path) unless @tk_path
            log "Found #{file} at: #{found_path}"
            file_found = true
            break
          end
        end
        break if file_found
      end
      unless file_found
        log "File not found: #{file}"
        return false
      end
      true
    end

    # Dynamic introspection to get Tcl/Tk version via tclsh
    def get_tcltk_version
      if system('which tclsh > /dev/null 2>&1')
        version = `tclsh <<EOF
puts [info patchlevel]
EOF`.strip
        log "Detected Tcl/Tk version: #{version}"
        version
      else
        log "No tclsh found; Tcl/Tk not detected."
        nil
      end
    end

    def check_requirements
      log "Checking requirements"
      unless system('which gem > /dev/null 2>&1')
        log 'Error: RubyGems not found. Please install Ruby.'
        cleanup_and_exit(1)
      end
      unless @os =~ /mswin|mingw/ || system('sudo -v > /dev/null 2>&1')
        log 'Error: sudo required for Linux/macOS. Please run as a user with sudo privileges.'
        cleanup_and_exit(1)
      end
    end

    def install_dependencies
      log "Installing Tcl/Tk #{@supported_version} dependencies"
      case @os
      when /linux/
        system 'sudo apt-get update'
        log 'Updating package lists... (1/3)'
        cmd = "sudo apt-get install -y ruby-all-dev tcl#{@supported_version}-dev tk#{@supported_version}-dev > #{@temp_log} 2>&1"
        unless system(cmd)
          log "Installation failed. Output: #{File.read(@temp_log)}"
          File.delete(@temp_log) if File.exist?(@temp_log)
          cleanup_and_exit(1)
        end
        log 'Installing development packages... (2/3)'
        log 'Finalizing installation... (3/3)'
      when /darwin/
        if system('brew --version > /dev/null 2>&1')
          system "brew install tcl-tk@#{@supported_version}" or
            log "Failed to install tcl-tk@#{@supported_version} via Homebrew. Please install Tcl/Tk #{@supported_version} manually."
            cleanup_and_exit(1)
        else
          log 'Homebrew not found. Please install Homebrew or Tcl/Tk 8.6 from https://www.activestate.com/products/activetcl.'
          cleanup_and_exit(1)
        end
      when /mswin|mingw/
        log 'Please install ActiveTcl 8.6 from https://www.activestate.com/products/activetcl.'
        exit 1 unless Dir.exist?('C:/ActiveTcl')
        @tcl_path = @tk_path = 'C:/ActiveTcl'
      else
        log "Unsupported OS: #{@os}. Please install Tcl/Tk #{@supported_version} manually."
        cleanup_and_exit(1)
      end
      # After installation, set version dynamically
      @tcltk_version = get_tcltk_version.split('.')[0..1].join('.') || @supported_version
    end

    def detect_tcltk
      log "Detecting Tcl/Tk"
      existing_version = get_tcltk_version
      if existing_version
        major_minor = existing_version.split('.')[0..1].join('.')
        if major_minor == @supported_version
          @tcltk_version = major_minor
          log "Compatible Tcl/Tk version #{@tcltk_version} detected. Proceeding."
        elsif major_minor.start_with?('9.')
          log "Warning: Detected Tcl/Tk #{existing_version}, but tk gem 0.5.1 does not support Tcl/Tk 9.0. Attempting to install #{@supported_version}."
          install_dependencies
          @tcltk_version = get_tcltk_version || @supported_version
          retry_detection if @tcltk_version.nil?
        else
          log "Unsupported Tcl/Tk version #{existing_version} detected. Installing #{@supported_version}."
          install_dependencies
          @tcltk_version = get_tcltk_version || @supported_version
          retry_detection if @tcltk_version.nil?
        end
      else
        log 'Tcl/Tk not found. Installing compatible version 8.6...'
        install_dependencies
        @tcltk_version = get_tcltk_version || @supported_version
        retry_detection if @tcltk_version.nil?
      end

      search_paths = case @os
                     when /linux/
                       ["/usr/lib", "/usr/lib/#{`uname -m`.strip}", "/usr/local/lib"]
                     when /darwin/
                       ["/opt/homebrew/Cellar/tcl-tk@#{@tcltk_version}", "/usr/local/Cellar/tcl-tk", "/Library/Frameworks"]
                     when /mswin|mingw/
                       ['C:/ActiveTcl', 'C:/Tcl']
                     else
                       []
                     end
      tcltk_files = ["tclConfig.sh", "tkConfig.sh", "libtcl#{@tcltk_version}.so", "libtk#{@tcltk_version}.so", "tcl.h"]
      found_all = tcltk_files.all? { |file| find_tcltk(file, search_paths) }
      unless found_all
        log 'Error: Some Tcl/Tk files not found after detection/installation.'
        cleanup_and_exit(1)
      end
    end

    def retry_detection
      log 'Retrying Tcl/Tk detection after installation...'
      sleep 5  # Give time for package setup
      @tcltk_version = get_tcltk_version
      if @tcltk_version.nil?
        log 'Error: Tcl/Tk still not detected. Please install manually or check PATH.'
        cleanup_and_exit(1)
      end
    end

    def create_symlinks
      return unless @os =~ /linux/
      log "Creating symlinks for Tcl/Tk #{@tcltk_version}"
      symlinks = [
        ["#{@tcl_path}/tclConfig.sh", '/usr/lib/tclConfig.sh'],
        ["#{@tk_path}/tkConfig.sh", '/usr/lib/tkConfig.sh'],
        ["#{@tcl_path}/libtcl#{@tcltk_version}.so.0", "/usr/lib/libtcl#{@tcltk_version}.so.0"],
        ["#{@tk_path}/libtk#{@tcltk_version}.so.0", "/usr/lib/libtk#{@tcltk_version}.so.0"]
      ]
      symlinks.each do |src, dest|
        if File.exist?(src) && !File.exist?(dest)
          system "sudo ln -s #{src} #{dest}" or log "Failed to create symlink: #{src} -> #{dest}"
        elsif File.exist?(dest)
          log "Symlink already exists: #{dest}"
        else
          log "Source file not found: #{src}"
          cleanup_and_exit(1)
        end
      end
    end

    def install_tk_gem
      log 'Installing tk gem (version 0.5.1)'
      case @os
      when /linux/
        system "gem install tk -- --with-tcltkversion=#{@tcltk_version} " \
               "--with-tcl-lib=#{@tcl_path} " \
               "--with-tk-lib=#{@tk_path} " \
               "--with-tcl-include=/usr/include/tcl#{@tcltk_version} " \
               "--with-tk-include=/usr/include/tcl#{@tcltk_version} " \
               "--enable-pthread" or log 'Failed to install tk gem' and cleanup_and_exit(1)
      when /darwin/
        system "gem install tk -- --with-tcl-dir=#{@tcl_path} " \
               "--with-tk-dir=#{@tk_path} " \
               "--with-tcllib=tcl#{@tcltk_version.gsub('.', '')} --with-tklib=tk#{@tcltk_version.gsub('.', '')}" or log 'Failed to install tk gem' and cleanup_and_exit(1)
      when /mswin|mingw/
        system "gem install tk -- --with-tcl-dir=#{@tcl_path} --with-tk-dir=#{@tk_path}" or
          log 'Failed to install tk gem' and cleanup_and_exit(1)
      end
    end

    def test_tk
      log 'Testing Tk gem'
      begin
        require 'tk'
        log "Tk version: #{Tk::TK_PATCHLEVEL}"
        root = TkRoot.new { title 'CufeHaco Tk Installer Test' }
        root['geometry'] = '400x200'
        TkLabel.new(root) { text 'Tk Installer Successful!' }.pack
        TkButton.new(root) { text 'EXIT'; command { exit } }.pack
        Tk.mainloop  # Blocks until window is closed
        log 'Tk test passed!'
      rescue LoadError
        log 'Error: Failed to load tk gem. Check Tcl/Tk installation.'
        cleanup_and_exit(1)
      rescue => e
        log "Error during Tk test: #{e.message}"
        cleanup_and_exit(1)
      end
    end

    def cleanup_and_exit(exit_code)
      log "Cleanup initiated due to failure (exit code: #{exit_code})"
      case @os
      when /linux/
        log 'Removing installed Tcl/Tk and Ruby packages...'
        system "sudo apt-get remove -y ruby-all-dev tcl#{@supported_version}-dev tk#{@supported_version}-dev libbrotli-dev libfontconfig-dev libfreetype-dev libpng-dev libxrender-dev libxft-dev libxss-dev > #{@temp_log} 2>&1"
        system "sudo apt-get autoremove -y --purge > #{@temp_log} 2>&1"
        system "sudo rm -f /usr/lib/tclConfig.sh /usr/lib/tkConfig.sh /usr/lib/libtcl#{@supported_version}.so.0 /usr/lib/libtk#{@supported_version}.so.0"
        log "Cleanup output: #{File.read(@temp_log)}" if File.exist?(@temp_log)
        File.delete(@temp_log) if File.exist?(@temp_log)
      when /darwin/
        log 'Removing Tcl/Tk via Homebrew (manual cleanup recommended if failed)...'
        system "brew uninstall tcl-tk@#{@supported_version}" if system('which brew > /dev/null 2>&1')
      when /mswin|mingw/
        log 'No automatic cleanup for Windows. Please uninstall ActiveTcl 8.6 manually.'
      end
      log 'Cleanup complete. Exiting.'
      exit exit_code
    end

    def run
      check_requirements
      detect_tcltk
      create_symlinks
      install_tk_gem
      test_tk
      log "Tk Installer completed successfully at #{Time.now}"
    end
  end
end

# Run the installer
TkInstaller::DynamicTkUtils.new.run
