// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Command-line tool presenting combined information from dump-info and
/// coverage data.
///
/// This tool requires two input files an `.info.json` and a
/// `.coverage.json` file. To produce this files you need to:
///   * compile an app with dart2js using --dump-info and defining the
///   Dart environment --instrumentForCoverage=true:
///
///      dart -DinstrumentForCoverage=true dart2js.dart --dump-info main.dart
///
///   * launch the coverage server to serve up the Javascript code in your app
///
///      dart tool/coverage_log_server.dart main.dart.js
///      # run your server and proxy JS and /coverage requests to the log
///      server.
library compiler.tool.live_code_size_analysis;

import 'dart:convert';
import 'dart:io';

import 'package:compiler/src/info/info.dart';

main(args) {
  if (args.length < 2) {
    print('usage: dart tool/live_code_analysis.dart path-to-info.json '
        'path-to-coverage.json');
    exit(1);
  }

  var json = JSON.decode(new File(args[0]).readAsStringSync());
  var info = AllInfo.parseFromJson(json);
  var coverage = JSON.decode(new File(args[1]).readAsStringSync());
  var verbose = args.length > 2 && args[2] == '-v';

  int realTotal = info.program.size;
  int totalLib = info.libraries.fold(0, (n, lib) => n + lib.size);
  int totalFunctions = info.functions.fold(0, (n, f) => n + f.size);
  int totalFields = info.fields.fold(0, (n, f) => n + f.size);


  Set<Info> listed = new Set()..addAll(info.functions)..addAll(info.fields);
  var tracker = new _SizeTracker(coverage);
  info.accept(tracker);

  // For our sanity we do some validation of dump-info invariants
  if (listed.length != tracker.discovered.length) {
    print('broken invariant:\n'
        '  listed: ${listed.length}\n'
        '  discovered: ${tracker.discovered.length}');
    var diff1 = listed.difference(tracker.discovered);
    var diff2 = tracker.discovered.difference(listed);
    if (diff1.length > 0) {
      print('extra ${diff1.length} in listed '
          '(non-zero ${diff1.where((f) => f.size > 0).length})');
    }
    if (diff2.length > 0) {
      print('extra ${diff2.length} in listed '
          '(non-zero ${diff2.where((f) => f.size > 0).length})');
    }
  }

  const sum = '\u03a3';
  print('--- $sum sizes ---');
  _show('$sum lib', totalLib, realTotal);
  _show('$sum fn', totalFunctions, realTotal);
  _show('$sum field', totalFields, realTotal);
  var discoveredSizes = tracker.discovered.fold(0, (a, i) => a + i.size);
  _show('$sum reachable fn + field', discoveredSizes, realTotal);
  var totalReachable = tracker.stack.last._totalSize;
  var totalUsed = tracker.stack.last._liveSize;
  _show('$sum reachable from libs', totalReachable, realTotal);
  var knownMissing = tracker.missing.values.fold(0, (a, b) => a + b);
  _show('$sum known missing', knownMissing, realTotal);

  _show('$sum in use', totalUsed, realTotal);
  _show('$sum real total', realTotal, realTotal);

  print('--- counters ---');
  var count = tracker.stack.last._count;
  var live = tracker.stack.last._liveCount;
  _show('# in use', live, count);
  _show('# total', count, count);

  if (verbose) {
    // tracker.missing.forEach((k, v) { print('- missing $v from $k'); });
    var unused = tracker.unused;
    unused.sort((a, b) => b.size - a.size);
    unused.forEach((i) {
      var percent = (i.size * 100 / realTotal).toStringAsFixed(2);
      print('${_pad(i.size, 8)} ${_pad(percent, 6)}% ${_longName(i)}');
    });
  }
}

class _SizeTracker extends RecursiveInfoVisitor {
  /// Coverage data (mapping itemId to a map containing two keys `name` and
  /// `count`).
  // TODO(sigmund): define a class for this data.
  final Map<String, Map> coverage;

  _SizeTracker(this.coverage);

  /// [FunctionInfo]s and [FieldInfo]s transitively reachable from [LibraryInfo]
  /// elements.
  final Set<Info> discovered = new Set<Info>();

  /// Total number of bytes missing if you look at the reported size compared
  /// to the sum of the nested infos (e.g. if a class size is smaller than the
  /// sum of its methods). Used for validation and debugging of the dump-info
  /// invariants.
  final Map<Info, int> missing = {};

  /// Set of [FunctionInfo]s that appear to be unused by the app (they are not
  /// registed [coverage]).
  final List unused = [];

  /// Tracks the current state of this visitor.
  List<_State> stack = [new _State()];

