//
//  WeatherBackgroundView.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/24/26.
//

import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

enum WeatherCondition: Equatable {
    case clear, cloudy, rain, thunderstorm

    var videoAssetName: String {
        switch self {
        case .clear: "bg_clear"
        case .cloudy: "bg_cloudy"
        case .rain: "bg_rain"
        case .thunderstorm: "bg_thunderstorm"
        }
    }

    fileprivate var fallbackColors: [Color] {
        switch self {
        case .clear:
            [Color(red: 0.55, green: 0.78, blue: 0.98), Color(red: 0.80, green: 0.91, blue: 1.0)]
        case .cloudy:
            [Color(red: 0.66, green: 0.71, blue: 0.77), Color(red: 0.80, green: 0.83, blue: 0.87)]
        case .rain:
            [Color(red: 0.36, green: 0.44, blue: 0.55), Color(red: 0.55, green: 0.62, blue: 0.70)]
        case .thunderstorm:
            [Color(red: 0.14, green: 0.16, blue: 0.22), Color(red: 0.29, green: 0.31, blue: 0.39)]
        }
    }
}

struct WeatherBackgroundView: View {
    let condition: WeatherCondition
    var replayTrigger: Int = 0

    var body: some View {
        ZStack {
            LinearGradient(colors: condition.fallbackColors, startPoint: .top, endPoint: .bottom)

            PlayOnceVideoPlayerView(
                assetName: condition.videoAssetName,
                fileExtension: "mp4",
                replayTrigger: replayTrigger
            )
        }
        .id(condition)
        .transition(.opacity)
        .animation(.easeInOut(duration: 1.2), value: condition)
        .ignoresSafeArea()
    }
}

private struct PlayOnceVideoPlayerView: UIViewRepresentable {
    let assetName: String
    let fileExtension: String
    let replayTrigger: Int

    func makeUIView(context: Context) -> PlayOncePlayerUIView {
        context.coordinator.lastReplayTrigger = replayTrigger
        return PlayOncePlayerUIView(assetName: assetName, fileExtension: fileExtension)
    }

    func updateUIView(_ uiView: PlayOncePlayerUIView, context: Context) {
        uiView.reload(assetName: assetName, fileExtension: fileExtension)

        if replayTrigger != context.coordinator.lastReplayTrigger {
            context.coordinator.lastReplayTrigger = replayTrigger
            uiView.replay()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastReplayTrigger = 0
    }
}

private final class PlayOncePlayerUIView: UIView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private var loadedAssetName: String?

    init(assetName: String, fileExtension: String) {
        super.init(frame: .zero)
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
        reload(assetName: assetName, fileExtension: fileExtension)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    func reload(assetName: String, fileExtension: String) {
        guard assetName != loadedAssetName else { return }
        loadedAssetName = assetName

        guard let url = Bundle.main.url(forResource: assetName, withExtension: fileExtension) else {
            playerLayer.player = nil
            player = nil
            return
        }

        let newPlayer = AVPlayer(playerItem: AVPlayerItem(url: url))
        playerLayer.player = newPlayer
        player = newPlayer
        newPlayer.play()
    }

    func replay() {
        player?.seek(to: .zero)
        player?.play()
    }
}
