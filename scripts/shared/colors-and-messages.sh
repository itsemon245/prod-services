#!/usr/bin/env bash
# shellcheck disable=SC2034  # library: not every script uses every color

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
RESET='\033[0m'

# Bold
BOLD='\033[1m'

# Underline
UNDERLINE='\033[4m'


psuccess() {
    printf '%b[OK]%b %s\n' "${GREEN}${BOLD}" "$RESET" "$1"
}
perror() {
    printf '%b[ERROR]%b %s\n' "${RED}${BOLD}" "$RESET" "$1" >&2
}
pwarn() {
    printf '%b[WARN]%b %s\n' "${YELLOW}${BOLD}" "$RESET" "$1"
}
pinfo() {
    printf '%b[INFO]%b %s\n' "${BLUE}${BOLD}" "$RESET" "$1"
}
