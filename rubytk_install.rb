#!/usr/bin/env ruby
# Tk_Installer.rb by CufeHaco
# Installs and patches Ruby/Tk for Ruby 2.4+ with Tcl/Tk 8.6 (dynamic detection)
# Repurposed from RubianFileUtils::DynamicUtils
# Updated August 13, 2025 for tk gem 0.5.1
# https://github.com/CufeHaco/Tk_Patch

require 'rbconfig'
require 'fileutils'

module TkInstaller
  class DynamicTkUtils
    def initialize
      @os = RbConfig::CONFIG['host_os']
      @tcltk_version = nil  # Will be set dynamically
      @supported_version = '8.6'  # Known supported by tk gem
      @tcl_path = nil
      @tk_path = nil
      @log_file = 'tk_installer.log'
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
        exit 1
      end
      unless @os =~ /mswin|mingw/ || system('sudo -v > /dev/null 2>&1')
        log 'Error: sudo required for Linux/macOS. Please run as a user with sudo privileges.'
        exit 1
      end
    end

    def install_dependencies
      log "Installing Tcl/Tk #{@supported_version} dependencies"
      case @os
      when /linux/
        system 'sudo apt-get update'
        system "sudo apt-get install -y ruby-all-dev tcl#{@supported_version}-dev tk#{@supported_version}-dev" or
          log "Failed to install dependencies. Please install tcl#{@supported_version}-dev and tk#{@supported_version}-dev manually."
      when /darwin/
        if system('brew --version > /dev/null 2>&1')
          system "brew install tcl-tk@#{@supported_version}" or
            log "Failed to install tcl-tk@#{@supported_version} via Homebrew. Please install Tcl/Tk #{@supported_version} manually from https://www.activestate.com/products/activetcl."
        else
          log 'Homebrew not found. Please install Homebrew or Tcl/Tk 8.6 from https://www.activestate.com/products/activetcl.'
          exit 1
        end
      when /mswin|mingw/
        log 'Please install ActiveTcl 8.6 from https://www.activestate.com/products/activetcl.'
        exit 1 unless Dir.exist?('C:/ActiveTcl')
        @tcl_path = @tk_path = 'C:/ActiveTcl'
      else
        log "Unsupported OS: #{@os}. Please install Tcl/Tk #{@supported_version} manually."
        exit 1
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
          log "Warning: Detected Tcl/Tk #{existing_version}, but Ruby tk gem (0.5.1) does not support Tcl/Tk 9.0 yet. Attempting to install #{@supported_version} alongside (may require manual path configuration)."
          install_dependencies
        else
          log "Unsupported Tcl/Tk version #{existing_version} detected. Installing compatible version #{@supported_version}."
          install_dependencies
        end
      else
        log 'Tcl/Tk not found. Installing compatible version 8.6...'
        install_dependencies
      end

      # Dynamic search paths based on detected/installed version
      search_paths = case @os
                     when /linux/
                       ["/usr/lib", "/usr/lib/x86_64-linux-gnu", "/usr/local/lib"]
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
        exit 1
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
               "--enable-pthread" or log 'Failed to install tk gem'
      when /darwin/
        system "gem install tk -- --with-tcl-dir=#{@tcl_path} " \
               "--with-tk-dir=#{@tk_path} " \
               "--with-tcllib=tcl#{@tcltk_version.gsub('.', '')} --with-tklib=tk#{@tcltk_version.gsub('.', '')}" or log 'Failed to install tk gem'
      when /mswin|mingw/
        system "gem install tk -- --with-tcl-dir=#{@tcl_path} --with-tk-dir=#{@tk_path}" or
          log 'Failed to install tk gem'
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
        Tk.mainloop
        log 'Tk test passed!'
      rescue LoadError
        log 'Error: Failed to load tk gem. Check Tcl/Tk installation.'
        exit 1
      rescue => e
        log "Error during Tk test: #{e.message}"
        exit 1
      end
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
