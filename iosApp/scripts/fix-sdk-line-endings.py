"""Normalize line endings in an extracted iOS SDK.

An SDK unpacked on Windows has its text files rewritten with CRLF. Swift's
.swiftinterface parser reads the first line as

    // swift-interface-format-version: 1.0

and the trailing CR ends up inside the parsed version, so the compiler reports

    error: error extracting version from module interface

which looks like a compiler/SDK version mismatch but is purely a line-ending
problem. Converting the files back to LF makes the same 6.4 compiler read the
same 1.0 format without issue - the Windows SDK shipped with the toolchain uses
LF and parses fine.

Only genuinely textual suffixes are listed below. .swiftdoc sits next to
.swiftinterface in the same directory but is a *binary* container, and rewriting
its bytes makes the compiler reject the module with "malformed compiled module".
The iOS 16.5 SDK did not trigger this because its SwiftUI .swiftdoc happened to
contain no CRLF; the iOS 27.0 SDK does, so the distinction has to be explicit
rather than incidental.

Idempotent: files that are already LF are left untouched.
"""

import os
import sys

SDK = sys.argv[1] if len(sys.argv) > 1 else \
    r"C:\Users\cxh20\AppData\Local\Temp\_nettest\sdks\iPhoneOS16.5.sdk"

# .swiftdoc is deliberately absent: it is a binary module container.
TARGET_SUFFIXES = (".swiftinterface", ".modulemap", ".apinotes",
                   ".h", ".json", ".plist", ".txt")

SKIP_DIRS = {"_Signature", "Symbols"}


def main():
    if not os.path.isdir(SDK):
        sys.exit("not a directory: %s" % SDK)

    changed = scanned = 0
    total_bytes = 0

    for root, dirs, files in os.walk(SDK):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if not name.endswith(TARGET_SUFFIXES):
                continue
            path = os.path.join(root, name)
            try:
                with open(path, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            if b"\r\n" not in data:
                continue
            scanned += 1
            fixed = data.replace(b"\r\n", b"\n")
            try:
                with open(path, "wb") as fh:
                    fh.write(fixed)
            except OSError as exc:
                print("  could not write %s: %s" % (path, exc))
                continue
            changed += 1
            total_bytes += len(data) - len(fixed)

    print("files scanned with CRLF: %d" % scanned)
    print("files converted to LF : %d" % changed)
    print("bytes removed         : %d" % total_bytes)


if __name__ == "__main__":
    main()
