// Replacement for the upstream script that nixpkgs' flutter wrapper ships
// in packages/flutter_tools/gradle/src/main/scripts (see
// "gradle-flutter-tools-wrapper.patch" in nixpkgs' flutter packaging).
//
// Identical to upstream except for one change, marked NIX PATCH below:
// plugins that ship inside the read-only nix store SDK — every app with a
// dev dependency on integration_test pulls one in — are redirected into a
// writable per-user cache mirror before the compiled
// FlutterAppPluginLoaderPlugin turns their "path" into a Gradle project
// directory. Gradle >= 9 refuses to configure a project whose directory is
// not writable, so without the redirect any Android build (not just
// integration test runs) fails with
//
//     Configuring project ':integration_test' without an existing directory
//     is not allowed. The configured projectDirectory
//     '.../packages/integration_test/android' does not exist, can't be
//     written to or is not a directory.
//
// The mirror strategy is the one nixpkgs itself uses for the
// flutter_tools/gradle includeBuild: symlink every top-level entry of the
// plugin's android/ directory back into the store so sources stay
// store-managed, while the mirror directory itself stays writable for
// Gradle build outputs. The script is interpreted on every configure, so
// unlike the compiled Kotlin next to it, patching it has no cache
// invalidation concerns. Method and class names must stay stable: the
// compiled NativePluginLoaderReflectionBridge looks them up reflectively.
//
// Upstream source:
// packages/flutter_tools/gradle/src/main/scripts/native_plugin_loader.gradle.kts

import groovy.json.JsonSlurper
import java.io.File

// When changing the names of either
// 1. this file or
// 2. the names of the methods on this class
// be sure to also modify the corresponding values in ../kotlin/NativePluginLoaderReflectionBridge.kt
class NativePluginLoader {
    companion object {
        // This string must match _kFlutterPluginsHasNativeBuildKey defined in
        // packages/flutter_tools/lib/src/flutter_plugins.dart.
        const val NATIVE_BUILD_KEY = "native_build"
        const val FLUTTER_PLUGINS_DEPENDENCIES_FILE = ".flutter-plugins-dependencies"
    }

    /**
     * Gets the list of plugins that support the Android platform.
     * The list contains map elements with the following content:
     * {
     *     "name": "plugin-a",
     *     "path": "/path/to/plugin-a",
     *     "dependencies": ["plugin-b", "plugin-c"],
     *     "native_build": true
     *     "dev_dependency": false
     * }
     *
     * Therefore the map value can either be a `String`, a `List<String>` or a `Boolean`.
     */
    fun getPlugins(flutterSourceDirectory: File): List<Map<String, Any>> {
        val nativePlugins = mutableListOf<Map<String, Any>>()
        val meta = getDependenciesMetadata(flutterSourceDirectory)
        if (meta == null) {
            return nativePlugins
        }

        val pluginsMap: Map<*, *> = (meta["plugins"] as? Map<*, *>) ?: error("Metadata 'plugins' is not a Map: $meta")
        val androidPluginsUntyped = pluginsMap["android"]
        if (androidPluginsUntyped == null) {
            return nativePlugins // Return empty list if android plugins are not found
        }
        val androidPlugins = androidPluginsUntyped as? List<*> ?: error("Metadata 'plugins.android' is not a List: $meta")

        // Includes the Flutter plugins that support the Android platform.
        androidPlugins.forEach { androidPluginUntyped ->
            val androidPlugin = androidPluginUntyped as? Map<*, *> ?: error("androidPlugin is not a Map: $androidPluginUntyped")

            // The property types can be found in _filterPluginsByPlatform defined in
            // packages/flutter_tools/lib/src/flutter_plugins.dart.
            check(androidPlugin["name"] is String) { "androidPlugin 'name' is not a String: $androidPlugin" }
            check(androidPlugin["path"] is String) { "androidPlugin 'path' is not a String: $androidPlugin" }
            check(androidPlugin["dependencies"] is List<*>) { "androidPlugin 'dependencies' is not a List: $androidPlugin" }
            check(androidPlugin["dev_dependency"] is Boolean) { "androidPlugin 'dev_dependency' is not a Boolean: $androidPlugin" }

            // Skip plugins that have no native build (such as a Dart-only implementation
            // of a federated plugin).
            val needsBuild = androidPlugin[NATIVE_BUILD_KEY] as? Boolean ?: true
            if (needsBuild) {
                // NIX PATCH: replace read-only (nix store) plugin roots with a
                // writable mirror; see the header comment. Copy the map so the
                // parsed metadata stays pristine for other readers.
                @Suppress("UNCHECKED_CAST")
                val plugin = LinkedHashMap<String, Any>(androidPlugin as Map<String, Any>)
                plugin["path"] = writablePluginRoot(File(plugin["path"] as String)).absolutePath
                nativePlugins.add(plugin)
            }
        }
        return nativePlugins.toList() // Return immutable list
    }

