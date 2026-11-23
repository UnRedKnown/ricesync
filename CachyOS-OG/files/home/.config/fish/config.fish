source /usr/share/cachyos-fish-config/cachyos-config.fish

# overwrite greeting
# potentially disabling fastfetch
#function fish_greeting
#    # smth smth
#end

alias ll 'eza -lah --total-size --color=always --group-directories-first --icons=always'
alias fdc 'complete -C | rg '
functions -e backup
alias fdc 'complete -C | rg '
alias lamp-start='sudo systemctl start httpd mariadb'
alias lamp-stop='sudo systemctl stop httpd mariadb'
alias lamp-status='systemctl status httpd mariadb --no-pager'
alias zed 'zeditor'
starship init fish | source
starship init fish | source
bind ctrl-l 'clear; commandline -f repaint'
