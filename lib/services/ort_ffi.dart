// 構造体のプレースホルダスロットは vtable 整列用のため未使用警告を抑止
// ignore_for_file: unused_field, unused_element

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

// C API の関数名はヘッダどおりの PascalCase を維持するため lint を抑止
// ignore_for_file: non_constant_identifier_names, library_private_types_in_public_api

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show MethodChannel;

import 'detector.dart';

/// ONNX Runtime C API の dart:ffi 直接バインディング (TinyUNet 推論専用の最小セット)。
///
/// flutter_onnxruntime は Java/JNI 経由で ORT を呼ぶが、その JNI 変換層が
/// リリースビルド (AOT) で `java_class == null` (SIGABRT) することがあるため、
/// Java 層を経由しない C API を直接叩く。ネイティブライブラリ自体は
/// onnxruntime-android (Maven) が同梱する libonnxruntime4jni.so を使う。
///
/// OrtApi は「関数ポインタの vtable」。順序は公式ヘッダ (v1.20) の宣言順で固定され、
/// 未使用スロットも 8 バイトのポインタとして数える必要がある。
/// 使用するインデックス (tools/ort_c_api.h から抽出・検証済み):
///   GetErrorMessage=2, CreateEnv=3, CreateSessionFromArray=8, Run=9,
///   CreateTensorWithDataAsOrtValue=49, GetTensorMutableData=51,
///   CreateCpuMemoryInfo=69, ReleaseEnv=92, ReleaseStatus=93,
///   ReleaseMemoryInfo=94, ReleaseSession=95, ReleaseValue=96

