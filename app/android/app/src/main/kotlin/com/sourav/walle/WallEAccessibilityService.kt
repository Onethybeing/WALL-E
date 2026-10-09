package com.sourav.walle

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Powers "control apps and scroll on my phone" (brain/tools.py's
 * control_screen/read_screen) -- a different risk/permission category from
 * everything else in this app, since Accessibility Service grants
 * system-wide screen-reading and gesture-injection access and needs the
 * person to explicitly approve it via Android's own Settings screen
 * (cannot be silently granted, unlike a normal runtime permission).
 *
 * MainActivity's MethodChannel forwards calls here via the static
 * [instance] reference, since a MethodChannel lives on the Activity but
 * these actions need the live, OS-managed AccessibilityService instance.
 */
class WallEAccessibilityService : AccessibilityService() {
    companion object {
        var instance: WallEAccessibilityService? = null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance == this) instance = null
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    fun globalAction(action: String): Boolean {
        val code = when (action) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            else -> return false
        }
        return performGlobalAction(code)
    }

    /** Swipes from (x1,y1) to (x2,y2) over durationMs -- a tap is just a
     * zero-length swipe, so this single primitive covers both tap and
     * scroll/swipe gestures. */
    fun gesture(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long, callback: (Boolean) -> Unit) {
        val path = Path().apply {
            moveTo(x1, y1)
            lineTo(x2, y2)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs.coerceAtLeast(1))
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        val dispatched = dispatchGesture(
            gesture,
            object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    callback(true)
                }
                override fun onCancelled(gestureDescription: GestureDescription?) {
                    callback(false)
                }
            },
            null,
        )
        if (!dispatched) callback(false)
    }

    /** Dumps visible text from the current screen, one entry per line --
     * lets the agent act on what's actually there instead of guessing
     * coordinates blind. */
    fun screenText(): String {
        val root = rootInActiveWindow ?: return ""
        val lines = mutableListOf<String>()
        collectText(root, lines)
        return lines.joinToString("\n")
    }

    private fun collectText(node: AccessibilityNodeInfo, out: MutableList<String>, depth: Int = 0) {
        if (depth > 50) return // guard against pathological view trees
        val text = node.text?.toString()?.trim()
        val desc = node.contentDescription?.toString()?.trim()
        if (!text.isNullOrEmpty()) out.add(text)
        else if (!desc.isNullOrEmpty()) out.add(desc)
        for (i in 0 until node.childCount) {
            node.getChild(i)?.let { collectText(it, out, depth + 1) }
        }
    }

    /** Finds the first visible node whose text/description contains
     * [needle] (case-insensitive) and taps its center. Returns false if
     * nothing matched. */
    fun findAndTap(needle: String): Boolean {
        val root = rootInActiveWindow ?: return false
        val target = findNode(root, needle.lowercase()) ?: return false
        val bounds = android.graphics.Rect()
        target.getBoundsInScreen(bounds)
        val cx = bounds.exactCenterX()
        val cy = bounds.exactCenterY()
        var ok = false
        val latch = java.util.concurrent.CountDownLatch(1)
        gesture(cx, cy, cx, cy, 50) {
            ok = it
            latch.countDown()
        }
        latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
        return ok
    }

    private fun findNode(node: AccessibilityNodeInfo, needleLower: String, depth: Int = 0): AccessibilityNodeInfo? {
        if (depth > 50) return null
        val text = node.text?.toString()?.lowercase()
        val desc = node.contentDescription?.toString()?.lowercase()
        if ((text != null && text.contains(needleLower)) || (desc != null && desc.contains(needleLower))) {
            return node
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            findNode(child, needleLower, depth + 1)?.let { return it }
        }
        return null
    }
}
