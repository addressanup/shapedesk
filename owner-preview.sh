#!/bin/sh
# Owner-only preview on this Mac. Customer release scripts never enable this flag.
set -eu
cd "$(dirname "$0")"
swift build --scratch-path .build/owner-preview -c debug -Xswiftc -DSHAPEDESK_OWNER_PREVIEW
python3 - <<'PY'
from pathlib import Path
import plistlib, shutil
app = Path('build/OwnerPreview/ShapeDesk.app')
if app.exists(): shutil.rmtree(app)
(app / 'Contents/MacOS').mkdir(parents=True)
shutil.copy2('.build/owner-preview/debug/ShapeDesk', app / 'Contents/MacOS/ShapeDesk')
with open('Info.plist', 'rb') as source: info = plistlib.load(source)
info['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True}
info['ShapeDeskOwnerPreview'] = True
with (app / 'Contents/Info.plist').open('wb') as target: plistlib.dump(info, target)
PY
./icon.sh build/OwnerPreview/ShapeDesk.app
codesign --force --sign - build/OwnerPreview/ShapeDesk.app
node scripts/install-owner-preview.mjs "$(command -v node)"
