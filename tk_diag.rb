#!/usr/bin/env ruby
# tk_diag.rb by CufeHaco
# Run this BEFORE rubytk_install.rb to map the actual Tcl/Tk layout on this machine.
# Output tells you exactly what the installer will find (or won't find).

puts "=== Tcl/Tk Diagnostic ==="
puts "arch:       #{`uname -m`.strip}"
puts "multiarch:  #{`dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null`.strip}"
puts "tclsh:      #{`which tclsh 2>/dev/null`.strip}"
puts "tclsh ver:  #{`printf 'puts [info patchlevel]\nexit\n' | tclsh 2>/dev/null`.strip}"
puts ""

targets = %w[tclConfig.sh tkConfig.sh libtcl8.6.so libtk8.6.so tcl.h tk.h]

puts "=== find /usr for each target ==="
targets.each do |f|
  results = `find /usr -name '#{f}' 2>/dev/null`.strip
  if results.empty?
    puts "  #{f}: NOT FOUND"
  else
    results.lines.each { |l| puts "  #{f}: #{l.chomp}" }
  end
end

puts ""
puts "=== dpkg -L tcl8.6-dev ==="
puts `dpkg -L tcl8.6-dev 2>/dev/null`.strip.then { |s| s.empty? ? "  (not installed)" : s }

puts ""
puts "=== dpkg -L tk8.6-dev ==="
puts `dpkg -L tk8.6-dev 2>/dev/null`.strip.then { |s| s.empty? ? "  (not installed)" : s }

puts ""
puts "=== dpkg -l | grep tcl ==="
puts `dpkg -l 2>/dev/null | grep tcl`.strip.then { |s| s.empty? ? "  (nothing)" : s }

puts ""
puts "=== dpkg -l | grep tk ==="
puts `dpkg -l 2>/dev/null | grep ' tk'`.strip.then { |s| s.empty? ? "  (nothing)" : s }
