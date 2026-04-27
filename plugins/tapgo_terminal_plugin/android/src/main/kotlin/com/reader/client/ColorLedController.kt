package com.reader.client

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.common.apiutil.ResultCode
import com.common.apiutil.pos.CommonUtil

class ColorLedController(context: Context) {
    private var commonUtil: CommonUtil? = null
    private val handler = Handler(Looper.getMainLooper())

    init {
        try {
            commonUtil = CommonUtil(context)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize CommonUtil (LED service missing?)", e)
            commonUtil = null
        }
    }

    private val ledTypes: IntArray = lookupConstants(
        LED_TYPE_CLASS,
        listOf("COLOR_LED_1", "COLOR_LED_2", "COLOR_LED_3", "COLOR_LED_4"),
    )

    private val yellowColor = constantInt(LED_COLOR_CLASS, "YELLOW_LED")
    private val greenColor = constantInt(LED_COLOR_CLASS, "GREEN_LED")
    private val redColor = constantInt(LED_COLOR_CLASS, "RED_LED")
    private val whiteColor = constantInt(LED_COLOR_CLASS, "WHITE_LED")
    private val defaultColor =
        listOf(yellowColor, whiteColor, greenColor, redColor).firstOrNull { it >= 0 } ?: 0
    private var currentColor = defaultColor

    private val resetRunnable = Runnable { turnOffAll() }

    fun showYellow(holdMs: Long = DEFAULT_HOLD_MS) {
        handler.removeCallbacks(resetRunnable)
        scheduleReset(holdMs)
    }

    fun showGreen(holdMs: Long = DEFAULT_HOLD_MS) {
        handler.removeCallbacks(resetRunnable)
        scheduleReset(holdMs)
    }

    fun showRed(holdMs: Long = DEFAULT_HOLD_MS) {
        handler.removeCallbacks(resetRunnable)
        scheduleReset(holdMs)
    }

    fun shutdown() {
        handler.removeCallbacks(resetRunnable)
        turnOffAll()
    }

    private fun scheduleReset(delayMs: Long) {
        if (delayMs <= 0) {
            turnOffAll()
        } else {
            handler.postDelayed(resetRunnable, delayMs)
        }
    }

    private fun applyColor(color: Int, brightness: Int) {
        val effectiveColor = if (color >= 0) color else defaultColor
        if (effectiveColor < 0 || ledTypes.isEmpty()) {
            return
        }

        val action = Runnable {
            ledTypes.forEach { ledType ->
                val util = commonUtil ?: return@forEach
                val result = runCatching {
                    util.setColorLed(ledType, effectiveColor, brightness)
                }.getOrElse {
                    Log.e(TAG, "setColorLed failed for type $ledType", it)
                    61448
                }
                if (result != ResultCode.SUCCESS) {
                    Log.w(TAG, "setColorLed returned code $result for type $ledType")
                }
            }
            currentColor = effectiveColor
        }

        if (Looper.myLooper() == handler.looper) {
            action.run()
        } else {
            handler.post(action)
        }
    }

    private fun turnOffAll() {
        val color = if (currentColor >= 0) currentColor else defaultColor
        handler.removeCallbacks(resetRunnable)
        applyColor(color, 0)
    }

    private fun lookupConstants(className: String, fieldNames: List<String>): IntArray {
        return fieldNames.mapNotNull { name ->
            val value = constantInt(className, name, fallback = Int.MIN_VALUE)
            if (value == Int.MIN_VALUE) null else value
        }.toIntArray()
    }

    private fun constantInt(className: String, fieldName: String, fallback: Int = -1): Int {
        return try {
            val clazz = Class.forName(className)
            val field = clazz.fields.firstOrNull { it.name == fieldName }
                ?: clazz.declaredFields.firstOrNull { it.name == fieldName }
            if (field != null) {
                field.isAccessible = true
                field.getInt(null)
            } else {
                fallback
            }
        } catch (_: Exception) {
            fallback
        }
    }

    companion object {
        private const val TAG = "ColorLedController"
        private const val DEFAULT_HOLD_MS = 2000L
        private const val LED_TYPE_CLASS = "com.common.CommonConstants\$LedType"
        private const val LED_COLOR_CLASS = "com.common.CommonConstants\$LedColor"
    }
}
