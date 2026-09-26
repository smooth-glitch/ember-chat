#!/bin/bash
# Downloads the placeholder photos/avatars the demo seed uses (not stored in the repo).
# Photos: Lorem Picsum (Unsplash licence). Avatars: pravatar.cc. Demo accounts are fictional.
cd "$(dirname "$0")" && mkdir -p assets && cd assets
for spec in "photo_mountain:1018:900:700" "photo_lake:1015:900:700" "photo_forest:1043:900:700" "icon_trip:1039:400:400" "icon_movie:1041:400:400"; do
  IFS=: read name id w h <<< "$spec"; curl -sL "https://picsum.photos/id/$id/$w/$h.jpg" -o "$name.jpg"
done
for i in 5 12 32 47 68 15; do curl -sL "https://i.pravatar.cc/300?img=$i" -o "av$i.jpg"; done
printf '%%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' > doc.pdf
ls
