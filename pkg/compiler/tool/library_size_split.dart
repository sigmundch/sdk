// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Command-line tool to show the size distribution of generated code among
/// libraries. Libraries can be grouped using regular expressions. See
/// [defaultGrouping] for an example.
library compiler.tool.library_size_split;

import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:compiler/src/info/info.dart';
import 'package:yaml/yaml.dart';

main(args) {
  if (args.length < 0) {
    print('usage: dart tool/size_info.dart path-to-info.json [grouping.yaml]');
    exit(1);
  }

  var filename = args[0];
  var json = JSON.decode(new File(filename).readAsStringSync());
  var info = AllInfo.parseFromJson(json);

  var groupingText = args.length > 1
      ? new File(args[1]).readAsStringSync() : defaultGrouping;
  var groupingYaml = loadYaml(groupingText);
  var groups = {};
  for (var group in groupingYaml['groups']) {
    var name = group['name'];
    groups[name] = new RegExp(group['regexp']);
  }

  var sizes = {};
  for (LibraryInfo lib in info.libraries) {
    groups.forEach((name, RegExp regexp) {
      var m = regexp.firstMatch('${lib.uri}');
      if (m != null) {
        if (name == null) name = m.group(1);
        if (name == null) name = m.group(0);
        sizes.putIfAbsent(name, () => 0);
        sizes[name] += lib.size;
      }
    });
  }

  var all = sizes.keys.toList();
  all.sort((a, b) => sizes[a] - sizes[b]);
  var realTotal = info.program.size;
  var longest = all.fold(0, (count, value) => max(count, value.length));
  for (var name in all) {
    var size = sizes[name];
    var percent = (size * 100 / realTotal).toStringAsFixed(2);
    print(' ${_pad(name, longest + 1, right: true)}'
          ' ${_pad(size, 8)} ${_pad(percent, 6)}%');
  }
}

_pad(value, n, {bool right: false}) {
  var s = '$value';
  if (s.length >= n) return s;
  var pad = ' ' * (n - s.length);
  return right ? '$s$pad' : '$pad$s';
}

/// Example grouping specification: a yaml format containing a list of
/// name/regexp pairs. If the name is omitted, it is assume to be group(1) of
/// the regexp.
const defaultGrouping = r"""
groups:
- { name: "TOTAL", regexp: ".*" }
- { name: "loose", regexp: "file://.*" }
- { name: "packages", regexp: "package:.*" }
- { name: "core libs", regexp: "dart:.*" }
# We omitted `name` to extract the package name from the regexp directly.
- { regexp: "package:([^/]*)" }
""";
