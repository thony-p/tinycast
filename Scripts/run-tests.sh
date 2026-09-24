#!/bin/bash
# The test suite. There is no XCTest target: each harness compiles the shipped sources it guards,
# so a harness that stops compiling means a decision leaked out of a pure layer. See docs/testing.md.
#
# Never join a compile and its run with `&&`: `set -e` ignores a failure in a non-final AND-OR list
# member, which is how CI reported success over a harness that had not compiled since phase 10.

set -uo pipefail

# Absolute: the workers re-enter this script after the cd, where a relative $0 would not resolve.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1

BIN="${TMPDIR:-/tmp}/tonycast-harness"
mkdir -p "$BIN"

# `--exec` is the worker half: xargs re-enters here once per queued harness.
if [ "${1:-}" = "--exec" ]; then
    shift
    name=$1 opt=$2
    shift 2
    : > "$BIN/$name.running"
    trap 'rm -f "$BIN/$name.running" "$BIN/$name.time"' EXIT
    fail() {
        printf '\033[31mFAIL\033[0m  %-25s %s\n' "$name" "$1"
        : > "$BIN/$name.failed"
        exit 0
    }
    TIMEFORMAT=%1R
    if ! compiled=$( { time swiftc -swift-version 6 "$opt" "$@" "Tests/$name.swift" -o "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2>&1 ); then
        fail "did not compile"
    fi
    { time "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2> "$BIN/$name.time" &
    pid=$!
    # macOS ships no `timeout`, so the worker polls; a wedged harness must fail, not stall the suite.
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((TONYCAST_TEST_TIMEOUT * 5)) ]; then
            { pkill -KILL -P "$pid"; kill -KILL "$pid"; wait "$pid"; } 2>/dev/null
            printf '\n[run-tests] killed after %ss without finishing\n' "$TONYCAST_TEST_TIMEOUT" >> "$BIN/$name.log"
            fail "timed out after ${TONYCAST_TEST_TIMEOUT}s"
        fi
        ticks=$((ticks + 1))
        sleep 0.2
    done
    wait "$pid"
    status=$?
    took=$(< "$BIN/$name.time")
    if [ "$status" -gt 128 ]; then fail "crashed (signal $((status - 128))) after ${took}s"; fi
    if [ "$status" -ne 0 ]; then fail "assertion failed after ${took}s"; fi
    printf '\033[32mok\033[0m    %-25s %5ss  \033[2m(compile %ss)\033[0m\n' "$name" "$took" "$compiled"
    exit 0
fi

QUEUE="$BIN/queue"
: > "$QUEUE"
rm -f "$BIN"/*.failed "$BIN"/*.running

failed=()
ran=0
only="${1:-}"

# `--index` merges each harness's compile command into .compile instead of running anything.
# xcodebuild never compiles the harnesses, so without this nothing in Tests/ resolves in an editor.
# The source lists below are the only copy, which is why this lives here rather than in its own script.
emit_db=0
DB="${TMPDIR:-/tmp}/tonycast-compile-db.json"
if [ "$only" = "--index" ]; then
    emit_db=1
    only=""
    printf '[' > "$DB"
fi

# run [slow] [-O] [index] <name> <source...> — queue the harness. `slow` dispatches it in the first
# wave; `index` claims editor flags for a harness that is compiled by hand rather than by the suite.
run() {
    local opt=-Onone pri=1 index_only=0
    while :; do
        case "$1" in
            slow)  pri=0; shift;;
            -O)    opt=-O; shift;;
            index) index_only=1; shift;;
            *)     break;;
        esac
    done
    local name=$1
    shift
    if [ -n "$only" ] && [ "$name" != "$only" ]; then return 0; fi
    if [ "$index_only" -eq 1 ] && [ "$emit_db" -eq 0 ]; then return 0; fi
    ran=$((ran + 1))

    # Absolute paths throughout: sourcekit-lsp resolves the command itself and does not apply
    # `directory` to relative arguments, so a relative path there silently yields no index.
    if [ "$emit_db" -eq 1 ]; then
        local sources=()
        for source in "$@" "Tests/$name.swift"; do sources+=("$PWD/$source"); done
        [ "$ran" -gt 1 ] && printf ',' >> "$DB"
        printf '{"directory":"%s","command":"swiftc -swift-version 6 -sdk %s' \
            "$PWD" "$(xcrun --show-sdk-path --sdk macosx)" >> "$DB"
        printf ' %s' "${sources[@]}" >> "$DB"
        # Claim every file under `Tests/`: the harness and any helper compiled beside it. A shipped
        # source stays unclaimed, because it would get this short command instead of the app's full
        # one and `.compile` is last-wins — but the app never compiles anything in `Tests/`.
        local claimed=""
        for source in "${sources[@]}"; do
            case "$source" in *"/Tests/"*) claimed="$claimed${claimed:+,}\"$source\"";; esac
        done
        printf '","files":[%s]}' "$claimed" >> "$DB"
        return 0
    fi

    # xargs splits the queue on whitespace, so no harness source path may contain a space.
    printf '%s %s %s %s\n' "$pri" "$name" "$opt" "$*" >> "$QUEUE"
}

L=Tonycast/Features/Launcher/Model
run slow -O fuzz-test      $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/EntryNaming.swift $L/LauncherOrder.swift
run slow -O corpus-test    $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/EntryNaming.swift $L/LauncherOrder.swift \
                           $L/LauncherRankingStore.swift
run file-search-test       $L/SearchRelevance.swift \
                           Tonycast/Features/FileSearch/Model/*.swift
run file-search-session-test Tonycast/Platform/Signposts.swift \
                             $L/SearchRelevance.swift \
                             Tonycast/Features/FileSearch/Model/*.swift \
                             Tonycast/Features/FileSearch/Service/*.swift
run menu-search-test       $L/SearchRelevance.swift \
                           Tonycast/Features/MenuSearch/Model/*.swift \
                           Tonycast/Features/MenuSearch/Service/*.swift
run window-switch-test     $L/SearchRelevance.swift \
                           Tonycast/Features/WindowSwitcher/Model/*.swift
run index file-search-performance Tonycast/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Tonycast/Features/FileSearch/Model/*.swift \
                           Tonycast/Features/FileSearch/Service/FileSearchService.swift
run ranking-test           $L/SearchRelevance.swift $L/LauncherRankingStore.swift
run scopes-test            $L/SearchScopes.swift
run app-name-test          Tonycast/Platform/AppDisplayName.swift \
                           Tonycast/Platform/BundleLocalization.swift \
                           $L/SearchRelevance.swift
run favorites-test         $L/FavoriteSlots.swift
run apple-shortcut-test    Tonycast/Features/AppleShortcuts/Model/*.swift
run calc-test              Tonycast/Features/Calculator/Model/*.swift
run index calc-performance Tonycast/Features/Calculator/Model/*.swift
run calendar-test          Tonycast/Features/Calendar/Model/*.swift
run clipboard-test         Tonycast/Features/Clipboard/Model/ClipboardStore.swift \
                           Tonycast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Tonycast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Tonycast/Features/Clipboard/Model/ColorValue.swift \
                           Tonycast/Features/Clipboard/Model/ColorFormat.swift \
                           Tonycast/Features/Clipboard/Model/ColorSpaces.swift
# `Q` is the URL detector a drag payload builds its link with, rather than a second one.
Q=Tonycast/Features/Quicklinks/Model/QuicklinkDestination.swift
run clipboard-search-test  Tonycast/Features/Clipboard/Model/*.swift $Q
run clipboard-text-test    Tonycast/Features/Clipboard/Model/*.swift $Q \
                           Tonycast/Features/Clipboard/Service/ClipboardTextExtractor.swift \
                           Tonycast/Features/Clipboard/Service/ClipboardTextIndexer.swift \
                           Tonycast/Features/Clipboard/Service/ClipboardTextWorker.swift
run pasteboard-test        Tonycast/Platform/PasteboardFiles.swift \
                           Tonycast/Features/Clipboard/Model/ClipboardStore.swift \
                           Tonycast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Tonycast/Features/Clipboard/Model/ColorValue.swift \
                           Tonycast/Features/Clipboard/Model/ColorFormat.swift \
                           Tonycast/Features/Clipboard/Model/ColorSpaces.swift \
                           Tonycast/Features/Clipboard/Service/ClipboardManager.swift \
                           Tonycast/Features/Clipboard/Service/Paster.swift
run index clipboard-file-performance \
                           Tonycast/Platform/PasteboardFiles.swift \
                           Tonycast/Features/Clipboard/Model/ClipboardStore.swift \
                           Tonycast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Tonycast/Features/Clipboard/Model/ColorValue.swift \
                           Tonycast/Features/Clipboard/Model/ColorFormat.swift \
                           Tonycast/Features/Clipboard/Model/ColorSpaces.swift \
                           Tonycast/Features/Clipboard/Service/ClipboardManager.swift
run emoji-test             Tonycast/Features/Emoji/Model/EmojiCatalog.swift \
                           Tonycast/Features/Emoji/Model/EmojiGridGeometry.swift \
                           Tonycast/Features/Emoji/Model/EmojiData.generated.swift
run emoji-search-test      Tonycast/Features/Emoji/Model/EmojiCatalog.swift \
                           Tonycast/Features/Emoji/Model/EmojiData.generated.swift \
                           Tonycast/Features/Emoji/Service/EmojiIndex.swift \
                           Tonycast/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Tonycast/Features/Emoji/Service/PinnedEmojiStore.swift \
                           Tonycast/Features/Launcher/Model/SearchRelevance.swift \
                           Tonycast/Platform/AppPaths.swift Tonycast/Platform/Memo.swift
run index emoji-search-performance \
                           Tonycast/Features/Emoji/Model/EmojiCatalog.swift \
                           Tonycast/Features/Emoji/Model/EmojiData.generated.swift \
                           Tonycast/Features/Emoji/Service/EmojiIndex.swift \
                           Tonycast/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Tonycast/Features/Launcher/Model/SearchRelevance.swift \
                           Tonycast/Platform/AppPaths.swift Tonycast/Platform/Memo.swift
run palette-selection-test Tonycast/Features/PaletteRowIndex.swift \
                           Tonycast/Features/Emoji/Model/EmojiGridGeometry.swift
run appearance-test        Tonycast/Platform/Appearance.swift \
                           Tonycast/DesignSystem/Theme.swift \
                           Tonycast/DesignSystem/InterfaceMetrics.swift \
                           Tonycast/Features/Settings/AppAppearance.swift
run interface-size-test    Tonycast/Platform/Appearance.swift \
                           Tonycast/DesignSystem/Theme.swift \
                           Tonycast/DesignSystem/InterfaceMetrics.swift \
                           Tonycast/Features/Settings/InterfaceSize.swift \
                           Tonycast/Features/Extensions/Model/ExtensionFormMetrics.swift
run palette-placement-test Tonycast/Platform/Appearance.swift \
                           Tonycast/DesignSystem/Theme.swift \
                           Tonycast/DesignSystem/InterfaceMetrics.swift \
                           Tonycast/Features/Settings/InterfaceSize.swift \
                           Tonycast/Palette/PalettePlacement.swift
run scroll-reveal-test     Tonycast/DesignSystem/Scrolling/SelectionReveal.swift
run redaction-test         Tonycast/DesignSystem/RedactedPlaceholder.swift
run keyboard-focus-test    Tonycast/DesignSystem/Interaction/KeyboardFocus.swift
run ai-instructions-test   Tonycast/Features/AI/Model/AIInstructions.swift \
                           Tonycast/Features/AI/Model/AIPreamble.swift
run hover-arming-test      Tonycast/Palette/HoverArming.swift \
                           Tonycast/Palette/PaletteState.swift \
                           Tonycast/Palette/PaletteMode.swift \
                           Tonycast/Features/Emoji/Model/EmojiCatalog.swift \
                           Tonycast/Features/Clipboard/Model/ClipboardStore.swift \
                           Tonycast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Tonycast/Features/FileSearch/Model/FileSearchFilter.swift \
                           Tonycast/Features/Clipboard/Model/ColorValue.swift \
                           Tonycast/Features/Clipboard/Model/ColorFormat.swift \
                           Tonycast/Features/Clipboard/Model/ColorSpaces.swift \
                           Tonycast/Features/Quicklinks/Model/Quicklink.swift \
                           Tonycast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Tonycast/Features/CustomCommands/Model/CustomCommand.swift
run palette-escape-test    Tonycast/Palette/PaletteMode.swift \
                           Tonycast/Palette/PaletteEscapeAction.swift \
                           Tonycast/Palette/CommandEscapeTap.swift \
                           Tonycast/Features/Settings/EscapeKeyBehavior.swift \
                           Tonycast/Features/Quicklinks/Model/Quicklink.swift \
                           Tonycast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Tonycast/Features/CustomCommands/Model/CustomCommand.swift
run palette-navigation-test Tonycast/Palette/PaletteState.swift \
                           Tonycast/Palette/PaletteMode.swift \
                           Tonycast/Palette/HoverArming.swift \
                           Tonycast/Features/Emoji/Model/EmojiCatalog.swift \
                           Tonycast/Features/Clipboard/Model/ClipboardStore.swift \
                           Tonycast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Tonycast/Features/FileSearch/Model/FileSearchFilter.swift \
                           Tonycast/Features/Clipboard/Model/ColorValue.swift \
                           Tonycast/Features/Clipboard/Model/ColorFormat.swift \
                           Tonycast/Features/Clipboard/Model/ColorSpaces.swift \
                           Tonycast/Features/Quicklinks/Model/Quicklink.swift \
                           Tonycast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Tonycast/Features/CustomCommands/Model/CustomCommand.swift
run palette-filter-test    Tonycast/Palette/PaletteMode.swift \
                           Tonycast/Palette/PaletteFilterAction.swift \
                           Tonycast/Features/Quicklinks/Model/Quicklink.swift \
                           Tonycast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Tonycast/Features/CustomCommands/Model/CustomCommand.swift
run action-menu-search-test Tonycast/Palette/ActionMenuSearchQuery.swift \
                            Tonycast/Features/Launcher/Model/SearchRelevance.swift
run palette-shortcut-test  Tonycast/Palette/PaletteShortcut.swift
run palette-tab-test       Tonycast/Palette/PaletteMode.swift \
                           Tonycast/Palette/PaletteTabAction.swift \
                           Tonycast/Features/Quicklinks/Model/Quicklink.swift \
                           Tonycast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Tonycast/Features/CustomCommands/Model/CustomCommand.swift
run fallback-test          Tonycast/Features/Launcher/Model/Fallback.swift \
                           Tonycast/Features/Launcher/Model/CommandID.swift \
                           Tonycast/Features/HotKeys/Model/HotKeyAction.swift \
                           Tonycast/Features/QuickActions/Model/QuickAction.swift \
                           Tonycast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Tonycast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Tonycast/Features/Quicklinks/Model/Quicklink.swift \
                           Tonycast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Tonycast/Features/SystemActions/Model/SystemAction.swift \
                           Tonycast/Features/WindowManagement/Model/WindowCommand.swift
run dictionary-test        Tonycast/Features/Dictionary/Model/DictionaryEntry.swift \
                           Tonycast/Features/Dictionary/Model/DictionaryMarkup.swift
run hotkey-test            Tonycast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Tonycast/Features/HotKeys/Model/DoubleTapDetector.swift \
                           Tonycast/Features/HotKeys/Model/HyperKey.swift \
                           Tonycast/Platform/ASCIIKeyboardLayout.swift \
                           Tonycast/Features/HotKeys/Service/KeyShortcut.swift \
                           Tonycast/Features/HotKeys/Model/HotKeyAction.swift \
                           Tonycast/Features/QuickActions/Model/QuickAction.swift \
                           Tonycast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Tonycast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Tonycast/Features/Launcher/Model/CommandID.swift \
                           Tonycast/Features/Quicklinks/Model/Quicklink.swift \
                           Tonycast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Tonycast/Features/SystemActions/Model/SystemAction.swift \
                           Tonycast/Features/WindowManagement/Model/WindowCommand.swift
run callout-test           Tonycast/Platform/Appearance.swift \
                           Tonycast/DesignSystem/Theme.swift \
                           Tonycast/DesignSystem/InterfaceMetrics.swift \
                           Tonycast/Features/HotKeys/UI/CalloutPlacement.swift
run icon-cache-test        Tonycast/Platform/Appearance.swift \
                           Tonycast/Platform/Images/IconCache.swift
run entry-icon-test        Tonycast/Platform/Appearance.swift \
                           Tonycast/Platform/Images/IconCache.swift \
                           Tonycast/Platform/Images/FileIconStamp.swift
run ext-icon-test          Tonycast/Platform/Appearance.swift \
                           Tonycast/Platform/AppDisplayName.swift \
                           Tonycast/Platform/Images/IconCache.swift \
                           Tonycast/Platform/Compression/Zlib.swift \
                           Tonycast/DesignSystem/Theme.swift \
                           Tonycast/DesignSystem/InterfaceMetrics.swift \
                           Tonycast/Features/Extensions/Model/ExtensionBootConfig.swift \
                           Tonycast/Features/Extensions/Model/ExtensionLaunchType.swift \
                           Tonycast/Features/Extensions/Model/ExtensionManifest.swift \
                           Tonycast/Features/Extensions/Model/ExtensionRefreshPolicy.swift \
                           Tonycast/Features/Extensions/Model/ExtensionRefreshState.swift \
                           Tonycast/Features/Extensions/Model/RenderNode.swift \
                           Tonycast/Features/Extensions/Service/ExtensionCatalog.swift \
                           Tonycast/Features/Extensions/Service/ExtensionFetcher.swift \
                           Tonycast/Features/Extensions/Service/ExtensionNodeShims.swift \
                           Tonycast/Features/Extensions/Service/ExtensionOAuthKeychain.swift \
                           Tonycast/Features/Extensions/Service/ExtensionOAuthSession.swift \
                           Tonycast/Features/Extensions/Service/ExtensionRuntime.swift \
                           Tonycast/Features/Extensions/Service/ExtensionIconCache.swift \
                           Tonycast/Features/Extensions/UI/ExtensionAnimatedImage.swift \
                           Tonycast/Features/Extensions/UI/ExtensionImage.swift \
                           Tonycast/Features/Clipboard/Model/ColorValue.swift \
                           Tonycast/Features/Clipboard/Model/ColorSpaces.swift
run system-action-test     Tonycast/Features/SystemActions/Model/SystemAction.swift
run volume-test            Tonycast/Features/SystemActions/Model/VolumeLevel.swift
run window-command-test    Tonycast/Features/WindowManagement/Model/WindowCommand.swift \
                           Tonycast/Features/WindowManagement/Model/WindowCycle.swift \
                           Tonycast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Tonycast/Features/WindowManagement/Model/WindowActionMemory.swift
run space-gesture-test     Tonycast/Features/WindowManagement/Model/WindowCommand.swift \
                           Tonycast/Features/WindowManagement/Model/SpaceGesture.swift
run window-layout-test     Tonycast/Features/WindowManagement/Model/WindowCommand.swift \
                           Tonycast/Features/WindowManagement/Model/WindowCycle.swift \
                           Tonycast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Tonycast/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Tonycast/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Tonycast/Features/WindowManagement/Model/WindowLayout.swift \
                           Tonycast/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Tonycast/Features/WindowManagement/Model/WindowLayoutPlan.swift \
                           Tonycast/Features/WindowManagement/Model/WindowLayoutStore.swift \
                           Tonycast/Features/WindowManagement/Model/CustomWindowSize.swift \
                           Tonycast/Features/WindowManagement/Model/CustomWindowSizeStore.swift
run custom-command-test    Tonycast/Platform/PseudoTerminal.swift \
                           Tonycast/Features/CustomCommands/Model/CustomCommand.swift \
                           Tonycast/Features/CustomCommands/Model/RaycastScriptImport.swift \
                           Tonycast/Features/CustomCommands/Service/ShellCommandRunner.swift
run uninstall-test         Tonycast/Features/Uninstall/Model/UninstallTarget.swift \
                           Tonycast/Features/Uninstall/Model/UninstallSearchRoot.swift \
                           Tonycast/Features/Uninstall/Model/UninstallRules.swift \
                           Tonycast/Features/Uninstall/Model/UninstallProtection.swift \
                           Tonycast/Features/Uninstall/Model/UninstallPlan.swift
run quicklink-test         Tonycast/Features/Quicklinks/Model/Quicklink.swift \
                           Tonycast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Tonycast/Features/Quicklinks/Model/QuicklinkStore.swift \
                           Tonycast/Features/Quicklinks/Model/QuicklinkArchive.swift \
                           Tonycast/Features/Quicklinks/Model/RaycastQuicklinkImport.swift
run slow snippets-test     Tonycast/Platform/NotificationToken.swift \
                           Tonycast/Platform/HealthTicker.swift \
                           Tonycast/Platform/AccessibilityText.swift \
                           Tonycast/Features/Snippets/Model/*.swift \
                           Tonycast/Features/Snippets/Service/*.swift \
                           Tonycast/Features/TextInjection/Service/*.swift
run notes-test             Tonycast/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Tonycast/Features/Notes/Model/*.swift \
                           Tonycast/Features/Notes/Service/*.swift
run notes-editor-test      Tonycast/Platform/Signposts.swift \
                           Tonycast/Platform/Appearance.swift \
                           Tonycast/DesignSystem/Theme.swift \
                           Tonycast/DesignSystem/InterfaceMetrics.swift \
                           Tonycast/Platform/NotificationToken.swift \
                           Tonycast/Features/TextInjection/Service/InjectableTextView.swift \
                           Tonycast/Features/Notes/Model/NoteDocument.swift \
                           Tonycast/Features/Notes/Model/NoteMarkdown.swift \
                           Tonycast/Features/Notes/Model/NoteMarkdownParser.swift \
                           Tonycast/Features/Notes/Model/NoteInlineScanner.swift \
                           Tonycast/Features/Notes/Model/NoteEditPlan.swift \
                           Tonycast/Features/Notes/Model/NoteEditAction.swift \
                           Tonycast/Features/Notes/Model/NoteFormatting.swift \
                           Tonycast/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Tonycast/Features/Notes/Model/NoteRevealPolicy.swift \
                           Tonycast/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Tonycast/Features/Notes/UI/NoteBlockDecoration.swift \
                           Tonycast/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Tonycast/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Tonycast/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Tonycast/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Tonycast/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Tonycast/Features/Notes/UI/NoteTextViewEditing.swift \
                           Tonycast/Features/Notes/UI/NoteTextView.swift \
                           Tonycast/Features/Notes/UI/NoteEditorView.swift
run -O index notes-editor-performance \
                           Tonycast/Platform/Signposts.swift \
                           Tonycast/Platform/Appearance.swift \
                           Tonycast/DesignSystem/Theme.swift \
                           Tonycast/DesignSystem/InterfaceMetrics.swift \
                           Tonycast/Platform/NotificationToken.swift \
                           Tonycast/Features/TextInjection/Service/InjectableTextView.swift \
                           Tonycast/Features/Notes/Model/NoteDocument.swift \
                           Tonycast/Features/Notes/Model/NoteMarkdown.swift \
                           Tonycast/Features/Notes/Model/NoteMarkdownParser.swift \
                           Tonycast/Features/Notes/Model/NoteInlineScanner.swift \
                           Tonycast/Features/Notes/Model/NoteEditPlan.swift \
                           Tonycast/Features/Notes/Model/NoteEditAction.swift \
                           Tonycast/Features/Notes/Model/NoteFormatting.swift \
                           Tonycast/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Tonycast/Features/Notes/Model/NoteRevealPolicy.swift \
                           Tonycast/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Tonycast/Features/Notes/UI/NoteBlockDecoration.swift \
                           Tonycast/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Tonycast/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Tonycast/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Tonycast/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Tonycast/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Tonycast/Features/Notes/UI/NoteTextViewEditing.swift \
                           Tonycast/Features/Notes/UI/NoteTextView.swift \
                           Tonycast/Features/Notes/UI/NoteEditorView.swift
run slow -O raycast-test   Tonycast/Features/Backup/Model/RaycastImportError.swift \
                           Tonycast/Features/Backup/Service/RaycastDecoder.swift \
                           Tonycast/Features/Backup/Service/Scrypt.swift \
                           Tonycast/Platform/Compression/Zlib.swift
run settings-backup-test   Tonycast/Features/Settings/AppSettingsKey.swift \
                           Tonycast/Features/Backup/Model/SettingsBackupCoverage.swift
run backup-archive-test    Tonycast/Platform/AppPaths.swift \
                           Tonycast/Features/Backup/Model/BackupArchive.swift \
                           Tonycast/Features/Backup/Model/BackupBundle.swift \
                           Tonycast/Features/Backup/Model/BackupCategory.swift \
                           Tonycast/Features/Backup/Model/BackupClipboardItem.swift \
                           Tonycast/Features/Backup/Model/BackupManifest.swift \
                           Tonycast/Features/Backup/Service/BackupStaging.swift
E=Tonycast/Features/Extensions
run symbols-test           $E/Service/SymbolCatalog.swift
run ext-cleanup-test       $E/Service/ExtensionCleanup.swift \
                           $E/Service/ExtensionCatalog.swift \
                           Tonycast/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-refresh-test       $E/Model/ExtensionManifest.swift \
                           Tonycast/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-metadata-test      $E/Model/ExtensionCommandMetadata.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift
run ext-store-test         $E/Model/ExtensionRegistry.swift \
                           $E/Model/ExtensionPackageManager.swift \
                           $E/Model/ExtensionStoreResponse.swift
run ext-form-test          $E/Model/ExtensionFormMetrics.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/UI/ExtensionFormKey.swift \
                           $E/Model/ExtensionDateExpression.swift \
                           $E/UI/ExtensionListKey.swift \
                           Tests/ext-list-key-test.swift
run ext-image-size-test   $E/Model/ExtensionImageSize.swift
run ext-accessory-test     $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionStorage.swift
run slow ext-test          -parse-as-library \
                           Tonycast/Platform/Appearance.swift \
                           Tonycast/Platform/AppDisplayName.swift \
                           Tonycast/Platform/Images/IconCache.swift \
                           Tonycast/DesignSystem/Theme.swift \
                           Tonycast/DesignSystem/InterfaceMetrics.swift \
                           $E/Model/ExtensionBootConfig.swift \
                           $E/Model/ExtensionDeepLink.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/Model/ExtensionGridLayout.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift \
                           $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionCatalog.swift \
                           $E/Service/ExtensionFetcher.swift \
                           $E/Service/ExtensionIconCache.swift \
                           $E/Service/ExtensionNodeShims.swift \
                           $E/Service/ExtensionOAuthKeychain.swift \
                           $E/Service/ExtensionOAuthSession.swift \
                           $E/Service/ExtensionRuntime.swift \
                           $E/Service/ExtensionNameResolver.swift \
                           $E/Service/ExtensionWebSocketBridge.swift \
                           $E/UI/ExtensionAnimatedImage.swift \
                           $E/UI/ExtensionImage.swift \
                           $E/UI/ExtensionScreen.swift \
                           $L/SearchRelevance.swift \
                           Tonycast/Platform/Compression/Zlib.swift \
                           Tonycast/Features/Clipboard/Model/ColorValue.swift \
                           Tonycast/Features/Clipboard/Model/ColorSpaces.swift
run settings-history-test  Tonycast/Features/Settings/SettingsTab.swift \
                           Tonycast/Features/Settings/SettingsHistory.swift \
                           Tonycast/Features/Settings/SettingsAnchor.swift \
                           Tonycast/Features/Settings/SettingsNavigationState.swift \
                           Tonycast/Features/Settings/SettingsSearchCatalog.swift \
                           $L/SearchRelevance.swift
run updates-test           Tonycast/Features/Updates/Model/*.swift \
                           Tonycast/Features/Updates/Service/BundleSignature.swift
run ai-provider-test       Tonycast/Features/Settings/AppSettingsKey.swift \
                           Tonycast/Features/AI/Model/*.swift \
                           Tonycast/Features/AI/Settings/AISettingsStore.swift
run ai-chat-test           Tonycast/Features/AI/Model/AIRequest.swift \
                           Tonycast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Tonycast/Features/AI/Model/AIRetention.swift \
                           Tonycast/Features/AI/Model/AITool.swift \
                           Tonycast/Features/AI/Model/JSONValue.swift \
                           Tonycast/Features/AI/Model/ChatMessage.swift \
                           Tonycast/Features/AI/Model/ChatSession.swift \
                           Tonycast/Features/AI/Model/MarkdownBlock.swift \
                           Tonycast/Features/AI/Service/AIProvider.swift \
                           Tonycast/Features/AI/Service/ChatHistoryStore.swift \
                           Tonycast/Features/AI/Service/AIToolLoopProvider.swift \
                           Tonycast/Features/AI/UI/AIChatState.swift
run mcp-test               Tonycast/Features/Settings/AppSettingsKey.swift \
                           Tonycast/Features/AI/Model/AIConnection.swift \
                           Tonycast/Features/AI/Model/AppleIntelligence.swift \
                           Tonycast/Features/AI/Model/AITool.swift \
                           Tonycast/Features/AI/Model/JSONValue.swift \
                           Tonycast/Features/MCP/Model/*.swift \
                           Tonycast/Features/MCP/Settings/MCPSettingsStore.swift
run hermes-permission-test Tonycast/Features/AI/Model/JSONValue.swift \
                           Tonycast/Platform/ExecutableLocator.swift \
                           Tonycast/Features/Hermes/Model/ACPAttachment.swift \
                           Tonycast/Features/Hermes/Model/HermesConnection.swift \
                           Tonycast/Features/Hermes/Service/ACPMessage.swift \
                           Tonycast/Features/Hermes/Service/ACPProtocol.swift \
                           Tonycast/Features/Hermes/Service/ACPFrameWriter.swift \
                           Tonycast/Features/Hermes/Service/ACPClient.swift \
                           Tonycast/Features/Hermes/Service/ACPPermissionBroker.swift
run hermes-placement-test Tonycast/Features/AI/Model/JSONValue.swift \
                           Tonycast/Platform/ExecutableLocator.swift \
                           Tonycast/Features/Hermes/Model/ACPTranscriptItem.swift \
                           Tonycast/Features/Hermes/Model/ACPAttachment.swift \
                           Tonycast/Features/Hermes/Model/HermesConnection.swift \
                           Tonycast/Features/Hermes/Model/HermesUsageFormat.swift \
                           Tonycast/Features/Hermes/Settings/HermesSettings.swift \
                           Tonycast/Features/Hermes/Service/ACPProtocol.swift \
                           Tonycast/Features/Hermes/Service/ACPMessage.swift \
                           Tonycast/Features/Hermes/Service/ACPFrameWriter.swift \
                           Tonycast/Features/Hermes/Service/ACPClient.swift \
                           Tonycast/Features/Hermes/Service/ACPPermissionBroker.swift \
                           Tonycast/Features/Hermes/Service/ACPSessionManager.swift
run hermes-features-test  Tonycast/Features/Updates/Model/AppVersion.swift \
                           Tonycast/Features/AI/Model/JSONValue.swift \
                           Tonycast/Features/Hermes/Model/ACPTranscriptItem.swift \
                           Tonycast/Features/Hermes/Model/ACPAttachment.swift \
                           Tonycast/Features/Hermes/Model/HermesConnection.swift \
                           Tonycast/Features/Hermes/Model/HermesUsageFormat.swift \
                           Tonycast/Features/Hermes/Service/ACPProtocol.swift \
                           Tonycast/Features/Hermes/Service/ACPMessage.swift
run -O text-diff-test      Tonycast/Features/QuickActions/Model/TextDiffEngine.swift
run index text-diff-performance Tonycast/Features/QuickActions/Model/TextDiffEngine.swift
run quick-action-test      Tonycast/Features/Settings/AppSettingsKey.swift \
                           Tonycast/Features/AI/Model/AIConnection.swift \
                           Tonycast/Features/AI/Model/AppleIntelligence.swift \
                           Tonycast/Features/AI/Model/ChatGPTSubscription.swift \
                           Tonycast/Features/AI/Model/InstalledAI.swift \
                           Tonycast/Features/QuickActions/Model/*.swift \
                           Tonycast/Features/QuickActions/Settings/QuickActionSettingsStore.swift
run apple-intelligence-test Tonycast/Features/Settings/AppSettingsKey.swift \
                           Tonycast/Features/AI/Model/*.swift \
                           Tonycast/Features/AI/Service/AIProvider.swift \
                           Tonycast/Features/AI/Service/AppleIntelligenceProvider.swift
run slow mcp-stdio-test    Tonycast/Platform/ExecutableLocator.swift \
                           Tonycast/Platform/KeychainSecretStore.swift \
                           Tonycast/Features/Settings/AppSettingsKey.swift \
                           Tonycast/Features/AI/Model/AIConnection.swift \
                           Tonycast/Features/AI/Model/AppleIntelligence.swift \
                           Tonycast/Features/AI/Model/AITool.swift \
                           Tonycast/Features/AI/Model/AIStreamDecoder.swift \
                           Tonycast/Features/AI/Model/AIRequest.swift \
                           Tonycast/Features/AI/Model/JSONValue.swift \
                           Tonycast/Features/MCP/Model/*.swift \
                           Tonycast/Features/MCP/Service/*.swift
run slow codex-turn-test   Tonycast/Platform/AppPaths.swift \
                           Tonycast/Features/AI/Model/*.swift \
                           Tonycast/Features/AI/Service/AIProvider.swift \
                           Tonycast/Features/AI/Service/ChatGPTSubscriptionManager.swift \
                           Tonycast/Features/AI/Service/CodexAppServerClient.swift \
                           Tonycast/Platform/ExecutableLocator.swift \
                           Tonycast/Features/AI/Service/CodexTurnRunner.swift
run installed-ai-test     Tonycast/Features/AI/Model/*.swift \
                          Tonycast/Features/AI/Service/AIProvider.swift \
                          Tonycast/Platform/AppPaths.swift \
                          Tonycast/Platform/ExecutableLocator.swift \
                          Tonycast/Features/AI/Service/InstalledCLIProvider.swift \
                          Tonycast/Features/AI/Service/InstalledAIManager.swift

if [ "$emit_db" -eq 1 ]; then
    printf ']\n' >> "$DB"
    [ -f .compile ] || echo '[]' > .compile
    node -e '
const fs = require("node:fs");
const [comp, db] = process.argv.slice(1);
const existing = JSON.parse(fs.readFileSync(comp, "utf8"));
const harnesses = JSON.parse(fs.readFileSync(db, "utf8"));
const kept = existing.filter((e) => !(e.files || []).some((f) => f.includes("/Tests/")));
fs.writeFileSync(comp, JSON.stringify([...kept, ...harnesses], null, 1));
console.log(harnesses.length + " harness entries indexed into .compile");
' .compile "$DB"
    exit 0
fi

if [ "$ran" -eq 0 ]; then
    echo "No harness named '$only'." >&2
    exit 2
fi

# `sort -s` is stable, so the slow harnesses lead and everything else keeps its declaration order.
JOBS="${TONYCAST_TEST_JOBS:-$(sysctl -n hw.ncpu)}"
export TONYCAST_TEST_TIMEOUT="${TONYCAST_TEST_TIMEOUT:-300}"
started=$SECONDS

# Numbers each result, and names what is still running whenever the output goes quiet.
report() {
    local finished=0 line asked running file
    while :; do
        asked=$SECONDS
        if IFS= read -r -t 15 line; then
            case "$line" in "dispatch "*) return "${line#dispatch }";; esac
            finished=$((finished + 1))
            printf '[%*d/%d] %s\n' "${#ran}" "$finished" "$ran" "$line"
            continue
        fi
        # Bash 3.2 returns the same status for a timeout and EOF; only EOF comes back at once.
        if [ $((SECONDS - asked)) -lt 10 ]; then return 1; fi
        running=""
        for file in "$BIN"/*.running; do
            [ -e "$file" ] && running="$running $(basename "$file" .running)"
        done
        printf '        \033[2mstill running after %ds:%s\033[0m\n' $((SECONDS - started)) "$running"
    done
}

# Without this the suite reports "all passed" whenever dispatch itself dies and no harness ran.
if ! { sort -s -k1,1n "$QUEUE" | cut -d' ' -f2- | xargs -P "$JOBS" -L1 "$SELF" --exec; echo "dispatch $?"; } | report; then
    echo "harness dispatch failed; no result below can be trusted" >&2
    exit 1
fi
elapsed=$((SECONDS - started))

# A compiler diagnostic is far longer than PIPE_BUF, so the workers log it and it is replayed here.
while read -r _ name _; do
    if [ -f "$BIN/$name.failed" ]; then failed+=("$name"); fi
done < "$QUEUE"

if [ ${#failed[@]} -gt 0 ]; then
    for name in "${failed[@]}"; do
        printf '\n\033[31m--- %s ---\033[0m\n' "$name"
        cat "$BIN/$name.log"
    done
    printf '\n\033[31mFAILED\033[0m  %d of %d harness(es) failed in %ds: %s\n' \
        "${#failed[@]}" "$ran" "$elapsed" "${failed[*]}" >&2
    exit 1
fi
printf '\n\033[32mPASSED\033[0m  All %d harness(es) passed in %ds.\n' "$ran" "$elapsed"
