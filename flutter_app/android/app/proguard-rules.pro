# SDL's Java layer is reached from C, not from Dart or from Java, so R8's
# reachability analysis cannot see it.
#
# libSDL2.so's JNI_OnLoad resolves org.libsdl.app.SDLActivity's static methods
# by name with GetStaticMethodID and aborts the process if one is missing.
# R8 with only the default rules deletes the ones no Java caller reaches --
# `nativeGetVersion()` was the first casualty, and the app died at
# System.loadLibrary with:
#
#   NoSuchMethodError: no static or non-static method
#   "Lorg/libsdl/app/SDLActivity;.nativeGetVersion()Ljava/lang/String;"
#
# (`-keepclasseswithmembernames ... native <methods>` from the default
# configuration only stops *renaming*; it does not stop removal.)
#
# Keep the whole package, members included: the native side also calls back
# into SDLActivity/SDLAudioManager/SDLControllerManager/HIDDeviceManager.
-keep class org.libsdl.app.** { *; }
-keep interface org.libsdl.app.** { *; }
