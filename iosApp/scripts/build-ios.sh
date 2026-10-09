#!/usr/bin/env bash
# Cross-compiles PalmAcademic for arm64 iOS on Windows and packages an installable IPA.
#
# Pipeline: swiftc -> ldid ad-hoc signature -> zip Payload/*.app -> IPA.
# The IPA is intentionally fakesigned. TrollStore and LiveContainer install it as-is; SideStore
# and AltStore re-sign it with a real Apple ID, which requires the binary to stay unencrypted.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PalmAcademic"
BUNDLE_ID="cn.edu.cupk.portalreader.ios"
MIN_IOS="16.0"
BUILD_DIR="$ROOT/build-ios"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

# Toolchain locations. Override via environment when the tools live elsewhere.
SWIFT_BIN="${SWIFT_BIN:-/c/Users/cxh20/AppData/Local/Programs/Swift/Toolchains/6.4.0+Asserts/usr/bin}"

# The iOS SDK.
#
# Defaults to the 16.5 SDK from theos, which is the newest one this build can actually use.
#
# An iOS 26/27 SDK is not an option on Windows, even though one can be obtained: starting with
# iOS 26, SwiftUI's property wrappers (@State, @Environment, @Bindable, ...) are implemented as
# external macros shipped in SwiftUIMacros.dylib, and that file is a macOS arm64 binary. Loading it
# on Windows fails with "%1 is not a valid Win32 application", so any SwiftUI file fails to
# compile. Pointing IOS_SDK at such an SDK still type-checks simple API probes, which is misleading.
#
# System glass therefore comes from the Objective-C runtime (see SystemGlassSupport) rather than
# from the SDK, and works on any device running iOS 26 or later.
SDK="${IOS_SDK:-/c/Users/cxh20/AppData/Local/Temp/_nettest/sdks/iPhoneOS16.5.sdk}"

# Kept for forward compatibility: set to 1 when building against an SDK that declares the iOS 26
# material. No such SDK is usable on Windows today, so this stays 0 and the runtime path is used.
USE_SYSTEM_GLASS="${USE_SYSTEM_GLASS:-0}"

LDID="${LDID:-/c/Users/cxh20/AppData/Local/Temp/_nettest/tools/ldid.exe}"
CLANG_BIN="${CLANG_BIN:-/c/Program Files/LLVM/bin}"
LD64="${LD64:-$CLANG_BIN/ld64.lld.exe}"

# Swift 6.x on Windows ships the standard library in a separate package from the
# compiler, under Platforms/<version>/Windows.platform/Developer/SDKs/Windows.sdk.
# Without this the compiler fails with "unable to load standard library" even for
# a plain print(). The Windows SDK is not used for the iOS build itself, but the
# resource directory is what lets the frontend find its own stdlib.
WIN_SDKROOT="${WIN_SDKROOT:-/c/Users/cxh20/AppData/Local/Programs/Swift/Platforms/6.4.0/Windows.platform/Developer/SDKs/Windows.sdk}"

SWIFTC="$SWIFT_BIN/swiftc.exe"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Swift's runtime aborts when the environment carries the same key in different cases
# (for example https_proxy and HTTPS_PROXY both set), so the proxy is normalized away.
normalize_env() {
  local key value
  for key in $(env | cut -d= -f1); do
    case "$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')" in
      http_proxy|https_proxy|all_proxy|no_proxy)
        value="${!key:-}"
        unset "$key"
        low="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
        [ -n "${!low:-}" ] || export "$low=$value"
        ;;
    esac
  done
}

