WaifuXSteamService prebuilt runtime
====================================

This directory carries prebuilt SteamKit2 service runtimes so a normal
Xcode build does NOT require the .NET SDK.

- arm64/    — framework-dependent publish (net10.0, RID osx-arm64) plus the
              Microsoft.NETCore.App 10.x runtime copied by the script.
- x86_64/   — same, RID osx-x64 (runs on Intel Macs natively; on Apple
              Silicon the x64 binary is translated by Rosetta and is only
              selected when the app itself runs under Rosetta).
- Licenses/ — SteamKit2 / DepotDownloader / LGPL notices, copied verbatim.

Build machine fingerprint (rebuilt together 2026-09-07, SDK 10.0.400):

  arm64/app/WaifuXSteamService.dll
  sha256 9d4aeb37d9d8b270915c55f25743c7c4478eb7693422bfe392cb9a3d9baff390
  arm64/runtime/dotnet
  sha256 (arm64 host, see git history for the recorded value)
  x86_64/app/WaifuXSteamService.dll
  sha256 fc4ae0ea4025b997ecf33d9412559c9f8619257a6a06c2cf885da861397f328f
  x86_64/runtime/dotnet
  sha256 (official osx-x64 10.0.11 host)
  Microsoft.NETCore.App version: 10.0.11

How the embedding works
-----------------------
scripts/build-steam-service.sh copies SteamService/prebuilt/<arch> into the
app bundle when the prebuilt runtime exists. Set
WAIFUX_STEAM_SERVICE_BUILD=1 to force a fresh `dotnet publish` instead
(then the .NET SDK with Microsoft.NETCore.App 10.x is required), e.g. after
editing SteamService/*.cs.

Cross-compiling note: the per-arch `dotnet` host / hostfxr / shared runtime
must match the TARGET architecture. When building x86_64 on an arm64
machine, point WAIFUX_DOTNET_ROOT_X86_64 at an x64 dotnet installation
(and WAIFUX_DOTNET_ROOT_ARM64 for the reverse). The script fails loudly
rather than copying a mismatched host.

When you rebuild with the SDK, refresh this directory with the new output so
the committed prebuilt stays current:

  WAIFUX_STEAM_SERVICE_BUILD=1 ./scripts/build-steam-service.sh /tmp/svc "arm64 x86_64"
  rm -rf SteamService/prebuilt/arm64 SteamService/prebuilt/x86_64
  cp -R /tmp/svc/arm64 /tmp/svc/x86_64 SteamService/prebuilt/
  git add SteamService/prebuilt
