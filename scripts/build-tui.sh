#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
if ! command -v dotnet >/dev/null; then
  echo 'Missing .NET 10 SDK: https://dotnet.microsoft.com/download/dotnet/10.0' >&2
  exit 2
fi
case "$(uname -m)" in
  x86_64) RID=linux-x64 ;;
  aarch64) RID=linux-arm64 ;;
  *) echo 'Unsupported CPU for bundled TUI. Headless agent remains supported.' >&2; exit 3 ;;
esac
mkdir -p "$ROOT/tui/bin"
dotnet publish "$ROOT/tui/CraftProbe.Tui/CraftProbe.Tui.csproj" -c Release -r "$RID" \
  --self-contained true -p:PublishSingleFile=true -p:PublishTrimmed=false -o "$ROOT/tui/bin"
[[ -x "$ROOT/tui/bin/CraftProbe.Tui" ]] || { echo 'Published TUI executable missing.' >&2; exit 4; }
echo "Ready: $ROOT/tui/bin/CraftProbe.Tui"