// OrtApi スロット 0..69 (未使用スロットはプレースホルダ)
final class OrtApiStruct extends Struct {
  // --- 0: CreateStatus ---
  external Pointer<NativeFunction<Void Function()>> _slot0;
  // --- 1: GetErrorCode ---
  external Pointer<NativeFunction<Void Function()>> _slot1;
  // --- 2: GetErrorMessage ---
  external Pointer<
          NativeFunction<Pointer<Uint8> Function(Pointer<Void>)>>
      GetErrorMessage;
  // --- 3: CreateEnv ---
  external Pointer<
          NativeFunction<
              Pointer<Void> Function(
                  Int32, Pointer<Uint8>, Pointer<Pointer<Void>>)>>
      CreateEnv;
  // --- 4: CreateEnvWithCustomLogger ---
  external Pointer<NativeFunction<Void Function()>> _slot4;
  // --- 5: EnableTelemetryEvents ---
  external Pointer<NativeFunction<Void Function()>> _slot5;
  // --- 6: DisableTelemetryEvents ---
  external Pointer<NativeFunction<Void Function()>> _slot6;
  // --- 7: CreateSession ---
  external Pointer<NativeFunction<Void Function()>> _slot7;
  // --- 8: CreateSessionFromArray ---
  external Pointer<
          NativeFunction<
              Pointer<Void> Function(
                  Pointer<Void>,
                  Pointer<Uint8>,
                  IntPtr,
                  Pointer<Void>,
                  Pointer<Pointer<Void>>)>>
      CreateSessionFromArray;
  // --- 9: Run ---
  external Pointer<
          NativeFunction<
              Pointer<Void> Function(
                  Pointer<Void>,
                  Pointer<Void>,
                  Pointer<Pointer<Uint8>>,
                  Pointer<Pointer<Void>>,
                  IntPtr,
                  Pointer<Pointer<Uint8>>,
                  IntPtr,
                  Pointer<Pointer<Void>>)>>
      Run;
  // --- 10..48: 未使用 ---
  external Pointer<NativeFunction<Void Function()>> _slot10;
  external Pointer<NativeFunction<Void Function()>> _slot11;
  external Pointer<NativeFunction<Void Function()>> _slot12;
  external Pointer<NativeFunction<Void Function()>> _slot13;
  external Pointer<NativeFunction<Void Function()>> _slot14;
  external Pointer<NativeFunction<Void Function()>> _slot15;
  external Pointer<NativeFunction<Void Function()>> _slot16;
  external Pointer<NativeFunction<Void Function()>> _slot17;
  external Pointer<NativeFunction<Void Function()>> _slot18;
  external Pointer<NativeFunction<Void Function()>> _slot19;
  external Pointer<NativeFunction<Void Function()>> _slot20;
  external Pointer<NativeFunction<Void Function()>> _slot21;
  external Pointer<NativeFunction<Void Function()>> _slot22;
  external Pointer<NativeFunction<Void Function()>> _slot23;
  external Pointer<NativeFunction<Void Function()>> _slot24;
  external Pointer<NativeFunction<Void Function()>> _slot25;
  external Pointer<NativeFunction<Void Function()>> _slot26;
  external Pointer<NativeFunction<Void Function()>> _slot27;
  external Pointer<NativeFunction<Void Function()>> _slot28;
  external Pointer<NativeFunction<Void Function()>> _slot29;
  external Pointer<NativeFunction<Void Function()>> _slot30;
  external Pointer<NativeFunction<Void Function()>> _slot31;
  external Pointer<NativeFunction<Void Function()>> _slot32;
  external Pointer<NativeFunction<Void Function()>> _slot33;
  external Pointer<NativeFunction<Void Function()>> _slot34;
  external Pointer<NativeFunction<Void Function()>> _slot35;
  external Pointer<NativeFunction<Void Function()>> _slot36;
  external Pointer<NativeFunction<Void Function()>> _slot37;
  external Pointer<NativeFunction<Void Function()>> _slot38;
  external Pointer<NativeFunction<Void Function()>> _slot39;
  external Pointer<NativeFunction<Void Function()>> _slot40;
  external Pointer<NativeFunction<Void Function()>> _slot41;
  external Pointer<NativeFunction<Void Function()>> _slot42;
  external Pointer<NativeFunction<Void Function()>> _slot43;
  external Pointer<NativeFunction<Void Function()>> _slot44;
  external Pointer<NativeFunction<Void Function()>> _slot45;
  external Pointer<NativeFunction<Void Function()>> _slot46;
  external Pointer<NativeFunction<Void Function()>> _slot47;
  external Pointer<NativeFunction<Void Function()>> _slot48;
  // --- 49: CreateTensorWithDataAsOrtValue ---
  external Pointer<
          NativeFunction<
              Pointer<Void> Function(
                  Pointer<Void>,
                  Pointer<Void>,
                  IntPtr,
                  Pointer<Int64>,
                  IntPtr,
                  Int32,
                  Pointer<Pointer<Void>>)>>
      CreateTensorWithDataAsOrtValue;
  // --- 50: CreateTensorAsOrtValue ---
  external Pointer<NativeFunction<Void Function()>> _slot50;
  // --- 51: GetTensorMutableData ---
  external Pointer<
          NativeFunction<
              Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Float>>)>>
      GetTensorMutableData;
  // --- 52..68: 未使用 ---
  external Pointer<NativeFunction<Void Function()>> _slot52;
  external Pointer<NativeFunction<Void Function()>> _slot53;
  external Pointer<NativeFunction<Void Function()>> _slot54;
  external Pointer<NativeFunction<Void Function()>> _slot55;
  external Pointer<NativeFunction<Void Function()>> _slot56;
  external Pointer<NativeFunction<Void Function()>> _slot57;
  external Pointer<NativeFunction<Void Function()>> _slot58;
  external Pointer<NativeFunction<Void Function()>> _slot59;
  external Pointer<NativeFunction<Void Function()>> _slot60;
  external Pointer<NativeFunction<Void Function()>> _slot61;
  external Pointer<NativeFunction<Void Function()>> _slot62;
  external Pointer<NativeFunction<Void Function()>> _slot63;
  external Pointer<NativeFunction<Void Function()>> _slot64;
  external Pointer<NativeFunction<Void Function()>> _slot65;
  external Pointer<NativeFunction<Void Function()>> _slot66;
  external Pointer<NativeFunction<Void Function()>> _slot67;
  external Pointer<NativeFunction<Void Function()>> _slot68;
  // --- 69: CreateCpuMemoryInfo ---
  external Pointer<
          NativeFunction<
              Pointer<Void> Function(Int32, Int32, Pointer<Pointer<Void>>)>>
      CreateCpuMemoryInfo;
  // --- 70..91: 未使用 ---
  external Pointer<NativeFunction<Void Function()>> _slot70;
  external Pointer<NativeFunction<Void Function()>> _slot71;
  external Pointer<NativeFunction<Void Function()>> _slot72;
  external Pointer<NativeFunction<Void Function()>> _slot73;
  external Pointer<NativeFunction<Void Function()>> _slot74;
  external Pointer<NativeFunction<Void Function()>> _slot75;
  external Pointer<NativeFunction<Void Function()>> _slot76;
  external Pointer<NativeFunction<Void Function()>> _slot77;
  external Pointer<NativeFunction<Void Function()>> _slot78;
  external Pointer<NativeFunction<Void Function()>> _slot79;
  external Pointer<NativeFunction<Void Function()>> _slot80;
  external Pointer<NativeFunction<Void Function()>> _slot81;
  external Pointer<NativeFunction<Void Function()>> _slot82;
  external Pointer<NativeFunction<Void Function()>> _slot83;
  external Pointer<NativeFunction<Void Function()>> _slot84;
  external Pointer<NativeFunction<Void Function()>> _slot85;
  external Pointer<NativeFunction<Void Function()>> _slot86;
  external Pointer<NativeFunction<Void Function()>> _slot87;
  external Pointer<NativeFunction<Void Function()>> _slot88;
  external Pointer<NativeFunction<Void Function()>> _slot89;
  external Pointer<NativeFunction<Void Function()>> _slot90;
  external Pointer<NativeFunction<Void Function()>> _slot91;
  // --- 92: ReleaseEnv ---
  external Pointer<NativeFunction<Void Function(Pointer<Void>)>> ReleaseEnv;
  // --- 93: ReleaseStatus ---
  external Pointer<NativeFunction<Void Function(Pointer<Void>)>> ReleaseStatus;
  // --- 94: ReleaseMemoryInfo ---
  external Pointer<NativeFunction<Void Function(Pointer<Void>)>>
      ReleaseMemoryInfo;
  // --- 95: ReleaseSession ---
  external Pointer<NativeFunction<Void Function(Pointer<Void>)>> ReleaseSession;
  // --- 96: ReleaseValue ---
  external Pointer<NativeFunction<Void Function(Pointer<Void>)>> ReleaseValue;
}

