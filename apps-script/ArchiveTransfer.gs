/**
 * Neulight OMS Archive → Supabase
 *
 * This is Google Apps Script, bound to the live Archive spreadsheet
 * (Neulight_OMS_Archive). It is not an AppSheet app.
 *
 * The script only reads the sheet. It never edits sheet cells.
 *
 * Install
 * 1. Open the live Archive Google Sheet.
 * 2. Extensions → Apps Script. Paste this file. Save.
 * 3. In Supabase SQL Editor, run supabase/migrations/20261012000000_archive_transfer_rpc.sql once,
 *    then supabase/migrations/20261012010000_archive_maintenance.sql.
 * 4. In Apps Script Project Settings → Script properties, add:
 *    SUPABASE_URL = https://xxxxxxxx.supabase.co
 *    SUPABASE_SERVICE_ROLE_KEY = the service_role secret (Project Settings → API).
 *    Do not put the key in a cell or in this file.
 * 5. Reload the spreadsheet. Archive → Test connection.
 * 6. Archive → Dry run products, then Transfer products.
 * 7. For other tabs use Dry run / Transfer one sheet. Then Transfer all enabled sheets.
 *
 * A rerun is safe. Existing identical rows are skipped. Changed rows are logged
 * in archive.archive_row_changes and are not overwritten.
 *
 * Apps Script stops around 6 minutes. Transfer all enabled sheets can be run
 * again; finished rows are skipped.
 */

var ARCHIVE_TIMEZONE = 'Asia/Manila';
var ARCHIVE_BATCH_SIZE = 150;
var ARCHIVE_TIME_BUDGET_MS = 4.5 * 60 * 1000;

function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu('Archive')
    .addItem('Test connection', 'testArchiveConnection')
    .addSeparator()
    .addItem('Dry run products', 'dryRunProducts')
    .addItem('Transfer products', 'transferProducts')
    .addSeparator()
    .addItem('Dry run one sheet…', 'dryRunChosenSheet')
    .addItem('Transfer one sheet…', 'transferChosenSheet')
    .addSeparator()
    .addItem('Transfer all enabled sheets', 'transferAllEnabled')
    .addToUi();
}

function dryRunChosenSheet() {
  var name = askSheetName_('Dry run one sheet');
  if (name) transferSheet_(name, true, false);
}

function transferChosenSheet() {
  var name = askSheetName_('Transfer one sheet');
  if (name) transferSheet_(name, false, false);
}

function askSheetName_(title) {
  var ui = SpreadsheetApp.getUi();
  var current = SpreadsheetApp.getActiveSheet().getName();
  var answer = ui.prompt(
    title,
    'Exact tab name. Leave blank to use the current tab (' + current + ').',
    ui.ButtonSet.OK_CANCEL
  );
  if (answer.getSelectedButton() !== ui.Button.OK) return null;
  return String(answer.getResponseText() || '').trim() || current;
}

function testArchiveConnection() {
  var sheets = rpc_('archive_list_sheets', { p_include_disabled: false });
  var names = (sheets || []).map(function (row) { return row.source_table; });
  SpreadsheetApp.getUi().alert(
    'Connected. Enabled sheets (' + names.length + '):\n' + names.join(', ')
  );
}

function dryRunProducts() { transferSheet_('products', true, false); }
function transferProducts() { transferSheet_('products', false, false); }

function transferAllEnabled() {
  var started = Date.now();
  var sheets = rpc_('archive_list_sheets', { p_include_disabled: false });
  var notes = [];
  var i;
  for (i = 0; i < sheets.length; i++) {
    if (Date.now() - started > ARCHIVE_TIME_BUDGET_MS) {
      notes.push('Stopped for time. Run Transfer all enabled sheets again.');
      break;
    }
    var result = transferSheet_(sheets[i].source_table, false, false, started);
    notes.push(sheets[i].source_table + ': ' + result.status +
      ' inserted ' + result.inserted +
      ', skipped ' + result.skipped +
      ', changed ' + result.changed +
      ', failed ' + result.failed);
    if (result.status === 'FAILED' || result.status === 'PARTIAL') break;
  }
  SpreadsheetApp.getUi().alert(notes.join('\n'));
}

