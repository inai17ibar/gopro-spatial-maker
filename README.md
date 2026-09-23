# GoPro Spatial Maker

2台の GoPro（例: HERO12 Black）を横に並べて撮影した左右の動画から、Apple Vision Pro の写真アプリで再生できる
**MV-HEVC 空間ビデオ (.mov)** を生成する macOS アプリです。SwiftUI + AVFoundation / VideoToolbox のみで動作し、
ffmpeg などの外部ツールは不要です。

## 機能

- 左目 / 右目クリップのドラッグ&ドロップ読み込み
- 同期
  - GoPro のタイムコードトラック (`tmcd`) を読み取り自動オフセット算出（Quik でタイムコード同期している場合）
  - 音声波形の相互相関 (FFT) による自動同期
  - フレーム単位の手動微調整
- 位置合わせ（右目を補正）: 水平（コンバージェンス）/ 垂直 / 回転 / スケール / 明るさ / コントラスト / 彩度、左右入れ替え
- プレビュー: 左 / 右 / 50%合成 / 差分 / アナグリフ / SBS
- 書き出し: MV-HEVC（左右2レイヤー）+ AAC 音声、空間メタデータ（基線長・水平画角・視差調整・Hero eye・投影方式）付き

## 要件

- macOS 15 以降（Apple silicon 推奨）
- Xcode 16 以降

## ビルド

### Swift Package として

```bash
swift build
swift run GoProSpatialMaker
swift test
```

### Xcode プロジェクトとして（App バンドル / サンドボックス）

[XcodeGen](https://github.com/yonaskolb/XcodeGen) を使います。

```bash
brew install xcodegen
xcodegen generate
open GoProSpatialMaker.xcodeproj
```

## 使い方

1. 左右の動画をそれぞれのドロップゾーンに読み込む（撮影者から見て左側のカメラが「左目」）。
2. 「タイムコードで同期」または「音声で同期」を押す。必要ならオフセットをフレーム単位で微調整。
3. プレビューを「差分」にして、垂直・回転・スケールを調整し縦ズレをなくす。
   「アナグリフ」にして主被写体の赤とシアンが重なるよう水平（コンバージェンス）を調整。
4. 書き出し設定（解像度・fps・基線長・画角）を確認して「空間ビデオを書き出す」。
5. 出力した `.mov` を AirDrop / iCloud で Vision Pro に送ると、写真アプリで空間ビデオとして再生できます。

## 撮影のヒント

- 2台は同じ解像度 / フレームレート / レンズモードで撮影する。
- **HyperSmooth はオフ**（左右で補正量が異なると立体視が崩れます）、レンズは **Linear** 推奨。
- GoPro HERO12 の横幅は約 72 mm なので、密着配置なら基線長は 72 mm。Linear (16:9) の水平画角は約 90°。

## 構成

```
Sources/GoProSpatialMaker/
  GoProSpatialMakerApp.swift     アプリエントリ
  Models/                        ProjectState（状態）、StereoAlignment、ExportSettings、VideoSource
  Services/
    TimecodeReader.swift         tmcd トラックから開始タイムコードを取得
    AudioSyncEstimator.swift     音声相互相関でオフセット推定（Accelerate）
    StereoFrameRenderer.swift    Core Image による補正・合成（プレビュー / 書き出し共通）
    SpatialVideoExporter.swift   AVAssetWriter + TaggedPixelBufferGroupAdaptor で MV-HEVC 出力
  Views/                         SwiftUI 画面
Tests/                           同期アルゴリズム・タイムコード整形・変換行列のユニットテスト
```
