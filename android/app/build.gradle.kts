plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.kjranyone.mymusicbook"
    // permission_handler_android 14.x が API 37 要求のため flutter.compileSdkVersion (36) から上書き
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.kjranyone.mymusicbook"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // flutter は --target-platform を指定しても abiFilters に全 ABI (arm/arm64/x64) を設定するため、
    // onnxruntime-android の他 ABI 用 .so (x86_64 20MB, armeabi-v7a 12MB) が APK に入ってしまう。
    // flutter が渡す -Ptarget-platform に含まれない ABI のネイティブライブラリを除外する。
    val flutterTargetPlatforms = (project.findProperty("target-platform") as String?)
        ?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }
    if (!flutterTargetPlatforms.isNullOrEmpty()) {
        val abiOf = mapOf(
            "android-arm" to "armeabi-v7a",
            "android-arm64" to "arm64-v8a",
            "android-x64" to "x86_64",
            "android-x86" to "x86",
        )
        val keep = flutterTargetPlatforms.mapNotNull { abiOf[it] }.toSet()
        if (keep.isNotEmpty()) {
            packaging {
                jniLibs {
                    for (abi in abiOf.values - keep) {
                        excludes += "lib/$abi/**"
                    }
                }
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// 紙面検出ネット (PaperNet) が dart:ffi で直接使う ORT のネイティブライブラリ
dependencies {
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.20.0")
}
