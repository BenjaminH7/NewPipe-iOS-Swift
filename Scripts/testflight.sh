#!/bin/bash
# Archive l'app et l'envoie sur App Store Connect (TestFlight).
#
# Prérequis (une seule fois) :
#   1. Xcode › Réglages › Comptes : ajouter son identifiant Apple (compte développeur payant).
#   2. App Store Connect › Apps › « + » › Nouvelle app, avec le même identifiant de bundle.
#
# Usage : Scripts/testflight.sh <IDENTIFIANT_DE_BUNDLE> [TEAM_ID]
#   Ex.  : Scripts/testflight.sh com.monnom.newpipe
# Si TEAM_ID est omis, l'équipe du compte Xcode est utilisée (s'il n'y en a qu'une).
set -euo pipefail

BUNDLE_ID="${1:-}"
TEAM_ID="${2:-}"
if [[ -z "$BUNDLE_ID" ]]; then
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Équipe : argument, sinon celle choisie dans Xcode (Signing & Capabilities), sinon celle du compte Xcode.
if [[ -z "$TEAM_ID" ]]; then
    TEAM_ID=$(sed -nE 's/.*DEVELOPMENT_TEAM = "?([A-Z0-9]{10})"?;.*/\1/p' "$ROOT/NewPipe.xcodeproj/project.pbxproj" | head -1)
fi
if [[ -z "$TEAM_ID" ]]; then
    TEAMS=$(defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null | grep -oE 'teamID = [A-Z0-9]{10}' | awk '{print $3}' | sort -u || true)
    [[ $(printf '%s\n' "$TEAMS" | grep -c .) -eq 1 ]] && TEAM_ID="$TEAMS"
fi
if [[ -z "$TEAM_ID" ]]; then
    cat <<MSG
Équipe de développement introuvable. Au choix :
  • Dans Xcode, ouvre NewPipe.xcodeproj › cible NewPipe › Signing & Capabilities › Team : choisis ton équipe,
    puis relance ce script ;
  • ou passe ton Team ID (10 caractères, developer.apple.com › Compte › Abonnement) en 2e argument :
      $0 $BUNDLE_ID ABCDE12345
MSG
    exit 1
fi

STAMP="$(date +%Y%m%d%H%M)"                 # numéro de build croissant
ARCHIVE="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/NewPipe $STAMP.xcarchive"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▶︎ Équipe $TEAM_ID • bundle $BUNDLE_ID • build $STAMP"

xcodebuild archive \
    -project "$ROOT/NewPipe.xcodeproj" -scheme NewPipe -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CURRENT_PROJECT_VERSION="$STAMP" \
    CODE_SIGN_STYLE=Automatic

cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>testFlightInternalTestingOnly</key><true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" \
    -exportPath "$WORK/export" \
    -allowProvisioningUpdates

echo "✅ Envoyé. Le build apparaît dans App Store Connect › TestFlight après ~10-20 min de traitement."
echo "   Archive : $ARCHIVE"