  /// Code discovered for a [LibraryInfo], only used for debugging.
  final StringBuffer _debugCode = new StringBuffer();
  int _indent = 2;

  _push() => stack.add(new _State());

  void _pop(info) {
    var last = stack.removeLast();
    var size = last._totalSize;
    if (size > info.size) {
      // record dump-info inconsistencies.
      missing[info] = size - info.size;
    } else {
      // if size < info.size, that is OK, the enclosing element might have code
      // of it's own (e.g. a class declaration includes the name of the class,
      // but the discovered size only counts the size of the members.)
      size = info.size;
    }
    stack.last
      .._totalSize += size
      .._count += last._count
      .._liveCount += last._liveCount
      .._bodySize += last._bodySize
      .._liveSize += last._liveSize;
  }

  bool _debug = false;

  visitLibrary(LibraryInfo info) {
    if ('$info'.contains('dart.js')) {
      //_debug = true;
    }
    _push();
    if (_debug) {
      _debugCode.write('{\n');
      _indent = 4;
    }
    super.visitLibrary(info);
    _pop(info);
    if (_debug) {
      _debug = false;
      _indent = 4;
      _debugCode.write('}\n');
    }
  }

  _handleCodeInfo(info) {
    discovered.add(info);
    var code = info.code;
    if (_debug && code != null) {
      bool isClosureClass = info.name.endsWith('.call');
      if (isClosureClass) {
        var cname = info.name.substring(0, info.name.indexOf('.'));
        _debugCode.write(' ' * _indent);
        _debugCode.write(cname);
        _debugCode.write(': {\n');
        _indent += 2;
        _debugCode.write(' ' * _indent);
        _debugCode.write('...\n');
      }

      print('$info ${isClosureClass} \n${info.code}');
      _debugCode.write(' ' * _indent);
      var endsInNewLine = code.endsWith('\n');
      if (endsInNewLine) code = code.substring(0, code.length - 1);
      _debugCode.write(code.replaceAll('\n', '\n' + (' ' * _indent)));
      if (endsInNewLine) _debugCode.write(',\n');
      if (isClosureClass) {
        _indent -= 2;
        _debugCode.write(' ' * _indent);
        _debugCode.write('},\n');
      }
    }
    stack.last._totalSize += info.size;
    stack.last._bodySize += info.size;
    stack.last._count++;
    if (coverage != null) {
      var data = coverage[info.coverageId];
      if (data != null) {
        // TODO(sigmund): use the same name.
        var name = info.name;
        if (name.contains('.')) name = name.substring(name.lastIndexOf('.') + 1);
        if (data['name'] != name && data['name'] != '') {
          print('invalid coverage: $data for $info');
        }
        stack.last._liveCount++;
        stack.last._liveSize += info.size;
      } else if (info.size > 0) {
        // we should track more precisely data about inlined functions
        unused.add(info);
      }
    }
  }

  visitField(FieldInfo info) {
    _handleCodeInfo(info);
    super.visitField(info);
  }

  visitFunction(FunctionInfo info) {
    _handleCodeInfo(info);
    super.visitFunction(info);
  }

  visitTypedef(TypedefInfo info) {
    if (_debug) print('$info');
    stack.last._totalSize += info.size;
    stack.last._liveSize += info.size;
    super.visitTypedef(info);
  }

  visitClass(ClassInfo info) {
    if (_debug) {
      print('$info');
      _debugCode.write(' ' * _indent);
      _debugCode.write('${info.name}: {\n');
      _indent += 2;
    }
    _push();
    super.visitClass(info);
    _pop(info);
    if (_debug) {
      _debugCode.write(' ' * _indent);
      _debugCode.write('},\n');
      _indent -= 2;
    }
  }
}

class _State {
  int _count = 0;
  int _liveCount = 0;
  int _totalSize = 0;
  int _bodySize = 0;
  int _liveSize = 0;
}


_longName(Info info) {
  var sb = new StringBuffer();
  helper(i) {
    if (i.parent == null) {
      sb.write('${i.name}');
    } else {
      helper(i.parent);
      sb.write('> ${i.name}');
    }
  }
  helper(info);
  return sb.toString();
}

_show(String msg, int size, int total) {
  var percent = (size * 100 / total).toStringAsFixed(2);
  print(' ${_pad(msg, 30, right: true)} ${_pad(size, 8)} ${_pad(percent, 6)}%');
}

_pad(value, n, {bool right: false}) {
  var s = '$value';
  if (s.length >= n) return s;
  var pad = ' ' * (n - s.length);
  return right ? '$s$pad' : '$pad$s';
}