    /**
     * NIX PATCH: Gradle >= 9 requires every project directory to be
     * writable, but plugins that live inside the nixpkgs flutter SDK
     * (integration_test) sit on a read-only store path. Mirror such a
     * plugin's android/ directory into the per-user Gradle cache,
     * symlinking each top-level entry back to the store: Gradle can then
     * write its build outputs inside the mirror while the plugin sources
     * remain store-managed. Plugins from the pub cache (or anywhere else
     * the user can write) pass through unchanged.
     */
    private fun writablePluginRoot(pluginRoot: File): File {
        val androidDir = File(pluginRoot, "android")
        if (androidDir.canWrite()) {
            return pluginRoot
        }
        // Keyed by the store path so a new SDK wrapper build gets a fresh
        // mirror instead of reusing links into a path that may have been
        // garbage-collected.
        val cacheKey = Integer.toHexString(pluginRoot.absolutePath.hashCode())
        val home = System.getenv("HOME") ?: System.getProperty("user.home")
        val mirrorRoot = File(
            File(home, ".cache/flutter/nix-flutter-plugin"),
            "${pluginRoot.name}-$cacheKey"
        )
        val mirrorAndroidDir = File(mirrorRoot, "android")
        mirrorAndroidDir.mkdirs()
        androidDir.listFiles()?.forEach { entry ->
            val link = File(mirrorAndroidDir, entry.name).toPath()
            // Recreate a missing or dangling link (e.g. after nix store gc);
            // never clobber a live one.
            if (!java.nio.file.Files.exists(link)) {
                java.nio.file.Files.deleteIfExists(link)
                try {
                    java.nio.file.Files.createSymbolicLink(link, entry.toPath())
                } catch (e: java.nio.file.FileAlreadyExistsException) {
                    // Lost a race with a concurrent Gradle configuration; the
                    // link the winner created serves the same purpose.
                }
            }
        }
        return mirrorRoot
    }

    private var parsedFlutterPluginsDependencies: Map<String, Any>? = null

    /**
     * Parses <project-src>/.flutter-plugins-dependencies
     */
    fun getDependenciesMetadata(flutterSourceDirectory: File): Map<String, Any>? {
        // Consider a `.flutter-plugins-dependencies` file with the following content:
        // {
        //     "plugins": {
        //       "android": [
        //         {
        //           "name": "plugin-a",
        //           "path": "/path/to/plugin-a",
        //           "dependencies": ["plugin-b", "plugin-c"],
        //           "native_build": true
        //           "dev_dependency": false
        //         },
        //         {
        //           "name": "plugin-b",
        //           "path": "/path/to/plugin-b",
        //           "dependencies": ["plugin-c"],
        //           "native_build": true
        //           "dev_dependency": false
        //         },
        //         {
        //           "name": "plugin-c",
        //           "path": "/path/to/plugin-c",
        //           "dependencies": [],
        //           "native_build": true
        //           "dev_dependency": false
        //         },
        //         {
        //           "name": "plugin-d",
        //           "path": "/path/to/plugin-d",
        //           "dependencies": [],
        //           "native_build": true
        //           "dev_dependency": true
        //         },
        //       ],
        //     },
        //     "dependencyGraph": [
        //       {
        //         "name": "plugin-a",
        //         "dependencies": ["plugin-b","plugin-c"]
        //       },
        //       {
        //         "name": "plugin-b",
        //         "dependencies": ["plugin-c"]
        //       },
        //       {
        //         "name": "plugin-c",
        //         "dependencies": []
        //       },
        //       {
        //         "name": "plugin-d",
        //         "dependencies": []
        //       }
        //     ]
        // }
        // This means, `plugin-a` depends on `plugin-b` and `plugin-c`.
        // `plugin-b` depends on `plugin-c`.
        // `plugin-c` doesn't depend on anything.
        // `plugin-d` also doesn't depend on anything, but it is a dev
        // dependency to the Flutter project, so it is marked as such.
        if (parsedFlutterPluginsDependencies != null) {
            return parsedFlutterPluginsDependencies
        }
        val pluginsDependencyFile = File(flutterSourceDirectory, FLUTTER_PLUGINS_DEPENDENCIES_FILE)
        if (pluginsDependencyFile.exists()) {
            val slurper = JsonSlurper()
            val readText = slurper.parseText(pluginsDependencyFile.readText())

            // Suppress the unchecked cast warning as we define the structure of the JSON in the tool.
            @Suppress("UNCHECKED_CAST")
            val parsedText =
                readText as? Map<String, Any>
                    ?: error("Parsed JSON is not a Map<String, Any>: $readText")
            parsedFlutterPluginsDependencies = parsedText
            return parsedText
        }
        return null
    }
}

extra["nativePluginLoader"] = NativePluginLoader()
