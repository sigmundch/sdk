/// Utility to display [GlobalResults] as a table on the command line.
library stats_viewer;

import 'dart:math' show max;
import 'stats.dart';

String formatAsTable(GlobalResult results) {
  var visitor = new _Counter();
  results.accept(visitor);
  var table = new _Table();
  table.declareColumn('group');
  
  Measurement.values.forEach(
      (m) => table.declareColumn(measurementNames[m], abbreviate: true));
  table.addHeader();
  appendCount(n) => table.addEntry(n == null ? 0 : n);

  for (var group in visitor.groupTotals.keys) {
    table.addEntry(group);
    for (var measurement in Measurement.values) {
      appendCount(visitor.groupTotals[group][measurement]);
    }
  }
  table.addEmptyRow();
  table.addHeader();
  table.addEntry('total');
  for (var measurement in Measurement.values) {
    appendCount(visitor.totals[measurement]);
  }

  appendPercent(count, total) {
    if (count == null) count = 0;
    var value = count * 100 / total;
    table.addEntry(value == 100 ? 100 : value.toStringAsFixed(2));
  }

  table.addEntry('%');
  var totalSends = visitor.totals[Measurement.send];
  for (var measurement in Measurement.values) {
    appendPercent(visitor.totals[measurement], totalSends);
  }

  return table.toString();
}

/// Visitor that adds up results for all functions in libraries, and all
/// libraries in a group.
class _Counter extends RecursiveResultVisitor {
  Map<String, Metrics> groupTotals = {};
  Metrics currentGroupTotals;
  Metrics totals = new Metrics();

  visitGroup(GroupResult group) {
    currentGroupTotals =
        groupTotals.putIfAbsent(group.name, () => new Metrics());
    super.visitGroup(group);
    totals.addFrom(currentGroupTotals);
  }

  visitFunction(FunctionResult function) {
    currentGroupTotals.addFrom(function.metrics);
  }
}

/// Helper class to combine all the information in table form.
class _Table {
  int _totalColumns = 0;
  int get totalColumns => _totalColumns;

  /// Abbreviations, used to make headers shorter.
  Map<String, String> abbreviations = {};

  /// Width of each column.
  List<int> widths = <int>[];

  /// The header for each column (`header.length == totalColumns`).
  List header = [];

  /// Each row on the table. Note that all rows have the same size
  /// (`rows[*].length == totalColumns`).
  List<List> rows = [];

  /// Whether we started adding entries. Indicates that no more columns can be
  /// added.
  bool _sealed = false;

  /// Current row being built by [addEntry].
  List _currentRow;

  /// Add a column with the given [name].
  void declareColumn(String name, {bool abbreviate: false}) {
    assert(!_sealed);
    var headerName = name;
    if (abbreviate) {
      // abbreviate the header by using only the initials of each word
      headerName = name.split(' ').map((s) => s.substring(0, 1).toUpperCase()).join('');
      while (abbreviations[headerName] != null) headerName = "$headerName'";
      abbreviations[headerName] = name;
    }
    widths.add(max(5, headerName.length + 1));
    header.add(headerName);
    _totalColumns++;
  }

  /// Add an entry in the table, creating a new row each time [totalColumns]
  /// entries are added.
  void addEntry(entry) {
    if (_currentRow == null) {
      _sealed = true;
      _currentRow = [];
    }
    int pos = _currentRow.length;
    assert(pos < _totalColumns);

    widths[pos] = max(widths[pos], '$entry'.length + 1);
    _currentRow.add('$entry');

    if (pos + 1 == _totalColumns) {
      rows.add(_currentRow);
      _currentRow = [];
    }
  }

  /// Add an empty row to divide sections of the table.
  void addEmptyRow() {
    var emptyRow = [];
    for (int i = 0; i < _totalColumns; i++) {
      emptyRow.add('-' * widths[i]);
    }
    rows.add(emptyRow);
  }

  /// Enter the header titles. OK to do so more than once in long tables.
  void addHeader() {
    rows.add(header);
  }

  /// Generates a string representation of the table to print on a terminal.
  // TODO(sigmund): add also a .csv format
  String toString() {
    var sb = new StringBuffer();
    sb.write('\n');
    for (var row in rows) {
      for (int i = 0; i < _totalColumns; i++) {
        var entry = row[i];
        // Align first column to the left, everything else to the right.
        sb.write(
            i == 0 ? entry.padRight(widths[i]) : entry.padLeft(widths[i] + 1));
      }
      sb.write('\n');
    }
    sb.write('\nWhere:\n');
    for (var id in abbreviations.keys) {
      sb.write('  $id:'.padRight(7));
      sb.write(' ${abbreviations[id]}\n');
    }
    return sb.toString();
  }
}
