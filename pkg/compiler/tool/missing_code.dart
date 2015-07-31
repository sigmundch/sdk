import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:compiler/src/info/info.dart';

class _SizeValidator extends RecursiveInfoVisitor {
  final Map<Info, int> missing = {};
  final Set<Info> discovered = new Set<Info>();
  int discoveredSizes = 0;
  final StringBuffer allCode = new StringBuffer();
  final StringBuffer debugCode = new StringBuffer();
  int _current = 0;
  int _indent = 2;

  int _before(info) {
    var old = _current;
    _current = 0;
    return old;
  }

  void _after(info, old) {
    if (_current > info.size) {
      missing[info] = _current - info.size;
    } else {
      _current = info.size;
    }
    _current += old;
  }

  bool _debug = false;

  visitLibrary(LibraryInfo info) {
    if ('$info'.contains('dart.js')) {
      //_debug = true;
    }
    var old = _before(info);
    if (_debug) {
      debugCode.write('{\n');
      _indent = 4;
    }
    super.visitLibrary(info);
    _after(info, old);
    if (_debug) {
      _debug = false;
      _indent = 4;
      debugCode.write('}\n');
    }
  }

  _handleCodeInfo(info) {
    if (discovered.add(info)) {
      discoveredSizes += info.size;
    }
    var code = info.code;
    if (_debug && code != null) {
      bool isClosureClass = info.name.endsWith('.call');
      if (isClosureClass) {
        var cname = info.name.substring(0, info.name.indexOf('.'));
        debugCode.write(' ' * _indent);
        debugCode.write(cname);
        debugCode.write(': {\n');
        _indent += 2;
        debugCode.write(' ' * _indent);
        debugCode.write('...\n');
      }

      print('$info ${isClosureClass} \n${info.code}');
      debugCode.write(' ' * _indent);
      var endsInNewLine = code.endsWith('\n');
      if (endsInNewLine) code = code.substring(0, code.length - 1);
      debugCode.write(code.replaceAll('\n', '\n' + (' ' * _indent)));
      if (endsInNewLine) debugCode.write(',\n');
      if (isClosureClass) {
        _indent -= 2;
        debugCode.write(' ' * _indent);
        debugCode.write('},\n');
      }
    }
    _current += info.size;
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
    _current += info.size;
    super.visitTypedef(info);
  }

  visitClass(ClassInfo info) {
    if (_debug) {
      print('$info');
      debugCode.write(' ' * _indent);
      debugCode.write('${info.name}: {\n');
      _indent += 2;
    }
    var old = _before(info);
    super.visitClass(info);
    _after(info, old);
    if (_debug) {
      debugCode.write(' ' * _indent);
      debugCode.write('},\n');
      _indent -= 2;
    }
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

  int totalLib = info.libraries.fold(0, (n, lib) => n + lib.size);
  int totalFunctions = info.functions.fold(0, (n, f) => n + f.size);
  int totalFields = info.fields.fold(0, (n, f) => n + f.size);
  int realTotal = info.program.size;

  Set<Info> listed = new Set()..addAll(info.functions)..addAll(info.fields);
  var validator = new _SizeValidator();
  print('=> listed: ${listed.length}, discovered: ${validator.discovered.length}');
  var diff1 = listed.difference(validator.discovered);
  var diff2 = validator.discovered.difference(listed);
  if (diff1.length > 0) {
    print('extra ${diff1.length} in listed (non-zero ${diff1.where((f) => f.size > 0).length})');
  }
  if (diff2.length > 0) {
    print('extra ${diff2.length} in listed (non-zero ${diff2.where((f) => f.size > 0).length})');
  }

  const sum = '\u03a3';
  _show('$sum lib', totalLib, realTotal);
  _show('$sum fn', totalFunctions, realTotal);
  _show('$sum field', totalFields, realTotal);

  info.accept(validator);
  _show('$sum reachable fn + field', validator.discoveredSizes, realTotal);
  var totalReachable = validator._current;
  var totalMissing = validator.missing.values.fold(0, (a, b) => a + b);
  _show('$sum reachable from libs', totalReachable, realTotal);
  _show('$sum diff missing', totalMissing, realTotal);
  _show('$sum all known', totalReachable + totalMissing, realTotal);
  validator.missing.forEach((k, v) {
      //print('- missing $v from $k');
  });
  _show('$sum real total', realTotal, realTotal);

  new File('$filename.t').writeAsStringSync('${validator.debugCode}');
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
