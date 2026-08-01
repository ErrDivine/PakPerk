import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningProperties = Properties().apply {
    val protectedFile = rootProject.file("key.properties")
    if (protectedFile.exists()) {
        protectedFile.inputStream().use(::load)
    }
}

fun protectedSigningValue(property: String, environment: String): String? =
    (releaseSigningProperties.getProperty(property) ?: System.getenv(environment))
        ?.trim()
        ?.takeIf(String::isNotEmpty)

val releaseStoreFile = protectedSigningValue(
    "storeFile",
    "PAKPERK_ANDROID_STORE_FILE",
)
val releaseStorePassword = protectedSigningValue(
    "storePassword",
    "PAKPERK_ANDROID_STORE_PASSWORD",
)
val releaseKeyAlias = protectedSigningValue(
    "keyAlias",
    "PAKPERK_ANDROID_KEY_ALIAS",
)
val releaseKeyPassword = protectedSigningValue(
    "keyPassword",
    "PAKPERK_ANDROID_KEY_PASSWORD",
)
val releaseSigningValues = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
)
val hasReleaseSigning = releaseSigningValues.all { it != null }
val hasPartialReleaseSigning = releaseSigningValues.any { it != null } && !hasReleaseSigning
val releaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}

if (hasPartialReleaseSigning || (releaseTaskRequested && !hasReleaseSigning)) {
    throw GradleException(
        "Release builds require all protected Pakperk Android signing values. " +
            "Use untracked android/key.properties or the " +
            "PAKPERK_ANDROID_* environment variables.",
    )
}

android {
    namespace = "app.pakperk.pakperk"
    // Keep the store contract explicit. Flutter's defaults move with the SDK
    // and must not silently change the API levels of a signed candidate.
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.pakperk.pakperk"
        // Pakperk supports Android 7.0 and targets the current Play contract.
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Dedicated to the OIDC callback. Paper deep links continue to use
        // `pakperk://paper/...` and cannot consume authorization responses.
        manifestPlaceholders["appAuthRedirectScheme"] = "pakperk-auth-dev"
        manifestPlaceholders["appDisplayName"] = "PakPerk Dev"
        manifestPlaceholders["appLinkScheme"] = "http"
        manifestPlaceholders["appLinkHost"] = "localhost"
        manifestPlaceholders["appLinkAutoVerify"] = "false"
    }

    flavorDimensions += "environment"
    productFlavors {
        create("dev") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            manifestPlaceholders["appAuthRedirectScheme"] = "pakperk-auth-dev"
            manifestPlaceholders["appDisplayName"] = "PakPerk Dev"
            manifestPlaceholders["appLinkScheme"] = "http"
            manifestPlaceholders["appLinkHost"] = "localhost"
            manifestPlaceholders["appLinkAutoVerify"] = "false"
        }
        create("staging") {
            dimension = "environment"
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-staging"
            manifestPlaceholders["appAuthRedirectScheme"] =
                "pakperk-auth-staging"
            manifestPlaceholders["appDisplayName"] = "PakPerk Staging"
            manifestPlaceholders["appLinkScheme"] = "https"
            manifestPlaceholders["appLinkHost"] = "staging.pakperk.app"
            manifestPlaceholders["appLinkAutoVerify"] = "true"
        }
        create("prod") {
            dimension = "environment"
            manifestPlaceholders["appAuthRedirectScheme"] = "pakperk-auth"
            manifestPlaceholders["appDisplayName"] = "PakPerk"
            manifestPlaceholders["appLinkScheme"] = "https"
            manifestPlaceholders["appLinkHost"] = "pakperk.app"
            manifestPlaceholders["appLinkAutoVerify"] = "true"
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
                enableV4Signing = true
            }
        }
    }

    buildTypes {
        release {
            // Release credentials live only in protected CI variables or an
            // untracked local key.properties file. Debug keys are never used.
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
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
