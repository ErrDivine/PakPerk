package app.pakperk.pakperk

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.os.Handler
import android.os.Looper
import java.io.ByteArrayOutputStream
import java.io.ByteArrayInputStream
import java.io.File
import java.util.concurrent.Executors
import android.content.Context
import android.view.View
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.common.BinaryMessenger

class MainActivity : FlutterActivity() {
    private val pdfExecutor = Executors.newSingleThreadExecutor()

    override fun onDestroy() {
        pdfExecutor.shutdown()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory("app.pakperk/figure", FigureViewFactory(flutterEngine.dartExecutor.binaryMessenger))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.pakperk/original_pdf")
            .setMethodCallHandler { call, result ->
                if (call.method != "pageCount" && call.method != "render") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                pdfExecutor.execute {
                    try {
                        val file = File(call.argument<String>("path") ?: "").canonicalFile
                        require(file.path.startsWith(cacheDir.canonicalPath + File.separator))
                        require(file.length() in 1..(64L * 1024 * 1024))
                        val output: Any = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                            PdfRenderer(descriptor).use { renderer ->
                                if (call.method == "pageCount") {
                                    renderer.pageCount
                                } else {
                                    val index = call.argument<Int>("page") ?: 0
                                    require(index in 0 until renderer.pageCount)
                                    renderer.openPage(index).use { page ->
                                        val width = (call.argument<Int>("width") ?: 1800).coerceIn(400, 2000)
                                        val height = (width.toDouble() * page.height / page.width).toInt()
                                        require(height in 1..6000)
                                        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                                        try {
                                            bitmap.eraseColor(Color.WHITE)
                                            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                            ByteArrayOutputStream().use { bytes ->
                                                bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes)
                                                bytes.toByteArray()
                                            }
                                        } finally { bitmap.recycle() }
                                    }
                                }
                            }
                        }
                        Handler(Looper.getMainLooper()).post { result.success(output) }
                    } catch (_: Exception) {
                        Handler(Looper.getMainLooper()).post { result.error("PDF_RENDER_FAILED", "Could not render original PDF", null) }
                    }
                }
            }
    }
}

// Render arXiv's vector figures with foreignObject/MathML intact. This is a
// script-free, non-navigating surface; it has no JavaScript bridge or file access.
private class FigureViewFactory(private val messenger: BinaryMessenger) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val parameters = args as? Map<*, *> ?: emptyMap<Any, Any>()
        val content = parameters["html"] as? String ?: ""
        require(content.length <= 8 * 1024 * 1024)
        val webView = WebView(context)
        webView.settings.apply {
            javaScriptEnabled = false
            allowFileAccess = false
            allowContentAccess = false
            builtInZoomControls = parameters["zoom"] == true
            displayZoomControls = false
            useWideViewPort = true
            setSupportZoom(true)
        }
        webView.setBackgroundColor(Color.WHITE)
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = true
            override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                if (request?.url?.scheme == "https" && request.url.host == "arxiv.org") return null
                return WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(ByteArray(0)))
            }
        }
        val zoomChannel = MethodChannel(messenger, "app.pakperk/figure/$viewId")
        zoomChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "zoomIn" -> { webView.zoomBy(1.5f); result.success(null) }
                "zoomOut" -> { webView.zoomBy(1f / 1.5f); result.success(null) }
                else -> result.notImplemented()
            }
        }
        val centering = if (parameters["zoom"] == true) "html,body{height:100%}body{display:flex;align-items:center;justify-content:center}" else ""
        webView.loadDataWithBaseURL("https://arxiv.org/", """<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,minimum-scale=1,maximum-scale=8,user-scalable=yes"><style>body{margin:0;background:white}svg,img{width:100%;height:auto;display:block}svg{overflow:visible}$centering</style></head><body>$content</body></html>""", "text/html", "UTF-8", null)
        return object : PlatformView {
            override fun getView(): View = webView
            override fun dispose() { zoomChannel.setMethodCallHandler(null); webView.stopLoading(); webView.destroy() }
        }
    }
}
