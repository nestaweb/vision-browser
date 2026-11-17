#!/usr/bin/env bash
# Installe le build Firefox officiel de Bitwarden pour Vision Browser.
#
#   scripts/install-bitwarden.sh                 # télécharge la dernière version (GitHub officiel)
#   scripts/install-bitwarden.sh chemin/dist-firefox-X.zip   # utilise une archive déjà téléchargée
#
# Étapes : vérification de l'empreinte SHA-256 publiée par GitHub, décompression dans
# ~/Library/Application Support/Vision Browser/Extensions/bitwarden, puis application
# des adaptations WebKit (patch-bitwarden.sh). La session Bitwarden est conservée :
# elle est rangée sous l'identifiant de l'extension, pas dans ces fichiers.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Application Support/Vision Browser/Extensions/bitwarden"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

release_json() { gh api "repos/bitwarden/clients/releases?per_page=40" --jq '[.[] | select(.tag_name|startswith("browser-"))][0]'; }

if [ $# -ge 1 ]; then
  ZIP="$1"
  NAME="$(basename "$ZIP")"
  TAG="browser-v$(echo "$NAME" | sed -E 's/^dist-firefox-(.*)\.zip$/\1/')"
  EXPECTED="$(gh api "repos/bitwarden/clients/releases/tags/$TAG" --jq ".assets[] | select(.name==\"$NAME\") | .digest" | sed 's/^sha256://')"
else
  JSON="$(release_json)"
  TAG="$(echo "$JSON" | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])')"
  NAME="dist-firefox-${TAG#browser-v}.zip"
  echo "• Dernière version : $TAG ($NAME)"
  gh release download "$TAG" --repo bitwarden/clients --pattern "$NAME" --dir "$WORK"
  ZIP="$WORK/$NAME"
  EXPECTED="$(echo "$JSON" | python3 -I -c "import sys,json; a=[x for x in json.load(sys.stdin)['assets'] if x['name']=='$NAME']; print(a[0]['digest'].split(':')[1])")"
fi

ACTUAL="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
if [ -z "$EXPECTED" ] || [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "✗ Empreinte SHA-256 différente de celle publiée par GitHub ($TAG) : installation annulée."
  exit 1
fi
echo "✓ Empreinte vérifiée ($ACTUAL)"

mkdir -p "$WORK/unzipped"
unzip -q "$ZIP" -d "$WORK/unzipped"
[ -f "$WORK/unzipped/manifest.json" ] || { echo "✗ Archive inattendue (pas de manifest.json)"; exit 1; }

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$WORK/unzipped" "$DEST"
echo "✓ Installé dans $DEST"

"$SCRIPTS/patch-bitwarden.sh" "$DEST"
echo "→ Relancer Vision Browser pour charger cette version."
