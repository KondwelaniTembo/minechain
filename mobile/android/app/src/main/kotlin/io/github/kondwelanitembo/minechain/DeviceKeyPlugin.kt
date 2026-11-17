package io.github.kondwelanitembo.minechain

// The device signing key, kept in the Android Keystore (decision Mobile (4);
// plan docs/plans/miner-registration-plan.md, M1).
//
// The Dart side reaches this class through one method channel,
// "minechain/device_key", with exactly three methods:
//
//   publicKey(alias)       -> the 91-byte SPKI DER public key, or null
//   createKey(alias)       -> makes a new P-256 key and returns its public key
//   sign(alias, bytes)     -> a DER ECDSA signature over the bytes
//
// What is deliberately NOT here: no method returns, exports or deletes a
// private key. The private key is created inside the Keystore and Android
// never hands its bytes to the app, so there is nothing to export; leaving
// out delete means a bug in the app cannot throw away the key that every
// unsynced step depends on. Replacing a key is an administrator's job
// (suspend, reset key, reactivate), not the app's.
//
// Errors go back as fixed codes only. An exception's own text can contain
// details of the device or the key, so it is never sent to Dart and never
// logged. Nothing in this file writes to the log.

import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

class DeviceKeyPlugin(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "minechain/device_key"

        // The fixed error codes. The Dart side (device_key_channel.dart)
        // knows exactly these four.
        const val BAD_ARGUMENT = "BAD_ARGUMENT"
        const val KEY_NOT_FOUND = "KEY_NOT_FOUND"
        const val KEY_EXISTS = "KEY_EXISTS"
        const val KEYSTORE_ERROR = "KEYSTORE_ERROR"

        private const val KEYSTORE = "AndroidKeyStore"

        // One key per user (decision Mobile (17)): the alias carries the
        // user id, so two people sharing a phone each have their own key.
        // Checked here, not only in Dart, so this class can never be asked
        // to touch any other Keystore entry.
        private val ALIAS = Regex(
            "^minechain_signing_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        )

        // The server takes payloads of at most 512 characters (api.md,
        // POST /sync/steps), and the payload is ASCII, so one byte each.
        // Anything larger is not a MineChain step.
        private const val MAX_SIGN_BYTES = 512

        // A P-256 public key in SPKI DER form is always 91 bytes
        // (signing-spec.md, section 2).
        private const val SPKI_P256_BYTES = 91
    }

    private val channel = MethodChannel(messenger, CHANNEL)

    // Keystore calls can take tens or hundreds of milliseconds (key
    // generation is the slowest), and Flutter calls this handler on the
    // main (UI) thread. Doing the work there would freeze the screen, so it
    // runs on this background thread instead.
    //
    // ONE thread, on purpose: calls run one after another, so a
    // "does this alias exist? then create it" check can never be split by
    // a second createKey for the same alias.
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()

    // Replies go back on the main thread, which is where Flutter's
    // MethodChannel.Result expects them.
    private val mainThread = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    /** Called when the Flutter engine goes away (MainActivity). */
    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf("publicKey", "createKey", "sign")) {
            // Dart sees a MissingPluginException.
            result.notImplemented()
            return
        }
        val work = workFor(call)
        if (work == null) {
            result.error(BAD_ARGUMENT, null, null)
            return
        }

        try {
            worker.execute {
                val outcome: Outcome = try {
                    Outcome.Success(work())
                } catch (e: KeyError) {
                    Outcome.Failure(e.code)
                } catch (e: Exception) {
                    // Any Keystore or provider failure. The exception is
                    // dropped on purpose: see the note at the top.
                    Outcome.Failure(KEYSTORE_ERROR)
                }
                mainThread.post { reply(result, outcome) }
            }
        } catch (e: RejectedExecutionException) {
            // The engine is shutting down and the worker has stopped.
            result.error(KEYSTORE_ERROR, null, null)
        }
    }

    /**
     * Checks the arguments on the main thread (cheap), and returns the work
     * to run on the worker thread, or null when an argument is wrong.
     */
    private fun workFor(call: MethodCall): (() -> Any?)? {
        // The arguments arrive as a map; anything else is a caller's mistake.
        val args = call.arguments as? Map<*, *> ?: return null
        val alias = args["alias"] as? String ?: return null
        if (!ALIAS.matches(alias)) return null

        when (call.method) {
            "publicKey" -> {
                val work: () -> Any? = { readPublicKey(alias) }
                return work
            }
            "createKey" -> {
                val work: () -> Any? = { createKey(alias) }
                return work
            }
            "sign" -> {
                val bytes = args["bytes"] as? ByteArray ?: return null
                if (bytes.isEmpty() || bytes.size > MAX_SIGN_BYTES) return null
                val work: () -> Any? = { sign(alias, bytes) }
                return work
            }
            else -> return null
        }
    }

    // --- The three operations, run on the worker thread -------------------

    private fun keyStore(): KeyStore =
        KeyStore.getInstance(KEYSTORE).apply { load(null) }

    /** The public key for [alias], or null when there is no such key. */
    private fun readPublicKey(alias: String): ByteArray? {
        val certificate = keyStore().getCertificate(alias) ?: return null
        return checkedSpki(certificate.publicKey.encoded)
    }

    private fun createKey(alias: String): ByteArray {
        val store = keyStore()
        // Never overwrite: generating a key under an existing alias would
        // silently replace it, and every step signed with the old key would
        // stop matching the key registered on the server.
        if (store.containsAlias(alias)) throw KeyError(KEY_EXISTS)

        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            // P-256, the only curve the server accepts (signing-spec.md, 2).
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            // No PIN or fingerprint before each signature. Asking at every
            // registration would break the three-tap target (NFR-06), and a
            // miner at a mine site may be wearing gloves or have wet hands.
            // KNOWN LIMIT: anyone holding the unlocked phone can sign as its
            // owner (decision Mobile (11)). Requiring a device screen lock
            // before the key is made is listed as a future improvement.
            // (false is also Android's default; it is written out so the
            // choice is visible.)
            .setUserAuthenticationRequired(false)
            .build()

        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
        generator.initialize(spec)
        // The private half stays inside the Keystore; only the public half
        // comes back to the app.
        return checkedSpki(generator.generateKeyPair().public.encoded)
    }

    private fun sign(alias: String, bytes: ByteArray): ByteArray {
        // This is a handle to the key inside the Keystore, not its bytes.
        val key = keyStore().getKey(alias, null) as? PrivateKey ?: throw KeyError(KEY_NOT_FOUND)
        // SHA256withECDSA hashes the bytes itself, so the payload is passed
        // as it is, never hashed first (signing-spec.md, section 5). The
        // result is DER, which is what the server expects.
        return Signature.getInstance("SHA256withECDSA").run {
            initSign(key)
            update(bytes)
            sign()
        }
    }

    /** Refuses anything that is not a 91-byte key, rather than pass it on. */
    private fun checkedSpki(encoded: ByteArray?): ByteArray {
        if (encoded == null || encoded.size != SPKI_P256_BYTES) throw KeyError(KEYSTORE_ERROR)
        return encoded
    }

    // --- Replies ---------------------------------------------------------

    private fun reply(result: MethodChannel.Result, outcome: Outcome) {
        when (outcome) {
            is Outcome.Success -> result.success(outcome.value)
            // The message and details are always null: the code says it all.
            is Outcome.Failure -> result.error(outcome.code, null, null)
        }
    }

    private sealed class Outcome {
        class Success(val value: Any?) : Outcome()
        class Failure(val code: String) : Outcome()
    }

    /** A refusal with one of the fixed codes. */
    private class KeyError(val code: String) : Exception()
}
