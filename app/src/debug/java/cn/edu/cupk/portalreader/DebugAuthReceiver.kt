package cn.edu.cupk.portalreader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Debug-only entry point that exercises the same password-login repository as the UI. */
class DebugAuthReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION_TEST_LOGIN) return
        val pendingResult = goAsync()
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        preferences.edit().clear().putString(KEY_STATUS, STATUS_RUNNING).commit()
        val username = intent.getStringExtra(EXTRA_USERNAME).orEmpty()
        val password = intent.getStringExtra(EXTRA_PASSWORD).orEmpty()

        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                val result = AuthRepository().login(username, password)
                preferences.edit()
                    .putString(KEY_STATUS, STATUS_FINISHED)
                    .putBoolean(KEY_SUCCESS, result.isSuccess)
                    .putString(KEY_MESSAGE, result.exceptionOrNull()?.message.orEmpty())
                    .commit()
            } finally {
                pendingResult.finish()
            }
        }
    }

    companion object {
        const val ACTION_TEST_LOGIN = "cn.edu.cupk.portalreader.DEBUG_TEST_LOGIN"
        const val EXTRA_USERNAME = "username"
        const val EXTRA_PASSWORD = "password"
        const val PREFS = "debug_auth_result"
        const val KEY_STATUS = "status"
        const val KEY_SUCCESS = "success"
        const val KEY_MESSAGE = "message"
        const val STATUS_RUNNING = "running"
        const val STATUS_FINISHED = "finished"
    }
}
