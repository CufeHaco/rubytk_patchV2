#!/usr/bin/env ruby
# frozen_string_literal: true
# Tk Patch v3 — CufeHaco
# Map the install tree. Do not glob the OS.
#
# v2 searched with Dir.glob and kept a hit only if the path STRING
# contained "8.6". Debian multiarch luckily does. Fedora /usr/lib64,
# Arch /usr/lib, Homebrew opt/, and Windows DLLs do not — so the gem
# failed even when Tcl/Tk was sitting on disk.
#
# v3 snatches the package-manager file list (dpkg -L / rpm -ql / brew
# list / pacman -Ql) into an array, then .map classifies each path.
# Version comes from tclConfig.sh itself, not from the folder name.
# Glob is gone. Walk, when we must, is Dir.entries + .map.
#
#   ruby rubytk_install.rb            # locate, install if needed, build gem
#   ruby rubytk_install.rb --dry-run  # classify + print flags, no writes
#   ruby rubytk_install.rb --tcl-dir=/opt/tcl
#
# MRI + Tcl/Tk 8.6 this pass. JRuby is detected and refused (the hook
# for a later backend). No auto-cleanup.

require 'rbconfig'
require 'fileutils'
require 'shellwords'
require 'optparse'

module TkInstaller
  SUPPORTED = '8.6'
  Hit = Struct.new(:path, :kind, :confidence, :version, :source, keyword_init: true)

  class Logger
    def initialize(file = 'tk_installer.log')
      @file = file
    end

    def call(msg)
      line = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}"
      File.open(@file, 'a') { |f| f.puts(line) }
      puts msg
    end
  end

  module Probe
    module_function

    def os
      host = RbConfig::CONFIG['host_os'].to_s
      case host
      when /mswin|mingw|cygwin/i then :windows
      when /darwin/i             then :darwin
      when /linux/i              then :linux
      else                            :other
      end
    end

    def jruby?
      defined?(JRUBY_VERSION) || RUBY_ENGINE == 'jruby'
    end

    def which?(cmd)
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir|
        File.join(dir, cmd)
      }.any? { |p| File.file?(p) && File.executable?(p) }
    end

    def package_manager
      return :unknown if os == :windows
      return :brew    if os == :darwin && which?('brew')
      return :port    if os == :darwin && which?('port')
      return :apt     if which?('apt-get')
      return :dnf     if which?('dnf')
      return :yum     if which?('yum')
      return :pacman  if which?('pacman')
      return :zypper  if which?('zypper')
      return :apk     if which?('apk')
      :unknown
    end

    def packages_for(pm)
      case pm
      when :apt    then %w[tcl8.6-dev tk8.6-dev libx11-dev]
      when :dnf, :yum then %w[tcl-devel tk-devel libX11-devel]
      when :pacman then %w[tcl tk]
      when :zypper then %w[tcl-devel tk-devel]
      when :apk    then %w[tcl-dev tk-dev]
      when :brew   then %w[tcl-tk@8.6]
      when :port   then %w[tk]
      else              []
      end
    end
  end

  module Tree
    module_function

    def capture(pm, packages, log)
      raw = case pm
            when :apt    then popen(%w[dpkg -L] + packages)
            when :dnf, :yum, :zypper then popen(%w[rpm -ql] + packages)
            when :pacman then popen(%w[pacman -Ql] + packages)
            when :apk    then packages.map { |pkg| popen(['apk', 'info', '-L', pkg]) }.join
            when :brew   then brew_list(packages)
            else              ''
            end
      paths = raw.lines.map { |line| normalize_pm_line(line, pm) }.compact
      log.call("Captured #{paths.length} paths from #{pm} (#{packages.join(', ')})")
      paths
    end

    def normalize_pm_line(line, pm)
      trimmed = line.strip
      return nil if trimmed.empty? || trimmed == '/' || trimmed == '.'
      if pm == :pacman
        m = trimmed.match(/\A\S+\s+(\/.+)\z/)
        return m ? m[1] : nil
      end
      trimmed.start_with?('/') || trimmed =~ /\A[A-Za-z]:[\/\\]/ ? trimmed : nil
    end

    def brew_list(packages)
      packages.map { |formula|
        prefix = popen(['brew', '--prefix', formula]).strip
        listing = popen(['brew', 'list', '--verbose', formula])
        listing.lines.map { |l|
          p = l.strip
          next p if p.start_with?('/')
          prefix.empty? ? nil : File.join(prefix, p)
        }.compact.join("\n")
      }.join("\n")
    end

    def walk(roots, max_depth: 6)
      roots.map { |root| walk_one(root, max_depth) }.flatten.uniq
    end

    def walk_one(root, max_depth)
      return [] unless File.directory?(root)
      acc = []
      stack = [[root, 0]]
      until stack.empty?
        dir, depth = stack.pop
        names = Dir.entries(dir) rescue next
        # Glob is gone: Dir.entries → .map to paths → classify later.
        paths = names.map { |name|
          name == '.' || name == '..' ? nil : File.join(dir, name)
        }.compact
        acc.concat(paths)
        paths.map { |path|
          next unless depth < max_depth && File.directory?(path) && !File.symlink?(path)
          stack << [path, depth + 1]
        }
      end
      acc
    end

    def fallback_roots(os)
      case os
      when :linux
        multiarch = popen(%w[dpkg-architecture -qDEB_HOST_MULTIARCH]).strip
        [
          '/usr/lib', '/usr/lib64', '/usr/local/lib', '/usr/include',
          '/usr/local/include', '/opt',
          (multiarch.empty? ? nil : File.join('/usr/lib', multiarch))
        ].compact
      when :darwin
        %w[
          /opt/homebrew/opt/tcl-tk
          /opt/homebrew/opt/tcl-tk@8.6
          /usr/local/opt/tcl-tk
          /opt/homebrew/Cellar
          /usr/local/Cellar
          /Library/Frameworks
          /usr/local
        ]
      when :windows
        %w[C:/ActiveTcl C:/Tcl]
      else
        %w[/usr/lib /usr/local/lib /opt]
      end.select { |p| File.exist?(p) }
    end

    def popen(args)
      IO.popen(args, err: File::NULL, &:read)
    rescue StandardError
      ''
    end
  end

  module Classify
    module_function

    def map_tree(paths)
      paths.map { |path| classify(path) }.compact
    end

    def classify(path)
      return nil if path.nil? || path.empty? || path.end_with?('/')
      return nil unless File.file?(path) || windows_maybe?(path)
      name = File.basename(path)
      from_path = version_from_path(path)
      from_name = version_from_name(name)

      case name
      when /\AtclConfig\.sh\z/i
        ver, src = version_from_config(path, 'TCL_VERSION')
        Hit.new(path: path, kind: :tcl_config, confidence: 1.0,
                version: ver || from_path || from_name, source: src || source_of(from_path, from_name))
      when /\AtkConfig\.sh\z/i
        ver, src = version_from_config(path, 'TK_VERSION')
        Hit.new(path: path, kind: :tk_config, confidence: 1.0,
                version: ver || from_path || from_name, source: src || source_of(from_path, from_name))
      when /\Atcl\.h\z/i
        Hit.new(path: path, kind: :tcl_header, confidence: 0.95,
                version: from_path || from_name, source: source_of(from_path, from_name))
      when /\Atk\.h\z/i
        Hit.new(path: path, kind: :tk_header, confidence: 0.95,
                version: from_path || from_name, source: source_of(from_path, from_name))
      when /\Alibtcl[\d.]*\.(so|dylib|dll|a)(\.\d+)*\z/i, /\Atcl\d+t?\.dll\z/i
        ver = from_name || from_path
        Hit.new(path: path, kind: :tcl_lib, confidence: ver ? 0.95 : 0.7,
                version: ver, source: source_of(from_name, from_path))
      when /\Alibtk[\d.]*\.(so|dylib|dll|a)(\.\d+)*\z/i, /\Atk\d+t?\.dll\z/i
        ver = from_name || from_path
        Hit.new(path: path, kind: :tk_lib, confidence: ver ? 0.95 : 0.7,
                version: ver, source: source_of(from_name, from_path))
      when /\Atclsh(\d+(\.\d+)?)?(\.exe)?\z/i
        Hit.new(path: path, kind: :tclsh, confidence: 0.9,
                version: from_name || from_path, source: source_of(from_name, from_path))
      when /\Awish(\d+(\.\d+)?)?(\.exe)?\z/i
        Hit.new(path: path, kind: :wish, confidence: 0.9,
                version: from_name || from_path, source: source_of(from_name, from_path))
      end
    end

    def windows_maybe?(path)
      Probe.os == :windows
    end

    def version_from_config(path, key)
      body = File.read(path, 8192) rescue nil
      return [nil, nil] unless body
      m = body.match(/#{key}\s*=\s*['"]?(\d+\.\d+)/)
      m ? [m[1], :config] : [nil, nil]
    end

    def version_from_name(name)
      if (m = name.match(/(\d+)\.(\d+)/))
        "#{m[1]}.#{m[2]}"
      elsif (m = name.match(/(?:tcl|tk|wish)(\d)(\d)/i))
        "#{m[1]}.#{m[2]}"
      end
    end

    def version_from_path(path)
      File.expand_path(path).split(/[\/\\]/).reverse_each { |part|
        if (m = part.match(/(?:tcl|tk)[_-]?(\d+)\.(\d+)/i) || part.match(/\A(\d+)\.(\d+)\z/))
          return "#{m[1]}.#{m[2]}"
        elsif (m = part.match(/(?:tcl|tk)(\d)(\d)/i))
          return "#{m[1]}.#{m[2]}"
        end
      }
      nil
    end

    def source_of(a, b)
      return :name if a
      return :path if b
      :none
    end

    def pick(hits, kind)
      pool = hits.select { |h| h.kind == kind }
      return nil if pool.empty?
      preferred = pool.select { |h| h.version == SUPPORTED }
      ranked = (preferred.empty? ? pool : preferred).sort_by { |h| [-h.confidence, h.path.length] }
      ranked.first
    end
  end

  module Locate
    module_function

    def resolve(hits)
      tcl_config = Classify.pick(hits, :tcl_config)
      tk_config  = Classify.pick(hits, :tk_config)
      tcl_lib    = Classify.pick(hits, :tcl_lib)
      tk_lib     = Classify.pick(hits, :tk_lib)
      tcl_h      = Classify.pick(hits, :tcl_header)
      tk_h       = Classify.pick(hits, :tk_header)
      tclsh      = Classify.pick(hits, :tclsh)
      version    = tcl_config&.version || tk_config&.version || tcl_lib&.version || tclsh&.version || SUPPORTED
      {
        tcl_config: tcl_config,
        tk_config:  tk_config,
        tcl_lib:    tcl_lib,
        tk_lib:     tk_lib,
        tcl_header: tcl_h,
        tk_header:  tk_h,
        tclsh:      tclsh,
        version:    version,
        compatible: version.to_s.start_with?(SUPPORTED),
        tcl_lib_dir: tcl_lib ? File.dirname(tcl_lib.path) : tcl_config && File.dirname(tcl_config.path),
        tk_lib_dir:  tk_lib ? File.dirname(tk_lib.path) : tk_config && File.dirname(tk_config.path),
        tcl_inc_dir: tcl_h && File.dirname(tcl_h.path),
        tk_inc_dir:  (tk_h && File.dirname(tk_h.path)) || (tcl_h && File.dirname(tcl_h.path))
      }
    end

    def gem_flags(res)
      flags = ["--with-tcltkversion=#{res[:version]}"]
      flags << "--with-tclConfig-file=#{res[:tcl_config].path}" if res[:tcl_config]
      flags << "--with-tkConfig-file=#{res[:tk_config].path}"   if res[:tk_config]
      flags << "--with-tcl-lib=#{res[:tcl_lib_dir]}"            if res[:tcl_lib_dir]
      flags << "--with-tk-lib=#{res[:tk_lib_dir]}"              if res[:tk_lib_dir]
      flags << "--with-tcl-include=#{res[:tcl_inc_dir]}"        if res[:tcl_inc_dir]
      flags << "--with-tk-include=#{res[:tk_inc_dir]}"          if res[:tk_inc_dir]
      flags << '--enable-pthread'
      flags
    end
  end

  module Packages
    SAFE_PKG = /\A[A-Za-z0-9.+@_-]+\z/

    module_function

    def install!(pm, packages, log)
      packages.each { |p| raise "Refusing unsafe package name: #{p}" unless p.match?(SAFE_PKG) }
      log.call("Installing via #{pm}: #{packages.join(', ')}")
      ok = case pm
           when :apt
             system('sudo', 'apt-get', 'update') && system('sudo', 'apt-get', 'install', '-y', *packages)
           when :dnf
             system('sudo', 'dnf', 'install', '-y', *packages)
           when :yum
             system('sudo', 'yum', 'install', '-y', *packages)
           when :pacman
             system('sudo', 'pacman', '-S', '--noconfirm', '--needed', *packages)
           when :zypper
             system('sudo', 'zypper', '--non-interactive', 'install', *packages)
           when :apk
             system('sudo', 'apk', 'add', *packages)
           when :brew
             system('brew', 'install', *packages)
           else
             log.call("No package manager. Install Tcl/Tk #{SUPPORTED} yourself, then re-run.")
             false
           end
      raise "Package install failed (#{pm})" unless ok
    end
  end

  module Linker
    module_function

    def maybe_symlink(res, log, dry:)
      return unless Probe.os == :linux
      pairs = []
      pairs << [res[:tcl_config].path, '/usr/lib/tclConfig.sh'] if res[:tcl_config]
      pairs << [res[:tk_config].path,  '/usr/lib/tkConfig.sh']  if res[:tk_config]
      pairs.map { |src, dest|
        next if src == dest
        next if File.exist?(dest)
        # Prefer passing --with-tclConfig-file. Symlink only if dest is missing
        # AND we are not already handing extconf the exact config file.
        next if res[:tcl_config] && dest.end_with?('tclConfig.sh')
        next if res[:tk_config] && dest.end_with?('tkConfig.sh')
        log.call("symlink #{src} -> #{dest}")
        next if dry
        system('sudo', 'ln', '-s', src, dest) or log.call("symlink failed: #{dest}")
      }
    end
  end

  module GemBuild
    module_function

    def install!(flags, log, dry:)
      cmd = ['gem', 'install', 'tk', '-v', '0.5.1', '--', *flags]
      unless gemdir_writable?
        log.call('gem dir not writable; prefixing sudo (system Ruby)')
        cmd.unshift('sudo')
      end
      log.call(cmd.shelljoin)
      return true if dry
      system(*cmd) or raise 'gem install tk failed'
    end

    def gemdir_writable?
      dir = `gem environment gemdir`.strip
      return false if dir.empty?
      File.writable?(dir) || File.writable?(File.dirname(dir))
    end
  end

  module Verify
    module_function

    def test!(log, dry:)
      return log.call('dry-run: skip require tk') if dry
      log.call("Testing require 'tk'")
      begin
        require 'tk'
        log.call("Tk::TK_PATCHLEVEL = #{Tk::TK_PATCHLEVEL}")
      rescue LoadError => e
        raise "Failed to load tk: #{e.message}"
      end
      display = ENV['DISPLAY'] || ENV['WAYLAND_DISPLAY']
      aqua = RbConfig::CONFIG['host_os'].to_s =~ /darwin/
      win  = Probe.os == :windows
      unless display || aqua || win
        log.call('No display — library loaded, skipping GUI window')
        return
      end
      root = TkRoot.new { title 'Tk Patch v3' }
      root['geometry'] = '420x160'
      TkLabel.new(root) { text "mapped. Tcl/Tk #{Tk::TK_PATCHLEVEL}" }.pack(pady: 16)
      TkButton.new(root) { text 'close'; command { root.destroy } }.pack
      Tk.mainloop
    end
  end

  class App
    def initialize(argv)
      @dry = false
      @tcl_dir = ENV['TCLTK_ROOT']
      OptionParser.new { |o|
        o.banner = 'Usage: ruby rubytk_install.rb [--dry-run] [--tcl-dir=PATH]'
        o.on('--dry-run', 'Classify and print flags, write nothing') { @dry = true }
        o.on('--tcl-dir=PATH', 'Override search root (always wins)') { |v| @tcl_dir = v }
      }.parse!(argv)
      @log = Logger.new
    end

    def run
      @log.call("Tk Patch v3 starting on #{Probe.os} / #{RUBY_ENGINE} #{RUBY_VERSION}")
      if Probe.jruby?
        @log.call("JRuby #{(defined?(JRUBY_VERSION) && JRUBY_VERSION) || RUBY_VERSION} detected.")
        @log.call('The MRI tk C extension cannot compile here. This is the hook for a later JRuby backend.')
        exit 2
      end

      pm   = Probe.package_manager
      pkgs = Probe.packages_for(pm)
      @log.call("package manager: #{pm}  packages: #{pkgs.join(', ')}")

      tree = []
      if @tcl_dir
        @log.call("override --tcl-dir=#{@tcl_dir}")
        tree = Tree.walk([@tcl_dir])
      else
        tree = Tree.capture(pm, pkgs, @log) unless pkgs.empty?
        if Classify.map_tree(tree).none? { |h| h.kind == :tcl_config }
          @log.call('Capture missed tclConfig.sh — installing packages, then snatching the tree')
          Packages.install!(pm, pkgs, @log) unless @dry || pkgs.empty?
          tree = Tree.capture(pm, pkgs, @log) unless pkgs.empty?
        end
        if Classify.map_tree(tree).none? { |h| h.kind == :tcl_config }
          @log.call('Still missing — walking fallback roots with Dir.entries + .map')
          tree = (tree + Tree.walk(Tree.fallback_roots(Probe.os))).uniq
        end
      end

      hits = Classify.map_tree(tree)
      @log.call("mapped #{tree.length} paths → #{hits.length} hits")
      hits.each { |h| @log.call("  #{h.kind}  #{h.version || '-'}  #{h.source}  #{h.path}") }

      res = Locate.resolve(hits)
      unless res[:tcl_config] && res[:tk_config]
        raise 'Could not classify tclConfig.sh / tkConfig.sh. Install Tcl/Tk 8.6 and re-run.'
      end
      unless res[:compatible]
        raise "Classified Tcl #{res[:version]}, need #{SUPPORTED}. Install 8.6 alongside and re-run."
      end

      flags = Locate.gem_flags(res)
      @log.call("gem flags:\n  #{flags.join(" \\\n  ")}")
      Linker.maybe_symlink(res, @log, dry: @dry)
      GemBuild.install!(flags, @log, dry: @dry)
      Verify.test!(@log, dry: @dry)
      @log.call('done.')
    end
  end
end

TkInstaller::App.new(ARGV).run if $PROGRAM_NAME == __FILE__