final class OrtApiBaseStruct extends Struct {
  external Pointer<
          NativeFunction<Pointer<OrtApiStruct> Function(Uint32)>>
      GetApi;
  external Pointer<Pointer<Uint8>> GetVersionString;
}

/// セッション一式 (ロード後に PaperNet が保持する)。
/// セッションの実行設定 (スレッド数・実行プロバイダ)。null 項目は ORT の既定。
class OrtSessionConfig {
  const OrtSessionConfig({
    this.intraOpThreads = 0,
    this.executionProvider,
    this.providerOptions = const <String, String>{},
    this.configEntries = const <String, String>{},
  });

  /// 演算内の並列スレッド数 (0 = ORT の既定 = 物理コア数)。
  final int intraOpThreads;

  /// 例: 'XNNPACK'。Android の onnxruntime-android に同梱されている。
  final String? executionProvider;
  final Map<String, String> providerOptions;

  /// 例: {'session.intra_op.allow_spinning': '0'}
  final Map<String, String> configEntries;

  @override
  String toString() => 'threads=$intraOpThreads ep=${executionProvider ?? 'cpu'}'
      '${providerOptions.isEmpty ? '' : ' $providerOptions'}';
}

class OrtSessionBundle {
  OrtSessionBundle({
    required this.api,
    required this.bindings,
    required this.env,
    required this.session,
    required this.memoryInfo,
    required this.inputTensor,
    required this.inputData,
    required this.outputTensor,
    required this.outputData,
    required this.inputNamePtr,
    required this.outputNamePtr,
    this.inputChannels = 1,
  });

