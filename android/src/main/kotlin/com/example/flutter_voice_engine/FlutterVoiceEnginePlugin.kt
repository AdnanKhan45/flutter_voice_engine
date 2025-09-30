package com.example.flutter_voice_engine

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.receiveAsFlow

class FlutterVoiceEnginePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
  private lateinit var context: Context
  private lateinit var methodChannel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private lateinit var audioManager: AudioManager
  private var eventSink: EventChannel.EventSink? = null
  private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    methodChannel = MethodChannel(binding.binaryMessenger, "flutter_voice_engine")
    methodChannel.setMethodCallHandler(this)

    eventChannel = EventChannel(binding.binaryMessenger, "flutter_voice_engine/events")
    eventChannel.setStreamHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "initialize" -> {
        val audioConfig = call.argument<Map<String, Any>>("audioConfig")!!
        val channels = (audioConfig["channels"] as Number).toInt()
        val sampleRate = (audioConfig["sampleRate"] as Number).toInt()
        val bitDepth = (audioConfig["bitDepth"] as Number).toInt()
        val bufferSize = (audioConfig["bufferSize"] as Number).toInt()
        val amplitudeThreshold = (audioConfig["amplitudeThreshold"] as Number).toFloat()
        val enableAEC = audioConfig["enableAEC"] as Boolean

        audioManager = AudioManager(context, channels, sampleRate, bitDepth, bufferSize, amplitudeThreshold, enableAEC)
        audioManager.setupEngine()
        result.success(null)
      }

      "startRecording" -> {
        scope.launch {
          audioManager.startRecording().receiveAsFlow().collect { audioData ->
            withContext(Dispatchers.Main) {
              eventSink?.success(mapOf(
                "type" to "audio_chunk",
                "data" to audioData
              ))
            }
          }
        }
        result.success(null)
      }

      "stopRecording" -> {
        audioManager.stopRecording()
        result.success(null)
      }

      "playAudioChunk" -> {
        val audioData = call.argument<ByteArray>("audioData")!!
        audioManager.playAudioChunk(audioData)
        result.success(null)
      }

      "stopPlayback" -> {
        audioManager.stopPlayback()
        result.success(null)
      }

      "shutdownAll" -> {
        audioManager.shutdown()
        scope.cancel()
        result.success(null)
      }
      "hasWiredOrBluetoothHeadset" -> {
          val audioSys = context.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
          val hasHeadset = audioSys.isWiredHeadsetOn || audioSys.isBluetoothScoOn || audioSys.isBluetoothA2dpOn
          result.success(hasHeadset)
        }
      else -> result.notImplemented()
    }
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events

    if (!::audioManager.isInitialized) {
      // Send error event immediately if audioManager is not ready
      eventSink?.success(mapOf("type" to "error", "message" to "AudioManager not initialized"))
      return
    }

    scope.launch {
      audioManager.getErrorChannel().receiveAsFlow().collect { error ->
        withContext(Dispatchers.Main) {
          eventSink?.success(mapOf("type" to "error", "message" to error))
        }
      }
    }
  }


  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    if (this::audioManager.isInitialized) {
      audioManager.shutdown()
    }
    scope.cancel()
  }
}
