import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:compiler/src/info/info.dart';

class _SizeValidator extends RecursiveInfoVisitor {
  Map<Info, int> diffs = {};
  StringBuffer allCode = new StringBuffer();
  int _current = 0;

  int _before(info) {
    var old = _current;
    _current = 0;
    return old;
  }

  void _after(info, old) {
    if (_current != info.size) {
      diffs[info] = _current - info.size;
      if (info is LibraryInfo && _current < info.size) _current = info.size;
    }
    _current += old;
  }

  visitLibrary(LibraryInfo info) {
    var old = _before(info);
    super.visitLibrary(info);
    _after(info, old);
  }

  visitField(FieldInfo info) {
    _current += info.size;
    allCode.write('\n');
    allCode.write(info.code);
    super.visitField(info);
  }

  visitFunction(FunctionInfo info) {
    _current += info.size;
    allCode.write('\n');
    allCode.write(info.code);
    super.visitFunction(info);
  }

  visitTypedef(TypedefInfo info) {
    _current += info.size;
    super.visitTypedef(info);
  }

  visitClass(ClassInfo info) {
    //var old = _before(info);
    super.visitClass(info);
    //_after(info, old);
  }

}

main(args) {
  if (args.length < 0) {
    print('usage: dart tool/size_info.dart path-to-info.json');
    exit(1);
  }

  var filename = args[0];
  var json = JSON.decode(new File(filename).readAsStringSync());
  var info = AllInfo.parseFromJson(json);

  int totalLib = 0;
  int totalFunctions = 0;
  int totalFields = 0;
  int realTotal = info.program.size;

  Set<Info> listed = new Set()..addAll(info.functions)..addAll(info.fields);
  Set<Info> discovered = new Set();
  var totalCovered = 0;
  int totalClasses = 0;
  helper(f) { totalCovered += f.size; discovered.add(f); f.closures.forEach(helper); }
  for (LibraryInfo lib in info.libraries) {
    totalLib += lib.size;
    lib.topLevelFunctions.forEach(helper);
    lib.topLevelVariables.forEach(helper);
    for (var c in lib.classes) {
      c.functions.forEach(helper);
      c.fields.forEach(helper);
    }
  }
  print('=> listed: ${listed.length}');
  print('=> discovered: ${discovered.length}');
  var diff1 = listed.difference(discovered);
  var diff2 = discovered.difference(listed);
  print('=> ${diff1.length}');
  print('=> ${diff2.length}');

  for (var function in info.functions) {
    totalFunctions += function.size;
  }

  for (var field in info.fields) {
    totalFields += field.size;
  }
  print('=> not covered 1: ${diff1.length} (non-zero ${diff1.where((f) => f.size > 0).length})');
  print('=> not covered 2: ${diff2.length} (non-zero ${diff2.where((f) => f.size > 0).length})');
  _show('total-lib', totalLib, realTotal);
  _show('total-function', totalFunctions, realTotal);
  _show('total-field', totalFields, realTotal);
  _show('total-covered', totalCovered, realTotal);

  var validator = new _SizeValidator();
  info.accept(validator);
  _show('valid?', validator._current, realTotal);
  validator.diffs.forEach((k, v) {
    if (v > 0) print('+$k: $v');
    if (v < 0) print('-$k: $v');
  });

  new File('$filename.t').writeAsStringSync('${validator.allCode}');
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
