// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Test the modular compilation pipeline of dart2js.
///
/// This is a shell that runs multiple tests, one per folder under `data/`.
import 'dart:io';

import 'package:args/args.dart';
import 'package:async_helper/async_helper.dart';
import 'package:expect/expect.dart';
import 'package:front_end/src/compute_platform_binaries_location.dart'
    show computePlatformBinariesLocation;
import 'package:modular_test/src/io_pipeline.dart';
import 'package:modular_test/src/loader.dart';
import 'package:modular_test/src/pipeline.dart';
import 'package:modular_test/src/suite.dart';

_Options _options;
main(List<String> args) {
  _options = _Options.parse(args);
  asyncTest(() async {
    var baseUri = Platform.script.resolve('data/');
    var baseDir = Directory.fromUri(baseUri);
    await for (var entry in baseDir.list(recursive: false)) {
      if (entry is Directory) {
        await _runTest(entry.uri, baseUri);
      }
    }
  });
}

Future<void> _runTest(Uri uri, Uri baseDir) async {
  var dirName = uri.path.substring(baseDir.path.length);
  if (_options.filter != null && !dirName.contains(_options.filter)) {
    if (_options.showSkipped) print("skipped: $dirName");
    return;
  }

  print("testing: $dirName");
  ModularTest test = await loadTest(uri);
  if (_options.verbose) _printTestStructure(test);
  var pipeline = new IOPipeline([
    SourceToDillStep(),
    CompileFromDillStep(),
    RunD8(),
  ]);

  await pipeline.run(test);
}

const dillId = const DataId("dill");
const updatedDillId = const DataId("udill");
const modularAnalysisId = const DataId("mdata");
const jsId = const DataId("js");

// Step that compiles sources in a module to a .dill file.
class SourceToDillStep implements IOModularStep {
  @override
  DataId get resultId => dillId;

  @override
  bool get needsSources => true;

  @override
  List<DataId> get dependencyDataNeeded => const [dillId];

  @override
  List<DataId> get moduleDataNeeded => const [];

  @override
  bool get onlyOnMain => false;

  @override
  Future<void> execute(
      Module module, Uri root, ModuleDataToRelativeUri toUri) async {
    if (_options.verbose) print("step: source-to-dill on $module");
    // We use non file-URI schemes for representeing source locations in a
    // root-agnostic way. This allows us to refer to file across modules and
    // across steps without exposing the underlying temporary folders that are
    // created by the framework. In build systems like bazel this is especially
    // important because each step may be run on a different machine.
    //
    // Files in packages are defined in terms of `package:` URIs, while
    // non-package URIs are defined using the `dart-dev-app` scheme.
    String rootScheme = 'dev-dart-app';
    String sourceToImportUri(Uri relativeUri) {
      if (module.isPackage) {
        var basePath = module.packageBase.path;
        var packageRelativePath = basePath == "./"
            ? relativeUri.path
            : relativeUri.path.substring(basePath.length);
        return 'package:${module.name}/$packageRelativePath';
      } else {
        return '$rootScheme:/$relativeUri';
      }
    }

    // We create a .packages file which defines the location of this module if
    // it is a package. The CFE requires that if a `package:` URI of a
    // dependency is used in an import, then we need that package entry in the
    // .packages file. However, after it checks that the definition exists, the
    // CFE will not actually use the resolved URI if a library for the import
    // URI is already found in one of the provided .dill files of the
    // dependencies. For that reason, it is safe to define those with an invalid
    // folder as we do below.
    var packagesContents = new StringBuffer();
    if (module.isPackage) {
      packagesContents.write('${module.name}:${module.packageBase}\n');
    }
    Set<Module> transitiveDependencies = computeTransitiveDependencies(module);
    for (Module dependency in transitiveDependencies) {
      if (dependency.isPackage) {
        packagesContents.write('${dependency.name}:unused\n');
      }
    }

    await File.fromUri(root.resolve('.packages'))
        .writeAsString('$packagesContents');

    var sdkRoot = Platform.script.resolve("../../../../");
    var platform =
        computePlatformBinariesLocation().resolve("dart2js_platform.dill");

    List<String> workerArgs = [
      sdkRoot.resolve("utils/bazel/kernel_worker.dart").toFilePath(),
      '--no-summary-only',
      '--target',
      'dart2js',
      '--multi-root',
      '$root',
      '--multi-root-scheme',
      rootScheme,
      '--dart-sdk-summary',
      '${platform}',
      '--output',
      '${toUri(module, dillId)}',
      '--packages-file',
      '$rootScheme:/.packages',
      ...(transitiveDependencies
          .expand((m) => ['--input-linked', '${toUri(m, dillId)}'])),
      ...(module.sources.expand((uri) => ['--source', sourceToImportUri(uri)])),
    ];

    var result = await _runProcess(
        Platform.resolvedExecutable, workerArgs, root.toFilePath());
    _checkExitCode(result, this, module);
  }
}

// Step that runs the dart2js modular analysis
class ModularAnalysisDart2jsStep implements IOModularStep {
  @override
  DataId get resultId => modularAnalysisId;

  @override
  bool get needsSources => false;

  @override
  List<DataId> get dependencyDataNeeded => const [dillId];

  @override
  List<DataId> get moduleDataNeeded => const [dillId];

  @override
  bool get onlyOnMain => false;

