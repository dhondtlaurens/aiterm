#!/bin/zsh
# Minimal Swift executable fixture for the compatibility-launcher regression test.
if [[ "${1:-}" == "--version" ]]; then
    print "Apple Swift version 6.3 (swift-6.3-RELEASE)"
    exit 0
fi

print -u2 "swift-6.3 fixture only supports --version"
exit 1
