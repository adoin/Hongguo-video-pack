package dev.hongguo.hongguo_studio.protocol

import org.junit.Assert.*
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URI

class SignerTest {
    private val body = """{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["7671977925326949400"]}}""".toByteArray()
    @Test fun signatureContract() {
        val request = Signer().sign("https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/", VendorConstants.device, body)
        assertEquals(52, request.headers.getValue("x-gorgon").length)
        assertTrue(request.headers.getValue("x-medusa").length > 500)
        assertEquals(body.toList(), request.body!!.toList())
        assertTrue(request.url.contains("version_code=73532"))
    }
    @Test fun liveNativeSigner() {
        if (System.getenv("HONGGUO_LIVE_TEST") != "1") return
        val request = Signer().sign("https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/", VendorConstants.device, body)
        val connection = URI(request.url).toURL().openConnection() as HttpURLConnection
        connection.requestMethod = "POST"; connection.connectTimeout = 20000; connection.readTimeout = 30000
        for ((key,value) in request.headers) connection.setRequestProperty(key,value)
        connection.doOutput = true; connection.outputStream.use { it.write(body) }
        val status = connection.responseCode
        val text = (if(status==200) connection.inputStream else connection.errorStream).bufferedReader().use { it.readText() }
        connection.disconnect()
        assertEquals("Native signer HTTP status",200,status)
        assertTrue("Native signer did not return requested episode (response length ${text.length})", text.contains("7671977925326949400"))
        assertTrue("Native signer returned a business error",Regex("\"(?:Code|code)\"\\s*:\\s*0").containsMatchIn(text))
    }
    @Test fun playbackPreservesRegisteredVisitor() {
        val identity = VendorConstants.device + mapOf("device_id" to "1000000000000001", "iid" to "2000000000000001")
        val signed = Signer().sign("https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/", identity, body, preserveIdentity = true)
        assertTrue(URI(signed.url).rawQuery.contains("device_id=1000000000000001"))
        assertTrue(URI(signed.url).rawQuery.contains("iid=2000000000000001"))
        assertEquals(52, signed.headers.getValue("x-gorgon").length)
    }
    @Test fun searchPreservesInstanceIdentityAndEncodesCursor() {
        val identity = mapOf("device_id" to "1000000000000001", "iid" to "1000000000000002")
        val request = Signer().signSearch(mapOf("query" to "重生", "tab_type" to "11", "count" to "0", "offset" to "6", "search_id" to "test-session", "passback" to "5"), identity)
        val uri = URI(request.url)
        assertEquals("api5-normal-sinfonlinec.fqnovel.com", uri.host)
        assertEquals("/reading/bookapi/search/tab/v", uri.path)
        assertTrue(uri.rawQuery.contains("query=%E9%87%8D%E7%94%9F"))
        assertTrue(uri.rawQuery.contains("device_id=1000000000000001"))
        assertTrue(uri.rawQuery.contains("iid=1000000000000002"))
        assertTrue(uri.rawQuery.contains("offset=6"))
        assertTrue(uri.rawQuery.contains("search_id=test-session"))
        assertNull(request.body)
        assertEquals(52, request.headers.getValue("x-gorgon").length)
    }
    @Test fun liveRegisteredSearch() {
        val identityFile = System.getenv("HONGGUO_SEARCH_IDENTITY_FILE") ?: return
        val properties = java.util.Properties().apply { java.io.File(identityFile).inputStream().use { load(it) } }
        val identity = mapOf("device_id" to properties.getProperty("device_id"), "iid" to properties.getProperty("iid"))
        val request = Signer().signSearch(mapOf("query" to "重生", "tab_type" to "11", "count" to "0", "offset" to "0", "bookshelf_search_plan" to "4", "user_is_login" to "0"), identity)
        val connection = URI(request.url).toURL().openConnection() as HttpURLConnection
        connection.connectTimeout = 20000; connection.readTimeout = 30000
        request.headers.forEach { (k,v) -> connection.setRequestProperty(k,v) }
        val status = connection.responseCode
        val response = (if (status == 200) connection.inputStream else connection.errorStream).use { it.readBytes().toString(Charsets.UTF_8) }
        connection.disconnect()
        assertEquals(200, status)
        assertTrue("Search has no structured result", response.contains("\"search_tabs\"") && response.contains("\"video_data\""))
        assertTrue("Search business error", Regex("\"code\"\\s*:\\s*0").containsMatchIn(response))
    }
}
