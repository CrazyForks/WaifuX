import Foundation

/// A local wallpaper candidate shown by the menu-bar quick switcher.
///
/// The item deliberately keeps the original library record payload so actions such as
/// applying the wallpaper and toggling a favorite continue to use the shared services.
struct MenuBarQuickWallpaperItem: Identifiable {
    enum Source {
        case wallpaper(Wallpaper)
        case media(MediaItem)
    }

    let id: String
    let title: String
    let localURL: URL
    let thumbnailURL: URL?
    let videoPreviewURL: URL?
    let downloadedAt: Date
    let source: Source
    let sceneBakeItemID: String?
    let bakedVideoPath: String?

    func replacingThumbnail(with thumbnailURL: URL?) -> Self {
        MenuBarQuickWallpaperItem(
            id: id,
            title: title,
            localURL: localURL,
            thumbnailURL: thumbnailURL,
            videoPreviewURL: videoPreviewURL,
            downloadedAt: downloadedAt,
            source: source,
            sceneBakeItemID: sceneBakeItemID,
            bakedVideoPath: bakedVideoPath
        )
    }
}
