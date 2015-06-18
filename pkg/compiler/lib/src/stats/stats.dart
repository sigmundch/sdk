// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Collects information used to debug and analyze internal parts of the
/// compiler.
///
/// Currently this is focused mainly on data from types and inference, such as
/// understanding of types of expressions and precision of send operations.
///
/// This library focuses on representing the information itself.
/// `stats_builder.dart` contains visitors we use to collect the data,
/// `stats_viewer.dart` contains logic to visualize the data.
library stats;

/// All results from a single run of the compiler on an application.
class GlobalResult {
  /// Results grouped by package.
  final Map<String, BundleResult> packages = {};

  /// Results for loose files, typically the entrypoint and files loaded via
  /// relative imports.
  final BundleResult loose = new BundleResult('*loose*');

  /// Results from system libraries (dart:core, dart:async, etc).
  final BundleResult system = new BundleResult('*system*');

  /// Add the result of a library in its corresponding group.
  void add(LibraryResult library) {
    if (library.uri.scheme == 'package') {
      var name = library.uri.pathSegments[0];
      var package = packages.putIfAbsent(name, () => new BundleResult(name));
      package.libraries.add(library);
    } else if (library.uri.scheme == 'dart') {
      system.libraries.add(library);
    } else {
      loose.libraries.add(library);
    }
  }

  accept(ResultVisitor v) => v.visitGlobal(this);
}

/// Summarizes results for a group of libraries. Used by [GlobalResult] to group
/// the systems libraries, loose libraries, and to create a separate a group per
/// package.
class BundleResult {
  /// Name of the group.
  final String name;

  /// Library results that are part of this group.
  final List<LibraryResult> libraries = [];

  BundleResult(this.name);
}

/// Results of an individual library.
class LibraryResult {
  /// Canonical URI for the library
  final Uri uri;

  /// List of class names.
  // TODO(sigmund): delete? Or should we have a bundle per class?
  final List<String> classes = [];

  /// Results per function and method in this library
  final List<FunctionResult> functions = [];

  LibraryResult(this.uri);
  accept(ResultVisitor v) => v.visitLibrary(this);
}

/// Results on a function.
class FunctionResult {
  /// Name, if-any, of the function.
  final String name;

  /// Measurements collected.
  final Measurements measurements;

  FunctionResult(this.name, this.measurements);
  accept(ResultVisitor v) => v.visitFunction(this);
}

/// Top-level set of metrics
const List<Metric> _topLevelMetrics = const [
  Metric.functions,
  Metric.send,
];

/// Apply `f` on each metric in DFS order on the metric "tree".
visitAllMetrics(f) {
  helper(Metric m, [Metric parent]) {
    f(m, parent);
    if (m is GroupedMetric) m.submetrics.forEach((c) => helper(c, m));
  }
  _topLevelMetrics.forEach(helper);
}

/// A metric we intend to measure.
class Metric {
  /// Name for the metric.
  final String name;

  const Metric(this.name);

  String toString() => name;

  /// Total functions in a library/package/program.
  static const Metric functions = const GroupedMetric('functions', const [
      reachableFunctions,
  ]);

  /// Subset of the functions that are reachable.
  static const Metric reachableFunctions = const Metric('reachable functions');

  /// Total sends, and classification of sends:
  ///
  ///     sends
  ///       |- monomorphic
  ///       |  |- static (top-levels, statics)
  ///       |  |- super
  ///       |  |- local (access to a local var, call local function)
  ///       |  |- constructor (like factory ctros)
  ///       |  |- type variable (reading a type variable)
  ///       |  |- nsm (known no such method exception)
  ///       |  |- single-nsm-call (known no such method call, single target)
  ///       |  |- instance (non-interceptor, only one possible target)
  ///       |  '- interceptor (interceptor, known)
  ///       |
  ///       '- polymorphic
  ///          |- multi-nsm (known to be nSM, but not sure if error, or call, or
  ///                        which call)
  ///          |- virtual (traditional virtual call, polymorphic equivalent of
  ///          |           `instance`, no-interceptor)
  ///          |- multi-interceptor (1 of n possible interceptors)
  ///          '- dynamic (any combination of the above)
  ///
  static const Metric send = const GroupedMetric('send', const [
      monomorphicSend,
      polymorphicSend,
  ]);