  final Pointer<OrtApiStruct> api;
  final OrtApiBindings bindings;
  final Pointer<Void> env;
  final Pointer<Void> session;
  final Pointer<Void> memoryInfo;
  final Pointer<Void> inputTensor;

  /// 入力データ (float32、createSessionBundle の inputShape 分)。推論ごとに上書きする。
  final Pointer<Float> inputData;
  final Pointer<Void> outputTensor;

  /// 出力データ (float32、outputShape 分)。Run がここに書き込む。
  final Pointer<Float> outputData;
  final Pointer<Uint8> inputNamePtr;
  final Pointer<Uint8> outputNamePtr;

  /// 入力のチャネル数 (NCHW の C)。紙面検出ネットは 1 (灰色) か 3 (RGB)。
  final int inputChannels;

  /// ネイティブ資源をすべて解放する (使い捨てのセッション用。以後この bundle は使えない)。
  void release() {
    bindings.releaseValue(inputTensor);
    bindings.releaseValue(outputTensor);
    bindings.releaseSession(session);
    bindings.releaseMemoryInfo(memoryInfo);
    bindings.releaseEnv(env);
    calloc.free(inputData);
    calloc.free(outputData);
    malloc.free(inputNamePtr); // toNativeUtf8 は malloc で確保される
    malloc.free(outputNamePtr);
  }

  /// 入力バッファ (float32) への書き込み。
  void writeInputValue(int index, double value) {
    inputData[index] = value;
  }

  /// 出力バッファ (float32) からの読み取り。
  double readOutputValue(int index) => outputData[index];

  /// 画像から紙の四隅 (正規化座標 [TL,TR,BR,BL] の平坦リスト) を検出する。
  /// 紙が見つからない (マスクが空/全面/形が崩壊) 場合は null。
  ///
  /// [pixels] は 1 画素 [channels] バイトの行優先の画素列 (1: 灰色、3: RGB、4: RGBA)。
  /// モデルの入力 ([inputChannels]) に合わせて、灰色のモデルには輝度 (BT.601) を、
  /// RGB のモデルには RGB を渡す (灰色の画像を RGB のモデルに渡すと R=G=B)。
  ///
  /// このメソッド内で ffi のポインタ拡張を使用するため、
  /// dart:isolate や camera を import しているファイルからは呼ばないこと
  /// (拡張メンバの解決が壊れる)。
  ///
  /// アプリの全経路 (切り抜き画面・撮影直後の自動判定・ライブ検出ワーカー) と
  /// 評価ハーネス (test/paper_net_eval_test.dart) が共通で使う唯一の実装。
  /// [onDebug] には推論後の (入力, 2 値マスク, 穴埋め後マスク, マスク面積比) を渡す
  /// (入力は NCHW。RGB のモデルでは先頭の 256x256 が R)。
  List<double>? detectPaperQuad(
    Uint8List pixels,
    int w,
    int h, {
    int channels = 1,
    void Function(Float32List input, Uint8List mask, Uint8List filled,
            double fill)?
        onDebug,
    double pad = DocumentDetector.netCornerPad,
    int openRadius = DocumentDetector.netMaskOpenRadius,
    bool refineEdges = true,
    double minMaskQuadIoU = DocumentDetector.netMinMaskQuadIoU,
    void Function(double maskQuadIoU)? onAgreement,
  }) {
    const elements = 256 * 256;
    final modelChannels = inputChannels;
    final input = inputData.asTypedList(elements * modelChannels);
    final scaleX = w / 256;
    final scaleY = h / 256;
    // 画素 i のチャネル c の値。灰色のモデルには輝度、灰色の画像は全チャネル同じ値
    double value(int i, int c) {
      final base = i * channels;
      if (modelChannels == 1 && channels >= 3) {
        return (pixels[base] * 299 + pixels[base + 1] * 587 + pixels[base + 2] * 114) /
            1000;
      }
      return pixels[base + (channels == 1 ? 0 : c)].toDouble();
    }

    for (int y = 0; y < 256; y++) {
      final sy = (y + 0.5) * scaleY - 0.5;
      final y0 = sy.floor().clamp(0, h - 1);
      final y1 = (y0 + 1).clamp(0, h - 1);
      final fy = (sy - y0).clamp(0.0, 1.0);
      final row0 = y0 * w;
      final row1 = y1 * w;
      for (int x = 0; x < 256; x++) {
        final sx = (x + 0.5) * scaleX - 0.5;
        final x0 = sx.floor().clamp(0, w - 1);
        final x1 = (x0 + 1).clamp(0, w - 1);
        final fx = (sx - x0).clamp(0.0, 1.0);
        for (int c = 0; c < modelChannels; c++) {
          final p00 = value(row0 + x0, c);
          final p10 = value(row0 + x1, c);
          final p01 = value(row1 + x0, c);
          final p11 = value(row1 + x1, c);
          final top = p00 + (p10 - p00) * fx;
          final bottom = p01 + (p11 - p01) * fx;
          input[c * elements + y * 256 + x] =
              ((top + (bottom - top) * fy) / 255.0).clamp(0.0, 1.0);
        }
      }
    }
    bindings.runSimple(this);

    final output = outputData.asTypedList(elements);
    var maskSum = 0;
    final mask = Uint8List(elements);
    for (int i = 0; i < elements; i++) {
      if (output[i] > 0) {
        mask[i] = 255;
        maskSum++;
      }
    }
    if (!DocumentDetector.isPlausiblePaperMask(maskSum, elements)) {
      onDebug?.call(input, mask, mask, maskSum / elements);
      return null; // 紙なし
    }
    final filled = DocumentDetector.openMask(
        DocumentDetector.fillHoles(mask, 256, 256), 256, 256, openRadius);
    onDebug?.call(input, mask, filled, maskSum / elements);
    final quad = DocumentDetector.detectLuminance(
        filled, 256, 256,
        workWidth: 256,
        paperChecks: false,
        pad: pad,
        refineEdges: refineEdges);
    if (quad == null) return null;
    // まだらなマスク (絵や柄の取り違え) は四角形を埋めないので紙とみなさない
    final agreement = DocumentDetector.maskQuadIoU(filled, 256, 256, quad);
    onAgreement?.call(agreement);
    if (agreement < minMaskQuadIoU) return null;
    return <double>[
      for (final c in quad) ...<double>[c.dx, c.dy],
    ];
  }
}

