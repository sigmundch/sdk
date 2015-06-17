import '../tree/tree.dart' show Node;
import '../universe/universe.dart' show Selector;
import '../resolution/resolution.dart' show TreeElements;

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

class AnalysisResult {
  /// Return whether the given node resolves to a value that implements no such
  /// method. The answer is `yes` if all values that [receiver] evaluates to at
  /// runtime contain it, or `no` if none of them does. Maybe if it depends on
  /// some context or we can't determine this information precisely.
  boolish hasNoSuchMethod(Node receiver);

  /// Return whether [receiver] may ever be null.
  boolish isNull(Node receiver);

  /// Whether [receiver] has a [selector].
  boolish hasSelector(Node receiver, Selector selector);

  /// Number of possible targets of `receiver.selector`. If [usesInterceptor] is
  /// truthy, this is the number of possible interceptor implementations.
  int possibleTargets(Node receiver, Selector selector);

  /// Whether [receiver] needs an interceptor to implement [selector].
  boolish usesInterceptor(Node receiver, Selector selector);
}

/// A naive [AnalysisResult] that tells us nothing.
class NaiveAnalysisResult implements AnalysisResult {
  NaiveAnalysisResult();

  boolish hasNoSuchMethod(Node receiver) => boolish.maybe;

  boolish isNull(Node receiver) => boolish.maybe;

  boolish hasSelector(Node receiver, Selector selector) => boolish.maybe;

  int possibleTargets(Node receiver, Selector selector) => 10;

  boolish usesInterceptor(Node receiver, Selector selector) => boolish.maybe;
}

/// An [AnalysisResult] produced by using type-propagation based on
/// trusted type annotations.
class TrustTypesAnalysisResult extends NaiveAnalysisResult
    implements AnalysisResult {
  TreeElements elements;

  TrustTypesAnalysisResult(this.elements);

  boolish hasNoSuchMethod(Node receiver) {
    var typeInfo = elements.typesCache[receiver];
    var clazz = typeInfo.element;
    return super.hasNoSuchMethod(receiver);
  }

  boolish isNull(Node receiver) => boolish.maybe;

  boolish hasSelector(Node receiver, Selector selector) => boolish.maybe;

  int possibleTargets(Node receiver, Selector selector) => 10;

  boolish usesInterceptor(Node receiver, Selector selector) => boolish.maybe;
}

/// The [AnalysisResult] that includes information computed by the type
/// inference engine.
class InferenceBasedAnalysisResult implements AnalysisResult {
}

class NewInferenceAnalysisResult implements AnalysisResult {
}
