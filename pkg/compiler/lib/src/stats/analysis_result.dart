// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// API to get results from a static analysis of the source program.
// TODO(sigmund): split out implementations out of this file.
library compiler.src.stats.analysis_result;

import '../tree/tree.dart' show Node;
import '../universe/universe.dart' show Selector;
import '../resolution/resolution.dart' show TreeElements;
import '../dart2jslib.dart' show ClassWorld;
import '../dart_types.dart' show InterfaceType;

/// A three-value logic bool (yes, no, maybe). We say that `yes` and `maybe` are
/// "truthy", while `no` and `maybe` are "falsy".
// TODO(sigmund): is it worth using an enum? or switch to true/false/null?
enum boolish { yes, no, maybe }

/// Specifies results of some kind of static analysis on a source program.
abstract class AnalysisResult {
  /// Information computed about a specific [receiver].
  ReceiverInfo infoForReceiver(Node receiver);

  /// Information computed about a specific [selector] applied to a specific
  /// [receiver].
  SelectorInfo infoForSelector(Node receiver, Selector selector);
}

/// Analysis information about a receiver of a send.
abstract class ReceiverInfo {
  /// Receiver node for which this information is computed.
  final Node receiver;

  /// Return whether [receiver] resolves to a value that implements no such
  /// method. The answer is `yes` if all values that [receiver] could evaluate
  /// to at runtime contain it, or `no` if none of them does. Maybe if it
  /// depends on some context or we can't determine this information precisely.
  boolish get hasNoSuchMethod;

  /// Return whether [receiver] may ever be null.
  boolish get isNull;
}

/// Information about a specific selector applied to a specific receiver.
abstract class SelectorInfo {
  /// Receiver node of the [selector].
  final Node receiver;

  /// Specific selector on [receiver] for which this information is computed.
  final Selector selector;

  /// Whether a member matching [selector] exists in [receiver].
  boolish get exists;

  /// Whether [receiver] needs an interceptor to implement [selector].
  boolish get usesInterceptor;

  /// Possible total number of methods that could be the target of the selector.
  /// This needs to be combined with [isAccurate] to correctly understand the
  /// value. Some invariants:
  ///
  ///   * If [exists] is `no`, the value here should be 0, regardless of
  ///   accuracy.
  ///   * If [exists] is `yes`, the value is always considered 1 or more.
  ///     If [isAccurate] is false, we treat it as there may be many possible
  ///     targets.
  ///   * If [exists] is `maybe`, the value is considered 0 or more.
  int get possibleTargets;

  /// Whether the information about [possibleTargets] is accurate.
  bool get isAccurate;
}


/// A naive [AnalysisResult] that tells us very little. This is the most
/// conservative we can be when we only use information from the AST structure
/// and from resolution, but no type information.
class NaiveAnalysisResult implements AnalysisResult {
  NaiveAnalysisResult();

  ReceiverInfo infoForReceiver(Node receiver) =>
    new NativeReceiverInfo(receiver);
  SelectorInfo infoForSelector(Node receiver, Selector selector) =>
    new NaiveSelectorInfo(receiver, selector);
}

class NaiveReceiverInfo implements ReceiverInfo {
  final Node receiver;

  NaiveReceiverInfo(this.receiver);
  boolish get hasNoSuchMethod => boolish.maybe;
  boolish get isNull => boolish.maybe;
}

class NaiveSelectorInfo implements SelectorInfo {
  final Node receiver;
  final Selector selector;

  NaiveSelectorInfo(this.receiver, this.selector);

  boolish get exists => boolish.maybe;
  boolish get usesInterceptor => boolish.maybe;
  int get possibleTargets => -1;
  bool get isAccurate => false;
}


/// An [AnalysisResult] produced by using type-propagation based on
/// trusted type annotations.
class TrustTypesAnalysisResult implements AnalysisResult {
  final ClassWorld world;
  final TreeElements elements;

  TrustTypesAnalysisResult(this.elements, this.world);

  ReceiverInfo infoForReceiver(Node receiver) =>
    new TrustTypesReceiverInfo(receiver, elements.typesCache[receiver], world);
  SelectorInfo infoForSelector(Node receiver, Selector selector) =>
    new TrustTypesSelectorInfo(
        receiver, elements.typesCache[receiver], selector, world);
}

class _SelectorLookupResult {
  final boolish exists;
  // TODO(sigmund): implement
  final boolish usesInterceptor = boolish.no;
  final int possibleTargets;

  _SelectorLookupResult(this.exists, this.possibleTargets);

  const _SelectorLookupResult.dontKnow()
    : exists = boolish.maybe, possibleTargets = -1;
}

_SelectorLookupResult _lookupSelector(
    String selectorName, InterfaceType type, ClassWorld world) {
  if (type == null) return const _SelectorLookupResult.dontKnow();
  bool isNsm = selectorName == 'noSuchMethod';
  bool notFound = false;
  var uniqueTargets = new Set();
  for (var cls in world.subtypesOf(type.element)) {
    var member = cls.lookupMember(selectorName);
    if (member != null && !member.isAbstract
        // Don't match nsm in Object
        && (!isNsm || !member.enclosingClass.isObject)) {
      uniqueTargets.add(member);
    } else {
      notFound = true;
    }
  }
  boolish exists = uniqueTargets.length > 0
        ? (notFound ? boolish.maybe : boolish.yes)
        : boolish.no;
  return new _SelectorLookupResult(exists, uniqueTargets.length);
}

class TrustTypesReceiverInfo implements ReceiverInfo {
  final Node receiver;
  final boolish hasNoSuchMethod;
  final int possibleNsmTargets;
  final boolish isNull = boolish.maybe;

  factory TrustTypesReceiverInfo(
      Node receiver, InterfaceType type, ClassWorld world) {
    // TODO(sigmund): refactor, maybe just store nsm as a SelectorInfo
    var res = _lookupSelector('noSuchMethod', type, world);
    return new TrustTypesReceiverInfo._(receiver,
        res.exists, res.possibleTargets);
  }

  TrustTypesReceiverInfo._(this.receiver, this.hasNoSuchMethod,
      this.possibleNsmTargets);
}

class TrustTypesSelectorInfo implements SelectorInfo {
  final Node receiver;
  final Selector selector;

  final boolish exists;
  final boolish usesInterceptor;
  final int possibleTargets;
  final bool isAccurate;

  factory TrustTypesSelectorInfo(Node receiver, InterfaceType type,
      Selector selector, ClassWorld world) {
    var res = _lookupSelector(
        selector != null ? selector.name : null, type, world);
    return new TrustTypesSelectorInfo._(receiver, selector, res.exists,
        res.usesInterceptor, res.possibleTargets,
        res.exists != boolish.maybe);
  }
  TrustTypesSelectorInfo._(
      this.receiver, this.selector, this.exists, this.usesInterceptor,
      this.possibleTargets, this.isAccurate);
}
