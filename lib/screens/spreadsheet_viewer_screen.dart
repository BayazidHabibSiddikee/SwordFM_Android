import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';
import '../theme/theme.dart';

/// In-app spreadsheet viewer for XLSX / XLS / ODS / CSV files.
///
/// XLSX/XLS/ODS: reads raw bytes, passes base64 to embedded SheetJS
/// (bundled locally at assets/js/xlsx.full.min.js — works fully offline)
/// which renders an HTML table. CSV: reads as text and formats directly
/// without SheetJS.
class SpreadsheetViewerScreen extends StatefulWidget {
  final String filePath;
  const SpreadsheetViewerScreen({super.key, required this.filePath});

  @override
  State<SpreadsheetViewerScreen> createState() =>
      _SpreadsheetViewerScreenState();
}

class _SpreadsheetViewerScreenState extends State<SpreadsheetViewerScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  String get _fileName => p.basename(widget.filePath);
  String get _ext => p.extension(widget.filePath).toLowerCase();
  bool get _isCsv => _ext == '.csv';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (err) {
          if (mounted) setState(() => _error = err.description);
        },
      ));
    _loadFile();
  }

  Future<void> _loadFile() async {
    try {
      if (_isCsv) {
        await _loadCsv();
      } else {
        await _loadBinarySheet();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  // ── CSV ─────────────────────────────────────────────────────────────────
  Future<void> _loadCsv() async {
    final raw = await File(widget.filePath).readAsString();
    final rows = raw.split('\n').where((r) => r.trim().isNotEmpty).toList();
    final tableRows = rows.map((row) {
      final cells = _parseCsvRow(row);
      final tds = cells.map((c) => '<td>${_esc(c)}</td>').join();
      return '<tr>$tds</tr>';
    }).join('\n');

    final html = _wrapHtml('<table>$tableRows</table>');
    await _controller.loadHtmlString(html);
  }

  List<String> _parseCsvRow(String row) {
    final cells = <String>[];
    final buf = StringBuffer();
    bool inQuotes = false;
    for (var i = 0; i < row.length; i++) {
      final c = row[i];
      if (c == '"') {
        inQuotes = !inQuotes;
      } else if (c == ',' && !inQuotes) {
        cells.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    cells.add(buf.toString());
    return cells;
  }

  // ── XLSX / XLS / ODS ────────────────────────────────────────────────────
  Future<void> _loadBinarySheet() async {
    final bytes = await File(widget.filePath).readAsBytes();
    final b64 = base64Encode(bytes);

    // Load SheetJS from the bundled asset (assets/js/xlsx.full.min.js) so the
    // viewer works fully offline. The JS is inlined into the HTML string to
    // avoid cross-origin/file:// restrictions in the WebView.
    final sheetJsBytes =
        await DefaultAssetBundle.of(context).loadString('assets/js/xlsx.full.min.js');

    final html = '''<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  body { font-family: monospace; font-size: 12px;
         background: #282c34; color: #abb2bf; margin: 0; }
  #msg { padding: 16px; color: #e5c07b; }
  .sheet-tabs { display:flex; flex-wrap:wrap; gap:4px;
                padding: 6px 8px; background:#21252b; }
  .sheet-tab  { padding: 4px 10px; border-radius: 4px; cursor: pointer;
                background:#3e4451; color:#abb2bf; border:none; font-size:12px; }
  .sheet-tab.active { background:#61afef; color:#282c34; }
  .tbl-wrap { overflow:auto; max-height: calc(100vh - 60px); }
  table { border-collapse: collapse; width: max-content; }
  th, td { border: 1px solid #3e4451; padding: 4px 8px;
            white-space: nowrap; min-width: 60px; }
  th { background:#2c313a; color:#e5c07b; position:sticky; top:0; z-index:1; }
  tr:nth-child(even) td { background:#2c313a; }
</style>
</head>
<body>
<div id="msg">Loading spreadsheet\u2026</div>
<script>
$sheetJsBytes
</script>
<script>
var B64 = "$b64";
function b64ToUint8(b){ var bin=atob(b),buf=new Uint8Array(bin.length);
  for(var i=0;i<bin.length;i++) buf[i]=bin.charCodeAt(i); return buf; }

function renderSheet(wb, name){
  var ws = wb.Sheets[name];
  if(!ws){ document.getElementById("tbl-wrap").innerHTML="<p>Empty sheet</p>"; return; }
  var html = XLSX.utils.sheet_to_html(ws,{editable:false});
  var wrap = document.getElementById("tbl-wrap");
  wrap.innerHTML = html;
  wrap.querySelectorAll("table").forEach(function(t){
    t.style.borderCollapse="collapse";
    t.querySelectorAll("td,th").forEach(function(c){
      c.style.border="1px solid #3e4451";
      c.style.padding="4px 8px";
      c.style.whiteSpace="nowrap";
      c.style.background="";
      c.style.color="#abb2bf";
    });
  });
}

function buildTabs(wb, active){
  var tabs = document.getElementById("tabs");
  tabs.innerHTML="";
  wb.SheetNames.forEach(function(n){
    var btn=document.createElement("button");
    btn.className="sheet-tab"+(n===active?" active":"");
    btn.textContent=n;
    btn.onclick=function(){ renderSheet(wb,n);
      tabs.querySelectorAll(".sheet-tab").forEach(function(b){b.classList.remove("active");});
      btn.classList.add("active");
    };
    tabs.appendChild(btn);
  });
}

try {
  var data = b64ToUint8(B64);
  var wb = XLSX.read(data, {type:"array"});
  document.getElementById("msg").style.display="none";
  document.getElementById("tabs").style.display="flex";
  document.getElementById("tbl-wrap").style.display="block";
  buildTabs(wb, wb.SheetNames[0]);
  renderSheet(wb, wb.SheetNames[0]);
} catch(e){
  document.getElementById("msg").textContent = "Error: "+e;
}
</script>
<div class="sheet-tabs" id="tabs" style="display:none"></div>
<div id="tbl-wrap" class="tbl-wrap" style="display:none"></div>
</body></html>''';

    await _controller.loadHtmlString(html);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────
  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  String _wrapHtml(String body) => '''<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  body { font-family: monospace; font-size: 12px;
         background: #282c34; color: #abb2bf; margin: 0; overflow-x: auto; }
  .tbl-wrap { overflow: auto; }
  table { border-collapse: collapse; width: max-content; }
  th, td { border: 1px solid #3e4451; padding: 4px 8px; white-space: nowrap; }
  th { background: #2c313a; color: #e5c07b; position: sticky; top: 0; }
  tr:nth-child(even) td { background: #2c313a; }
</style>
</head>
<body><div class="tbl-wrap">$body</div></body>
</html>''';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        backgroundColor: OneDarkColors.bgDark,
        title: Text(_fileName,
            style: TextStyle(color: OneDarkColors.fg, fontSize: 14)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: OneDarkColors.fg),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: OneDarkColors.fgDim),
            tooltip: 'Reload',
            onPressed: _loadFile,
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline,
                        color: OneDarkColors.red, size: 48),
                    const SizedBox(height: 12),
                    Text('Failed to load spreadsheet',
                        style: TextStyle(
                            color: OneDarkColors.fg,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(_error!,
                        style: TextStyle(
                            color: OneDarkColors.fgDim, fontSize: 12),
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            )
          else
            WebViewWidget(controller: _controller),
          if (_loading && _error == null)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
