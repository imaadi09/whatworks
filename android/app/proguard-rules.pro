# Project ProGuard/R8 rules for the release build (isMinifyEnabled = true).
# These are ADDITIVE keep rules — they only prevent the shrinker from removing
# classes/attributes that are reached reflectively at runtime. Flutter's engine
# AAR already ships its own consumer rules, so nothing io.flutter.** is kept
# here (keeping it surfaces unused Play-Core deferred-component references).

# ── Gson / flutter_local_notifications ────────────────────────────────────────
# flutter_local_notifications persists scheduled notifications and action
# models as JSON via Gson reflection, using anonymous TypeToken<...> subclasses
# and no-arg model constructors. R8 strips the generic signature and the
# members, which throws at runtime:
#   "TypeToken must be created with a type argument: new TypeToken<...>() {}"
# Keep generic signatures + annotations so TypeToken resolves its type argument,
# and keep the plugin's own classes so its model fields survive shrinking.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes Exceptions

-keep class * extends com.google.gson.reflect.TypeToken
-keep,allowobfuscation class * extends com.google.gson.reflect.TypeToken

-keep class com.google.gson.** { *; }
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
-dontwarn com.google.gson.**

-keep class com.dexterous.** { *; }
-dontwarn com.dexterous.**

# Play Core (deferred components) classes are referenced by the Flutter
# embedding but are not on the compile classpath; suppress the missing-class
# notes so R8 does not treat them as errors.
-dontwarn com.google.android.play.core.**
