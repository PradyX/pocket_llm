import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

val repoRootDir = rootProject.projectDir.parentFile
val llmfitAndroidArm64Asset = repoRootDir.resolve(
    "assets/tools/llmfit/android/arm64-v8a/llmfit"
)
val generatedLlmfitJniLibsDir = layout.buildDirectory.dir("generated/llmfit/jniLibs")
val llmfitAndroidArm64Source = providers.environmentVariable(
    "POCKET_LLMFIT_ANDROID_ARM64_SOURCE"
)

android {
    namespace = "com.prady.pocketllm"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.prady.pocketllm"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // safe casts so debug still builds even if key.properties is absent
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("release")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDir(generatedLlmfitJniLibsDir)
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}

tasks.register("bundleLlmfitAndroidArm64") {
    group = "llmfit"
    description = "Copies a prebuilt Android arm64 llmfit binary into Flutter assets."

    doLast {
        val sourcePath = llmfitAndroidArm64Source.orNull?.trim().orEmpty()
        if (llmfitAndroidArm64Asset.exists() && sourcePath.isEmpty()) {
            println(
                "bundleLlmfitAndroidArm64: using existing bundled asset at ${llmfitAndroidArm64Asset.absolutePath}"
            )
            return@doLast
        }

        if (sourcePath.isEmpty()) {
            println(
                "bundleLlmfitAndroidArm64: POCKET_LLMFIT_ANDROID_ARM64_SOURCE not set, skipping bundled Android llmfit copy."
            )
            return@doLast
        }

        val sourceFile = file(sourcePath)
        if (!sourceFile.exists()) {
            throw GradleException(
                "bundleLlmfitAndroidArm64: source binary not found at $sourcePath"
            )
        }

        llmfitAndroidArm64Asset.parentFile.mkdirs()
        sourceFile.copyTo(target = llmfitAndroidArm64Asset, overwrite = true)
        llmfitAndroidArm64Asset.setExecutable(true, false)

        println(
            "bundleLlmfitAndroidArm64: copied $sourcePath -> ${llmfitAndroidArm64Asset.absolutePath}"
        )
    }
}

tasks.register("syncLlmfitAndroidArm64JniLib") {
    group = "llmfit"
    description = "Copies the bundled Android arm64 llmfit binary into generated jniLibs."

    dependsOn("bundleLlmfitAndroidArm64")

    doLast {
        if (!llmfitAndroidArm64Asset.exists()) {
            println(
                "syncLlmfitAndroidArm64JniLib: bundled asset not found at ${llmfitAndroidArm64Asset.absolutePath}, skipping native library sync."
            )
            return@doLast
        }

        val targetFile = generatedLlmfitJniLibsDir.get().file(
            "arm64-v8a/libllmfit_cli.so"
        ).asFile
        targetFile.parentFile.mkdirs()
        llmfitAndroidArm64Asset.copyTo(target = targetFile, overwrite = true)
        targetFile.setExecutable(true, false)

        println(
            "syncLlmfitAndroidArm64JniLib: copied ${llmfitAndroidArm64Asset.absolutePath} -> ${targetFile.absolutePath}"
        )
    }
}

tasks.named("preBuild") {
    dependsOn("bundleLlmfitAndroidArm64")
    dependsOn("syncLlmfitAndroidArm64JniLib")
}
