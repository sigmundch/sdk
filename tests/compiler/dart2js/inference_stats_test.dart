// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Tests that we compute send metrics correctly in many simple scenarios.
library stats_test;

import 'package:expect/expect.dart';
import 'package:compiler/src/stats/stats.dart';
import 'compiler_helper.dart';

main() {
  _check('''
    main() {}
    test() { int x = 3; } // nothing counted because test is unreachable.
    ''');

  _check('''
    main() => test();
    test() { int x = 3; int y = x; }
    ''',
    localSend: 1); // from `int y = x`;

  /// Need work:
  /// - need to add _checkWithTypeOnly, _checkWithInferredType

  _check('''
    class A {
      get f => 1;
    }
    main() => test();
    test() { new A().f; }
    ''',
    dynamicSend: 1); // x.f itself - type information not implemented yet.

  _check('''
    class A {
      get f => 1;
    }
    class B {
      get f => 1;
    }
    main() => test();
    test() { new B().f; }
    ''',
    dynamicSend: 1); // x.f itself - type information not implemented yet.

  _check('''
    class A {
      get f => 1;
    }
    class B {
      get f => 1;
    }
    main() => test();
    test() { A x = new B(); x.f; }
    ''',
    localSend:1, // x in x.f
    dynamicSend: 1); // x.f itself - type information not implemented yet.
}


/// Checks that the `test` function in [code] produces the given distribution of
/// sends.
_check(String code, {int staticSend: 0, int superSend: 0, int localSend: 0,
    int constructorSend: 0, int typeVariableSend: 0, int nsmErrorSend: 0,
    int singleNsmCallSend: 0, int instanceSend: 0, int interceptorSend: 0,
    int multiNsmCallSend: 0, int virtualSend: 0, int multiInterceptorSend: 0,
    int dynamicSend: 0}) async {

  // Set up the expectation.
  var expected = new Measurements();
  int monomorphic = staticSend + superSend + localSend + constructorSend +
    typeVariableSend + nsmErrorSend + singleNsmCallSend + instanceSend +
    interceptorSend;
  int polymorphic = multiNsmCallSend + virtualSend + multiInterceptorSend +
    dynamicSend;

  expected[Metric.monomorphicSend] = monomorphic;
  expected[Metric.staticSend] = staticSend;
  expected[Metric.superSend] = superSend;
  expected[Metric.localSend] = localSend;
  expected[Metric.constructorSend] = constructorSend;
  expected[Metric.typeVariableSend] = typeVariableSend;
  expected[Metric.nsmErrorSend] = nsmErrorSend;
  expected[Metric.singleNsmCallSend] = singleNsmCallSend;
  expected[Metric.instanceSend] = instanceSend;
  expected[Metric.interceptorSend] = interceptorSend;

  expected[Metric.polymorphicSend] = polymorphic;
  expected[Metric.multiNsmCallSend] = multiNsmCallSend;
  expected[Metric.virtualSend] = virtualSend;
  expected[Metric.multiInterceptorSend] = multiInterceptorSend;
  expected[Metric.dynamicSend] = dynamicSend;

  expected[Metric.send] = monomorphic + polymorphic;

  // Run the compiler to get the results.
  var globalResult = await _compileAndGetStats(code);
  var libs = globalResult.loose.libraries;
  var lib = libs.firstWhere((l) => l.uri == testFileUri,
      orElse: () => Expect.fail("Cannot find the tested library."));
  var function = lib.functions.firstWhere((f) => f.name == 'test',
      orElse: () => Expect.fail("Cannot find function named 'test'."));
  var result = function.measurements;

  for (var key in expected.counters.keys) {
    var expectedValue = expected[key];
    var value = result[key];
    if (value == expectedValue) continue;
    Expect.equals(expected[key], result[key],
        "$key didn't match:\n"
        "expected measurements: ${recursiveDiagnosticString(expected,key)}\n"
        "actual measurements: ${recursiveDiagnosticString(result, key)}");
  }
}

Uri testFileUri = new Uri(scheme: 'source');

/// Helper that runs the compiler and returns the [GlobalResult] computed for
/// it.
Future<GlobalResult> _compileAndGetStats(String code) async {
  MockCompiler compiler = new MockCompiler.internal();
  compiler.stopAfterTypeInference = true;
  compiler.registerSource(testFileUri, code);
  await compiler.runCompiler(testFileUri);
  Expect.isFalse(compiler.compilationFailed,
      'Unexpected compilation error(s): ${compiler.errors}');
  return compiler.statsBuilderTask.resultForTesting;
}
