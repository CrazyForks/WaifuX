import AppKit

@main
struct SceneRealtimePosterGeometryRegression {
    static func main() {
        let landscape = WallpaperPosterGeometry.evenPixelSize(
            widthPoints: 1600,
            heightPoints: 900,
            scale: 2
        )
        let portrait = WallpaperPosterGeometry.evenPixelSize(
            widthPoints: 1080,
            heightPoints: 1920,
            scale: 1
        )
        let roundedPortrait = WallpaperPosterGeometry.evenPixelSize(
            widthPoints: 1080.5,
            heightPoints: 1920.5,
            scale: 1
        )

        precondition(landscape == WallpaperPosterPixelSize(width: 3200, height: 1800))
        precondition(portrait == WallpaperPosterPixelSize(width: 1080, height: 1920))
        precondition(roundedPortrait == WallpaperPosterPixelSize(width: 1080, height: 1920))
        precondition(landscape.width > landscape.height)
        precondition(portrait.width < portrait.height)
        precondition(Set([landscape, portrait]).count == 2)

        print(
            "Scene realtime poster geometry regression passed: "
                + "landscape=\(landscape.width)x\(landscape.height), "
                + "portrait=\(portrait.width)x\(portrait.height)"
        )
    }
}
