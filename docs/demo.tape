# vhs tape for recording the monitor.sh demo GIF.
#
# Prerequisites (run on a LINUX box that has the tool's dependencies):
#   - Install vhs:  https://github.com/charmbracelet/vhs#installation
#   - Make sure monitor.sh's deps are present (run ./scripts/monitor.sh once).
#
# Record:
#   vhs docs/demo.tape        # writes docs/demo.gif
#
# Then uncomment the ![demo](docs/demo.gif) line in README.md.

Output docs/demo.gif

Set FontSize 16
Set Width 1200
Set Height 700
Set Padding 20
Set Theme "Catppuccin Mocha"

Type "./scripts/monitor.sh"
Enter
Sleep 2s

# The whiptail checklist is up — accept the defaults.
Tab
Sleep 500ms
Enter
Sleep 4s

# We're in the tmux dashboard now. Show a couple of tabs.
Ctrl+b
Type "n"
Sleep 3s

Ctrl+b
Type "n"
Sleep 3s

# Back to the main dashboard.
Ctrl+b
Type "0"
Sleep 3s
