// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "package:expect/expect.dart";
import "package:async_helper/async_helper.dart";
import 'memory_compiler.dart';

const MEMORY_SOURCE_FILES = const {
    'main.dart': '''
        main() {
          print(12300000);
          print(1234567890123456789012345);
          print(double.MAX_FINITE);
          print(-22230000);
        }'''};

void test({bool minify}) {
  OutputCollector collector = new OutputCollector();
  var compiler = compilerFor(MEMORY_SOURCE_FILES,
                             outputProvider: collector,
                             options: minify ? ['--minify'] : []);
  asyncTest(() => compiler.run(Uri.parse('memory:main.dart')).then((_) {
    // Check that we use the shorter exponential representations.
    String jsOutput = collector.getOutput('', 'js');
    print(jsOutput);

    if (minify) {
      Expect.isTrue(jsOutput.contains('123e5')); // Shorter than 12300000.
      Expect.isFalse(jsOutput.contains('12300000'));
      Expect.isTrue(jsOutput.contains('-2223e4')); // Shorter than -22230000.
      Expect.isFalse(jsOutput.contains('-22230000'));
    } else {
      Expect.isTrue(jsOutput.contains('12300000'));
      Expect.isTrue(jsOutput.contains('-22230000'));
    }
    Expect.isTrue(jsOutput.contains('12345678901234568e8'));
    Expect.isTrue(jsOutput.contains('17976931348623157e292'));
    Expect.isFalse(jsOutput.contains('1234567890123456789012345'));
    // The decimal expansion of double.MAX_FINITE has 308 digits. We only check
    // for its prefix.
    Expect.isFalse(jsOutput.contains('179769313486231570814527423731'));
  }));
}

main() {
  test(minify: true);
  test(minify: false);
}
