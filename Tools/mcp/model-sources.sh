# The app sources that compile without UI frameworks (shared by build.sh and test.sh).
APP="$(cd "$HERE/../../MindMap" && pwd)"
MODEL_SOURCES=()
while IFS= read -r f; do MODEL_SOURCES+=("$f"); done < <(
  { ls "$APP"/Model/*.swift | grep -v -E '/(MindMapModel[^/]*|HandwrittenNote|ShapeRecognizer|DocumentLock|MindMap\+Find)\.swift$'
    ls "$APP"/Layout/*.swift | grep -v -E '/(TouchHandles|NotePencilPolicy)\.swift$'
    for f in Document/MindMapPackage Document/UntitledName Document/AttachmentStore Document/LockedPackage Library/MarkdownExport; do
      echo "$APP/$f.swift"; done; })
