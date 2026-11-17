#!/usr/bin/env bash
# Adapte le build Firefox de Bitwarden à WebKit (WKWebExtension).
# À relancer après chaque mise à jour de Bitwarden dans Extensions/bitwarden.
#
# Patch 1 : menu de suggestions dans les champs (inline menu)
#   La page du menu (overlay/menu.js) n'accepte son message d'initialisation que si
#   l'adresse de l'extension utilise un protocole connu : chrome-extension:,
#   moz-extension: ou safari-web-extension:. WebKit utilise « webkit-extension: »,
#   et changer de protocole bloque le chargement de l'extension dans WebKit
#   (vérifié le 17/11/2026 avec safari-web-extension: et moz-extension:).
#   On ajoute donc « webkit-extension: » à cette liste. Sans ça, le cadre du menu
#   est placé au bon endroit mais reste vide (aucune icône dans les champs).
#
# Licence : Bitwarden est sous GPL-3.0 ; ces modifications sont publiées dans ce dépôt.
set -euo pipefail

DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/Extensions/bitwarden}"
FILE="$DIR/overlay/menu.js"
[ -f "$FILE" ] || { echo "✗ Fichier introuvable : $FILE"; exit 1; }

python3 -I - "$FILE" <<'EOF'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
needle = '"safari-web-extension:",\n            ]);'
patched = '"safari-web-extension:",\n                "webkit-extension:", // Vision : protocole des extensions WebKit\n            ]);'
if patched in text:
    print("• Déjà patché : overlay/menu.js")
elif text.count(needle) == 1:
    open(path, "w", encoding="utf-8").write(text.replace(needle, patched))
    print("✓ Patché : overlay/menu.js (protocole webkit-extension: accepté)")
else:
    print(f"✗ Motif trouvé {text.count(needle)} fois au lieu d'une : le code de Bitwarden a changé, patch à revoir.")
    sys.exit(1)
EOF
