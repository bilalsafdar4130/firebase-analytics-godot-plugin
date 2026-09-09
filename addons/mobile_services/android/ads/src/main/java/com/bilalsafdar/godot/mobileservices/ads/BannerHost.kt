package com.bilalsafdar.godot.mobileservices.ads

import android.app.Activity
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout

/**
 * Where a banner view actually lives on screen.
 *
 * A Godot game is one `GLSurfaceView` filling the window, so a banner has to go
 * into a container of its own laid over it. `addContentView` puts a view into
 * the activity's content frame — above the engine's surface, below the system
 * bars — which is where every Android game's banner goes.
 *
 * ONE CONTAINER PER PLACEMENT, kept in a map, so a game with a menu banner and a
 * gameplay banner can show, hide and destroy them independently. Hiding sets
 * visibility rather than detaching: the ad keeps refreshing, which is what the
 * networks expect and what a game switching between two screens wants.
 *
 * `fitsSystemWindows` keeps the banner clear of a gesture bar or a notch — Godot
 * draws edge to edge, so without it a bottom banner sits under the navigation
 * bar and takes taps that were meant for it.
 */
internal class BannerHost(private val activity: Activity) {

	private val containers = HashMap<String, FrameLayout>()

	fun attach(placement: String, view: View, position: String) {
		detach(placement)
		val container = FrameLayout(activity)
		container.fitsSystemWindows = true
		val gravity = if (position == "top") {
			Gravity.TOP or Gravity.CENTER_HORIZONTAL
		} else {
			Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
		}
		container.addView(
			view,
			FrameLayout.LayoutParams(
				ViewGroup.LayoutParams.WRAP_CONTENT,
				ViewGroup.LayoutParams.WRAP_CONTENT,
				gravity
			)
		)
		activity.addContentView(
			container,
			FrameLayout.LayoutParams(
				ViewGroup.LayoutParams.MATCH_PARENT,
				ViewGroup.LayoutParams.MATCH_PARENT
			)
		)
		containers[placement] = container
	}

	fun setVisible(placement: String, visible: Boolean) {
		containers[placement]?.visibility = if (visible) View.VISIBLE else View.GONE
	}

	/** Takes the container out of the window. The AD OBJECT inside it is the
	 * provider's to destroy — this only owns the layout. */
	fun detach(placement: String) {
		val container = containers.remove(placement) ?: return
		container.removeAllViews()
		(container.parent as? ViewGroup)?.removeView(container)
	}

	fun detachAll() {
		for (placement in containers.keys.toList()) {
			detach(placement)
		}
	}
}
