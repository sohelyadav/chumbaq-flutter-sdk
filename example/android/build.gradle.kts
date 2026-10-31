allprojects {
    repositories {
        google()
        mavenCentral()
        // Required so the example app can resolve the native chumbaq-android-sdk
        // modules that the plugin depends on. Before running the example, publish
        // the native SDK via:  (cd ../../chumbaq-android-sdk && ./gradlew publishToMavenLocal)
        mavenLocal()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
