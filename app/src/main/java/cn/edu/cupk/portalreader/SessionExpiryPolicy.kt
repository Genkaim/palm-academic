package cn.edu.cupk.portalreader

import android.content.Context

internal fun Context.requiresCaptchaReauthentication(): Boolean = runCatching {
    SchoolAdapterRepository.load(this).auth.let { auth ->
        !auth.webOnly && auth.captcha.required
    }
}.getOrDefault(false)

internal fun Context.supportsSilentPasswordReauthentication(): Boolean = runCatching {
    SchoolAdapterRepository.load(this).auth.let { auth ->
        // Script login must be replayed by LoginScriptRuntime. AuthRepository still implements
        // only the legacy salted/engine handshakes, so routing a script school through it can
        // submit the wrong protocol and falsely report a background recovery.
        !auth.webOnly && !auth.usesScript && !auth.captcha.required &&
            PasswordCredentialStore.load(this) != null
    }
}.getOrDefault(false)

internal fun Context.markCaptchaReauthenticationRequired() {
    PortalNotificationPreferences.preferences(this).edit()
        .putBoolean(PortalPollWorker.KEY_CAPTCHA_REAUTH_REQUIRED, true)
        .apply()
}
