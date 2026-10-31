group = "com.chumbaq.chumbaq"
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
        // Pulls the locally-published chumbaq-android-sdk artifacts.
        //
        // DEV WORKFLOW: before running the example app or a consumer app,
        // publish the native SDK to ~/.m2 via:
        //
        //   cd ../../chumbaq-android-sdk
        //   ./gradlew publishToMavenLocal
        //
        // Once chumbaq-android-sdk is published to Maven Central this
        // mavenLocal() entry can be removed.
        mavenLocal()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "com.chumbaq.chumbaq"

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
    // ── Native Chumbaq SDK (pulled from mavenLocal during dev) ──────────────
    // See the `mavenLocal()` note above for publishing instructions.
    //
    // The group is `in.chumbaq`, matching the native SDK's own
    // gradle.properties and its README. Keep the two in step: a stale group
    // here can still resolve on a machine with an old artifact in ~/.m2, so
    // the build silently compiles against an outdated copy of the SDK while
    // a clean checkout just fails to resolve.
    val chumbaqSdkVersion = "0.1.0"
    api("in.chumbaq:chumbaq-core:$chumbaqSdkVersion")
    api("in.chumbaq:chumbaq-push:$chumbaqSdkVersion")
    api("in.chumbaq:chumbaq-banners:$chumbaqSdkVersion")
    api("in.chumbaq:chumbaq-messages:$chumbaqSdkVersion")

    // ── Coroutines (needed to bridge suspend SDK methods into Pigeon callbacks)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // ── Firebase Messaging, compile-time only ───────────────────────────────
    // ChumbaqFlutterMessagingService subclasses the push module's
    // ChumbaqMessagingService, so FirebaseMessagingService has to resolve at
    // compile time. chumbaq-push declares firebase-messaging as
    // `implementation`, which makes it runtime-scoped in the published POM —
    // present when the app runs, absent from this module's compile classpath.
    //
    // compileOnly and not implementation: the class is already on every
    // consumer's runtime classpath via chumbaq-push, so asking for it again
    // would only risk a version conflict with the app's own Firebase BoM.
    // Keep this version in step with chumbaq-push's.
    compileOnly("com.google.firebase:firebase-messaging:24.0.0")

    // ── Test ────────────────────────────────────────────────────────────────
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
    // firebase-messaging is compileOnly above, so it is absent from the test
    // runtime classpath — which makes ChumbaqFlutterMessagingService
    // unloadable, and the token-refresh override untestable.
    testImplementation("com.google.firebase:firebase-messaging:24.0.0")
}
