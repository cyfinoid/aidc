# zsh completion for aidc — thin wrapper over the bash completion via
# bashcompinit. Source it from your ~/.zshrc:
#   source /path/to/aidc/completions/aidc.zsh
# (install.sh prints the exact line for your checkout.)

autoload -U +X bashcompinit && bashcompinit
autoload -U +X compinit && compinit -u 2>/dev/null

source "${0:A:h}/aidc.bash"
