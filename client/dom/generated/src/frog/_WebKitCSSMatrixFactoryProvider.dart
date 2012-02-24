// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class _WebKitCSSMatrixFactoryProvider {
  factory WebKitCSSMatrix([String cssValue = null]) native
'''
if (cssValue == null) return new WebKitCSSMatrix();
return new WebKitCSSMatrix(cssValue);
''';
}
