package com.example.tapandgo_poc

import android.content.ComponentName
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.tapandgo_poc/emv_payment"
    private val REQUEST_CODE_PAYMENT = 1001
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "startPayment") {
                val amount = call.argument<Double>("amount")
                if (amount != null) {
                    startPaymentIntent(amount, result)
                } else {
                    result.error("INVALID_ARGUMENT", "Amount is required", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun startPaymentIntent(amount: Double, result: MethodChannel.Result) {
        pendingResult = result
        try {
            val intent = Intent()
            val compName = ComponentName("com.arke2", "com.arke.thirdcalling.ThirdPartyCallActivity")
            intent.component = compName
            intent.putExtra("applicationName", "ArkeAcquiringProject")
            intent.putExtra("transactionName", "Consume")
            
            val transactionData = JSONObject()
            transactionData.put("amount", amount)
            intent.putExtra("transactionData", transactionData.toString())
            
            startActivityForResult(intent, REQUEST_CODE_PAYMENT)
        } catch (e: Exception) {
            pendingResult?.error("INTENT_ERROR", "Failed to start payment intent: ${e.message}", null)
            pendingResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_PAYMENT) {
            if (data == null) {
                pendingResult?.error("NULL_INTENT", "Intent data is null", null)
                pendingResult = null
                return
            }

            val responseCode = data.getStringExtra("responseCode")
            val responseMessage = data.getStringExtra("responseMessage")
            val transactionDataString = data.getStringExtra("transactionData")

            when (responseCode) {
                "00", "01" -> {
                    // Success
                    val resultMap = mapOf(
                        "responseCode" to responseCode,
                        "responseMessage" to responseMessage,
                        "transactionData" to transactionDataString
                    )
                    pendingResult?.success(resultMap)
                }
                else -> {
                    // Error based on Appendix 1 of docs_sdk_emv.txt or specific error code
                    pendingResult?.error(responseCode ?: "UNKNOWN_ERROR", responseMessage ?: "Unknown error occurred", transactionDataString)
                }
            }
            pendingResult = null
        }
    }
}
