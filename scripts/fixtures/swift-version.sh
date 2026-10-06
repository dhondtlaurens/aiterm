#!/bin/zsh
# A Swift executable for the toolchain guard's tests that reports whichever version
# AITERM_FIXTURE_SWIFT_VERSION names, so one fixture stands for a toolchain older and newer than the pin.
if [[ "${1:-}" == "--version" ]]; then
    print "Apple Swift version ${AITERM_FIXTURE_SWIFT_VERSION:?} (swift-${AITERM_FIXTURE_SWIFT_VERSION}-RELEASE)"
    exit 0
fi

print -u2 "the swift-version fixture only supports --version"
exit 1
