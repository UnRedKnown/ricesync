function ff --description 'fd -HI PATTERN [DIR]  (search everything from /)'
    if test (count $argv) -eq 0
        echo "usage: find PATTERN [DIR]"
        return 1
    end
    set -l dir /
    if test (count $argv) -ge 2
        set dir $argv[2..-1]
    end
    fd -HI $argv[1] $dir
end
