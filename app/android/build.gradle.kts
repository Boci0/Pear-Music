allprojects {
    repositories {
        google()
        mavenCentral()
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

// Force all plugin subprojects to compile against the same SDK level as :app.
// Prevents AAR metadata failures when a transitive dependency (e.g.
// flutter_plugin_android_lifecycle) requires a higher compileSdk than
// a plugin (e.g. file_picker) declares.
// Uses plugins.withId instead of afterEvaluate to avoid "already evaluated" errors.
subprojects {
    plugins.withId("com.android.library") {
        val android = extensions.getByName("android") as com.android.build.gradle.BaseExtension
        android.compileSdkVersion(37)
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
