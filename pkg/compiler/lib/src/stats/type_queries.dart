import '../tree/tree.dart' show Node;
import '../universe/universe.dart' show Selector;
import '../resolution/resolution.dart' show TreeElements;
import '../dart2jslib.dart' show ClassWorld;
import '../dart_types.dart' show InterfaceType;

// class TypeSet {
// 
//   // Whether a type is in this set
//   bool contains(Element type);
//   Set<Element> enumerateTypes();
// 
//   bool mayHaveNoSuchMethod();
//   bool mustHaveNoSuchMethod();
// }
// 
// class InferenceService {
//   TypeInfo infoForType(type);
//   TypeSet infoForSelector(node, selector);
// }
// 
// class TypeInfo {
//   Element type;
//   bool get hasNoSuchMethod;
// }
// 
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

class AnalysisResult {

  ReceiverInfo infoForReceiver(Node receiver);
  SelectorInfo infoForSelector(Node receiver, Selector selector);
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

/// A naive [AnalysisResult] that tells us nothing.
class NaiveAnalysisResult implements AnalysisResult {
  NaiveAnalysisResult();

  ReceiverInfo infoForReceiver(Node receiver) => 
    new NativeReceiverInfo(receiver);
  SelectorInfo infoForSelector(Node receiver, Selector selector) =>
    new NaiveSelectorInfo(receiver, selector);
}

class TrustTypesReceiverInfo implements ReceiverInfo {
  final Node receiver;
  final InterfaceType type;
  final ClassWorld world;

  TrustTypesReceiverInfo(this.receiver, this.type, this.world);
  // TODO: determine if [receiver] may implement noSuchMethod
  boolish get hasNoSuchMethod => boolish.maybe;
  boolish get isNull => boolish.maybe;
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
    boolish usesInterceptor = boolish.no; // TODO;
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
      }
    }
    return new TrustTypesSelectorInfo._(receiver, selector, exists,
        usesInterceptor, count, isAccurate);
  }
  TrustTypesSelectorInfo._(
      this.receiver, this.selector, this.exists, this.usesInterceptor,
      this.possibleTargets, this.isAccurate);
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
