package com.crownparkcomputing.retrodos

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.zip.ZipInputStream
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * RetroMedia client (https://media.crownparkcomputing.com).
 *
 * Networking lives here rather than in the C++ frontend for one blunt reason:
 * TLS. The Android core links no HTTP stack, and adding one (curl + a CA
 * bundle) to ship a handful of REST calls is a poor trade when the platform
 * already has HttpURLConnection with the system trust store.
 *
 * Everything is asynchronous. The frontend runs a 60fps ImGui loop, so no call
 * here may block it: each operation is queued onto a single background thread
 * and its outcome is posted to [results], which native code drains once a frame
 * via [poll]. A single worker (not a pool) keeps ordering predictable -- a
 * login followed by a catalogue fetch must not race.
 *
 * The wire format back to C++ is tab/newline delimited rather than JSON, to
 * avoid dragging a JSON parser into the native side. Game titles do not contain
 * tabs or newlines; every field that could is sanitised on the way out.
 *
 * SECURITY: no credential is compiled in. The Firebase web key is fetched from
 * /api/auth/config at sign-in time -- the same way the website gets it -- so a
 * key rotation does not brick already-shipped binaries. The password is never
 * persisted; only the resulting session is, encrypted with a hardware-backed
 * Keystore key.
 */
object MediaBridge {

    private const val TAG      = "retrodos"
    private const val BASE     = "https://media.crownparkcomputing.com"
    private const val SYSTEM   = "dos"
    private const val UA       = "Retro-DOS/1.0 RetroMedia client"
    private const val PREFS    = "retrodos_media"
    private const val K_SESSION = "session"
    private const val K_APIKEY  = "apikey"
    private const val K_EMAIL   = "email"
    private const val KEY_ALIAS = "com.crownparkcomputing.retrodos.media.session"

    private const val JSON_CAP = 8 shl 20      /* 8 MiB  */
    private const val ART_CAP  = 32 shl 20     /* 32 MiB */

    @Volatile @JvmStatic var activity: MainActivity? = null
    private fun ctx(): Context? = activity?.applicationContext

    private val worker  = Executors.newSingleThreadExecutor { r ->
        Thread(r, "retromedia").apply { isDaemon = true }
    }
    private val results = ConcurrentLinkedQueue<String>()

    /* ---------------------------------------------------------------- */
    /* Native entry points                                               */
    /* ---------------------------------------------------------------- */

    /** Drain one completed operation, or "" when nothing is ready. Native
     *  code calls this once per frame; it never blocks. */
    @JvmStatic
    fun poll(): String = results.poll() ?: ""

    /* A DOS game here is routinely hundreds of megabytes -- Harvester is 1.2 GB
     * -- so a download is minutes of apparent silence. Progress is published
     * separately from [results] because it is sampled, not queued: the UI wants
     * the latest value each frame, not every value ever set. */
    @Volatile private var progressText = ""

    @JvmStatic
    fun progress(): String = progressText

    @JvmStatic fun beginStatus()  = submit("STATUS")  { doStatus() }
    @JvmStatic fun beginLogout()  = submit("LOGOUT")  { doLogout() }

    @JvmStatic
    fun beginLogin(email: String, password: String) = submit("LOGIN") {
        doLogin(email, password)
    }

    /** Sign in with a `rmk_...` API key issued by the website. Preferable on a
     *  shared handheld: it is revocable server-side and carries no password. */
    @JvmStatic
    fun beginLoginKey(apiKey: String) = submit("LOGIN") { doLoginKey(apiKey) }

    @JvmStatic
    fun beginCatalogue(search: String, letter: String, romsOnly: Boolean) =
        submit("CATALOGUE") { doCatalogue(search, letter, romsOnly) }

    @JvmStatic
    fun beginArtwork(slug: String, preview: String) =
        submit("ARTWORK") { doArtwork(slug, preview) }

    @JvmStatic
    fun beginDownload(slug: String, destDir: String) =
        submit("DOWNLOAD") { doDownload(slug, destDir) }

    /* ---------------------------------------------------------------- */
    /* Plumbing                                                          */
    /* ---------------------------------------------------------------- */

    /** Run [body] off the UI/render thread and post exactly one result, even
     *  when it throws -- a swallowed exception would leave the frontend
     *  spinning on a request that never completes. */
    private fun submit(op: String, body: () -> String) {
        worker.execute {
            val out = try {
                body()
            } catch (e: Exception) {
                Log.w(TAG, "$op failed: $e")
                fail(op, e.message ?: e.javaClass.simpleName)
            }
            results.add(out)
        }
    }

    private fun clean(s: String?) = (s ?: "").replace('\t', ' ').replace('\n', ' ')
    private fun ok(op: String, msg: String = "", payload: String = "") =
        "$op\tOK\t${clean(msg)}\n$payload"
    private fun fail(op: String, msg: String) = "$op\tERR\t${clean(msg)}\n"

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

    private fun prefs() = ctx()!!.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /* ---------------------------------------------------------------- */
    /* Session at rest                                                   */
    /* ---------------------------------------------------------------- */

    /* The session cookie is a bearer credential for a paid account, so it is
     * encrypted with a Keystore key rather than left in cleartext prefs where
     * any backup or rooted read would pick it up. */
    private fun secretKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        kg.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
             .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
             .build()
        )
        return kg.generateKey()
    }

    private fun encrypt(plain: String): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, secretKey()) }
        val ct = c.doFinal(plain.toByteArray())
        return Base64.encodeToString(c.iv, Base64.NO_WRAP) + "." +
               Base64.encodeToString(ct, Base64.NO_WRAP)
    }

    private fun decrypt(blob: String): String? = try {
        val parts = blob.split(".")
        if (parts.size != 2) null else {
            val iv = Base64.decode(parts[0], Base64.NO_WRAP)
            val ct = Base64.decode(parts[1], Base64.NO_WRAP)
            val c = Cipher.getInstance("AES/GCM/NoPadding")
                .apply { init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv)) }
            String(c.doFinal(ct))
        }
    } catch (e: Exception) {
        /* A Keystore key is invalidated by events outside our control (restore
         * to a new device, lock-screen removal). Treat that as signed-out
         * rather than as a hard error. */
        Log.w(TAG, "stored session unreadable: $e"); null
    }

    private fun storedSession(): String? = prefs().getString(K_SESSION, null)?.let { decrypt(it) }
    private fun storedApiKey(): String?  = prefs().getString(K_APIKEY,  null)?.let { decrypt(it) }

    private fun clearSession() =
        prefs().edit().remove(K_SESSION).remove(K_APIKEY).apply()

    /* ---------------------------------------------------------------- */
    /* HTTP                                                              */
    /* ---------------------------------------------------------------- */

    private class Resp(val code: Int, val body: ByteArray, val headers: Map<String, List<String>>) {
        fun text() = String(body)
        fun json() = try { JSONObject(text()) } catch (e: Exception) { JSONObject() }
        /** The server reports failures as {"error": "..."}; surface that rather
         *  than a bare status code, which tells the user nothing. */
        fun error(): String = json().optString("error").ifEmpty { "HTTP $code" }
    }

    private fun http(
        path: String,
        method: String = "GET",
        body: ByteArray? = null,
        contentType: String? = null,
        auth: Boolean = true,
        accept: String = "application/json, image/*, application/zip",
        cap: Int = JSON_CAP,
        readTimeout: Int = 60_000,
        absolute: Boolean = false
    ): Resp {
        val url = URL(if (absolute) path else BASE + path)
        val c = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 15_000
            this.readTimeout = readTimeout
            setRequestProperty("User-Agent", UA)
            setRequestProperty("Accept", accept)
            contentType?.let { setRequestProperty("Content-Type", it) }
            if (auth) {
                /* An API key wins when present: it survives session expiry, so
                 * a keyed device never has to re-authenticate. */
                val key = storedApiKey()
                if (key != null) setRequestProperty("Authorization", "Bearer $key")
                else storedSession()?.let { setRequestProperty("Cookie", it) }
            }
            if (body != null) { doOutput = true; outputStream.use { it.write(body) } }
        }
        val code = c.responseCode
        val stream: InputStream? = if (code in 200..299) c.inputStream else c.errorStream
        val bytes = stream?.use { readCapped(it, cap) } ?: ByteArray(0)
        val headers = c.headerFields ?: emptyMap()
        c.disconnect()
        return Resp(code, bytes, headers)
    }

    /**
     * Open a connection and hand back the live stream instead of a byte array.
     *
     * Required for game downloads: buffering the response first would mean
     * holding the whole title in RAM, and these are routinely 300 MB to 1.2 GB.
     * No handheld survives that, so the body is consumed straight to disk.
     */
    private fun httpOpen(path: String, accept: String, readTimeout: Int): HttpURLConnection {
        val c = (URL(BASE + path).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15_000
            this.readTimeout = readTimeout
            setRequestProperty("User-Agent", UA)
            setRequestProperty("Accept", accept)
            val key = storedApiKey()
            if (key != null) setRequestProperty("Authorization", "Bearer $key")
            else storedSession()?.let { setRequestProperty("Cookie", it) }
        }
        return c
    }

    /** Read at most [cap] bytes. An unbounded read of a hostile or simply huge
     *  response is an OOM on a handheld. */
    private fun readCapped(input: InputStream, cap: Int): ByteArray {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(64 * 1024)
        var total = 0
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            total += n
            if (total > cap) throw IllegalStateException("response too large")
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    /* ---------------------------------------------------------------- */
    /* Auth                                                              */
    /* ---------------------------------------------------------------- */

    private fun accountLine(acct: JSONObject) =
        "${clean(acct.optString("email"))}\t${if (acct.optBoolean("isAdmin")) 1 else 0}\t" +
        "${acct.optInt("credits")}\t${acct.optInt("freeRemainingToday")}\n"

    private fun doStatus(): String {
        if (storedSession() == null && storedApiKey() == null)
            return ok("STATUS", "signed out")
        val r = http("/api/me")
        if (r.code == 401 || r.code == 403) {
            /* Expired or revoked: drop it, or every later call fails the same
             * way and the UI shows a permanently broken account. */
            clearSession()
            return fail("STATUS", "session expired -- please sign in again")
        }
        if (r.code != 200) return fail("STATUS", r.error())
        return ok("STATUS", "", accountLine(r.json().optJSONObject("account") ?: JSONObject()))
    }

    private fun doLogin(email: String, password: String): String {
        val cfg = http("/api/auth/config", auth = false)
        if (cfg.code != 200) return fail("LOGIN", "cannot reach RetroMedia (${cfg.code})")
        val fb = cfg.json().optJSONObject("firebase") ?: JSONObject()

        val cookie: String
        if (fb.optBoolean("enabled")) {
            val apiKey = fb.optString("apiKey")
            if (apiKey.isEmpty()) return fail("LOGIN", "server did not supply a Firebase key")

            val payload = JSONObject()
                .put("email", email).put("password", password)
                .put("returnSecureToken", true).toString().toByteArray()
            val fr = http(
                "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${enc(apiKey)}",
                method = "POST", body = payload,
                contentType = "application/json; charset=utf-8",
                auth = false, absolute = true
            )
            if (fr.code != 200) {
                val m = fr.json().optJSONObject("error")?.optString("message") ?: "HTTP ${fr.code}"
                return fail("LOGIN", when (m) {
                    "INVALID_LOGIN_CREDENTIALS", "INVALID_PASSWORD" -> "Wrong email or password"
                    "EMAIL_NOT_FOUND" -> "No account for that email"
                    /* The account may exist but only as a Google sign-in, in
                     * which case there is no password to check against. */
                    else -> m
                })
            }
            val idToken = fr.json().optString("idToken")
            if (idToken.isEmpty()) return fail("LOGIN", "no token returned")

            val ex = http(
                "/api/auth/firebase", method = "POST",
                body = JSONObject().put("id_token", idToken).toString().toByteArray(),
                contentType = "application/json; charset=utf-8", auth = false
            )
            if (ex.code != 200) return fail("LOGIN", ex.error())
            cookie = sessionCookie(ex) ?: return fail("LOGIN", "server returned no session")
        } else {
            val lr = http(
                "/api/auth/login", method = "POST",
                body = JSONObject().put("email", email).put("password", password)
                    .toString().toByteArray(),
                contentType = "application/json; charset=utf-8", auth = false
            )
            if (lr.code != 200) return fail("LOGIN", lr.error())
            cookie = sessionCookie(lr) ?: return fail("LOGIN", "server returned no session")
        }

        prefs().edit()
            .putString(K_SESSION, encrypt(cookie))
            .remove(K_APIKEY)
            .putString(K_EMAIL, email)
            .apply()
        return doStatus().replaceFirst("STATUS", "LOGIN")
    }

    private fun doLoginKey(apiKey: String): String {
        val key = apiKey.trim()
        if (!key.startsWith("rmk_")) return fail("LOGIN", "an API key starts with rmk_")
        /* Store first, because /api/me is what validates it -- then roll back
         * if the server rejects it, so a bad key is never left behind. */
        prefs().edit().putString(K_APIKEY, encrypt(key)).remove(K_SESSION).apply()
        val r = http("/api/me")
        if (r.code != 200) {
            clearSession()
            return fail("LOGIN", if (r.code == 401) "that API key was rejected" else r.error())
        }
        val acct = r.json().optJSONObject("account") ?: JSONObject()
        prefs().edit().putString(K_EMAIL, acct.optString("email")).apply()
        return ok("LOGIN", "", accountLine(acct))
    }

    private fun sessionCookie(r: Resp): String? {
        for ((k, v) in r.headers) {
            if (!k.equals("Set-Cookie", true)) continue
            for (line in v) {
                /* Keep only name=value: the attributes (Path, HttpOnly, Max-Age)
                 * are instructions to a browser and are rejected if echoed back
                 * on a request. */
                val pair = line.split(";").firstOrNull { it.trim().startsWith("rm_session=") }
                if (pair != null) return pair.trim()
            }
        }
        return null
    }

    private fun doLogout(): String {
        try { http("/api/auth/logout", method = "POST") } catch (e: Exception) {
            /* Best effort: the local session must go regardless of whether the
             * server could be told. */
            Log.w(TAG, "logout call failed: $e")
        }
        clearSession()
        return ok("LOGOUT", "signed out")
    }

    /* ---------------------------------------------------------------- */
    /* Catalogue                                                         */
    /* ---------------------------------------------------------------- */

    /**
     * One page-walked catalogue fetch.
     *
     * [romsOnly] asks the server for downloadable games; it returns nothing
     * useful unless the account is an admin, because rom media is stripped from
     * every response for everyone else.
     */
    private fun doCatalogue(search: String, letter: String, romsOnly: Boolean): String {
        val sb = StringBuilder()
        var page = 1
        var total = Int.MAX_VALUE
        var seen = 0
        val limit = 200

        while (page <= 20 && seen < total) {
            val q = StringBuilder("/api/systems/$SYSTEM/games?limit=$limit&page=$page")
            if (search.isNotBlank()) q.append("&search=").append(enc(search.trim()))
            if (letter.isNotBlank())  q.append("&letter=").append(enc(letter))
            if (romsOnly)             q.append("&category=rom")

            val r = http(q.toString())
            if (r.code != 200) return fail("CATALOGUE", r.error())
            val j = r.json()
            total = j.optInt("total", 0)
            val games = j.optJSONArray("games") ?: break
            if (games.length() == 0) break

            for (i in 0 until games.length()) {
                val g = games.optJSONObject(i) ?: continue
                val avail = g.optJSONObject("availability")
                sb.append(clean(g.optString("slug"))).append('\t')
                  .append(clean(g.optString("title").ifEmpty { g.optString("name") })).append('\t')
                  .append(avail?.optInt("romFiles") ?: 0).append('\t')
                  .append(g.optLong("totalBytes")).append('\t')
                  .append(clean(g.optString("preview"))).append('\n')
            }
            seen += games.length()
            page++
        }
        return ok("CATALOGUE", "$seen of $total", sb.toString())
    }

    /* ---------------------------------------------------------------- */
    /* Artwork                                                           */
    /* ---------------------------------------------------------------- */

    /**
     * Fetch one game's card art.
     *
     * This uses the per-file media route with `?size=480`, which is FREE and
     * unmetered, rather than the `/zip?types=` route that costs a credit per
     * game. For a launcher that wants art for hundreds of titles that is the
     * difference between usable and unaffordable.
     *
     * The bitmap is decoded here and cached as raw RGBA, because the native
     * side has no image decoder -- only SDL_Renderer, which takes pixels.
     */
    private fun doArtwork(slug: String, preview: String): String {
        if (preview.isBlank()) return fail("ARTWORK", "no artwork for $slug")
        val c = ctx() ?: return fail("ARTWORK", "no context")

        val dir = File(c.filesDir, "media-art").apply { mkdirs() }
        val cache = File(dir, sha256(slug) + ".rda")
        if (cache.exists()) {
            readHeader(cache)?.let { (w, h) ->
                return ok("ARTWORK", "", "${clean(slug)}\t${cache.absolutePath}\t$w\t$h\n")
            }
        }

        /* The path is relative to the media root and contains spaces and
         * parentheses, so each segment is encoded separately -- encoding the
         * whole thing would escape the slashes too. */
        val encPath = preview.split("/").joinToString("/") { enc(it) }
        val r = http("/api/systems/$SYSTEM/games/${enc(slug)}/media/$encPath?size=480",
                     cap = ART_CAP)
        if (r.code != 200) return fail("ARTWORK", r.error())

        val bmp = BitmapFactory.decodeByteArray(r.body, 0, r.body.size)
            ?: return fail("ARTWORK", "unreadable image for $slug")
        val scaled = fit(bmp, 360, 500)
        writeRgba(cache, scaled)
        val out = "${clean(slug)}\t${cache.absolutePath}\t${scaled.width}\t${scaled.height}\n"
        if (scaled != bmp) scaled.recycle()
        bmp.recycle()
        return ok("ARTWORK", "", out)
    }

    private fun fit(b: Bitmap, maxW: Int, maxH: Int): Bitmap {
        if (b.width <= maxW && b.height <= maxH) return b
        val s = minOf(maxW.toFloat() / b.width, maxH.toFloat() / b.height)
        return Bitmap.createScaledBitmap(b, (b.width * s).toInt().coerceAtLeast(1),
                                            (b.height * s).toInt().coerceAtLeast(1), true)
    }

    /* Cache format: "RDA1", big-endian u32 width, u32 height, then RGBA8 rows.
     * Deliberately trivial -- the native side reads it with fread and hands the
     * pixels straight to SDL_UpdateTexture. */
    private fun writeRgba(f: File, b: Bitmap) {
        val px = IntArray(b.width * b.height)
        b.getPixels(px, 0, b.width, 0, 0, b.width, b.height)
        val buf = ByteBuffer.allocate(12 + px.size * 4).order(ByteOrder.BIG_ENDIAN)
        buf.put("RDA1".toByteArray()).putInt(b.width).putInt(b.height)
        for (p in px) {
            /* getPixels yields ARGB; SDL wants the bytes in RGBA order. */
            buf.put(((p shr 16) and 0xFF).toByte())
               .put(((p shr 8) and 0xFF).toByte())
               .put((p and 0xFF).toByte())
               .put(((p ushr 24) and 0xFF).toByte())
        }
        f.writeBytes(buf.array())
    }

    private fun readHeader(f: File): Pair<Int, Int>? = try {
        f.inputStream().use { s ->
            val h = ByteArray(12)
            if (s.read(h) != 12 || String(h, 0, 4) != "RDA1") null
            else {
                val bb = ByteBuffer.wrap(h, 4, 8).order(ByteOrder.BIG_ENDIAN)
                val w = bb.int; val ht = bb.int
                if (w in 1..2048 && ht in 1..2048 && f.length() == 12L + w * ht * 4L)
                    Pair(w, ht) else null
            }
        }
    } catch (e: Exception) { null }

    private fun sha256(s: String): String =
        MessageDigest.getInstance("SHA-256").digest(s.toByteArray())
            .joinToString("") { "%02x".format(it) }

    /* ---------------------------------------------------------------- */
    /* Download (admin only)                                             */
    /* ---------------------------------------------------------------- */

    private val ROM_EXTS = setOf("zip", "exe", "com", "bat", "img", "ima", "iso",
                                 "cue", "bin", "7z", "rar", "gz")

    /**
     * Download a game into [destDir].
     *
     * The body is STREAMED to disk rather than buffered. These are not small
     * files -- the catalogue is full of 300 MB titles and Harvester is 1.2 GB
     * -- and holding one in memory first would fail on any handheld.
     *
     * The server sends a single rom unwrapped and multiple roms as a zip, so
     * the shape is decided by sniffing the PK magic off the front of the
     * stream rather than by trusting the file count: sniffed bytes cannot
     * disagree with what actually arrived.
     */
    private fun doDownload(slug: String, destDir: String): String {
        val me = http("/api/me")
        if (me.code != 200) return fail("DOWNLOAD", "sign in first")
        if (!(me.json().optJSONObject("account")?.optBoolean("isAdmin") ?: false))
            return fail("DOWNLOAD", "downloading games requires an administrator account")

        val d = http("/api/systems/$SYSTEM/games/${enc(slug)}")
        if (d.code != 200) return fail("DOWNLOAD", d.error())
        val detail = d.json()
        val roms = detail.optJSONArray("roms")
        if (roms == null || roms.length() == 0)
            return fail("DOWNLOAD", "no downloadable files for this game")

        val title = sanitise(detail.optString("title").ifEmpty { detail.optString("name") }
            .ifEmpty { slug })
        val out = File(destDir, title).apply { mkdirs() }

        val conn = httpOpen("/api/systems/$SYSTEM/games/${enc(slug)}/zip?types=rom",
                            "application/octet-stream, application/zip", 600_000)
        val code = conn.responseCode
        if (code != 200) {
            val err = try {
                JSONObject(String(conn.errorStream?.readBytes() ?: ByteArray(0)))
                    .optString("error").ifEmpty { "HTTP $code" }
            } catch (e: Exception) { "HTTP $code" }
            conn.disconnect()
            progressText = ""
            return fail("DOWNLOAD", if (code == 402) "out of credits: $err" else err)
        }

        val expected = roms.optJSONObject(0)?.optLong("size") ?: 0L
        val total = conn.contentLengthLong.let { if (it > 0) it else expected }
        var written = 0

        try {
            /* Buffered so the magic can be peeked and pushed back; the zip
             * reader below then starts from byte zero either way. */
            val input = java.io.BufferedInputStream(conn.inputStream, 64 * 1024)
            input.mark(4)
            val magic = ByteArray(4)
            val got = input.read(magic)
            input.reset()
            val isZip = got == 4 && magic[0] == 'P'.code.toByte() &&
                        magic[1] == 'K'.code.toByte() &&
                        magic[2] == 3.toByte() && magic[3] == 4.toByte()

            if (isZip && roms.length() > 1) {
                ZipInputStream(input).use { zin ->
                    while (true) {
                        val e = zin.nextEntry ?: break
                        if (!e.isDirectory) {
                            val name = sanitise(File(e.name).name)
                            if (name.isNotEmpty()) {
                                File(out, name).outputStream().use { o ->
                                    copyWithProgress(zin, o, title, 0L)
                                }
                                written++
                            }
                        }
                        zin.closeEntry()
                    }
                }
            } else {
                /* A single rom comes back as the file itself. Its name comes
                 * from the catalogue entry, since the body carries none. */
                val first = roms.optJSONObject(0)?.optString("file") ?: "$slug.zip"
                val name = sanitise(File(first).name).ifEmpty { "$slug.zip" }
                File(out, name).outputStream().use { o ->
                    copyWithProgress(input, o, title, total)
                }
                written = 1
            }
        } catch (e: Exception) {
            /* Leave nothing behind. The destination is inside the library root,
             * so an empty or half-written directory would be scanned and listed
             * as a game that cannot start. */
            cleanupFailed(out)
            throw e
        } finally {
            conn.disconnect()
            progressText = ""
        }

        if (written == 0) { cleanupFailed(out); return fail("DOWNLOAD", "nothing was written") }

        /* The catalogue ships games as archives, but the launcher starts a game
         * by finding a .BAT/.COM/.EXE in its folder and DOSBox-X mounts that
         * folder as a drive. A downloaded .zip left as-is therefore appears in
         * the library as a title with nothing to run. Unpack it here so a
         * downloaded game is immediately playable. */
        extractArchives(out)

        Log.i(TAG, "downloaded '$title' ($written file(s)) -> ${out.absolutePath}")
        return ok("DOWNLOAD", "$title: $written file(s)", "${out.absolutePath}\n")
    }

    /** Copy, publishing progress as it goes. [total] of 0 means unknown, in
     *  which case only the amount so far can be reported. */
    private fun copyWithProgress(input: InputStream, out: java.io.OutputStream,
                                 title: String, total: Long) {
        val buf = ByteArray(256 * 1024)
        var done = 0L
        var lastPost = 0L
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            out.write(buf, 0, n)
            done += n
            /* Publish at most every 4 MB: this runs in the inner copy loop and
             * formatting a string per 256 KB block would cost more than the I/O. */
            if (done - lastPost >= 4L shl 20) {
                lastPost = done
                val mb = done / (1024.0 * 1024.0)
                progressText = if (total > 0)
                    "%s  %.0f / %.0f MB  (%d%%)".format(
                        title, mb, total / (1024.0 * 1024.0), done * 100 / total)
                else
                    "%s  %.0f MB".format(title, mb)
            }
        }
        out.flush()
    }

    /**
     * Unpack every .zip sitting directly in [dir], then delete the archive.
     *
     * Only the top level, and not recursively: a game that legitimately ships
     * an archive as data should keep it.
     */
    private fun extractArchives(dir: File) {
        val zips = dir.listFiles()?.filter {
            it.isFile && it.name.endsWith(".zip", true)
        } ?: return

        for (z in zips) {
            progressText = "Extracting ${z.name}..."
            try {
                ZipInputStream(z.inputStream().buffered(64 * 1024)).use { zin ->
                    while (true) {
                        val e = zin.nextEntry ?: break
                        val target = File(dir, e.name)
                        /* Reject entries that escape the folder: a crafted
                         * archive with ../ paths would otherwise write anywhere
                         * the app can reach. */
                        if (!target.canonicalPath.startsWith(dir.canonicalPath + File.separator)) {
                            Log.w(TAG, "skipping suspicious entry ${e.name}")
                            zin.closeEntry(); continue
                        }
                        if (e.isDirectory) target.mkdirs()
                        else {
                            target.parentFile?.mkdirs()
                            target.outputStream().use { zin.copyTo(it, 64 * 1024) }
                        }
                        zin.closeEntry()
                    }
                }
                z.delete()
                Log.i(TAG, "extracted ${z.name}")
            } catch (e: Exception) {
                /* Keep the archive on failure: a half-unpacked game plus a
                 * deleted source would leave nothing to retry from. */
                Log.w(TAG, "could not extract ${z.name}: $e")
            }
        }
        flattenSingleFolder(dir)
        progressText = ""
    }

    /**
     * Lift the contents of a lone wrapper directory up into [dir].
     *
     * Archives in this catalogue usually contain one top-level folder, so a
     * plain extraction leaves the game one level below the folder the emulator
     * mounts as C:. The launcher looks for a runnable in the mount directory
     * itself, so without this the title appears with nothing to run.
     *
     * Bounded rather than recursive: a couple of nested wrappers happen, an
     * unbounded walk into a game's own subdirectories does not.
     */
    private fun flattenSingleFolder(dir: File) {
        repeat(3) {
            val kids = dir.listFiles() ?: return
            if (kids.size != 1 || !kids[0].isDirectory) return
            val inner = kids[0]
            val moved = inner.listFiles() ?: return
            for (f in moved) {
                if (!f.renameTo(File(dir, f.name))) {
                    Log.w(TAG, "could not flatten ${f.name}")
                    return
                }
            }
            inner.delete()
        }
    }

    /** Delete a failed download's directory, so a partial title never shows up
     *  in the library as a game that will not run. */
    private fun cleanupFailed(dir: File) {
        try {
            dir.listFiles()?.forEach { it.delete() }
            dir.delete()
        } catch (e: Exception) {
            Log.w(TAG, "could not clean up ${dir.absolutePath}: $e")
        }
    }

    /** Strip anything that is a path, a control character, or illegal on the
     *  FAT volumes these libraries usually live on. */
    private fun sanitise(s: String): String =
        s.replace(Regex("[\\p{Cntrl}/\\\\:*?\"<>|]"), "_").trim().trim('.')

    /* ---------------------------------------------------------------- */
    /* Misc                                                              */
    /* ---------------------------------------------------------------- */

    /** Remembered email, so the sign-in form is not blank every time. */
    @JvmStatic
    fun lastEmail(): String = try { prefs().getString(K_EMAIL, "") ?: "" }
                              catch (e: Exception) { "" }
}
