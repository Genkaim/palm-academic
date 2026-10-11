package cn.edu.cupk.portalreader

import android.content.Context

internal fun Context.requiresCaptchaReauthentication(): Boolean = runCatching {
    SchoolAdapterRepository.load(this).auth.let { auth ->
        !auth.webOnly && auth.captcha.required
    }
}.getOrDefault(false)

internal fun Context.supportsSilentPasswordReauthentication(): Boolean = runCatching {
    SchoolAdapterRepository.load(this).auth.let { auth ->
        // Script schools are replayed by ScriptSilentLogin; legacy schools keep using
        // AuthRepository. Both are silent until the server explicitly asks for interaction.
        !auth.webOnly && !auth.captcha.required &&
            PasswordCredentialStore.load(this) != null
    }
}.getOrDefault(false)

internal fun Context.markCaptchaReauthenticationRequired() {
    PortalNotificationPreferences.preferences(this).edit()
        .putBoolean(PortalPollWorker.KEY_CAPTCHA_REAUTH_REQUIRED, true)
        .apply()
}
