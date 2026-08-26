# Pear Music ProGuard/R8 keep rules

# commons-compress for youtubedl-android
-keep class org.apache.commons.compress.archivers.zip.** { *; }
-dontwarn org.tukaani.xz.**

# Bundled yt-dlp engine + reflection-reachable classes
-keep class com.yausername.** { *; }

# audio_service & just_audio_background
-keep class com.ryanheise.** { *; }
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio.** { *; }
-keep class com.ryanheise.just_audio_background.** { *; }

# Flutter & embedding classes
-keep class com.peerm.peerm_app.** { *; }