typedef _CreateEnvDart = Pointer<Void> Function(
    int, Pointer<Uint8>, Pointer<Pointer<Void>>);
typedef _CreateSessionFromArrayDart = Pointer<Void> Function(
    Pointer<Void>,
    Pointer<Uint8>,
    int,
    Pointer<Void>,
    Pointer<Pointer<Void>>);
typedef _RunDart = Pointer<Void> Function(
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Pointer<Uint8>>,
    Pointer<Pointer<Void>>,
    int,
    Pointer<Pointer<Uint8>>,
    int,
    Pointer<Pointer<Void>>);
typedef _CreateTensorDart = Pointer<Void> Function(
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<Int64>,
    int,
    int,
    Pointer<Pointer<Void>>);
typedef _GetTensorDataDart = Pointer<Void> Function(
    Pointer<Void>, Pointer<Pointer<Float>>);
typedef _CreateMemInfoDart = Pointer<Void> Function(
    int, int, Pointer<Pointer<Void>>);
typedef _ReleaseDart = void Function(Pointer<Void>);
typedef _ReleaseNative = Void Function(Pointer<Void>);
typedef _CreateOptionsNative = Pointer<Void> Function(Pointer<Pointer<Void>>);
typedef _CreateOptionsDart = Pointer<Void> Function(Pointer<Pointer<Void>>);
typedef _SetThreadsNative = Pointer<Void> Function(Pointer<Void>, Int32);
typedef _SetThreadsDart = Pointer<Void> Function(Pointer<Void>, int);
typedef _AddConfigNative = Pointer<Void> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _AddConfigDart = Pointer<Void> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _AppendEpNative = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>, Size);
typedef _AppendEpDart = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>, int);
typedef _GetErrorDart = Pointer<Uint8> Function(Pointer<Void>);

/// OrtApi の関数群を Dart から呼びやすい形にまとめたもの。
class OrtApiBindings {
  OrtApiBindings._(this.api);