function transferSheet_(sourceTable, dryRun, force, startedAt) {
  var started = startedAt || Date.now();
  var ui = SpreadsheetApp.getUi();
  var ss = SpreadsheetApp.getActive();
  var contract = rpc_('archive_sheet_contract', { p_source_table: sourceTable });
  var sheet = ss.getSheetByName(sourceTable);
  if (!sheet) throw new Error('No sheet named ' + sourceTable);

  var rows = readMappedRows_(sheet, contract);
  var executionId = rpc_('archive_begin_run', {
    p_source_table: sourceTable,
    p_run_mode: dryRun ? 'DRY_RUN' : 'INITIAL',
    p_source_database: ss.getName(),
    p_force: force
  });

  var totals = { read: 0, inserted: 0, skipped: 0, changed: 0, failed: 0 };
  var status = 'SUCCESS';
  var errorMessage = null;

  try {
    var offset = 0;
    while (offset < rows.length) {
      if (Date.now() - started > ARCHIVE_TIME_BUDGET_MS) {
        status = 'PARTIAL';
        errorMessage = 'Stopped before the Apps Script time limit. Run the same transfer again.';
        break;
      }
      var batch = rows.slice(offset, offset + ARCHIVE_BATCH_SIZE);
      var counts = rpc_('archive_apply_batch', {
        p_source_table: sourceTable,
        p_execution_id: executionId,
        p_rows: batch,
        p_source_file: ss.getName(),
        p_dry_run: dryRun
      });
      totals.read += counts.read || 0;
      totals.inserted += counts.inserted || 0;
      totals.skipped += counts.skipped || 0;
      totals.changed += counts.changed || 0;
      totals.failed += counts.failed || 0;
      offset += batch.length;
    }
    if (status === 'SUCCESS' && totals.failed > 0) {
      status = 'PARTIAL';
      errorMessage = totals.failed + ' row(s) failed. See archive.archive_row_failures.';
    }
  } catch (err) {
    status = 'FAILED';
    errorMessage = String(err && err.message ? err.message : err);
  }

  rpc_('archive_finish_run', {
    p_execution_id: executionId,
    p_status: status,
    p_error: errorMessage
  });

  var summary = sourceTable + ' ' + (dryRun ? 'dry run' : 'transfer') + ': ' + status +
    '\nread ' + totals.read +
    '\ninserted ' + totals.inserted +
    '\nskipped ' + totals.skipped +
    '\nchanged ' + totals.changed +
    '\nfailed ' + totals.failed +
    (errorMessage ? '\n' + errorMessage : '');

  if (!startedAt) ui.alert(summary);

  return {
    status: status,
    inserted: totals.inserted,
    skipped: totals.skipped,
    changed: totals.changed,
    failed: totals.failed
  };
}

