group = "com.dyplink.dyplink"
version = "0.0.1"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
        mavenLocal()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        // Pulls the locally-published dyplink-android-sdk artifacts.
        //
        // DEV WORKFLOW: before running the example app or a consumer app,
        // publish the native SDK to ~/.m2 via:
        //
        //   cd ../../dyplink-android-sdk
        //   ./gradlew publishToMavenLocal
        //
        // Once dyplink-android-sdk is published to Maven Central this
        // mavenLocal() entry can be removed.
        mavenLocal()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "com.dyplink.dyplink"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()
                it.outputs.upToDateWhen { false }
                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

dependencies {
    // ── Native Dyplink SDK (pulled from mavenLocal during dev) ──────────────
    // See the `mavenLocal()` note above for publishing instructions.
    //
    // The group is `in.dyplink`, matching the native SDK's own
    // gradle.properties and its README. It used to be `com.dyplink`, and this
    // file kept asking for that long after the rename — which resolved anyway
    // on any machine that still had the pre-rename artifact in ~/.m2, so the
    // build went on compiling against a months-old copy of the SDK while
    // newer native APIs looked like they did not exist. A clean checkout just
    // failed to resolve.
    val dyplinkSdkVersion = "0.1.0"
    api("in.dyplink:dyplink-core:$dyplinkSdkVersion")
    api("in.dyplink:dyplink-push:$dyplinkSdkVersion")
    api("in.dyplink:dyplink-banners:$dyplinkSdkVersion")
    api("in.dyplink:dyplink-messages:$dyplinkSdkVersion")

    // ── Coroutines (needed to bridge suspend SDK methods into Pigeon callbacks)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // ── Firebase Messaging, compile-time only ───────────────────────────────
    // DyplinkFlutterMessagingService subclasses the push module's
    // DyplinkMessagingService, so FirebaseMessagingService has to resolve at
    // compile time. dyplink-push declares firebase-messaging as
    // `implementation`, which makes it runtime-scoped in the published POM —
    // present when the app runs, absent from this module's compile classpath.
    //
    // compileOnly and not implementation: the class is already on every
    // consumer's runtime classpath via dyplink-push, so asking for it again
    // would only risk a version conflict with the app's own Firebase BoM.
    // Keep this version in step with dyplink-push's.
    compileOnly("com.google.firebase:firebase-messaging:24.0.0")

    // ── Test ────────────────────────────────────────────────────────────────
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
    // firebase-messaging is compileOnly above, so it is absent from the test
    // runtime classpath — which makes DyplinkFlutterMessagingService
    // unloadable, and the token-refresh override untestable.
    testImplementation("com.google.firebase:firebase-messaging:24.0.0")
}
