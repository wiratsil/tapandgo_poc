package com.tapgo.tapgo_terminal_plugin

import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.bluetooth.BluetoothAdapter
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.annotation.NonNull
import com.alibaba.fastjson.JSON
import com.common.apiutil.ResultCode
import com.common.apiutil.decode.DecodeReader
import com.common.apiutil.powercontrol.PowerControl
import com.common.apiutil.util.AppStringUtil
import com.common.callback.IDecodeReaderListener
import com.reader.client.ColorLedController
import com.reader.client.emv.TlvParser
import com.reader.service.IReaderSdkListener
import com.reader.service.ReaderAIDL
import com.reader.service.ReaderConstant
import com.reader.service.utils.HexUtils
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.nio.charset.Charset
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.ArrayList
import java.util.Date
import java.util.Hashtable
import java.util.Locale

class TapgoTerminalPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
    ActivityAware {
    private lateinit var applicationContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val pos: ReaderAIDL = ReaderAIDL
    private var registered = false
    private var readerReady = false
    private var nfcStarted = false
    private var lastReaderStatus = "IDLE"
    private var lastReaderDetail = "Reader service has not been requested yet."
    private var lastReaderContext = "UNSET"
    private lateinit var locationManager: LocationManager
    private lateinit var powerControl: PowerControl
    private lateinit var decodeReader: DecodeReader
    private lateinit var colorLedController: ColorLedController
    private val mainHandler = Handler(Looper.getMainLooper())
    private val coroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var nfcJob: Job? = null
    private var ledResetJob: Job? = null
    private var qrSessionActive = false

    private val scanHandler = Handler(Looper.getMainLooper())
    private val scanRunnable: Runnable = object : Runnable {
        override fun run() {
            if (!qrSessionActive) {
                return
            }
            try {
                decodeReader.cmdSend(AppStringUtil.hexStringToBytes(SCAN_COMMAND))
            } catch (ex: Exception) {
                emitQrStatus("QR scan error: ${ex.message}. Stopping.")
                qrSessionActive = false
                resetLedState()
                return
            } finally {
                if (qrSessionActive) {
                    scanHandler.postDelayed(this, QR_SCAN_INTERVAL_MS)
                }
            }
        }
    }

    private val decodeListener: IDecodeReaderListener = object : IDecodeReaderListener {
        override fun onRecvData(data: ByteArray?) {
            if (data == null) {
                return
            }
            val result = runCatching { String(data, qrCharset) }.getOrElse {
                emitQrStatus("QR charset error: ${it.message}")
                showFailureFeedback()
                scheduleLedReset(LED_ERROR_HOLD_MS)
                return
            }

            runCatching { pos.peripheral_buzzer(120L) }
            emitQrStatus("QR Result: $result")
            emitEvent(
                type = "qrScanned",
                message = "QR code scanned.",
                payload = mapOf("code" to result),
            )
            showSuccessFeedback()
            scheduleLedReset(LED_SUCCESS_HOLD_MS)
            scanHandler.removeCallbacks(scanRunnable)
            if (qrSessionActive) {
                scanHandler.postDelayed(scanRunnable, QR_SCAN_INTERVAL_MS)
            }
        }
    }

    private val readerListener = IReaderSdkListener { data ->
        mainHandler.post {
            if (data != null) {
                @Suppress("UNCHECKED_CAST")
                handlePosCallback(data as Hashtable<String, String>)
            }
        }
    }

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        initDependencies()
        methodChannel = MethodChannel(binding.binaryMessenger, "tapgo_terminal_plugin/methods")
        eventChannel = EventChannel(binding.binaryMessenger, "tapgo_terminal_plugin/events")
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                emitEvent(
                    type = "initialized",
                    message = "TapGo terminal plugin initialized.",
                    payload = mapOf(
                        "hasActivity" to (activityBinding != null),
                        "packageName" to applicationContext.packageName,
                    ),
                )
                result.success(commandResult(success = true, message = "Plugin initialized."))
            }

            "getDeviceId" -> {
                val androidId = Settings.Secure.getString(
                    applicationContext.contentResolver,
                    Settings.Secure.ANDROID_ID,
                ) ?: ""
                result.success(androidId)
            }

            "getPlatformInfo" -> {
                result.success(
                    mapOf(
                        "platform" to "android",
                        "androidVersion" to android.os.Build.VERSION.RELEASE,
                        "sdkInt" to android.os.Build.VERSION.SDK_INT,
                        "manufacturer" to android.os.Build.MANUFACTURER,
                        "brand" to android.os.Build.BRAND,
                        "model" to android.os.Build.MODEL,
                        "device" to android.os.Build.DEVICE,
                        "hardware" to android.os.Build.HARDWARE,
                    ),
                )
            }

            "getCapabilities" -> {
                result.success(buildCapabilities())
            }

            "getSystemStatus" -> {
                result.success(buildSystemStatus())
            }

            "startNfc" -> {
                val simulate = call.argument<Boolean>("simulate") ?: false
                startNfcSession(simulate)
                result.success(commandResult(true, true, "Starting NFC session...", mapOf("simulate" to simulate)))
            }

            "stopNfc" -> {
                stopNfcSession("Stopped by Flutter request.")
                result.success(
                    commandResult(
                        success = true,
                        implemented = true,
                        message = "NFC session stopped in plugin migration layer.",
                    ),
                )
            }

            "startQr" -> {
                startQrScan()
                result.success(commandResult(true, true, "Starting QR scanner..."))
            }

            "stopQr" -> {
                stopQrScan()
                result.success(commandResult(true, true, "QR scanner stopped."))
            }

            "showGreenLed" -> {
                val holdMs = call.argument<Int>("holdMs") ?: 2000
                showGreenLedInternal(holdMs.toLong())
                result.success(
                    commandResult(
                        success = true,
                        implemented = true,
                        message = "Green LED activated.",
                        data = mapOf("holdMs" to holdMs),
                    ),
                )
            }

            "showYellowLed" -> {
                val holdMs = call.argument<Int>("holdMs") ?: 2000
                showYellowLedInternal(holdMs.toLong())
                result.success(
                    commandResult(
                        success = true,
                        implemented = true,
                        message = "Yellow LED activated.",
                        data = mapOf("holdMs" to holdMs),
                    ),
                )
            }

            "showRedLed" -> {
                val holdMs = call.argument<Int>("holdMs") ?: 2000
                showRedLedInternal(holdMs.toLong())
                result.success(
                    commandResult(
                        success = true,
                        implemented = true,
                        message = "Red LED activated.",
                        data = mapOf("holdMs" to holdMs),
                    ),
                )
            }

            "playBuzzer" -> {
                val durationMs = call.argument<Int>("durationMs") ?: 120
                val buzzerResult = runCatching { pos.peripheral_buzzer(durationMs.toLong()) }.isSuccess
                emitEvent(
                    type = "buzzer",
                    message = if (buzzerResult) "Buzzer played." else "Buzzer call failed.",
                    payload = mapOf("durationMs" to durationMs),
                )
                result.success(
                    commandResult(
                        success = buzzerResult,
                        implemented = true,
                        message = if (buzzerResult) {
                            "Buzzer played."
                        } else {
                            "Buzzer call failed. Reader service may be unavailable."
                        },
                        data = mapOf("durationMs" to durationMs),
                    ),
                )
            }

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        emitEvent(
            type = "streamReady",
            message = "TapGo terminal event stream connected.",
            payload = buildCapabilities(),
        )
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        runCatching { pos.unRegister() }
        registered = false
        readerReady = false
        nfcStarted = false
        nfcJob?.cancel()
        coroutineScope.cancel()
        stopQrScan()
        if (::colorLedController.isInitialized) {
            runCatching { colorLedController.shutdown() }
        }
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        emitEvent("activityAttached", "Activity attached to plugin.")
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding = null
        emitEvent("activityDetached", "Activity detached for configuration change.")
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        emitEvent("activityReattached", "Activity reattached after configuration change.")
    }

    override fun onDetachedFromActivity() {
        activityBinding = null
        emitEvent("activityDetached", "Activity detached from plugin.")
    }

    private fun emitPendingMigration(command: String, payload: Map<String, Any?> = emptyMap()) {
        emitEvent(
            type = "pendingMigration",
            message = "$command is defined in the Flutter API but has not been migrated from the host app yet.",
            payload = mapOf("command" to command) + payload,
        )
    }

    private fun emitEvent(type: String, message: String? = null, payload: Map<String, Any?> = emptyMap()) {
        logEvent(type, message, payload)
        mainHandler.post {
            eventSink?.success(
                mapOf(
                    "type" to type,
                    "message" to message,
                    "payload" to payload,
                ),
            )
        }
    }

    private fun commandResult(
        success: Boolean,
        implemented: Boolean = true,
        message: String? = null,
        data: Map<String, Any?> = emptyMap(),
    ): Map<String, Any?> {
        return mapOf(
            "success" to success,
            "implemented" to implemented,
            "message" to message,
            "data" to data,
        )
    }

    private fun pendingResult(message: String): Map<String, Any?> {
        return commandResult(
            success = false,
            implemented = false,
            message = message,
        )
    }

    private fun buildCapabilities(): Map<String, Any?> {
        val pm = applicationContext.packageManager
        return mapOf(
            "isAndroid" to true,
            "hasNfcFeature" to pm.hasSystemFeature(PackageManager.FEATURE_NFC),
            "hasBluetoothFeature" to pm.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH),
            "hasWifiDirectFeature" to pm.hasSystemFeature("android.hardware.wifi.direct"),
            "hasCameraFeature" to pm.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY),
            "hasGpsFeature" to pm.hasSystemFeature(PackageManager.FEATURE_LOCATION_GPS),
            "vendorReaderServiceInstalled" to isPackageInstalled("com.reader.service"),
            "vendorReaderSdkBundled" to true,
            "vendorUtilitySdkBundled" to true,
            "zxingBundled" to true,
        )
    }

    private fun buildSystemStatus(): Map<String, Any?> {
        val gps = if (::locationManager.isInitialized) {
            val enabled = runCatching {
                locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)
            }.getOrDefault(false)
            if (enabled) "ONLINE" else "OFFLINE"
        } else {
            "INITIALIZING..."
        }

        val reader = when {
            readerReady || nfcStarted -> "READY"
            !isPackageInstalled("com.reader.service") -> "SERVICE_MISSING"
            registered -> "REGISTERED_WAITING_CALLBACK"
            else -> lastReaderStatus
        }
        val qr = if (::decodeReader.isInitialized) "READY" else "INITIALIZING..."
        val network = try {
            val cm =
                applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val activeNetwork = cm.activeNetworkInfo
            if (activeNetwork?.isConnectedOrConnecting == true) "ONLINE" else "DISCONNECTED"
        } catch (_: Exception) {
            "UNKNOWN"
        }
        val bluetooth = try {
            val adapter = BluetoothAdapter.getDefaultAdapter()
            when {
                adapter == null -> "UNSUPPORTED"
                adapter.isEnabled -> "ENABLED"
                else -> "DISABLED"
            }
        } catch (_: Exception) {
            "UNKNOWN"
        }

        return mapOf(
            "gps" to gps,
            "reader" to reader,
            "readerDetail" to lastReaderDetail,
            "readerContext" to lastReaderContext,
            "qr" to qr,
            "network" to network,
            "bluetooth" to bluetooth,
        )
    }

    private fun initDependencies() {
        locationManager =
            applicationContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        powerControl = PowerControl(applicationContext)
        decodeReader = DecodeReader(applicationContext)
        colorLedController = ColorLedController(applicationContext)
        resetLedState()
    }

    private fun tryRegisterReaderService() {
        if (registered) {
            logReader("Register skipped because reader is already marked registered.")
            return
        }
        val readerPackageInstalled = isPackageInstalled("com.reader.service")
        logReader("Register requested. packageInstalled=$readerPackageInstalled activityAttached=${activityBinding != null}")
        if (!readerPackageInstalled) {
            registered = false
            readerReady = false
            lastReaderStatus = "SERVICE_MISSING"
            lastReaderDetail = "Package com.reader.service is not installed on this device."
            lastReaderContext = "NO_READER_PACKAGE"
            logReader(lastReaderDetail)
            emitEvent("readerServiceError", lastReaderDetail)
            return
        }
        val context = activityBinding?.activity ?: applicationContext
        lastReaderContext = context.javaClass.name
        runCatching {
            lastReaderStatus = "REGISTERING"
            lastReaderDetail = "Attempting to register reader service with $lastReaderContext."
            logReader(lastReaderDetail)
            pos.register(context, readerListener)
        }.onSuccess {
            registered = true
            lastReaderStatus = "REGISTERED_WAITING_CALLBACK"
            lastReaderDetail =
                "Reader service register() succeeded with $lastReaderContext; waiting for service connected callback."
            logReader(lastReaderDetail)
            emitEvent(
                "readerService",
                "Reader service registered.",
                mapOf(
                    "readerStatus" to lastReaderStatus,
                    "readerDetail" to lastReaderDetail,
                    "readerContext" to lastReaderContext,
                ),
            )
        }.onFailure {
            registered = false
            readerReady = false
            lastReaderStatus = "REGISTER_FAILED"
            val exceptionClass = it::class.java.name
            val exceptionMessage = it.message ?: "Unknown reader registration failure."
            lastReaderDetail =
                "register() failed with $exceptionClass using $lastReaderContext: $exceptionMessage"
            Log.e(TAG, "Reader register() failed.", it)
            emitEvent(
                "readerServiceError",
                "Reader service registration failed: $exceptionMessage",
                mapOf(
                    "readerStatus" to lastReaderStatus,
                    "readerDetail" to lastReaderDetail,
                    "readerContext" to lastReaderContext,
                    "exceptionClass" to exceptionClass,
                ),
            )
        }
    }

    private fun showYellowLedInternal(holdMs: Long) {
        runCatching { colorLedController.showYellow(holdMs) }
        emitEvent("led", "Yellow LED activated.", mapOf("holdMs" to holdMs, "color" to "yellow"))
    }

    private fun showGreenLedInternal(holdMs: Long) {
        runCatching { pos.peripheral_ledGreen() }
        runCatching { colorLedController.showGreen(holdMs) }
        emitEvent("led", "Green LED activated.", mapOf("holdMs" to holdMs, "color" to "green"))
    }

    private fun showRedLedInternal(holdMs: Long) {
        runCatching { pos.peripheral_ledRed() }
        runCatching { colorLedController.showRed(holdMs) }
        emitEvent("led", "Red LED activated.", mapOf("holdMs" to holdMs, "color" to "red"))
    }

    private fun resetLedState() {
        runCatching { pos.peripheral_ledClose() }
        runCatching { colorLedController.shutdown() }
    }

    private fun startNfcSession(simulate: Boolean) {
        if (!simulate && !registered) {
            tryRegisterReaderService()
            if (!registered) {
                emitStatus("Reader service not registered yet. Registering now...")
                return
            }
        }

        if (nfcJob?.isActive == true) {
            emitStatus("NFC reading already running.")
            return
        }

        nfcStarted = true
        nfcJob = coroutineScope.launch {
            try {
                runNfcFlow(simulate)
            } finally {
                runCatching { pos.peripheral_ledClose() }
                if (readerReady) {
                    runCatching { pos.nfc_close() }
                }
            }
        }
    }

    private fun stopNfcSession(reason: String? = null) {
        reason?.let { emitStatus(it) }
        nfcStarted = false
        nfcJob?.cancel()
        nfcJob = null
    }

    private suspend fun runNfcFlow(simulate: Boolean) = withContext(Dispatchers.IO) {
        emitStatus("Opening NFC reader...")
        val openResult = pos.nfc_open()
        if (openResult != ReaderConstant.RESULT_CODE_SUCCESS) {
            emitStatus("Failed to open NFC reader. Code: $openResult")
            showFailureFeedback()
            scheduleLedReset(LED_ERROR_HOLD_MS)
            return@withContext
        }

        while (isActive) {
            resetLedState()
            emitStatus("NFC Reader Opened. Waiting for card...")

            var cardDetected = false
            while (!cardDetected && isActive) {
                colorLedController.showYellow()
                val pollResult = pos.nfc_pollOnMifareCard(1000)
                if (pollResult.isNotEmpty()) {
                    try {
                        val resp = JSON.parseObject(pollResult)
                        if (resp.containsKey(ReaderConstant.KEY_RESULT_CODE)) {
                            val code = resp.getIntValue(ReaderConstant.KEY_RESULT_CODE)
                            if (code == ReaderConstant.RESULT_CODE_SUCCESS) {
                                cardDetected = true
                            }
                        }
                    } catch (_: Exception) {
                    }
                }
                if (!cardDetected) {
                    delay(500)
                }
            }

            if (!isActive) {
                return@withContext
            }

            val cardData = sendApduAndGetData()
            if (cardData != null) {
                emitStatus("Card reading complete.")
                emitEvent(
                    type = "nfcResult",
                    message = "NFC card read complete.",
                    payload = mapOf(
                        "pan" to cardData.first,
                        "expiry" to cardData.second,
                        "label" to cardData.third,
                    ),
                )
                runCatching { pos.peripheral_buzzer(200L) }
                showSuccessFeedback()
                delay(LED_SUCCESS_HOLD_MS)
            } else {
                emitStatus("Failed to read card data.")
                showFailureFeedback()
                delay(LED_ERROR_HOLD_MS)
            }

            resetLedState()
            emitStatus("Please remove the card.")
            delay(2000)
            emitStatus("Present a new card.")
            delay(1000)
        }
    }

    private fun sendApduAndGetData(): Triple<String?, String?, String?>? {
        emitStatus("Sending PPSE...")
        val ppseResp =
            executeNfcApduCommandGetResponse("PPSE", "00A404000E325041592E5359532E444446303100")
                ?: return null
        val ppseData = TlvParser.parse(ppseResp.dropLast(4))
        val finalAid = ppseData.mapNotNull { it.getAid() }.firstOrNull() ?: return null
        val label = ppseData.mapNotNull { it.getLabel() }.firstOrNull()

        emitStatus("Selecting AID...")
        val selectResp =
            executeNfcApduCommandGetResponse("SELECT AID", "00A4040007$finalAid") ?: return null
        val selectData = TlvParser.parse(selectResp.dropLast(4))
        val pdol = selectData.mapNotNull { it.getPdol() }.firstOrNull()

        emitStatus("GPO...")
        val amountInCents = 100L
        val pdolBytes = if (pdol != null) HexUtils.hexStringToBytes(pdol) else ByteArray(0)
        val pdolData =
            if (pdolBytes.isNotEmpty()) buildPdolData(pdolBytes, amountInCents) else ByteArray(0)
        val gpoApduHex = buildGpoApduHex(pdolData)
        val gpoResp = executeNfcApduCommandGetResponse("GPO", gpoApduHex) ?: return null

        var cardInfo = EmvUtils.extractPanAndExpiry(gpoResp)
        if (cardInfo == null) {
            emitStatus("Reading Records...")
            val recordInfo = parseAflAndReadRecords(gpoResp)
            val pan = recordInfo["PAN"]
            if (pan != null) {
                cardInfo = Pair(pan, recordInfo["EXP"] ?: "")
            }
        }

        return if (cardInfo != null) {
            Triple(cardInfo.first, cardInfo.second, label)
        } else {
            null
        }
    }

    private fun executeNfcApduCommandGetResponse(functionName: String, commandHex: String): String? {
        return try {
            emitStatus("APDU $functionName")
            val commandBytes = HexUtils.hexStringToBytes(commandHex)
            val rawResp = pos.nfc_sendApdu(commandBytes)
            if (rawResp.isBlank()) {
                return null
            }
            if (rawResp.matches(Regex("^[0-9A-Fa-f]+$"))) {
                return rawResp
            }
            val obj = JSON.parseObject(rawResp)
            obj.getString("payload")
                ?: obj.getString("data")
                ?: obj.getString("response")
                ?: obj.getString("apdu")
                ?: obj.getString("outData")
                ?: obj.getString("result")
        } catch (e: Exception) {
            emitStatus("$functionName exception: ${e.message}")
            null
        }
    }

    private fun startQrScan() {
        if (qrSessionActive) {
            return
        }
        emitQrStatus("Preparing QR scanner...")
        val powerResult = runCatching { powerControl.decodePower(1) }.getOrElse {
            emitQrStatus("QR power on error: ${it.message}")
            resetLedState()
            qrSessionActive = false
            scheduleQrRetry()
            return
        }
        if (powerResult != ResultCode.SUCCESS) {
            if (powerResult == 61447 || powerResult == -4089) {
                emitQrStatus("QR Hardware Error ($powerResult). Stopping.")
                resetLedState()
                qrSessionActive = false
                return
            }
            emitQrStatus("QR power on failed (code $powerResult). Retrying...")
            resetLedState()
            qrSessionActive = false
            scheduleQrRetry()
            return
        }

        val openResult = runCatching { decodeReader.open(QR_BAUD_RATE) }.getOrElse {
            emitQrStatus("QR reader open error: ${it.message}")
            resetLedState()
            qrSessionActive = false
            scheduleQrRetry()
            return
        }

        if (openResult == ResultCode.SUCCESS) {
            qrSessionActive = true
            decodeReader.setDecodeReaderListener(decodeListener)
            emitQrStatus("QR scanner ready. Waiting for code...")
            scanHandler.post(scanRunnable)
        } else {
            emitQrStatus("Failed to open QR reader (code $openResult). Retrying...")
            resetLedState()
            qrSessionActive = false
            scheduleQrRetry()
        }
    }

    private fun scheduleQrRetry() {
        scanHandler.removeCallbacks(scanRunnable)
        scanHandler.postDelayed({ startQrScan() }, QR_RETRY_DELAY_MS)
    }

    private fun stopQrScan() {
        qrSessionActive = false
        scanHandler.removeCallbacksAndMessages(null)
        runCatching { decodeReader.close() }
        runCatching { powerControl.decodePower(0) }
        resetLedState()
    }

    private fun handlePosCallback(data: Hashtable<String, String>) {
        val msg = data[ReaderConstant.KEY_RESULT_MSG]
        logReader(
            "Callback received. message=${msg ?: "null"} payloadKeys=${data.entries.joinToString(",") { it.key }}"
        )
        if (msg?.contains("service connected", ignoreCase = true) == true) {
            readerReady = true
            lastReaderStatus = "READY"
            lastReaderDetail = "Reader service connected via callback on $lastReaderContext."
            emitStatus("Reader service connected.")
        }
    }

    private fun emitStatus(message: String) {
        emitEvent("status", message, mapOf("status" to message))
    }

    private fun emitQrStatus(message: String) {
        emitEvent("qrStatus", message, mapOf("status" to message))
    }

    private fun logReader(message: String) {
        Log.d(TAG, "[Reader] $message")
        println("$TAG [Reader] $message")
    }

    private fun logEvent(type: String, message: String?, payload: Map<String, Any?>) {
        val suffix = if (payload.isEmpty()) "" else " payload=$payload"
        val line = "[Event:$type] ${message ?: "-"}$suffix"
        if (type.contains("error", ignoreCase = true)) {
            Log.e(TAG, line)
        } else {
            Log.i(TAG, line)
        }
        println("$TAG $line")
    }

    private fun showSuccessFeedback() {
        runCatching { pos.peripheral_ledGreen() }
        runCatching { colorLedController.showGreen(LED_SUCCESS_HOLD_MS) }
    }

    private fun showFailureFeedback() {
        runCatching { pos.peripheral_ledRed() }
        runCatching { colorLedController.showRed(LED_ERROR_HOLD_MS) }
    }

    private fun scheduleLedReset(delayMs: Long) {
        ledResetJob?.cancel()
        ledResetJob = coroutineScope.launch {
            delay(delayMs)
            resetLedState()
        }
    }

    private fun buildPdolData(pdolBytes: ByteArray, amountInCents: Long): ByteArray {
        val out = ArrayList<Byte>()
        var i = 0
        while (i < pdolBytes.size) {
            var tag = pdolBytes[i].toInt() and 0xFF
            i++
            if ((tag and 0x1F) == 0x1F) {
                do {
                    val b = pdolBytes[i].toInt() and 0xFF
                    tag = (tag shl 8) or b
                    i++
                    if ((b and 0x80) == 0) {
                        break
                    }
                } while (i < pdolBytes.size)
            }
            val len = pdolBytes[i].toInt() and 0xFF
            i++
            val value = when (tag) {
                0x9F66 -> fitToLength(byteArrayOf(0x32, 0x00, 0x40, 0x00), len)
                0x9F02 -> amountToBcd(amountInCents, len)
                0x9F03 -> ByteArray(len) { 0x00 }
                0x9F1A -> fitToLength(byteArrayOf(0x02, 0xF4.toByte()), len)
                0x95 -> fitToLength(byteArrayOf(0x00, 0x00, 0x00, 0x00, 0x00), len)
                0x5F2A -> fitToLength(byteArrayOf(0x02, 0xF4.toByte()), len)
                0x9A -> fitToLength(dateYYMMDD(), len)
                0x9C -> fitToLength(byteArrayOf(0x00), len)
                0x9F37 -> randomBytes(len)
                else -> ByteArray(len) { 0x00 }
            }
            out.addAll(value.toList())
        }
        return out.toByteArray()
    }

    private fun parseAflAndReadRecords(gpoRespHex: String): Map<String, String> {
        val result = mutableMapOf<String, String>()
        val gpoBytes = stripSWBytes(gpoRespHex)
        val gpoTlvs = TlvParser.parse(HexUtils.bytesToHexString(gpoBytes))
        val aflTlv = gpoTlvs.mapNotNull { it.findTag("94") }.firstOrNull()
        val afl = if (aflTlv != null) {
            HexUtils.hexStringToBytes(aflTlv.value)
        } else if (gpoBytes.isNotEmpty() && (gpoBytes[0].toInt() and 0xFF) != 0x77) {
            gpoBytes
        } else {
            ByteArray(0)
        }

        if (afl.isEmpty()) {
            return result
        }

        var i = 0
        while (i + 3 < afl.size) {
            val b1 = afl[i].toInt() and 0xFF
            val firstRec = afl[i + 1].toInt() and 0xFF
            val lastRec = afl[i + 2].toInt() and 0xFF
            val sfi = (b1 and 0xF8) shr 3
            for (rec in firstRec..lastRec) {
                val p2 = ((sfi shl 3) or 0x04) and 0xFF
                val readCmd = String.format("00B2%02X%02X00", rec, p2)
                val readResp = executeNfcApduCommandGetResponse("READ REC", readCmd)
                if (readResp != null) {
                    val recTlvs = TlvParser.parse(readResp.dropLast(4))
                    val panTlv = recTlvs.mapNotNull { it.findTag("5A") }.firstOrNull()
                    if (panTlv != null) {
                        result["PAN"] = bcdToString(HexUtils.hexStringToBytes(panTlv.value))
                    }
                    val expTlv = recTlvs.mapNotNull { it.findTag("5F24") }.firstOrNull()
                    if (expTlv != null) {
                        result["EXP"] = bcdToString(HexUtils.hexStringToBytes(expTlv.value))
                    }
                    if (result.containsKey("PAN")) {
                        return result
                    }
                }
            }
            i += 4
        }
        return result
    }

    private fun stripSWBytes(hexResp: String): ByteArray {
        val bytes = HexUtils.hexStringToBytes(hexResp)
        if (bytes.size >= 2) {
            val sw1 = bytes[bytes.size - 2].toInt() and 0xFF
            val sw2 = bytes[bytes.size - 1].toInt() and 0xFF
            if (sw1 == 0x90 && sw2 == 0x00) {
                return bytes.copyOfRange(0, bytes.size - 2)
            }
        }
        return bytes
    }

    private fun fitToLength(src: ByteArray, len: Int): ByteArray =
        when {
            src.size == len -> src
            src.size < len -> ByteArray(len - src.size) { 0x00 } + src
            else -> src.copyOfRange(src.size - len, src.size)
        }

    private fun amountToBcd(amountInCents: Long, numBytes: Int): ByteArray {
        val digits = numBytes * 2
        val s = amountInCents.toString().padStart(digits, '0')
        return decimalStringToBcd(s)
    }

    private fun decimalStringToBcd(s: String): ByteArray {
        val source = if (s.length % 2 != 0) "0$s" else s
        val out = ByteArray(source.length / 2)
        var i = 0
        var j = 0
        while (j < source.length) {
            val hi = source[j].digitToInt()
            val lo = source[j + 1].digitToInt()
            out[i] = ((hi shl 4) or lo).toByte()
            j += 2
            i++
        }
        return out
    }

    private fun bcdToString(bcd: ByteArray): String {
        val sb = StringBuilder()
        for (b in bcd) {
            val hi = (b.toInt() and 0xF0) ushr 4
            val lo = b.toInt() and 0x0F
            if (hi <= 9) {
                sb.append(hi)
            } else {
                break
            }
            if (lo <= 9) {
                sb.append(lo)
            } else {
                break
            }
        }
        return sb.toString()
    }

    private fun dateYYMMDD(): ByteArray {
        val fmt = SimpleDateFormat("yyMMdd", Locale.US)
        return decimalStringToBcd(fmt.format(Date()))
    }

    private fun randomBytes(len: Int): ByteArray {
        val b = ByteArray(len)
        SecureRandom().nextBytes(b)
        return b
    }

    private fun buildGpoApduHex(pdolData: ByteArray): String {
        return if (pdolData.isEmpty()) {
            "80A8000002830000"
        } else {
            val pdolTl = byteArrayOf(0x83.toByte(), pdolData.size.toByte()) + pdolData
            val lc = pdolTl.size.toByte()
            val apdu =
                byteArrayOf(0x80.toByte(), 0xA8.toByte(), 0x00, 0x00, lc) + pdolTl + byteArrayOf(0x00)
            HexUtils.bytesToHexString(apdu)
        }
    }

    private object EmvUtils {
        fun extractPanAndExpiry(gpoHex: String): Pair<String, String>? {
            val data = gpoHex.uppercase(Locale.US)
            val idx = data.indexOf("57")
            if (idx == -1) {
                return null
            }
            val len = data.substring(idx + 2, idx + 4).toInt(16)
            val start = idx + 4
            val end = start + len * 2
            if (end > data.length) {
                return null
            }
            val track2 = data.substring(start, end)
            val sepIdx = track2.indexOfAny(charArrayOf('D', 'F'))
            if (sepIdx == -1) {
                return null
            }
            val pan = track2.substring(0, sepIdx)
            val expiry = track2.substring(sepIdx + 1, sepIdx + 5)
            return Pair(pan, expiry)
        }
    }

    companion object {
        private const val TAG = "TapGoTerminalPlugin"
        private const val QR_BAUD_RATE = 115200
        private const val QR_SCAN_INTERVAL_MS = 3000L
        private const val QR_RETRY_DELAY_MS = 3000L
        private const val SCAN_COMMAND = "7E01303030304053434E545247313B03"
        private const val LED_SUCCESS_HOLD_MS = 2500L
        private const val LED_ERROR_HOLD_MS = 2500L
        private val qrCharset: Charset = Charset.forName("GB2312")
    }

    private fun isPackageInstalled(packageName: String): Boolean {
        return try {
            applicationContext.packageManager.getPackageInfo(packageName, 0)
            true
        } catch (_: Exception) {
            false
        }
    }
}
