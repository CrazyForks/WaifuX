# WaifuX Steam Service

This directory contains the long-lived SteamKit2 service used by WaifuX to
authenticate once and download Wallpaper Engine Workshop content through the
Steam manifest and CDN APIs.

The service is adapted from the architecture and implementation of
[MirageWallpaper](https://github.com/laobamac/MirageWallpaper). WaifuX keeps
the service under the GPL-3.0 project license and includes the original
attribution in the source headers.

The service does not persist Steam passwords. The macOS app stores the
SteamKit2 refresh token and optional Guard data in Keychain, then passes them
to the service only when restoring a session.

`scripts/build-steam-service.sh` embeds the published service and the required
.NET runtime under `WaifuX.app/Contents/Resources/WaifuXSteamService/`.
