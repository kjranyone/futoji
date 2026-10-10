import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerOrtBridge(engineBridge.pluginRegistry)
  }

  /// iOS の ORT は静的リンクで dart:ffi から開けないため、OrtGetApiBase() の
  /// 戻り値アドレスを Dart (lib/services/ort_ffi.dart の preparePlatform) に渡す。
  /// ここで関数を呼ぶことでリンカに ORT を確実に取り込ませる役目もある。
  private func registerOrtBridge(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "OrtBridge") else { return }
    let channel = FlutterMethodChannel(
      name: "futoji/ort", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "apiBase" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(Int(bitPattern: OrtGetApiBase()))
    }
  }
}
