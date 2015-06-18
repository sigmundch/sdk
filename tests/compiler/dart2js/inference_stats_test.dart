// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Tests that we compute send metrics correctly in many simple scenarios.
library stats_test;

import 'dart:async';
import 'package:test/test.dart';
import 'package:compiler/src/stats/stats.dart';
import 'compiler_helper.dart';

main() {
  test('nothing is reachable, nothing to count', () {
    return _check('''
      main() {}
      test() { int x = 3; }
      ''');
  });

  test('local variable read', () {
    return _check('''
      main() => test();
      test() { int x = 3; int y = x; }
      ''',
      localSend: 1); // from `int y = x`;
  });

  test('generative constructor call', () {
    return _check('''
      class A {
        get f => 1;
      }
      main() => test();
      test() { new A(); }
      ''',
      constructorSend: 1);  // from new A()
  });

  group('instance call', () {
    test('monomorphic only one implementor', () {
      return _check('''
        class A {
          get f => 1;
        }
        main() => test();
        test() { new A().f; }
        ''',
        constructorSend: 1, // new A()
        instanceSend: 1);   // f resolved to A.f
    });

    test('monomorphic only one type possible from types', () {
      return _check('''
        class A {
          get f => 1;
        }
        class B extends A {
          get f => 1;
        }
        main() => test();
        test() { new B().f; }
        ''',
        constructorSend: 1,
        instanceSend: 1); // f resolved to B.f
    });

    test('monomorphic only one type possible from liveness', () {
      return _check('''
        class A {
          get f => 1;
        }
        class B extends A {
          get f => 1;
        }
        main() => test();
        test() { A x = new B(); x.f; }
        ''',
        constructorSend: 1, // new B()
        localSend: 1,       // x in x.f
        instanceSend: 1);  // x.f known to resolve to B.f
    });

    test('monomorphic one possible, more than one live', () {
      return _check('''
        class A {
          get f => 1;
        }
        class B extends A {
          get f => 1;
        }
        main() { new A(); test(); }
        test() { B x = new B(); x.f; }
        ''',
        constructorSend: 1, // new B()
        localSend: 1,       // x in x.f
        instanceSend: 1);   // x.f resolves to B.f
    });

    test('polymorphic-virtual couple possible types from liveness', () {
        // Note: this would be an instanceSend if we used the inferrer.
      return _check('''
        class A {
          get f => 1;
        }
        class B extends A {
          get f => 1;
        }
        main() { new A(); test(); }
        test() { A x = new B(); x.f; }
        ''',
        constructorSend: 1, // new B()
        localSend: 1,       // x in x.f
        virtualSend: 1);    // x.f may be A.f or B.f (types alone is not enough)
    });

    test("polymorphic-dynamic: type annotations don't help", () {
      return _check('''
        class A {
          get f => 1;
        }
        class B extends A {
          get f => 1;
        }
        main() { new A(); test(); }
        test() { var x = new B(); x.f; }
        ''',
        constructorSend: 1, // new B()
        localSend: 1,       // x in x.f
        dynamicSend: 1);    // x.f could be any `f` or no `f`
    });
  });

  group('noSuchMethod', () {
    test('error will be thrown', () {
      return _check('''
        class A {
        }
        main() { test(); }
        test() { new A().f; }
        ''',
        constructorSend: 1, // new B()
        nsmErrorSend: 1);   // f not there, A has no nSM
    });

    test('nSM will be called - one option', () {
      return _check('''
        class A {
          noSuchMethod(i) => null;
        }
        main() { test(); }
        test() { new A().f; }
        ''',
        constructorSend: 1,    // new B()
        singleNsmCallSend: 1); // f not there, A has nSM
    });

    // TODO(sigmund): is it worth splitting multiNSMvirtual?
    test('nSM will be called - multiple options', () {
      return _check('''
        class A {
          noSuchMethod(i) => null;
        }
        class B extends A {
          noSuchMethod(i) => null;
        }
        main() { new A(); test(); }
        test() { A x = new B(); x.f; }
        ''',
        constructorSend: 1,   // new B()
        localSend: 1,         // x in x.f
        multiNsmCallSend: 1); // f not there, A has nSM
    });

    // TODO(sigmund): is it worth splitting multiNSMvirtual?
    test('nSM will be called - multiple options', () {
      return _check('''
        class A {
          noSuchMethod(i) => null;
        }
        class B extends A {
          // don't count A's nsm as distinct
        }
        main() { new A(); test(); }
        test() { A x = new B(); x.f; }
        ''',
        constructorSend: 1,    // new B()
        localSend: 1,          // x in x.f
        singleNsmCallSend: 1); // f not there, A has nSM
    });

    test('nSM will be called - multiple options', () {
      return _check('''
        class A {
          noSuchMethod(i) => null;
        }
        class B extends A {
          get f => null;
        }
        main() { new A(); test(); }
        test() { A x = new B(); x.f; }
        ''',
        constructorSend: 1,   // new B()
        localSend: 1,         // x in x.f
        dynamicSend: 1);      // f not known to be there there, A has nSM
    });
  });
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
      orElse: () => fail("Cannot find the tested library."));
  var function = lib.functions.firstWhere((f) => f.name == 'test',
      orElse: () => fail("Cannot find function named 'test'."));
  var result = function.measurements;

  _compareMetric(Metric key) {
    var expectedValue = expected[key];
    var value = result[key];
    if (value == expectedValue) return;
    expect(expected[key], result[key],
        reason: "count for `$key` didn't match:\n"
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
  MockCompiler compiler = new MockCompiler.internal(computeAnalysisStats: true);
  compiler.stopAfterTypeInference = true;
  compiler.registerSource(testFileUri, code);
  compiler.diagnosticHandler = createHandler(compiler, code);
  await compiler.runCompiler(testFileUri);
  expect(compiler.compilationFailed, false,
      reason: 'Unexpected compilation error(s): ${compiler.errors}');
  return compiler.statsBuilderTask.resultForTesting;
}
