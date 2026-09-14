/// HTML generation for the in-app spreadsheet viewer
/// (SpreadsheetViewerScreen).
///
/// XLSX/XLS/ODS documents are rendered by SheetJS (bundled at
/// `assets/js/xlsx.full.min.js`); CSV is rendered directly. Both paths emit a
/// standalone HTML document that the screen writes to a temp file and loads
/// via `WebViewController.loadFile` — `loadHtmlString` silently fails to
/// paint large documents (the inlined SheetJS asset alone is ~930 KB) on some
/// Android WebViews.
library;

/// Escapes [s] for safe interpolation into HTML text content.
String escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Splits a single CSV [row] into cell values.
///
/// Commas inside double-quoted cells are kept; quote characters toggle
/// quoting rather than being removed (matches the historical viewer
/// behaviour).
List<String> parseCsvRow(String row) {
  final cells = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
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

/// Wraps a pre-rendered HTML [body] fragment in the viewer page shell.
String wrapSheetHtml(String body) => '''<!DOCTYPE html>
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

/// Builds the CSV viewer document from raw CSV text [raw].
String buildCsvViewerHtml(String raw) {
  final rows = raw.split('\n').where((r) => r.trim().isNotEmpty).toList();
  final tableRows = rows.map((row) {
    final tds = parseCsvRow(row).map((c) => '<td>${escapeHtml(c)}</td>').join();
    return '<tr>$tds</tr>';
  }).join('\n');
  return wrapSheetHtml('<table>$tableRows</table>');
}

/// Builds the XLSX/XLS/ODS viewer document: [sheetJsSource] (the bundled
/// SheetJS asset) and the file's [base64Bytes] are inlined into a standalone
/// HTML page that parses the workbook and renders sheet tabs + a table.
String buildSheetJsViewerHtml({
  required String sheetJsSource,
  required String base64Bytes,
}) {
  // A literal "</script>" anywhere inside inlined JS would terminate the
  // <script> block early and silently disable the whole viewer — the parser
  // never reaches the render call. Guard against it at build time.
  assert(
    !sheetJsSource.contains('</script'),
    'sheetJsSource must not contain a literal </script sequence',
  );
  return '''<!DOCTYPE html>
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
<div id="msg">Loading spreadsheet…</div>
<script>
$sheetJsSource
</script>
<script>
var B64 = "$base64Bytes";
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
}