  static const Metric monomorphicSend = const GroupedMetric('monomorphic',
      const [
        staticSend,
        superSend,
        localSend,
        constructorSend,
        typeVariableSend,
        nsmErrorSend,
        singleNsmCallSend,
        instanceSend,
        interceptorSend,
      ]);

  static const Metric staticSend = const Metric('static');
  static const Metric superSend = const Metric('super');
  static const Metric localSend = const Metric('local');
  static const Metric constructorSend = const Metric('constructor');
  static const Metric typeVariableSend = const Metric('type variable');
  static const Metric nsmErrorSend = const Metric('nSM error');
  static const Metric singleNsmCallSend = const Metric('nSM call single');
  static const Metric instanceSend = const Metric('instance');
  static const Metric interceptorSend = const Metric('interceptor');

  static const Metric polymorphicSend = const GroupedMetric('polymorphic',
      const [
        multiNsmCallSend,
        virtualSend,
        multiInterceptorSend,
        dynamicSend,
      ]);

  static const Metric multiNsmCallSend = const Metric('nSM call multi');
  static const Metric virtualSend = const Metric('virtual');
  static const Metric multiInterceptorSend = const Metric('interceptor multi');
  static const Metric dynamicSend = const Metric('dynamic');
}

/// A metric that is subdivided in smaller metrics.
class GroupedMetric extends Metric {
  final List<Metric> submetrics;

  const GroupedMetric(String name, this.submetrics) : super(name);
}

/// A collection of data points for each metric. Used to summarize a single
/// fucntion, a library, a package, or an entire program.
class Measurements {
  final Map<Metric, int> counters;

  Measurements() : counters = <Metric, int>{};

  const Measurements.unreachableFunction()
    : counters = const { Metric.functions: 1};

  Measurements.reachableFunction()
    : counters = { Metric.functions: 1, Metric.reachableFunctions: 1};

  operator[](Metric key) {
    var res = counters[key];
    return res == null ? 0 : res;
  }
  operator[]=(Metric key, int value) => counters[key] = value;

  /// Add the counters from [other] into this set of measurements.
  addFrom(Measurements other) {
    other.counters.forEach((k, v) => this[k] += v);
  }

  /// Check that every grouped metric totals the individual counts of it's
  /// submetric.
  bool checkInvariant(GroupedMetric key) {
    int total = this[key];
    int submetricTotal = key.submetrics.fold(0, (n, m) => n + this[m]);
    return total == submetricTotal;
  }
}

/// Simple visitor of the result hierarchy (useful for computing summaries for
/// quick reports).
abstract class ResultVisitor {
  visitGlobal(GlobalResult global);
  visitBundle(BundleResult group);
  visitLibrary(LibraryResult library);
  visitFunction(FunctionResult functino);
}

/// Recursive visitor that visits every function starting from the global
/// results.
abstract class RecursiveResultVisitor extends ResultVisitor {
  visitGlobal(GlobalResult global) {
    global.packages.values.forEach(visitBundle);
    visitBundle(global.system);
    visitBundle(global.loose);
  }

  visitBundle(BundleResult group) {
    group.libraries.forEach(visitLibrary);
  }

  visitLibrary(LibraryResult library) {
    library.functions.forEach(visitFunction);
  }
}

/// Color-highighted string used mainly to debug our invariants.
String recursiveDiagnosticString(Measurements measurements, Metric metric) {
  var sb = new StringBuffer();
  int indent = 0;
  helper(Metric m) {
    //sb.write('  ' * indent);
    int value = measurements[m];
    if (m is! GroupedMetric) {
      sb.write(value);
      sb.write(' ${m.name}');
      return;
    }

    int expected = 0;
    for (var sub in m.submetrics) {
      expected += measurements[sub];
    }
    if (value == expected) {
      sb.write('[32m');
      sb.write(value);
    } else {
      sb.write('[31m');
      sb.write(value);
      sb.write('[33m[');
      sb.write(expected);
    sb.write(']');
    }
    sb.write('[0m');
    sb.write(' ${m.name}');

    bool first = true;
    //sb.write('\n');
    sb.write('(');
    indent++;
    for (var sub in m.submetrics) {
      if (first) {
        first = false;
      } else {
        sb.write(' + ');
      }
      helper(sub);
    }
    indent--;
    sb.write(')');
  }
  helper(metric);
  return sb.toString();
}