  final Pointer<OrtApiStruct> api;

  late final _CreateEnvDart createEnv =
      api.ref.CreateEnv.asFunction<_CreateEnvDart>();
  late final _CreateSessionFromArrayDart createSessionFromArray = api
      .ref.CreateSessionFromArray
      .asFunction<_CreateSessionFromArrayDart>();
  late final _RunDart runFn = api.ref.Run.asFunction<_RunDart>();
  late final _CreateTensorDart createTensor = api
      .ref.CreateTensorWithDataAsOrtValue
      .asFunction<_CreateTensorDart>();
  late final _GetTensorDataDart getTensorData =
      api.ref.GetTensorMutableData.asFunction<_GetTensorDataDart>();
  late final _CreateMemInfoDart createCpuMemoryInfo =
      api.ref.CreateCpuMemoryInfo.asFunction<_CreateMemInfoDart>();
  late final _ReleaseDart releaseEnv =
      api.ref.ReleaseEnv.asFunction<_ReleaseDart>();
  late final _ReleaseDart releaseSession =
      api.ref.ReleaseSession.asFunction<_ReleaseDart>();
  late final _ReleaseDart releaseMemoryInfo =
      api.ref.ReleaseMemoryInfo.asFunction<_ReleaseDart>();
  late final _ReleaseDart releaseStatus =
      api.ref.ReleaseStatus.asFunction<_ReleaseDart>();
  late final _ReleaseDart releaseValue =
      api.ref.ReleaseValue.asFunction<_ReleaseDart>();
  late final _GetErrorDart getErrorMessage =
      api.ref.GetErrorMessage.asFunction<_GetErrorDart>();

  // ---- セッションオプション (構造体に並べていない後方のスロットは番号で引く) ----
  // 番号は tools/ort_c_api.h (v1.20) の宣言順。既知の番号 (Run=9, ReleaseEnv=92 など) と
  // 同じ数え方で確認済み。
  Pointer<NativeFunction<T>> _slot<T extends Function>(int index) =>
      api.cast<Pointer<NativeFunction<T>>>()[index];

  late final _CreateOptionsDart createSessionOptions =
      _slot<_CreateOptionsNative>(10).asFunction<_CreateOptionsDart>();
  late final _SetThreadsDart setIntraOpNumThreads =
      _slot<_SetThreadsNative>(24).asFunction<_SetThreadsDart>();
  late final _ReleaseDart releaseSessionOptions =
      _slot<_ReleaseNative>(100).asFunction<_ReleaseDart>();
  late final _AddConfigDart addSessionConfigEntry =
      _slot<_AddConfigNative>(130).asFunction<_AddConfigDart>();
  late final _AppendEpDart appendExecutionProvider =
      _slot<_AppendEpNative>(216).asFunction<_AppendEpDart>();

  /// iOS: AppDelegate が返す `OrtGetApiBase()` のアドレス ([preparePlatform] で取得)。
  /// iOS の ORT (CocoaPods onnxruntime-c) は静的リンクで .so が無く、シンボルも
  /// strip されるため、ネイティブ側で呼んだ結果のポインタを受け取って使う。
  /// isolate 間では共有されないので、ワーカーには値を渡すこと。
  static int? iosApiBaseAddress;

  /// プラットフォーム固有の準備 (iOS のみ)。メイン isolate で ORT を使う前に呼ぶ。
  static Future<void> preparePlatform() async {
    if (!Platform.isIOS || iosApiBaseAddress != null) return;
    iosApiBaseAddress =
        await const MethodChannel('futoji/ort').invokeMethod<int>('apiBase');
  }

