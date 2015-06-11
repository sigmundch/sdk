/// Collects information used to debug and analyzer internal parts of the
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

/// Summarizes results for a group of libraries. [GlobalResult] defines a group
/// the systems libraries, for loose libraries, and a group per package.
class BundleResult {
  /// Name of the group.
  final String name;
  final List<LibraryResult> libraries = [];

  BundleResult(this.name);
}

/// Results of an individual library.
class LibraryResult {
  /// Canonical URI for the library
  final Uri uri;

  /// List of class names.
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

const List<Metric> _allMetrics = const [
  Metric.functions,
  Metric.reachableFunctions,
  Metric.send,
  Metric.dynamicSend,
  Metric.virtualSend,
  Metric.staticSend,
  Metric.localSend,
  //Metric.newSend,
  Metric.monomorphicSend,
//  Metric.dynamicGet,
//  Metric.dynamicSet,
//  Metric.dynamicInvoke,
////  Metric.staticGet,
////  Metric.staticSet,
////  Metric.staticInvoke,
//  Metric.virtualGet,
//  Metric.virtualSet,
//  Metric.virtualInvoke,
//  Metric.monomorphicGet,
//  Metric.monomorphicSet,
//  Metric.monomorphicInvoke,
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
  final String name;

  const Metric(this.name);

  String toString() => name;

  /// Total functions in a library/package/program.
  static const Metric functions = const GroupedMetric('functions', const [
      reachableFunctions,
  ]);
  static const Metric reachableFunctions = const Metric('reachable functions');

  /// Total sends, and classification of sends
  static const Metric send = const GroupedMetric('send', const [
      dynamicSend,
      virtualSend,
      staticSend,
      localSend,
      nsmSend,
      constructorSend,
      monomorphicSend,
  ]);

  static const Metric dynamicSend = const Metric('dynamic');
  static const Metric virtualSend = const Metric('virtual');
  static const Metric staticSend = const Metric('static');
  // doesn't really count, we might normalize results to remove these at the end
  // includes reading a local variable, reading a parameter, reading a local
  // function.
  static const Metric localSend = const Metric('local');
  static const Metric constructorSend = const Metric('constructor');
  static const Metric monomorphicSend = const Metric('monomorphic');

  // no such method sends
  static const Metric nsmSend = const Metric('nSM');

  // static const Metric dynamicSend = const GroupedMetric('dynamic', const [
  //     dynamicGet,
  //     dynamicSet,
  //     dynamicInvoke,
  // ]);

  // static const Metric virtualSend = const GroupedMetric('virtual', const [
  //     virtualGet,
  //     virtualSet,
  //     virtualInvoke,
  // ]);

  // static const Metric staticSend = const GroupedMetric('static', const [
  //     staticGet,
  //     staticSet,
  //     staticInvoke,
  // ]);


  // static const Metric monomorphicSend = const GroupedMetric('monomorphic', const [
  //     monomorphicGet,
  //     monomorphicSet,
  //     monomorphicInvoke,
  // ]);

  //static const dynamicGet = const Metric('dynamic get');
  //static const dynamicSet = const Metric('dynamic set');
  //static const dynamicInvoke = const Metric('dynamic invoke');
  //static const virtualGet = const Metric('virtual get');
  //static const virtualSet = const Metric('virtual set');
  //static const virtualInvoke = const Metric('virtual invoke');
  //static const staticGet = const Metric('static get');
  //static const staticSet = const Metric('static set');
  //static const staticInvoke = const Metric('static invoke');
  //static const monomorphicGet = const Metric('monomorphic get');
  //static const monomorphicSet = const Metric('monomorphic set');
  //static const monomorphicInvoke = const Metric('monomorphic invoke');
}

/// A metric that is subdivided in smaller metrics.
class GroupedMetric extends Metric {
  final List<Metric> submetrics;

  const GroupedMetric(String name, this.submetrics) : super(name);
}

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

  addFrom(Measurements other) {
    other.counters.forEach((k, v) => this[k] += v);
  }

  bool checkInvariant(Metric key) {
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
