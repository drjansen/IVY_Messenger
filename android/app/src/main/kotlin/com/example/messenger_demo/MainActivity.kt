package com.example.messenger_demo

import android.os.Bundle
import android.view.WindowManager
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 🔒 Disable screenshots and screen recording
        // Temporarily disabled so screenshots are allowed again
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
        // 🟢 Enable edge-to-edge for Android 15+ compatibility
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }
}