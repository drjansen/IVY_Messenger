// android/app/src/main/java/app/icsportals/ics_messenger_app/MyFirebaseMessagingService.kt

package app.icsportals.ics_messenger_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONArray

class MyFirebaseMessagingService : FirebaseMessagingService() {
  override fun onMessageReceived(message: RemoteMessage) {
    // 1️⃣ Load the Flutter SharedPreferences file
    val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

    // 2️⃣ Parse the JSON-encoded list of muted room IDs
    val idJson   = prefs.getString("muted_rooms", "[]") ?: "[]"
    val mutedIds = mutableSetOf<String>().apply {
      val arr = JSONArray(idJson)
      for (i in 0 until arr.length()) add(arr.getString(i))
    }

    // 3️⃣ Parse the JSON-encoded list of muted room display names
    val nameJson   = prefs.getString("muted_room_names", "[]") ?: "[]"
    val mutedNames = mutableSetOf<String>().apply {
      val arr = JSONArray(nameJson)
      for (i in 0 until arr.length()) add(arr.getString(i))
    }

    // 4️⃣ Extract room ID and raw title from the incoming message
    val roomId   = message.data["room_id"] ?: message.data["rid"]
    val rawTitle = message.notification?.title ?: ""
    // ← Convert underscores to spaces for display
    val displayTitle = rawTitle.replace("_", " ")

    // 5️⃣ If either the room ID or the display title is in our muted sets, drop silently
    if ((roomId != null && mutedIds.contains(roomId)) ||
      (displayTitle.isNotBlank() && mutedNames.contains(displayTitle))) {
      return
    }

    // 6️⃣ Otherwise, build and show the notification
    val channelId = "chat_channel"
    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      nm.createNotificationChannel(
        NotificationChannel(
          channelId,
          "Chat Messages",
          NotificationManager.IMPORTANCE_HIGH
        )
      )
    }

    val notif = NotificationCompat.Builder(this, channelId)
      .setSmallIcon(R.mipmap.ic_launcher)
      // ← Use our cleaned-up title
      .setContentTitle(displayTitle.ifBlank { "New message" })
      .setContentText(message.notification?.body ?: "")
      .setAutoCancel(true)
      .build()

    // Use the roomId hash as a unique notification ID (if null, use 0)
    nm.notify(roomId?.hashCode() ?: 0, notif)
  }
}
