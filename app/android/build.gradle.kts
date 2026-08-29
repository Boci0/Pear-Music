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
        // Defer to afterEvaluate so this compileSdk override wins over each plugin
        // module's own android { compileSdk ... } declaration. Without deferral,
        // file_picker (compileSdk 34) fails :checkReleaseAarMetadata because its
        // dependency flutter_plugin_android_lifecycle requires compileSdk 36+.
        afterEvaluate {
            val android = extensions.getByName("android") as com.android.build.gradle.BaseExtension
            android.compileSdkVersion(37)

            // Disable strict AAR/lint checks so plugins with known metadata issues
            // (e.g., earlier file_picker releases) still build and run correctly.
            android.lintOptions {
                isCheckReleaseBuilds = false
                disable("MissingDimensionActivityCreator")
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