preflight() {
  log "Checking toolchain"
  [ -x "$SWIFTC" ] || [ -f "$SWIFTC" ] || die "swiftc not found at $SWIFTC"
  [ -d "$SDK" ] || die "iOS SDK not found at $SDK"
  [ -f "$LDID" ] || die "ldid not found at $LDID"
  [ -f "$LD64" ] || die "Mach-O linker not found at $LD64"
  "$SWIFTC" --version | head -1

  # Verify the standard library actually loads. A partial toolchain install leaves
  # the compiler present but unable to read its own stdlib, and the failure only
  # shows up as "unable to load standard library" much later.
  [ -d "$WIN_SDKROOT/usr/lib/swift/windows" ] \
    || die "Swift standard library missing at $WIN_SDKROOT/usr/lib/swift/windows
       Reinstall the Windows platform SDK, or set WIN_SDKROOT."

  log "Probing the standard library"
  # The probe lives in a fixed directory inside the build tree so nothing outside it is ever
  # deleted, and so a leftover from an aborted run is simply overwritten.
  local probe="$BUILD_DIR/.stdlib-probe"
  mkdir -p "$probe"
  printf 'print("probe")\n' > "$probe/probe.swift"
  if "$SWIFTC" -typecheck "$probe/probe.swift" -sdk "$WIN_SDKROOT" \
       -resource-dir "$WIN_SDKROOT/usr/lib/swift" \
       -I "$WIN_SDKROOT/usr/lib/swift" > "$probe/out.txt" 2>&1; then
    log "Standard library loads"
  else
    cat "$probe/out.txt" >&2
    die "swiftc cannot load its standard library"
  fi
}

compile() {
  log "Compiling Swift sources for arm64-apple-ios$MIN_IOS"

  # The glass switch has to reach the compiler as a define, because the decision of whether the
  # iOS 26 material exists is a property of the SDK rather than of the device. Naming
  # `glassEffect` against an SDK that lacks it is a compile error, not a runtime condition, so
  # the capability is resolved once here and read by SystemGlassSupport.hasNativeGlassAPI.
  local glass_flag=()
  if [ "$USE_SYSTEM_GLASS" = "1" ]; then
    glass_flag=(-DUSE_SYSTEM_GLASS)
    log "System glass enabled (USE_SYSTEM_GLASS=1)"
  else
    warn "System glass disabled (USE_SYSTEM_GLASS=0): hand-drawn materials only"
  fi
  # The previous output is moved aside rather than deleted outright, so an aborted build
  # never leaves a half-written bundle behind and nothing is removed while it is in use.
  if [ -d "$BUILD_DIR" ]; then
    mv "$BUILD_DIR" "$BUILD_DIR.old.$$"
  fi
  mkdir -p "$APP_DIR"

  local sources
  sources="$(find "$ROOT/Sources" -name '*.swift' | tr '\n' ' ')"

  # swiftc on Windows cannot drive the link step for a Mach-O target: it asks lld for the
  # "llvm" emulation, and the ld.exe that Git for Windows puts on PATH rejects that with
  # "unrecognised emulation mode: llvm". Pointing -use-ld at ld64.lld is not enough either,
  # because the driver never passes the darwin flavour or -platform_version on for a cross
  # target. The workable split is to have swiftc stop after emitting an object file and let
  # clang do the link, which selects ld64.lld correctly on its own.
  log "Compiling to a single object"
  # -wmo makes the compiler treat the inputs as one module, which is required for the
  # cross-file type information this app relies on. -c stops before the link step, and with
  # whole-module output a single -o is accepted even though there are many sources.
  # Swift 6.4 otherwise emits swift_coroFrameAlloc, a runtime entry point introduced after the
  # iOS 16.5 SDK used by this Windows cross-build. The older allocation path is ABI-compatible
  # with the deployment target and avoids requiring an unavailable Apple compatibility pack.
  "$SWIFTC" \
    -target "arm64-apple-ios$MIN_IOS" \
    -sdk "$SDK" \
    -swift-version 5 \
    -Xfrontend -disable-emit-type-malloc-for-coro-frame \
    "${glass_flag[@]}" \
    -O \
    -c \
    -wmo \
    -module-name PalmAcademic \
    -o "$BUILD_DIR/PalmAcademic.o" \
    $sources

  log "Compiling the platform-version stub"
  # The extracted SDK does not declare __isPlatformVersionAtLeast, which the Swift runtime
  # calls for every availability check. The stub answers from the deployment target.
  "$CLANG_BIN/clang.exe" \
    -target "arm64-apple-ios$MIN_IOS" \
    -isysroot "$SDK" \
    -c \
    -o "$BUILD_DIR/platform-version-stub.o" \
    "$ROOT/scripts/platform-version-stub.c"

  log "Linking Mach-O executable"
  # The Swift overlay libraries sit directly in usr/lib/swift, with no per-architecture
  # subdirectory, and the system frameworks (SwiftUI, CryptoKit, ...) are linked as frameworks
  # rather than as -l entries.
  "$CLANG_BIN/clang.exe" \
    -target "arm64-apple-ios$MIN_IOS" \
    -isysroot "$SDK" \
    -fuse-ld=lld \
    -o "$APP_DIR/$APP_NAME" \
    "$BUILD_DIR/PalmAcademic.o" \
    "$BUILD_DIR/platform-version-stub.o" \
    -L"$SDK/usr/lib/swift" \
    -L"$SDK/usr/lib" \
    -lswiftCore \
    -lswiftFoundation \
    -lswiftWebKit \
    -lswiftDispatch \
    -lswift_Concurrency \
    -lswiftObjectiveC \
    -framework Foundation \
    -framework UIKit \
    -framework SwiftUI \
    -framework WebKit \
    -framework CryptoKit \
    -framework BackgroundTasks \
    -framework UserNotifications

  log "Linked executable"
  ls -la "$APP_DIR/$APP_NAME"
}

