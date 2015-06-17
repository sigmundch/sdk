// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Tests that we compute send metrics correctly in many simple scenarios.
library stats_test;

import 'dart:async';
import 'package:expect/expect.dart';
import 'package:compiler/src/stats/stats.dart';
import 'compiler_helper.dart';

main() async {
  await _check('''
    main() {}
    test() { int x = 3; } // nothing counted because test is unreachable.
    ''');

  await _check('''
    main() => test();
    test() { int x = 3; int y = x; }
    ''',
    localSend: 1); // from `int y = x`;

  await _check('''
    class A {
      get f => 1;
    }
    main() => test();
    test() { new A(); }
    ''',
    constructorSend: 1);  // new A()

  await _check('''
    class A {
      get f => 1;
    }
    main() => test();
    test() { new A().f; }
    ''',
    constructorSend: 1, // new A()
    instanceSend: 1); // _.f itself - type information not implemented yet.

  await _check('''
    class A {
      get f => 1;
    }
    class B {
      get f => 1;
    }
    main() => test();
    test() { new B().f; }
    ''',
    constructorSend: 1,
    instanceSend: 1); // _.f itself - type information not implemented yet.

  await _check('''
    class A {
      get f => 1;
    }
    class B {
      get f => 1;
    }
    main() => test();
    test() { A x = new B(); x.f; }
    ''',
    constructorSend: 1, // new B()
    localSend: 1, // x in x.f
    virtualSend: 1); // x.f itself - type information not implemented yet.
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

  _compareMetric(Metric key) {
    var expectedValue = expected[key];
    var value = result[key];
    if (value == expectedValue) return;
    Expect.equals(expected[key], result[key],
        "count for `$key` didn't match:\n"
        "expected measurements:\n${recursiveDiagnosticString(expected,key)}\n"
        "actual measurements:\n${recursiveDiagnosticString(result, key)}");
  }

  _compareMetric(Metric.send);
  expected.counters.keys.forEach(_compareMetric);
}

Uri testFileUri = new Uri(scheme: 'source');

/// Helper that runs the compiler and returns the [GlobalResult] computed for
/// it.
Future<GlobalResult> _compileAndGetStats(String code) async {
  MockCompiler compiler = new MockCompiler.internal(
      trustTypeAnnotations: true,
      trustUncheckedTypeAnnotations: true);
  compiler.stopAfterTypeInference = true;
  compiler.registerSource(testFileUri, code);
  await compiler.runCompiler(testFileUri);
  Expect.isFalse(compiler.compilationFailed,
      'Unexpected compilation error(s): ${compiler.errors}');
  return compiler.statsBuilderTask.resultForTesting;
}
