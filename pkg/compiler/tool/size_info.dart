import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:compiler/src/info/info.dart';

main(args) {
  if (args.length < 0) {
    print('usage: dart tool/size_info.dart path-to-info.json');
    exit(1);
  }

  var filename = args[0];
  var json = JSON.decode(new File(filename).readAsStringSync());
  var info = AllInfo.parseFromJson(json);

  var packageSizes = {};
  packageSizes['TOTAL'] = 0;
  packageSizes['loose'] = 0;
  packageSizes['other packages'] = 0;
  packageSizes['angular2'] = 0;
  packageSizes['awsm app'] = 0;
  packageSizes['acx'] = 0;
  packageSizes['other g3 packages'] = 0;
  packageSizes['core libs'] = 0;
  for (LibraryInfo lib in info.libraries) {
    var pname;
    var bname;
    var scheme = lib.uri.scheme;
    if (scheme == 'file') {
      pname = 'loose';
      bname = 'loose';
    } else if (scheme == 'package') {
      pname = lib.uri.pathSegments[0];
      bname = pname;
      if (!bname.contains('.') && bname != 'angular2') bname = 'other packages';
    } else if (scheme == 'dart') {
      pname = '${lib.uri}';
      bname = 'core libs';
    }
    if (pname.startsWith('ads.acx2')) bname = 'acx';
    if (pname.startsWith('ads.awapps')) bname = 'awsm app';
    packageSizes.putIfAbsent(pname, () => 0);
    packageSizes[pname] += lib.size;
    packageSizes[bname] += lib.size;
    packageSizes['TOTAL'] += lib.size;
  }

  var all = packageSizes.keys.toList();
  all.sort((a, b) => packageSizes[a] - packageSizes[b]);
  var realTotal = info.program.size;
  var longest = all.fold(0, (count, value) => max(count, value.length));
  for (var pname in all) {
    var size = packageSizes[pname];
    var percent = (size * 100 / realTotal).toStringAsFixed(2);
    print(' ${_pad(pname, longest + 1, right: true)} ${_pad(size, 8)} ${_pad(percent, 6)}%');
  }
}

_pad(value, n, {bool right: false}) {
  var s = '$value';
  if (s.length >= n) return s;
  var pad = ' ' * (n - s.length);
  return right ? '$s$pad' : '$pad$s';
}