  /// libonnxruntime4jni.so (Android) から OrtApi を取得する。
  ///
  /// [libraryPath] を渡すと別の ORT (例: 評価ハーネス用の Windows 版
  /// onnxruntime.dll, 1.16 以上) を読み込む。C API は OS 間で共通。
  /// [apiBaseAddress] (iOS) があればライブラリを開かずにそれを使う。
  static OrtApiBindings load({String? libraryPath, int? apiBaseAddress}) {
    final addr = apiBaseAddress ?? iosApiBaseAddress;
    final Pointer<OrtApiBaseStruct> base;
    if (libraryPath == null && addr != null && addr != 0) {
      base = Pointer<OrtApiBaseStruct>.fromAddress(addr);
    } else {
      final lib = DynamicLibrary.open(libraryPath ?? 'libonnxruntime.so');
      base = lib.lookupFunction<Pointer<OrtApiBaseStruct> Function(),
          Pointer<OrtApiBaseStruct> Function()>('OrtGetApiBase')();
    }
    // API バージョン 16 を要求 (vtable の並びは以後互換で固定)
    final getApi = base.ref.GetApi
        .asFunction<Pointer<OrtApiStruct> Function(int)>();
    return OrtApiBindings._(getApi(16));
  }

  /// 入出力 1 組 ('input' / 'output') の推論を 1 回実行する。
  /// テンソルは [bundle] に事前束縛されたネイティブバッファを用いる。
  void runSimple(OrtSessionBundle bundle) {
    final inNames = calloc<Pointer<Uint8>>();
    final outNames = calloc<Pointer<Uint8>>();
    final inVals = calloc<Pointer<Void>>();
    final outVals = calloc<Pointer<Void>>();
    try {
      inNames[0] = bundle.inputNamePtr;
      outNames[0] = bundle.outputNamePtr;
      inVals[0] = bundle.inputTensor;
      outVals[0] = bundle.outputTensor;
      check(runFn(
        bundle.session,
        nullptr,
        inNames,
        inVals,
        1,
        outNames,
        1,
        outVals,
      ));
    } finally {
      calloc
        ..free(inNames)
        ..free(outNames)
        ..free(inVals)
        ..free(outVals);
    }
  }

  /// OrtStatus がエラーを指していれば例外にする。
  /// [config] からセッションオプションを作る (呼び出し側で releaseSessionOptions)。
  Pointer<Void> _createOptions(OrtSessionConfig config) {
    final out = calloc<Pointer<Void>>();
    check(createSessionOptions(out));
    final options = out.value;
    calloc.free(out);
    try {
      if (config.intraOpThreads > 0) {
        check(setIntraOpNumThreads(options, config.intraOpThreads));
      }
      for (final e in config.configEntries.entries) {
        final k = e.key.toNativeUtf8();
        final v = e.value.toNativeUtf8();
        try {
          check(addSessionConfigEntry(options, k, v));
        } finally {
          malloc.free(k);
          malloc.free(v);
        }
      }
      final ep = config.executionProvider;
      if (ep != null) {
        final name = ep.toNativeUtf8();
        final entries = config.providerOptions.entries.toList();
        final keys = calloc<Pointer<Utf8>>(math.max(1, entries.length));
        final values = calloc<Pointer<Utf8>>(math.max(1, entries.length));
        for (int i = 0; i < entries.length; i++) {
          keys[i] = entries[i].key.toNativeUtf8();
          values[i] = entries[i].value.toNativeUtf8();
        }
        try {
          check(appendExecutionProvider(options, name, keys, values, entries.length));
        } finally {
          for (int i = 0; i < entries.length; i++) {
            malloc.free(keys[i]);
            malloc.free(values[i]);
          }
          calloc.free(keys);
          calloc.free(values);
          malloc.free(name);
        }
      }
    } catch (_) {
      releaseSessionOptions(options);
      rethrow;
    }
    return options;
  }

  void check(Pointer<Void> status) {
    if (status != nullptr) {
      final msgPtr = getErrorMessage(status);
      final msg = msgPtr == nullptr
          ? 'unknown ORT error'
          : Pointer<Utf8>.fromAddress(msgPtr.address).toDartString();
      releaseStatus(status);
      throw Exception('ORT error: $msg');
    }
  }

