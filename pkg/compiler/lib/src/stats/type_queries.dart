import '../tree/tree.dart' show Node;
import '../universe/universe.dart' show Selector;
import '../resolution/resolution.dart' show TreeElements;
import '../dart2jslib.dart' show ClassWorld;
import '../dart_types.dart' show InterfaceType;

// /// TODO:
// - define what we need from a type, from a set of types, from a selector
// - define queries to determine whether
//  -- an interceptor may be used
//  -- nsm may be fired
//  -- nsm may be caught
//  -- a selector is only implemented in one of a group of types
//  -- filter out members from abstract classes that are always overriden (except
//  for super calls)
//  -- 

/// A three-value logic bool (yes, no, maybe). We say that `yes` and `maybe` are
/// "truthy", while `no` and `maybe` are "falsy".
enum boolish { yes, no, maybe }

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

  /// Whether the infromation about [possibleTargets] is accurate.
  bool get isAccurate;
}

/// Specifies results of some kind of static analysis on a source program.
abstract class AnalysisResult {
  /// Information computed about a specific [receiver].
  ReceiverInfo infoForReceiver(Node receiver);

  /// Information computed about a specific [selector] applied to a specific
  /// [receiver].
  SelectorInfo infoForSelector(Node receiver, Selector selector);
}

/// A naive [AnalysisResult] that tells us very little. This is the most
/// conservative we can be when we only use information from the AST structure
/// and the resolution, but no type information.
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
    new TrustTypesSelectorInfo(receiver, elements.typesCache[receiver], selector, world);
}

class TrustTypesReceiverInfo implements ReceiverInfo {
  final Node receiver;
  final boolish hasNoSuchMethod;
  final boolish isNull = boolish.maybe;

  factory TrustTypesReceiverInfo(
      Node receiver, InterfaceType type, ClassWorld world) {
    boolish hasNoSuchMethod;
    if (type != null) {
      bool someNSM = false;
      bool allNSM = true;
      for (var cls in world.subclassesOf(type.element)) {
        var member = cls.lookupMember('noSuchMethod');
        if (member != null && !member.isAbstract) {
          someNSM = true;
        } else {
          allNSM = false;
        }
      }
      hasNoSuchMethod = 
          someNSM ? (allNSM ? boolish.yes : boolish.maybe) : boolish.no;
    } else {
      hasNoSuchMethod = boolish.maybe;
    }
    return new TrustTypesReceiverInfo._(receiver, hasNoSuchMethod);
  }

  TrustTypesReceiverInfo._(this.receiver, this.hasNoSuchMethod);
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
    boolish exists;
    // TODO(sigmund): specify which selectors on what types need an interceptor
    boolish usesInterceptor = boolish.no;
    int count = 0;
    bool isAccurate = true;

    if (type == null) {
      exists = boolish.maybe;
      usesInterceptor = boolish.maybe;
      count = -1;
      isAccurate = false;
    } else {
      bool allLiveClassesImplementSelector = true;
      var cls = type.element;
      for (var child in world.subclassesOf(cls)) {
        var member = child.lookupMember(selector.name);
        if (member != null && !member.isAbstract) {
          count++;
        } else {
          allLiveClassesImplementSelector = false;
        }
      }
      if (count == 0) {
        exists = boolish.no;
      } else if (allLiveClassesImplementSelector) {
        exists = boolish.yes;
      } else {
        isAccurate = false;
        exists = boolish.maybe;
        usesInterceptor = boolish.maybe;
      }
    }
    return new TrustTypesSelectorInfo._(receiver, selector, exists,
        usesInterceptor, count, isAccurate);
  }
  TrustTypesSelectorInfo._(
      this.receiver, this.selector, this.exists, this.usesInterceptor,
      this.possibleTargets, this.isAccurate);
}


