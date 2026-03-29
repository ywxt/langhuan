package org.eu.ywxt.langhuan

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
	private external fun initRustlsVerifier(context: Context)

	override fun onCreate(savedInstanceState: Bundle?) {
		initRustlsVerifier(applicationContext)
		super.onCreate(savedInstanceState)
	}

	companion object {
		init {
			System.loadLibrary("hub")
		}
	}
}