  /// モデルバイト列からセッション一式 (入出力テンソル束縛済み) を作る。
  /// どの isolate から呼んでもよい (C API はスレッドセーフ)。
  /// [inputShape] / [outputShape] は固定形状 (NCHW)。既定は紙面検出ネットの 1x1x256x256。
  static OrtSessionBundle createSessionBundle(Uint8List modelBytes,
      {String? libraryPath,
      int? apiBaseAddress,
      List<int> inputShape = const <int>[1, 1, 256, 256],
      List<int> outputShape = const <int>[1, 1, 256, 256],
      OrtSessionConfig? config}) {
    final bindings =
        OrtApiBindings.load(libraryPath: libraryPath, apiBaseAddress: apiBaseAddress);
    final modelBuf = calloc<Uint8>(modelBytes.length);
    modelBuf.asTypedList(modelBytes.length).setAll(0, modelBytes);

    final env = calloc<Pointer<Void>>();
    // ORT_LOGGING_LEVEL_WARNING = 2
    final logId = Pointer<Uint8>.fromAddress('futoji'.toNativeUtf8().address);
    bindings.check(bindings.createEnv(2, logId, env));
    calloc.free(logId);

    final options = config == null ? nullptr : bindings._createOptions(config);
    final session = calloc<Pointer<Void>>();
    try {
      bindings.check(bindings.createSessionFromArray(
          env.value, modelBuf, modelBytes.length, options, session));
    } finally {
      if (options != nullptr) bindings.releaseSessionOptions(options);
    }
    // セッションはモデルを内部に取り込むので、元のバッファはもう要らない
    calloc.free(modelBuf);

    final memInfo = calloc<Pointer<Void>>();
    // OrtArenaAllocator = 0, OrtMemTypeDefault = 0
    bindings.check(bindings.createCpuMemoryInfo(0, 0, memInfo));

    Pointer<Int64> shapeOf(List<int> dims) {
      final p = calloc<Int64>(dims.length);
      for (int i = 0; i < dims.length; i++) {
        p[i] = dims[i];
      }
      return p;
    }

    final inElements = inputShape.fold<int>(1, (a, b) => a * b);
    final outElements = outputShape.fold<int>(1, (a, b) => a * b);
    final inShape = shapeOf(inputShape);
    final outShape = shapeOf(outputShape);

    final inputData = calloc<Float>(inElements);
    final inputTensor = calloc<Pointer<Void>>();
    // ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT = 1
    bindings.check(bindings.createTensor(
        memInfo.value,
        Pointer<Void>.fromAddress(inputData.address),
        inElements * 4,
        inShape,
        inputShape.length,
        1,
        inputTensor));

    final outputData = calloc<Float>(outElements);
    final outputTensor = calloc<Pointer<Void>>();
    bindings.check(bindings.createTensor(
        memInfo.value,
        Pointer<Void>.fromAddress(outputData.address),
        outElements * 4,
        outShape,
        outputShape.length,
        1,
        outputTensor));

    return OrtSessionBundle(
      api: bindings.api,
      bindings: bindings,
      env: env.value,
      session: session.value,
      memoryInfo: memInfo.value,
      inputTensor: inputTensor.value,
      inputData: inputData,
      outputTensor: outputTensor.value,
      outputData: outputData,
      inputNamePtr:
          Pointer<Uint8>.fromAddress('input'.toNativeUtf8().address),
      outputNamePtr:
          Pointer<Uint8>.fromAddress('output'.toNativeUtf8().address),
      inputChannels: inputShape.length == 4 ? inputShape[1] : 1,
    );
  }

  /// 紙面検出ネットのセッションを作る。入力が RGB (1x3x256x256) か灰色 (1x1x256x256) かは
  /// モデルによるので、RGB で 1 回推論して通らなければ灰色で作り直す。
  static OrtSessionBundle createPaperSessionBundle(Uint8List modelBytes,
      {String? libraryPath, int? apiBaseAddress, OrtSessionConfig? config}) {
    for (final channels in const <int>[3, 1]) {
      final bundle = createSessionBundle(modelBytes,
          libraryPath: libraryPath,
          apiBaseAddress: apiBaseAddress,
          inputShape: <int>[1, channels, 256, 256],
          config: config);
      try {
        bundle.bindings.runSimple(bundle);
        return bundle;
      } catch (_) {
        bundle.release();
        if (channels == 1) rethrow;
      }
    }
    throw StateError('unreachable');
  }
}
