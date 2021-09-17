# This file is part of https://github.com/astoff/comint-mime
# shellcheck shell=sh

mimecat () {
    local type
    local file
    case "$1" in
        -h|--help)
            echo "Usage: mimecat [-t TYPE] [FILE]"
            return 0
            ;;
        -t|--type)
            type="$2"
            shift; shift
            ;;
    esac
    if [ -z "$1" ]; then
        if [ -z "$type" ]; then
           echo "mimecat: When reading from stdin, please provide -t TYPE"
           return 1
        fi
        base64 | xargs -0 printf '\033]5151;{"type":"%s"}\n%s\033\\\n' "$type"
    else
        file=$(realpath -e "$1") || return 1
        [ -n "$type" ] || type=$(file -bi "$file")
        printf '\033]5151;{"type":"%s"}\nfile://%s%s\033\\\n' \
               "$type" "$(hostname)" "$file"
    fi
}