  @override
  Future<void> execute(
      Module module, Uri root, ModuleDataToRelativeUri toUri) async {
    if (_options.verbose) print("step: modular dart2js on $module");
    Set<Module> transitiveDependencies = computeTransitiveDependencies(module);
    Iterable<String> dillDependencies =
        transitiveDependencies.map((m) => '${toUri(m, dillId)}');
    List<String> dart2jsArgs = [
      '${toUri(module, dillId)}',
      '--dill-dependencies=${dillDependencies.join(',')}',
      '--out=${toUri(module, resultId)}',
      '--modular-analysis',
    ];
    var sdkRoot = Platform.script.resolve("../../../../");
    var result = await _runProcess(
        sdkRoot.resolve("sdk/bin/dart2js").toFilePath(),
        dart2jsArgs,
        root.toFilePath());

    _checkExitCode(result, this, module);
  }
}

//// ------------
//// Work in progress, next steps:
//// 1. add ability to read the modular data
//// 2. add ability for tests to produce output for the sdk
//// 2b. support hybrid mode where the SDK is computed on phase-3?

//// Separate:
//// 3. add ability for tests to emit more than one file
//// 4. add global step separate from full compile step

// Step that links all invokes dart2js on the main module and provides all
// compiled .dill files as inputs to dart2js.
// TODO(sigmund): split out the global analysis. That requires adding support
// for emitting 2 outputs from a step in the modular framework.
class CompileFromDillStep implements IOModularStep {
  @override
  DataId get resultId => jsId;

  @override
  bool get needsSources => false;

  @override
  List<DataId> get dependencyDataNeeded => const [dillId, modularAnalysisId];

  @override
  List<DataId> get moduleDataNeeded => const [dillId, modularAnalysisId];

  @override
  bool get onlyOnMain => true;

  @override
  Future<void> execute(
      Module module, Uri root, ModuleDataToRelativeUri toUri) async {
    if (_options.verbose) print("step: dart2js on $module");
    Set<Module> transitiveDependencies = computeTransitiveDependencies(module);
    Iterable<String> dillDependencies =
        transitiveDependencies.map((m) => '${toUri(m, dillId)}');
    Iterable<String> dataDependencies =
        transitiveDependencies.map((m) => '${toUri(m, modularAnalysisId)}');
    List<String> dart2jsArgs = [
      '${toUri(module, dillId)}',
      '--dill-dependencies=${dillDependencies.join(',')}',
      '--modular-data-dependencies=${dataDependencies.join(',')}',
      '--out=${toUri(module, resultId)}',
    ];
    var sdkRoot = Platform.script.resolve("../../../../");
    var result = await _runProcess(
        sdkRoot.resolve("sdk/bin/dart2js").toFilePath(),
        dart2jsArgs,
        root.toFilePath());

    _checkExitCode(result, this, module);
  }
}

/// Step that runs the output of dart2js in d8 and saves the output.
class RunD8 implements IOModularStep {
  @override
  DataId get resultId => const DataId("txt");

  @override
  bool get needsSources => false;

  @override
  List<DataId> get dependencyDataNeeded => const [];

  @override
  List<DataId> get moduleDataNeeded => const [jsId];

  @override
  bool get onlyOnMain => true;

  @override
  Future<void> execute(
      Module module, Uri root, ModuleDataToRelativeUri toUri) async {
    if (_options.verbose) print("step: d8 on $module");
    var sdkRoot = Platform.script.resolve("../../../../");
    List<String> d8Args = [
      sdkRoot
          .resolve('sdk/lib/_internal/js_runtime/lib/preambles/d8.js')
          .toFilePath(),
      root.resolveUri(toUri(module, jsId)).toFilePath(),
    ];
    var result = await _runProcess(
        sdkRoot.resolve(_d8executable).toFilePath(), d8Args, root.toFilePath());

    _checkExitCode(result, this, module);

    await File.fromUri(root.resolveUri(toUri(module, resultId)))
        .writeAsString(result.stdout);
  }
}

void _printTestStructure(ModularTest test) {
  var buffer = new StringBuffer();
  for (var module in test.modules) {
    buffer.write('   ');
    buffer.write(module.name);
    buffer.write(': ');
    buffer.write(module.isPackage ? 'package' : '(not package)');
    buffer.write(
        ', deps: {${module.dependencies.map((d) => d.name).join(", ")}}');
    buffer.write(', sources: {${module.sources.map((u) => "$u").join(', ')}}');
    buffer.write('\n');
  }
  print('$buffer');
}

void _checkExitCode(ProcessResult result, IOModularStep step, Module module) {
  if (result.exitCode != 0 || _options.verbose) {
    stdout.write(result.stdout);
    stderr.write(result.stderr);
  }
  if (result.exitCode != 0) {
    exitCode = result.exitCode;
    Expect.fail("${step.runtimeType} failed on $module");
  }
}

Future<ProcessResult> _runProcess(
    String command, List<String> arguments, String workingDirectory) {
  if (_options.verbose) {
    print('command:\n$command ${arguments.join(' ')} from $workingDirectory');
  }
  return Process.run(command, arguments, workingDirectory: workingDirectory);
}

String get _d8executable {
  if (Platform.isWindows) {
    return 'third_party/d8/windows/d8.exe';
  } else if (Platform.isLinux) {
    return 'third_party/d8/linux/d8';
  } else if (Platform.isMacOS) {
    return 'third_party/d8/macos/d8';
  }
  throw new UnsupportedError('Unsupported platform.');
}

class _Options {
  bool showSkipped = false;
  bool verbose = false;
  String filter = null;

  static _Options parse(List<String> args) {
    var parser = new ArgParser()
      ..addFlag('verbose',
          abbr: 'v',
          defaultsTo: false,
          help: "print detailed information about the test and modular steps")
      ..addFlag('show-skipped',
          defaultsTo: false,
          help: "print the name of the tests skipped by the filtering option")
      ..addOption('filter',
          help: "only run tests containing this filter as a substring");
    ArgResults argResults = parser.parse(args);
    return _Options()
      ..showSkipped = argResults['show-skipped']
      ..verbose = argResults['verbose']
      ..filter = argResults['filter'];
  }
}
