package com.mindoula.canon_selphy_print

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import jp.co.canon.android.print.selphy.usbsdk.CanonPermissionRequestCallback
import jp.co.canon.android.print.selphy.usbsdk.CanonPreparationCallback
import jp.co.canon.android.print.selphy.usbsdk.CanonPrintCallback
import jp.co.canon.android.print.selphy.usbsdk.CanonPrintDevice
import jp.co.canon.android.print.selphy.usbsdk.CanonPrintJob
import jp.co.canon.android.print.selphy.usbsdk.CanonPrintSizeInfo
import jp.co.canon.android.print.selphy.usbsdk.CanonPrinterAccessoryInfo
import jp.co.canon.android.print.selphy.usbsdk.CanonPrinterStatus
import jp.co.canon.android.print.selphy.usbsdk.CanonUsbManager
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {

    private val channelName = "com.mindoula.canon_selphy_print/usb"
    private val mainHandler = Handler(Looper.getMainLooper())

    // Cached device so startPrint reuses the same instance that was permission-checked.
    private var cachedDevice: CanonPrintDevice? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> requestUsbPermission(result)
                    "print" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath == null) result.error("INVALID_ARG", "filePath is required", null)
                        else {
                            val copies     = call.argument<Int>("copies") ?: 1
                            val paperSize  = call.argument<String>("paperSize") ?: "4x6"
                            val filter     = call.argument<String>("filter") ?: "Off"
                            val brightness = call.argument<Int>("brightness") ?: 0
                            val bordered   = call.argument<Boolean>("bordered") ?: false
                            startPrint(filePath, copies, paperSize, filter, brightness, bordered, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── Permission request (called on screen open) ────────────────────────────

    private fun requestUsbPermission(result: MethodChannel.Result) {
        val ctx = applicationContext

        fun findAndRequestPermission() {
            @Suppress("UNCHECKED_CAST")
            val printers = CanonUsbManager.getPrinterList(ctx) as? List<CanonPrintDevice> ?: emptyList()

            if (printers.isEmpty()) {
                mainHandler.post {
                    result.error("NO_PRINTER", "No Canon Selphy printer found via USB", null)
                }
                return
            }

            val device = printers[0]

            if (CanonUsbManager.hasPermission(ctx, device)) {
                cachedDevice = device
                mainHandler.post { result.success("Printer ready: ${device.printerName}") }
                return
            }

            val requested = CanonUsbManager.requestPermission(
                ctx, device,
                object : CanonPermissionRequestCallback() {
                    override fun onReceivePermissionGranted(dev: CanonPrintDevice, granted: Boolean) {
                        mainHandler.post {
                            if (granted) {
                                cachedDevice = dev
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

    // ── Print ─────────────────────────────────────────────────────────────────

    private fun startPrint(
        filePath: String,
        copies: Int,
        paperSize: String,
        filter: String,
        brightness: Int,
        bordered: Boolean,
        result: MethodChannel.Result
    ) {
        val ctx = applicationContext
        val device = cachedDevice

        if (device == null || !CanonUsbManager.hasPermission(ctx, device)) {
            mainHandler.post {
                result.error("NO_PERMISSION", "Printer not ready. Tap the refresh button.", null)
            }
            return
        }

        // Resolve the user-selected paper size to the SDK cassette type and JPEG dimensions.
        val paperType = when (paperSize) {
            "L-size" -> CanonPrinterAccessoryInfo.PaperCassetteStatus.L
            "Card"   -> CanonPrinterAccessoryInfo.PaperCassetteStatus.Card
            else     -> CanonPrinterAccessoryInfo.PaperCassetteStatus.Post  // default: 4x6
        }
        val sizeInfo = CanonPrintSizeInfo.getPrintSizeInfo(paperType)
        val required = sizeInfo.printableJpegSize  // Point: x=width, y=height

        // Prepare the image at the required dimensions.
        val resizedFile = try {
            resizeImageForPrinting(filePath, required.x, required.y, filter, brightness, bordered)
        } catch (e: Exception) {
            mainHandler.post {
                result.error("IMAGE_ERROR", "Failed to prepare image: ${e.message}", null)
            }
            return
        }

        // Configure and submit the print job.
        val job = CanonPrintJob()
        job.setPrintConfiguration(CanonPrintJob.Configuration.Copies, copies)

        val uri = Uri.fromFile(resizedFile)
        if (!job.setPrintFile(uri, this)) {
            resizedFile.delete()
            mainHandler.post {
                result.error("FILE_ERROR", "Printer rejected the image. Ensure the correct paper cassette is loaded.", null)
            }
            return
        }

        val resolved = AtomicBoolean(false)

        val started = device.print(job, object : CanonPrintCallback() {
            override fun onChangedJobStatus(job: CanonPrintJob) {
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

            override fun onChangedPrinterStatus(job: CanonPrintJob, status: CanonPrinterStatus) {
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

    // ── Image resize ──────────────────────────────────────────────────────────

    // Scales the image to fit entirely within (targetW × targetH), preserving
    // aspect ratio. Any empty space is filled with white. EXIF orientation is
    // applied automatically by ImageDecoder. Then applies brightness, filter,
    // and border effects in order.
    private fun resizeImageForPrinting(
        sourcePath: String, targetW: Int, targetH: Int,
        filter: String, brightness: Int, bordered: Boolean
    ): File {
        // ImageDecoder (API 28+) automatically applies EXIF orientation, so no
        // manual rotation is needed and double-rotation on Samsung devices is avoided.
        val source = ImageDecoder.createSource(File(sourcePath))
        var bmp = ImageDecoder.decodeBitmap(source) { decoder, _, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }

        val srcW = bmp.width.toFloat()
        val srcH = bmp.height.toFloat()

        // Borderless: scale to FILL the paper (center-crop any overflow) so the
        // photo covers the full 4×6 with no white bars.
        // Bordered: scale to FIT within the bordered area (whole image visible).
        var canvas: Bitmap
        if (!bordered) {
            val scale = maxOf(targetW / srcW, targetH / srcH)
            val scaledW = (srcW * scale).toInt()
            val scaledH = (srcH * scale).toInt()
            val scaled = Bitmap.createScaledBitmap(bmp, scaledW, scaledH, true)
            bmp.recycle()
            val cropX = (scaledW - targetW) / 2
            val cropY = (scaledH - targetH) / 2
            val cropped = Bitmap.createBitmap(scaled, cropX, cropY, targetW, targetH)
            if (cropped !== scaled) scaled.recycle()
            canvas = cropped
        } else {
            // Fit inside the bordered area (4% inset on each side).
            val borderPx = (targetW * 0.04f).toInt()
            val innerW = targetW - borderPx * 2
            val innerH = targetH - borderPx * 2
            val scale = minOf(innerW / srcW, innerH / srcH)
            val scaledW = (srcW * scale).toInt()
            val scaledH = (srcH * scale).toInt()
            val scaled = Bitmap.createScaledBitmap(bmp, scaledW, scaledH, true)
            bmp.recycle()
            canvas = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
            val c = Canvas(canvas)
            c.drawColor(Color.WHITE)
            val left = (targetW - scaledW) / 2f
            val top  = (targetH - scaledH) / 2f
            c.drawBitmap(scaled, left, top, Paint(Paint.FILTER_BITMAP_FLAG))
            scaled.recycle()
        }

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
