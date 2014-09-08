#unix aliases

alias ls='ls --color=auto'
alias l='ls -lh'
alias la='ls -lha'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias c='clear'
alias cx='chmod +x'
alias tree="find . -print | sed -e 's;[^/]*/;|____;g;s;____|; |;g'"
alias profile='emacs ~/.bash_profile'
alias .='source ~/.bash_profile'
alias psef='ps -ef | grep'
alias psaux='ps aux | grep'
alias ll='ls -l'
