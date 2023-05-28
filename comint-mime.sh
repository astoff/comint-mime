# This file is part of https://github.com/astoff/comint-mime
# shellcheck shell=dash

mimecat () {
    local type file
    case "$1" in
        -h|--help)
            echo >&2 "\
Usage: mimecat [-t TYPE] [FILE]
Display contents of FILE as mime TYPE."
            return 0
            ;;
        -t|--type) type="$2"; shift 2;;
    esac
    if [ $# -eq 0 ]; then
        if [ -z "$type" ]; then
           echo >&2 "mimecat: When reading from stdin, please provide -t TYPE"
           return 1
        fi
        base64 | xargs -0 printf '\033]5151;{"type":"%s"}\n%s\033\\\n' "$type"
    else
        file=$(realpath "$1") || return 1
        [ -n "$type" ] || type=$(file -b --mime "$file")
        printf '\033]5151;{"type":"%s"}\nfile://%s%s\033\\\n' "$type" "$(uname -n)" "$file"
    fi
}
