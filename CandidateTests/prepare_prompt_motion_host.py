"""Prepare isolated hosted tests for search prompts, OCR appearance and composer motion."""
from pathlib import Path
import shutil, subprocess, sys
root = Path(__file__).resolve().parents[1]
host = Path(sys.argv[1]).resolve()
subprocess.run([sys.executable, str(root / 'CandidateTests/prepare_search_tool_prompt_host.py'), str(host)], check=True)
icon = host / 'Mocca/AppIcon.icon'
if icon.is_symlink():
    source = icon.resolve()
    icon.unlink()
    shutil.copytree(source, icon)
settings = host / 'Mocca/SettingsViews.swift'
settings.write_text(settings.read_text() + '\nstruct OCRPromptTestView: View { var body: some View { OCRPromptEditorPage(initialPrompt: UserPreferences.defaultOCRPrompt) { _ in } } }\n')
tests = host / 'Slice1UITests/Slice1UITests.swift'
source = tests.read_text()
needle = '        window.isHidden = true'
assert source.count(needle) == 1
source = source.replace(needle, '        await capture(NavigationStack { OCRPromptTestView() }, "ocr-prompt-body-font")\n' + needle)
tests.write_text(source + '\n' + (root / 'CandidateTests/ComposerIndependentMotionTests.swift').read_text())
print(host)