function readMappedRows_(sheet, contract) {
  var display = sheet.getDataRange().getDisplayValues();
  var raw = sheet.getDataRange().getValues();
  if (display.length < 2) return [];

  var columnsByName = {};
  contract.columns.forEach(function (col) {
    columnsByName[col.name] = col.data_type;
  });

  var skipHeaders = {};
  (contract.secret_headers || []).forEach(function (name) { skipHeaders[name] = true; });
  (contract.ignored_headers || []).forEach(function (name) { skipHeaders[name] = true; });

  var headerPlan = [];
  var unnamedUsed = 0;
  var unknown = [];
  var seenHeaders = {};
  var c;
  for (c = 0; c < display[0].length; c++) {
    var header = String(display[0][c] || '').trim();
    if (!header) {
      var unnamed = (contract.unnamed_headers || [])[unnamedUsed];
      if (unnamed && columnsByName[unnamed]) {
        headerPlan.push({ index: c, name: unnamed, dataType: columnsByName[unnamed] });
        unnamedUsed++;
      }
      continue;
    }
    if (skipHeaders[header]) continue;
    var mapped = (contract.header_renames && contract.header_renames[header]) || header;
    if (!columnsByName[mapped]) {
      unknown.push(header);
      continue;
    }
    if (seenHeaders[mapped]) throw new Error('Duplicate header for ' + mapped);
    seenHeaders[mapped] = true;
    headerPlan.push({ index: c, name: mapped, dataType: columnsByName[mapped] });
  }

  if (unknown.length) {
    throw new Error('Sheet ' + contract.source_table + ' has headers with no column: ' + unknown.join(', '));
  }

  (contract.key_columns || []).forEach(function (key) {
    if (!seenHeaders[key]) {
      throw new Error('Sheet ' + contract.source_table + ' is missing key column ' + key);
    }
  });

  var out = [];
  var r;
  for (r = 1; r < display.length; r++) {
    var obj = {};
    var any = false;
    headerPlan.forEach(function (col) {
      var value = coerceCell_(col, raw[r][col.index], display[r][col.index]);
      obj[col.name] = value;
      if (value !== null && value !== '') any = true;
    });
    if (any) out.push(obj);
  }
  return out;
}

function coerceCell_(col, rawValue, displayValue) {
  var shown = String(displayValue == null ? '' : displayValue).trim();
  if (rawValue === '' || rawValue === null || shown === '') return null;

  if (col.name === 'packing_duration_seconds') {
    return coerceDuration_(rawValue, shown);
  }

  if (col.dataType === 'boolean') {
    if (typeof rawValue === 'boolean') return rawValue ? 'true' : 'false';
    return shown;
  }

  if (col.dataType === 'timestamp with time zone') {
    if (rawValue instanceof Date && !isNaN(rawValue.getTime())) {
      return Utilities.formatDate(rawValue, ARCHIVE_TIMEZONE, "yyyy-MM-dd'T'HH:mm:ss'+08:00'");
    }
    return shown;
  }

  if (col.dataType === 'jsonb') {
    try {
      return JSON.parse(shown);
    } catch (err) {
      return shown;
    }
  }

  if (col.dataType === 'numeric' || col.dataType === 'integer' || col.dataType === 'bigint') {
    if (typeof rawValue === 'number') return String(rawValue);
    return shown.replace(/[^0-9.\-]/g, '');
  }

  // Text ids must use the displayed text. Numeric cells over 15 digits are already rounded.
  return shown;
}

function coerceDuration_(rawValue, shown) {
  if (typeof rawValue === 'number') return String(rawValue);
  var match = shown.match(/^(\d+):(\d{1,2}):(\d{1,2})$/);
  if (match) {
    return String(Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]));
  }
  if (rawValue instanceof Date && !isNaN(rawValue.getTime())) {
    return String(rawValue.getHours() * 3600 + rawValue.getMinutes() * 60 + rawValue.getSeconds());
  }
  return shown.replace(/,/g, '');
}

function rpc_(name, payload) {
  var props = PropertiesService.getScriptProperties();
  var base = props.getProperty('SUPABASE_URL');
  var key = props.getProperty('SUPABASE_SERVICE_ROLE_KEY');
  if (!base || !key) {
    throw new Error('Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in Apps Script Project Settings → Script properties.');
  }

  var response = UrlFetchApp.fetch(base + '/rest/v1/rpc/' + name, {
    method: 'post',
    contentType: 'application/json',
    headers: {
      apikey: key,
      Authorization: 'Bearer ' + key
    },
    payload: JSON.stringify(payload || {}),
    muteHttpExceptions: true
  });

  var code = response.getResponseCode();
  var text = response.getContentText() || '';
  if (code < 200 || code >= 300) {
    throw new Error(name + ' failed (' + code + '): ' + text);
  }
  if (!text) return null;
  return JSON.parse(text);
}
