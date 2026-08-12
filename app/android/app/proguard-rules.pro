# Pear Music — ProGuard/R8 keep rules
#
# R8 minification was crashing the phone's "Add from link" downloads with:
#   FATAL EXCEPTION (pool-N-thread) ... ExceptionInInitializerError
#     at org.apache.commons.compress.archivers.zip.<clinit>
#   Caused by: RuntimeException: class org.apache.commons.compress.archivers.zip.a
#              is not a concrete class
#
# Root cause: the bundled yt-dlp engine (youtubedl-android) uses commons-compress
# to extract its native libs (libpython.zip.so / libffmpeg.zip.so) at
# YoutubeDL.getInstance().init() time. R8 renamed/removed those classes, so the
# zip static initializer could not resolve its concrete class and the download
# (and the app process) crashed. Keep the whole package so it is never minified.

# Only the `archivers.zip` package is needed (that is what the crash + the
# native-lib extraction use). Keeping the ENTIRE commons-compress package
# pulls in its 7z/xz code, which references the OPTIONAL org.tukaani.xz
# library that is not on the classpath -> R8 hard-fails ("Missing class
# org.tukaani.xz.*"). The zip package itself never references xz, so a
# targeted keep avoids both the original crash AND the build failure.
-keep class org.apache.commons.compress.archivers.zip.** { *; }

# Safety net: if any other retained commons-compress code happens to reference
# the optional xz classes, treat them as warnings rather than build errors.
-dontwarn org.tukaani.xz.**

# Keep the bundled yt-dlp engine + its reflection-reachable classes intact.
-keep class com.yausername.** { *; }
