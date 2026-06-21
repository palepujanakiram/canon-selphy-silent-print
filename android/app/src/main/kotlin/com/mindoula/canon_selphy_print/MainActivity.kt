package com.mindoula.canon_selphy_print

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.Point
import android.graphics.Rect
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
// ── USB SDK ───────────────────────────────────────────────────────────────────
import jp.co.canon.android.print.selphy.usbsdk.CanonPermissionRequestCallback
import jp.co.canon.android.print.selphy.usbsdk.CanonPreparationCallback
import jp.co.canon.android.print.selphy.usbsdk.CanonPrintCallback as UsbPrintCallback
import jp.co.canon.android.print.selphy.usbsdk.CanonPrintDevice as UsbPrintDevice
import jp.co.canon.android.print.selphy.usbsdk.CanonPrintJob as UsbPrintJob
import jp.co.canon.android.print.selphy.usbsdk.CanonPrintSizeInfo as UsbPrintSizeInfo
import jp.co.canon.android.print.selphy.usbsdk.CanonPrinterAccessoryInfo as UsbAccessoryInfo
import jp.co.canon.android.print.selphy.usbsdk.CanonPrinterStatus as UsbPrinterStatus
import jp.co.canon.android.print.selphy.usbsdk.CanonUsbManager
// ── WiFi SDK ──────────────────────────────────────────────────────────────────
import jp.co.canon.android.print.selphy.wifisdk.CanonDiscoveryCallback
import jp.co.canon.android.print.selphy.wifisdk.CanonPrintCallback as WifiPrintCallback
import jp.co.canon.android.print.selphy.wifisdk.CanonPrintDevice as WifiPrintDevice
import jp.co.canon.android.print.selphy.wifisdk.CanonPrintJob as WifiPrintJob
import jp.co.canon.android.print.selphy.wifisdk.CanonPrinterStatus as WifiPrinterStatus
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {

    private val channelName = "com.mindoula.canon_selphy_print/usb"
    private val mainHandler = Handler(Looper.getMainLooper())

    // Cached devices so startPrint reuses the instance that was connected/permissioned.
    private var cachedUsbDevice: UsbPrintDevice? = null
    private var cachedWifiDevice: WifiPrintDevice? = null

    // Wi-Fi network binding (see bindToWifiNetwork).
    private var connectivityManager: ConnectivityManager? = null
    private var wifiNetworkCallback: ConnectivityManager.NetworkCallback? = null

    private val logTag = "SelphyWifi"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> requestUsbPermission(result)   // USB
                    "discoverWifi"      -> discoverWifiPrinter(result)     // WiFi
                    "print" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath == null) result.error("INVALID_ARG", "filePath is required", null)
                        else {
                            val transport  = call.argument<String>("transport") ?: "usb"
                            val copies     = call.argument<Int>("copies") ?: 1
                            val paperSize  = call.argument<String>("paperSize") ?: "4x6"
                            val filter     = call.argument<String>("filter") ?: "Off"
                            val brightness = call.argument<Int>("brightness") ?: 0
                            val bordered   = call.argument<Boolean>("bordered") ?: false
                            if (transport == "wifi") {
                                startWifiPrint(filePath, copies, paperSize, filter, brightness, bordered, result)
                            } else {
                                startUsbPrint(filePath, copies, paperSize, filter, brightness, bordered, result)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        // Release the Wi-Fi binding so the rest of the system isn't forced onto
        // the (internet-less) printer network after the app closes.
        try {
            connectivityManager?.bindProcessToNetwork(null)
            wifiNetworkCallback?.let { connectivityManager?.unregisterNetworkCallback(it) }
        } catch (e: Exception) {
            Log.w(logTag, "Wi-Fi cleanup failed: ${e.message}")
        }
        wifiNetworkCallback = null
        super.onDestroy()
    }

    // ── USB: permission request (called on screen open) ────────────────────────

    private fun requestUsbPermission(result: MethodChannel.Result) {
        val ctx = applicationContext

        fun findAndRequestPermission() {
            @Suppress("UNCHECKED_CAST")
            val printers = CanonUsbManager.getPrinterList(ctx) as? List<UsbPrintDevice> ?: emptyList()

            if (printers.isEmpty()) {
                mainHandler.post {
                    result.error("NO_PRINTER", "No Canon Selphy printer found via USB", null)
                }
                return
            }

            val device = printers[0]

            if (CanonUsbManager.hasPermission(ctx, device)) {
                cachedUsbDevice = device
                mainHandler.post { result.success("Printer ready: ${device.printerName}") }
                return
            }

            val requested = CanonUsbManager.requestPermission(
                ctx, device,
                object : CanonPermissionRequestCallback() {
                    override fun onReceivePermissionGranted(dev: UsbPrintDevice, granted: Boolean) {
                        mainHandler.post {
                            if (granted) {
                                cachedUsbDevice = dev
                                result.success("Printer ready: ${dev.printerName}")
                            } else {
                                result.error(
                                    "PERMISSION_DENIED",
                                    "USB permission denied. Tap refresh and try again.",
                                    null
                                )
                            }
                        }
                    }
                }
            )

            if (!requested) {
                mainHandler.post {
                    result.error(
                        "PERMISSION_REQUEST_FAILED",
                        "Could not request USB permission. Try reconnecting the printer.",
                        null
                    )
                }
            }
        }

        try {
            findAndRequestPermission()
        } catch (e: SecurityException) {
            CanonUsbManager.prepareToGetPrinterList(ctx, object : CanonPreparationCallback() {
                override fun onSuccess() = findAndRequestPermission()
                override fun onFailure() {
                    mainHandler.post {
                        result.error("PREPARE_FAILED", "Failed to access USB. Try reconnecting the printer.", null)
                    }
                }
            })
        }
    }

    // ── WiFi: network binding ───────────────────────────────────────────────────

    // The printer's Direct Connection AP has no internet, so Android keeps the
    // default network on cellular and routes the SDK's discovery/print sockets
    // there — never reaching the printer. Binding the process to the Wi-Fi
    // network forces all traffic over Wi-Fi. Invokes [onResult] once.
    private fun bindToWifiNetwork(onResult: (Boolean) -> Unit) {
        val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        connectivityManager = cm

        // Already bound to a Wi-Fi network? Reuse it.
        val bound = cm.boundNetworkForProcess
        if (bound != null) {
            val caps = cm.getNetworkCapabilities(bound)
            if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                Log.i(logTag, "Already bound to a Wi-Fi network")
                onResult(true)
                return
            }
        }

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()

        val resolved = AtomicBoolean(false)
        val timeout = Runnable {
            if (resolved.compareAndSet(false, true)) {
                Log.w(logTag, "Wi-Fi bind timed out")
                onResult(false)
            }
        }

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val ok = cm.bindProcessToNetwork(network)
                Log.i(logTag, "Bound process to Wi-Fi network=$network ok=$ok")
                if (resolved.compareAndSet(false, true)) {
                    mainHandler.removeCallbacks(timeout)
                    mainHandler.post { onResult(true) }
                }
            }

            override fun onUnavailable() {
                if (resolved.compareAndSet(false, true)) {
                    mainHandler.removeCallbacks(timeout)
                    mainHandler.post { onResult(false) }
                }
            }
        }
        wifiNetworkCallback = callback
        cm.requestNetwork(request, callback)
        mainHandler.postDelayed(timeout, 8000)
    }

    // ── WiFi: discover and auto-connect to the first printer found ──────────────

    private fun discoverWifiPrinter(result: MethodChannel.Result) {
        // Ensure traffic is routed over Wi-Fi before discovering.
        bindToWifiNetwork { bound ->
            if (!bound) {
                result.error(
                    "WIFI_BIND_FAILED",
                    "Could not route to the printer's Wi-Fi. Make sure your phone is connected to the printer's Wi-Fi network.",
                    null
                )
                return@bindToWifiNetwork
            }
            startWifiDiscovery(result)
        }
    }

    private fun startWifiDiscovery(result: MethodChannel.Result) {
        val resolved = AtomicBoolean(false)

        val started = WifiPrintDevice.startDiscovery(this, object : CanonDiscoveryCallback() {
            override fun onFoundPrinter(device: WifiPrintDevice) {
                // Auto-connect to the first printer discovered on the network.
                if (resolved.compareAndSet(false, true)) {
                    cachedWifiDevice = device
                    WifiPrintDevice.stopDiscovery()
                    mainHandler.post {
                        result.success("Printer ready: ${device.printerName} (${device.printerIpAddress})")
                    }
                }
            }

            override fun onFinished(found: Boolean) {
                // Discovery completed without any printer being picked up.
                if (resolved.compareAndSet(false, true)) {
                    mainHandler.post {
                        result.error(
                            "NO_PRINTER",
                            "No Canon Selphy printer found on Wi-Fi. Ensure the printer and phone are on the same network.",
                            null
                        )
                    }
                }
            }
        })

        if (!started && resolved.compareAndSet(false, true)) {
            mainHandler.post {
                result.error("DISCOVERY_FAILED", "Could not start Wi-Fi discovery. Check Wi-Fi is enabled.", null)
            }
        }
    }

    // ── USB print ───────────────────────────────────────────────────────────────

    private fun startUsbPrint(
        filePath: String,
        copies: Int,
        paperSize: String,
        filter: String,
        brightness: Int,
        bordered: Boolean,
        result: MethodChannel.Result
    ) {
        val ctx = applicationContext
        val device = cachedUsbDevice

        if (device == null || !CanonUsbManager.hasPermission(ctx, device)) {
            mainHandler.post {
                result.error("NO_PERMISSION", "Printer not ready. Tap the refresh button.", null)
            }
            return
        }

        val sizeInfo = sizeInfoFor(paperSize)

        val resizedFile = try {
            resizeImageForPrinting(filePath, sizeInfo.printableJpegSize, sizeInfo.printableArea, filter, brightness, bordered)
        } catch (e: Exception) {
            mainHandler.post {
                result.error("IMAGE_ERROR", "Failed to prepare image: ${e.message}", null)
            }
            return
        }

        val job = UsbPrintJob()
        job.setPrintConfiguration(UsbPrintJob.Configuration.Copies, copies)

        val uri = Uri.fromFile(resizedFile)
        if (!job.setPrintFile(uri, this)) {
            resizedFile.delete()
            mainHandler.post {
                result.error("FILE_ERROR", "Printer rejected the image. Ensure the correct paper cassette is loaded.", null)
            }
            return
        }

        val resolved = AtomicBoolean(false)

        val started = device.print(job, object : UsbPrintCallback() {
            override fun onChangedJobStatus(job: UsbPrintJob) {
                if (job.isFinished && resolved.compareAndSet(false, true)) {
                    resizedFile.delete()
                    val statusMsg = job.status.toString()
                    mainHandler.post {
                        if (statusMsg.contains("Error", ignoreCase = true)) {
                            result.error("PRINT_ERROR", "Print failed: $statusMsg", null)
                        } else {
                            result.success("Print completed: $statusMsg")
                        }
                    }
                }
            }

            override fun onChangedPrinterStatus(job: UsbPrintJob, status: UsbPrinterStatus) {
                // no-op
            }
        })

        if (!started && resolved.compareAndSet(false, true)) {
            resizedFile.delete()
            mainHandler.post {
                result.error("PRINT_START_FAILED", "Failed to start print job.", null)
            }
        }
    }

    // ── WiFi print ───────────────────────────────────────────────────────────────

    private fun startWifiPrint(
        filePath: String,
        copies: Int,
        paperSize: String,
        filter: String,
        brightness: Int,
        bordered: Boolean,
        result: MethodChannel.Result
    ) {
        val device = cachedWifiDevice

        if (device == null) {
            mainHandler.post {
                result.error("NO_PRINTER", "Printer not ready. Tap the refresh button to search.", null)
            }
            return
        }

        val sizeInfo = sizeInfoFor(paperSize)

        val resizedFile = try {
            resizeImageForPrinting(filePath, sizeInfo.printableJpegSize, sizeInfo.printableArea, filter, brightness, bordered)
        } catch (e: Exception) {
            mainHandler.post {
                result.error("IMAGE_ERROR", "Failed to prepare image: ${e.message}", null)
            }
            return
        }

        val job = WifiPrintJob()
        job.setPrintConfiguration(WifiPrintJob.Configuration.Copies, copies)

        // WiFi setPrintFile returns void (unlike USB which returns a Boolean).
        val uri = Uri.fromFile(resizedFile)
        job.setPrintFile(uri, this)

        val resolved = AtomicBoolean(false)

        // WiFi print() takes a Context argument in addition to job + callback.
        val started = device.print(job, this, object : WifiPrintCallback() {
            override fun onChangedJobStatus(job: WifiPrintJob) {
                if (job.isFinished && resolved.compareAndSet(false, true)) {
                    resizedFile.delete()
                    val statusMsg = job.status.toString()
                    mainHandler.post {
                        if (statusMsg.contains("Error", ignoreCase = true)) {
                            result.error("PRINT_ERROR", "Print failed: $statusMsg", null)
                        } else {
                            result.success("Print completed: $statusMsg")
                        }
                    }
                }
            }

            override fun onChangedPrinterStatus(job: WifiPrintJob, status: WifiPrinterStatus) {
                // no-op
            }
        })

        if (!started && resolved.compareAndSet(false, true)) {
            resizedFile.delete()
            mainHandler.post {
                result.error("PRINT_START_FAILED", "Failed to start print job.", null)
            }
        }
    }

    // ── Paper size lookup ─────────────────────────────────────────────────────

    // The full JPEG dimensions the SDK expects (includes a bleed margin) plus
    // the printable area (the sub-rectangle that actually lands on the paper —
    // the rest bleeds off the edge). The physical paper specs are identical
    // across transports, so the USB SDK's size table is used for both.
    private fun sizeInfoFor(paperSize: String): UsbPrintSizeInfo {
        val paperType = when (paperSize) {
            "L-size" -> UsbAccessoryInfo.PaperCassetteStatus.L
            "Card"   -> UsbAccessoryInfo.PaperCassetteStatus.Card
            else     -> UsbAccessoryInfo.PaperCassetteStatus.Post  // default: 4x6
        }
        return UsbPrintSizeInfo.getPrintSizeInfo(paperType)
    }

    // ── Image resize ──────────────────────────────────────────────────────────

    // Renders the image onto the full (jpegSize) canvas the SDK expects, fitting
    // the WHOLE photo inside the printable area so nothing is cropped or printed
    // off the paper edge. The photo is scaled to fit (contain) and centered
    // within the printable rectangle; everything outside it (the off-paper bleed
    // margin, plus any letterbox gap when the photo's shape differs from the
    // paper) is filled white. EXIF orientation is applied automatically by
    // ImageDecoder. Brightness and filter are then applied in order.
    private fun resizeImageForPrinting(
        sourcePath: String, jpegSize: Point, printable: Rect,
        filter: String, brightness: Int, bordered: Boolean
    ): File {
        val targetW = jpegSize.x
        val targetH = jpegSize.y

        // ImageDecoder (API 28+) automatically applies EXIF orientation, so no
        // manual rotation is needed and double-rotation on Samsung devices is avoided.
        val source = ImageDecoder.createSource(File(sourcePath))
        var bmp = ImageDecoder.decodeBitmap(source) { decoder, _, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }

        // If source and paper orientations differ (e.g. landscape photo on portrait
        // paper), rotate the bitmap 90° so it fills the paper naturally.
        val srcIsLandscape = bmp.width > bmp.height
        val paperIsLandscape = targetW > targetH
        if (srcIsLandscape != paperIsLandscape) {
            val matrix = android.graphics.Matrix().apply { postRotate(90f) }
            val rotated = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, matrix, true)
            bmp.recycle()
            bmp = rotated
        }

        val srcW = bmp.width.toFloat()
        val srcH = bmp.height.toFloat()

        // The on-paper printable region. A small uniform safety inset is always
        // applied so every print has a clean, even white border (and so the
        // printer's borderless overscan/feed tolerance isn't visible at the very
        // edge). "Bordered" insets further for a larger, deliberate margin.
        val insetFraction = if (bordered) 0.06f else 0.025f
        val insetX = (printable.width() * insetFraction).toInt()
        val insetY = (printable.height() * insetFraction).toInt()
        val areaLeft = printable.left + insetX
        val areaTop = printable.top + insetY
        val areaW = printable.width() - insetX * 2
        val areaH = printable.height() - insetY * 2

        // Scale to FIT (contain) inside the printable area — the entire photo is
        // visible. If aspect ratios differ, the shorter dimension is centered.
        val scale = minOf(areaW / srcW, areaH / srcH)
        val scaledW = (srcW * scale).toInt()
        val scaledH = (srcH * scale).toInt()
        val scaled = Bitmap.createScaledBitmap(bmp, scaledW, scaledH, true)
        bmp.recycle()

        var canvas = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
        val c = Canvas(canvas)
        c.drawColor(Color.WHITE)
        val left = areaLeft + (areaW - scaledW) / 2f
        val top  = areaTop + (areaH - scaledH) / 2f
        c.drawBitmap(scaled, left, top, Paint(Paint.FILTER_BITMAP_FLAG))
        scaled.recycle()

        // ── Brightness ────────────────────────────────────────────────────────
        if (brightness != 0) {
            val scale2 = 1f + brightness * 0.12f
            val brightMatrix = ColorMatrix().apply {
                setScale(scale2, scale2, scale2, 1f)
            }
            val paint = Paint().apply { colorFilter = ColorMatrixColorFilter(brightMatrix) }
            val adjusted = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
            Canvas(adjusted).drawBitmap(canvas, 0f, 0f, paint)
            canvas.recycle()
            canvas = adjusted
        }

        // ── Filter ────────────────────────────────────────────────────────────
        if (filter != "Off") {
            val colorMatrix = when (filter) {
                "B&W" -> ColorMatrix().apply { setSaturation(0f) }
                "Sepia" -> ColorMatrix().apply {
                    set(floatArrayOf(
                        0.393f, 0.769f, 0.189f, 0f, 0f,
                        0.349f, 0.686f, 0.168f, 0f, 0f,
                        0.272f, 0.534f, 0.131f, 0f, 0f,
                        0f,     0f,     0f,     1f, 0f
                    ))
                }
                "Vivid" -> ColorMatrix().apply { setSaturation(1.6f) }
                else -> null
            }
            if (colorMatrix != null) {
                val paint = Paint().apply { colorFilter = ColorMatrixColorFilter(colorMatrix) }
                val filtered = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
                Canvas(filtered).drawBitmap(canvas, 0f, 0f, paint)
                canvas.recycle()
                canvas = filtered
            }
        }

        val outFile = File(cacheDir, "selphy_print_${System.currentTimeMillis()}.jpg")
        FileOutputStream(outFile).use { fos ->
            canvas.compress(Bitmap.CompressFormat.JPEG, 95, fos)
        }
        canvas.recycle()

        return outFile
    }
}
