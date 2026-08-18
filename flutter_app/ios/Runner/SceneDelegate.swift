import Flutter
import UIKit

/// Owns the window, whichever build path produced it.
///
/// None of this is guessable from the file it replaces (an empty
/// `FlutterSceneDelegate` subclass). Two different things build this app:
///
///  - **iosbox** (the Linux path) does not compile the `AppDelegate.swift`
///    next to this file. It substitutes its own, which runs an explicit
///    FlutterEngine and creates a window before any scene exists -- so that
///    window belongs to no UIWindowScene.
///  - **Xcode** compiles our thin AppDelegate, which creates no window at all.
///    `Main.storyboard` is wired to nothing (no `UIMainStoryboardFile`, no
///    `UISceneStoryboardFile`), so nothing instantiates a
///    FlutterViewController either.
///
/// `FlutterSceneDelegate` tries to rescue the first case by re-parenting the
/// FlutterViewController into a fresh scene window, but on iOS 18 UIKit
/// refuses the re-parent: the FlutterView attaches to nothing and the app runs
/// with a black screen and no error in any log. The second case is worse --
/// no FlutterViewController means no engine, so Dart never runs and the screen
/// stays black with no crash.
///
/// Both are handled explicitly below. Verified against the same code in
/// Amiga-Retro (`uae4arm2026p`), which is the app this pipeline is known to
/// launch correctly.
class SceneDelegate: FlutterSceneDelegate {

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // Cast to the concrete class, not the UIApplicationDelegate protocol:
    // `window` on the protocol existential is immutable, and it has to be
    // cleared below.
    if let windowScene = scene as? UIWindowScene,
       let appDelegate = UIApplication.shared.delegate as? FlutterAppDelegate,
       let existingWindow = appDelegate.window,
       existingWindow.rootViewController != nil {
      // The iosbox path. Attaching the scene is the part the app delegate
      // could not do: it ran before any scene existed.
      existingWindow.windowScene = windowScene

      // Resize as well as re-parent. The window was created before any scene
      // existed, so it carries whatever bounds UIScreen reported then, and
      // adopting it does not resize it: the content renders into the wrong
      // frame (measured: content confined to the left ~56% and anchored to the
      // bottom, with a visible seam down the middle) while the scene itself
      // correctly reports the full 834x1194.
      existingWindow.frame = windowScene.coordinateSpace.bounds

      self.window = existingWindow

      // Hides it from FlutterSceneDelegate's migration guard, which fires on
      // appDelegate.window.rootViewController being non-nil.
      appDelegate.window = nil
      existingWindow.makeKeyAndVisible()
    } else if let windowScene = scene as? UIWindowScene {
      // The Xcode path: nothing built a window, so build one here.
      //
      // Plugins are registered against this engine specifically. The
      // AppDelegate registers against itself, feeding the implicit engine --
      // a different registry, so this does not trip "Duplicate plugin key".
      let engine = FlutterEngine(name: "main")
      engine.run()
      GeneratedPluginRegistrant.register(with: engine)

      let window = UIWindow(windowScene: windowScene)
      window.rootViewController = FlutterViewController(
        engine: engine, nibName: nil, bundle: nil)
      self.window = window
      window.makeKeyAndVisible()
    }

    // Still call super: it registers the engine for scene life-cycle events,
    // which is how plugins receive them. It finds the FlutterViewController
    // through self.window.rootViewController, which is now correctly set.
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
}
