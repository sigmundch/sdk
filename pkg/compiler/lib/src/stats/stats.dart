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
  final Map<String, GroupResult> packages = {};

  /// Results for loose files, typically the entrypoint and files loaded via
  /// relative imports.
  final GroupResult loose = new GroupResult('*loose*');

  /// Results from system libraries (dart:core, dart:async, etc).
  final GroupResult system = new GroupResult('*system*');

  /// Add the result of a library in its corresponding group.
  void add(LibraryResult library) {
    if (library.uri.scheme == 'package') {
      var name = library.uri.pathSegments[0];
      var package = packages.putIfAbsent(name, () => new GroupResult(name));
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
class GroupResult {
  /// Name of the group.
  final String name;
  final List<LibraryResult> libraries = [];

  GroupResult(this.name);
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

  /// Metrics collected.
  final Metrics metrics;

  FunctionResult(this.name, this.metrics);
  accept(ResultVisitor v) => v.visitFunction(this);
}

enum Measurement {
  send,
  dynamicGet
}

Map<Measurement, String> measurementNames = const {
  Measurement.send: 'send',
  Measurement.dynamicGet: 'dynamic get',
};

class Metrics {
  Map<Measurement, int> counters = <Measurement, int>{};

  Metrics() {
    Measurement.values.forEach((v) => counters[v] = 0);
  }

  operator[](Measurement key) => counters[key];
  operator[]=(Measurement key, int value) => counters[key] = value;

  addFrom(Metrics other) {
    other.counters.forEach((k, v) => counters[k] += v);
  }
}

/// Simple visitor of the result hierarchy (useful for computing summaries for
/// quick reports).
abstract class ResultVisitor {
  visitGlobal(GlobalResult global);
  visitGroup(GroupResult group);
  visitLibrary(LibraryResult library);
  visitFunction(FunctionResult functino);
}

/// Recursive visitor that visits every function starting from the global
/// results.
abstract class RecursiveResultVisitor {
  visitGlobal(GlobalResult global) {
    global.packages.values.forEach(visitGroup);
    visitGroup(global.system);
    visitGroup(global.loose);
  }

  visitGroup(GroupResult group) {
    group.libraries.forEach(visitLibrary);
  }

  visitLibrary(LibraryResult library) {
    library.functions.forEach(visitFunction);
  }
}
