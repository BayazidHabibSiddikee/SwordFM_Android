import re

with open('lib/screens/settings_screen.dart', 'r') as f:
    content = f.read()

# Remove onToolTap
content = content.replace('final void Function(int index)? onToolTap;', '')
content = content.replace('const SettingsScreen({super.key, this.onToolTap});', 'const SettingsScreen({super.key});')

# Remove Tools and OCR sections
tools_start = content.find('// Tools')
help_start = content.find("_settingTile(\n            icon: Icons.help_outline,\n            title: 'Help & How-To',")
if tools_start != -1 and help_start != -1:
    content = content[:tools_start] + content[help_start:]

# Remove unused imports
imports_to_remove = [
    "import 'document_scanner_screen.dart';",
    "import 'cast_screen.dart';",
    "import 'notepad_screen.dart';",
    "import 'cloud_browser_screen.dart';",
    "import 'storage_analysis_screen.dart';",
    "import 'duplicates_screen.dart';"
]
for imp in imports_to_remove:
    content = content.replace(imp + '\n', '')

# Remove _openRcloneBrowser, _showOcrLanguagePicker, _showOcrPsmPicker
methods = ['_openRcloneBrowser', '_showOcrLanguagePicker', '_showOcrPsmPicker']
for method in methods:
    start_idx = content.find(f'Future<void> {method}(')
    if start_idx == -1:
        start_idx = content.find(f'void {method}(')
    
    if start_idx != -1:
        # find matching bracket
        open_brackets = 0
        end_idx = -1
        started = False
        for i in range(start_idx, len(content)):
            if content[i] == '{':
                open_brackets += 1
                started = True
            elif content[i] == '}':
                open_brackets -= 1
            if started and open_brackets == 0:
                end_idx = i + 1
                break
        if end_idx != -1:
            content = content[:start_idx] + content[end_idx:]

with open('lib/screens/settings_screen.dart', 'w') as f:
    f.write(content)
