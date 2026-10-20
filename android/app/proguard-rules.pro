# R8 rules for release builds. Most libraries ship their own consumer rules (Compose,
# coroutines, Play services, Mapbox); these are belt and braces for the ones that
# reach into classes by name.

# Mapbox's maps and common libraries call into Kotlin and Java classes from native code.
-keep class com.mapbox.** { *; }
-keep interface com.mapbox.** { *; }
-dontwarn com.mapbox.**

# kotlinx.serialization. Walkies reads and writes JsonElement trees rather than
# @Serializable classes, but keep the library's companions and serializers anyway.
-keepattributes *Annotation*, InnerClasses, Signature, EnclosingMethod
-dontnote kotlinx.serialization.**
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** { kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class kotlinx.serialization.** { *; }

# Stack traces in crash reports keep their line numbers.
-keepattributes SourceFile, LineNumberTable
-renamesourcefileattribute SourceFile

# Optional dependencies some libraries mention but Walkies doesn't ship. Without
# these, R8 can stop the build over classes that are never loaded.
-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-dontwarn org.slf4j.**