bundle_resources() {
  log "Copying bundle resources"

  # Info.plist carries the bundle identity. The cross-compile path does not run Xcode's
  # Info.plist generation, so it is copied verbatim.
  cp "$ROOT/Resources/Info.plist" "$APP_DIR/Info.plist"

  # Swift standard libraries are resolved from the SDK at build time, so nothing is embedded.
  mkdir -p "$APP_DIR/_CodeSignature"

  # Asset catalogs cannot be compiled without actool, so the icon ships as a loose PNG and is
  # declared through CFBundleIcons in Info.plist.
  if [ -f "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" ]; then
    cp "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" "$APP_DIR/AppIcon.png"
  fi

  mkdir -p "$APP_DIR/schools" "$APP_DIR/adapters"
  cp "$ROOT"/Resources/schools/*.json "$APP_DIR/schools/" 2>/dev/null || warn "no schools/*.json"
  cp "$ROOT"/Resources/adapters/*.js "$APP_DIR/adapters/" 2>/dev/null || warn "no adapters/*.js"

  log "Bundle contents"
  find "$APP_DIR" -type f | sed "s|$APP_DIR|  .app|"
}

sign() {
  log "Applying ad-hoc signature (ldid)"
  # ldid is a native Windows binary and does not understand the MSYS-style paths bash hands
  # out, so the working directory is changed and relative names are used instead.
  # The flag is a bare -S: -Sadhoc would be read as "-S with a file named adhoc".
  ( cd "$APP_DIR" && "$LDID" -S "$APP_NAME" ) || die "ldid failed to sign the executable"
  "$LDID" -S "$(cygpath -w "$APP_DIR")" 2>/dev/null || warn "bundle-level signing skipped"
  log "Signature applied"
}

package() {
  log "Packaging IPA"
  local ipa="$BUILD_DIR/$APP_NAME.ipa"
  # An IPA is a zip whose single top level directory is Payload, containing the app bundle.
  # Zipping the .app directly produces an archive the installer rejects with
  # "Archive missing valid Payload/*.app/Info.plist", so the staging copy matters.
  local payload="$BUILD_DIR/Payload"
  mkdir -p "$payload"
  cp -r "$APP_DIR" "$payload/$APP_NAME.app"
  ( cd "$BUILD_DIR" && zip -qr "$APP_NAME.ipa" "Payload" )
  ls -la "$ipa"
  log "IPA ready: $ipa"
}

main() {
  normalize_env
  preflight
  compile
  bundle_resources
  sign
  package
}

main "$@"
