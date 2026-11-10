#!/bin/sh
# Swift Testing ships with the Command Line Tools but is not on the default search path without Xcode.
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib "$@"
