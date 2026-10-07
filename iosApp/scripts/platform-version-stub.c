/*
 * Implementation of __isPlatformVersionAtLeast for the Windows cross-compile path.
 *
 * Why this file exists
 * --------------------
 * The .tbd stubs in the extracted iPhoneOS SDK do not declare this symbol, but the code the
 * compiler generates for every availability check references it, so the link fails with
 * "undefined symbol: __isPlatformVersionAtLeast".
 *
 * Why it must read the real OS version
 * ------------------------------------
 * The previous version of this file answered every check above the deployment target with
 * "true", on the reasoning that a binary built for iOS 16 never runs on anything older. That
 * reasoning is wrong in a way that matters here: the deployment target is 16.0, so the answer
 * was true for *every* iOS 17/18/26/27 check, on every device. That silently inverted the
 * meaning of `#available(iOS 26.0, *)` and friends -- code paths meant for a newer system were
 * taken on an old one.
 *
 * Because this is a strong definition compiled into the executable, it also takes precedence
 * over the implementation dyld would otherwise supply at runtime. So the answer has to be the
 * real one.
 *
 * How the version is obtained
 * ---------------------------
 * Through os_system_version_get_current_version, which is what the Swift standard library's own
 * _stdlib_isOSVersionAtLeast does: it resolves the symbol with dlsym and asks it for the current
 * version. libc exports it, so no extra framework needs to be linked.
 *
 * Caching
 * -------
 * The value cannot change while the process runs, so it is read once. Availability checks are
 * emitted in the bodies of view builders and layout code, which run often enough that a sysctl
 * per check would be measurable.
 */

#include <stdint.h>
#include <string.h>
#include <dlfcn.h>
#include <stdio.h>
#include <sys/sysctl.h>
#include <sys/types.h>

extern int32_t __isPlatformVersionAtLeast(int32_t major, int32_t minor, int32_t patch);

/*
 * os_system_version_get_current_version is declared in <os/version.h> on the SDK, but that header
 * is not reachable from this include path, so the layout is restated here. It matches the one the
 * symbol is defined with:
 *
 *   struct os_system_version_s { int32_t major; int32_t minor; int32_t patch; };
 *   void os_system_version_get_current_version(struct os_system_version_s *);
 */
struct palm_os_system_version {
    int32_t major;
    int32_t minor;
    int32_t patch;
};

typedef void (*palm_os_version_fn)(struct palm_os_system_version *);

/*
 * Resolved lazily on first use. The host OS is a fixed value, so the cache is written once and
 * the benign race is irrelevant: every writer stores the same bytes.
 */
static int palm_read_system_version(struct palm_os_system_version *out) {
    static struct palm_os_system_version cached;
    static int have_cached = 0;

    if (!have_cached) {
        palm_os_version_fn lookup =
            (palm_os_version_fn)dlsym(RTLD_DEFAULT, "os_system_version_get_current_version");
        if (lookup != 0) {
            lookup(&cached);
        } else {
            /*
             * Should not happen on any real device, since libc exports the symbol. Fall back to the
             * kernel's product version rather than leaving the version at zero: answering "older
             * than everything" would disable every optional code path in the app.
             */
            char buf[32];
            size_t len = sizeof(buf);
            if (sysctlbyname("kern.osproductversion", buf, &len, 0, 0) != 0) {
                return -1;
            }
            buf[sizeof(buf) - 1] = '\0';
            cached.major = 0;
            cached.minor = 0;
            cached.patch = 0;
            sscanf(buf, "%d.%d.%d", &cached.major, &cached.minor, &cached.patch);
        }
        have_cached = 1;
    }

    *out = cached;
    return 0;
}

/*
 * Reports whether the running system is at least the given iOS version.
 *
 * The platform argument is absent from the signature the compiler emits against, which passes
 * (major, minor, patch) directly. Builds are iOS-only here, so no platform filtering is needed.
 */
int32_t __isPlatformVersionAtLeast(int32_t major, int32_t minor, int32_t patch) {
    struct palm_os_system_version current;

    if (palm_read_system_version(&current) != 0) {
        /*
         * The version could not be established. Returning true keeps optional features enabled
         * rather than silently dropping the app into its oldest code paths; a wrong "true" only
         * reaches OS APIs guarded by their own class checks, whereas a wrong "false" would hide
         * functionality that works.
         */
        return 1;
    }

    if (current.major != major) {
        return current.major > major;
    }
    if (current.minor != minor) {
        return current.minor > minor;
    }
    return current.patch >= patch;
}