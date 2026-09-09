package com.bilalsafdar.godot.mobileservices.core

import org.godotengine.godot.Dictionary
import org.json.JSONArray
import org.json.JSONObject

/**
 * The serialiser both directions of the JNI boundary agree on.
 *
 * Everything structured in this SDK — a purchase, an ad's revenue, the Remote
 * Config snapshot — crosses as a JSON string rather than as a marshalled
 * object. See [MobileServicesPlugin]'s rule 3 for why.
 *
 * `org.json` rather than a library: it is in the Android platform, so it adds
 * nothing to the app, and this SDK's payloads are a dozen flat keys.
 */
object Json {

	/** An object builder that skips nulls, so a missing field is absent rather
	 * than the string "null" for GDScript to guess at. */
	fun obj(vararg pairs: Pair<String, Any?>): JSONObject {
		val json = JSONObject()
		for ((key, value) in pairs) {
			if (value != null) {
				json.put(key, value)
			}
		}
		return json
	}

	fun string(vararg pairs: Pair<String, Any?>): String = obj(*pairs).toString()

	fun array(items: List<JSONObject>): String {
		val json = JSONArray()
		for (item in items) {
			json.put(item)
		}
		return json.toString()
	}

	/** A flat map as a JSON object. Values keep their own types. */
	fun fromMap(values: Map<String, Any?>): String {
		val json = JSONObject()
		for ((key, value) in values) {
			if (value != null) {
				json.put(key, value)
			}
		}
		return json.toString()
	}

	/**
	 * Parses a JSON object into a flat map, never throwing.
	 *
	 * Malformed input answers an empty map: the callers are all "what did
	 * GDScript ask for", and a half-read configuration is worse than none.
	 */
	fun toMap(text: String?): Map<String, Any> {
		if (text.isNullOrBlank()) return emptyMap()
		return try {
			val json = JSONObject(text)
			val out = LinkedHashMap<String, Any>()
			for (key in json.keys()) {
				val value = json.get(key)
				if (value != JSONObject.NULL) {
					out[key] = value
				}
			}
			out
		} catch (error: Throwable) {
			emptyMap()
		}
	}

	/** Parses a JSON array of objects, never throwing. */
	fun toList(text: String?): List<Map<String, Any>> {
		if (text.isNullOrBlank()) return emptyList()
		return try {
			val array = JSONArray(text)
			val out = ArrayList<Map<String, Any>>(array.length())
			for (index in 0 until array.length()) {
				out.add(toMap(array.getJSONObject(index).toString()))
			}
			out
		} catch (error: Throwable) {
			emptyList()
		}
	}

	/**
	 * Godot's `Dictionary` as a flat map of its string keys.
	 *
	 * `Dictionary` is a `HashMap<String, Object>` carrying whatever Variant
	 * types the caller put in, which is exactly what the analytics bridge wants
	 * to iterate.
	 */
	fun fromGodot(dictionary: Dictionary): Map<String, Any?> = dictionary
}
