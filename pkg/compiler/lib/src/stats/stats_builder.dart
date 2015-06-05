library inference_stats;

import '../stats/stats.dart';
import '../stats/stats_viewer.dart';
import '../dart_types.dart';
import '../elements/elements.dart';
import '../resolution/operators.dart';
import '../resolution/resolution.dart';
import '../resolution/semantic_visitor.dart';
import '../tree/tree.dart';
import '../universe/universe.dart' show Selector, CallStructure;
import '../dart2jslib.dart' show CompilerTask, Compiler;
import '../elements/visitor.dart' show ElementVisitor;

/// Task that collects metric information about types.
class StatsBuilderTask extends CompilerTask {
  String get name => "Inference Stats";

  StatsBuilderTask(Compiler compiler) : super(compiler);

  void run() {
    measure(() {
      var visitor = new StatsBuilder();
      print('collecting stats');
      for (var lib in compiler.libraryLoader.libraries) {
        lib.accept(visitor, null);
      }
      print(formatAsTable(visitor.result));
    });
  }
}

/// Visitor that goes through all elements and builds the metrics information
/// from it.
class StatsBuilder extends RecursiveElementVisitor {
  final GlobalResult result = new GlobalResult();
  LibraryResult currentLib;

  merge(r) => null;

  visitLibraryElement(LibraryElement e, arg) {
    var uri = e.canonicalUri;
    currentLib = new LibraryResult(e.canonicalUri);
    result.add(currentLib);
    return super.visitLibraryElement(e, arg);
  }

  visitClassElement(ClassElement e, arg) {
    currentLib.classes.add(e.name);
    return super.visitClassElement(e, arg);
  }

  static Set<String> _messages = new Set<String>();
  static _debug(String message) {
    if (_messages.add(message)) {
      print('[33mdebug:[0m $message');
    }
  }

  visitFunctionElement(FunctionElement e, arg) {
    if (!e.hasResolvedAst) {
      _debug('no resolved ast ${e.runtimeType}');
      return;
    }
    var resolvedAst = e.resolvedAst;
    var visitor = new _StatsVisitor(resolvedAst.elements);
    if (resolvedAst.node == null) {
      _debug('no node ${e.runtimeType}');
      return;
    }
    var def = resolvedAst.elements.getFunctionDefinition(resolvedAst.node);
    if (def == null) {
      _debug('def is null? ${e.runtimeType}');
      return;
    }
    resolvedAst.node.accept(visitor);
    currentLib.functions.add(new FunctionResult(e.name, visitor.metrics));
  }

  // TODO(sigmund): visit initializers too, they can contain `sends`.
}

/// Visitor that collects statistics about our understanding of a function.
class _StatsVisitor<T> extends TraversalVisitor<Void, T>
    implements SemanticSendVisitor {
  _StatsVisitor(TreeElements elements) : super(elements);

  Metrics metrics = new Metrics();

  apply(node, a) {
    super.apply(node, a);
  }

  void visitNode(Node node) {
    super.visitNode(node);
  }

  void visitSend(Send node) {
    //print('visitsend: $node');
    metrics[Measurement.send]++;
    super.visitSend(node);
  }

  /// Invocation of the [parameter] with [arguments].
  ///
  /// For instance:
  ///     m(parameter) {
  ///       parameter(null, 42);
  ///     }
  ///
  void visitParameterInvoke(Send node, ParameterElement parameter,
      NodeList arguments, CallStructure callStructure, T arg) {
    super.visitParameterInvoke(node, parameter, arguments, callStructure, arg);
  }

  /// Invocation of the local variable [variable] with [arguments].
  ///
  /// For instance:
  ///     m() {
  ///       var variable;
  ///       variable(null, 42);
  ///     }
  ///
  void visitLocalVariableInvoke(Send node, LocalVariableElement variable,
      NodeList arguments, CallStructure callStructure, T arg) {
    super.visitLocalVariableInvoke(
        node, variable, arguments, callStructure, arg);
  }

  /// Invocation of the local [function] with [arguments].
  ///
  /// For instance:
  ///     m() {
  ///       o(a, b) {}
  ///       return o(null, 42);
  ///     }
  ///
  void visitLocalFunctionInvoke(Send node, LocalFunctionElement function,
      NodeList arguments, CallStructure callStructure, T arg) {
    super.visitLocalFunctionInvoke(
        node, function, arguments, callStructure, arg);
  }

  /// Getter call on [receiver] of the property defined by [selector].
  ///
  /// For instance
  ///     m(receiver) => receiver.foo;
  ///
  void visitDynamicPropertyGet(
      Send node, Node receiver, Selector selector, T arg) {
    metrics[Measurement.dynamicGet]++;
    super.visitDynamicPropertyGet(node, receiver, selector, arg);
  }

  /// Setter call on [receiver] with argument [rhs] of the property defined by
  /// [selector].
  ///
  /// For instance
  ///     m(receiver) {
  ///       receiver.foo = rhs;
  ///     }
  ///
  void visitDynamicPropertySet(
      SendSet node, Node receiver, Selector selector, Node rhs, T arg) {
    super.visitDynamicPropertySet(node, receiver, selector, rhs, arg);
  }

  /// Invocation of the property defined by [selector] on [receiver] with
  /// [arguments].
  ///
  /// For instance
  ///     m(receiver) {
  ///       receiver.foo(null, 42);
  ///     }
  ///
  void visitDynamicPropertyInvoke(
      Send node, Node receiver, NodeList arguments, Selector selector, T arg) {
    super.visitDynamicPropertyInvoke(node, receiver, arguments, selector, arg);
  }

// --- we need it for analysis: this.foo can be on a child class, not sure if
// inference encodes this kind of context sensitivity --
  /// Getter call on `this` of the property defined by [selector].
  ///
  /// For instance
  ///     class C {
  ///       m() => this.foo;
  ///     }
  ///
  /// or
  ///
  ///     class C {
  ///       m() => foo;
  ///     }
  ///
  void visitThisPropertyGet(Send node, Selector selector, A arg) {
    super.visitThisPropertyGet(node, selector, arg);
  }

  /// Setter call on `this` with argument [rhs] of the property defined by
  /// [selector].
  ///     class C {
  ///       m() { this.foo = rhs; }
  ///     }
  ///
  /// or
  ///
  ///     class C {
  ///       m() { foo = rhs; }
  ///     }
  ///
  void visitThisPropertySet(SendSet node, Selector selector, Node rhs, A arg) {
    super.visitThisPropertySet(node, selector, rhs, arg);
  }

  // --- needed in case [selector] is a field, not a method ---
  // --- or is that handled by the expression invoke? TEST!! --
  //
  /// Invocation of the property defined by [selector] on `this` with
  /// [arguments].
  ///
  /// For instance
  ///     class C {
  ///       m() { this.foo(null, 42); }
  ///     }
  ///
  /// or
  ///
  ///     class C {
  ///       m() { foo(null, 42); }
  ///     }
  ///
  ///
  void visitThisPropertyInvoke(
      Send node, NodeList arguments, Selector selector, A arg) {
    super.visitThisPropertyInvoke(node, arguments, selector, arg);
  }

  /// Invocation of a [expression] with [arguments].
  ///
  /// For instance
  ///     m() => (a, b){}(null, 42);
  ///
  void visitExpressionInvoke(Send node, Node expression, NodeList arguments,
      Selector selector, T arg) {
    super.visitExpressionInvoke(node, expression, arguments, selector, arg);
  }

  /// Invocation of the static [field] with [arguments].
  ///
  /// For instance
  ///     class C {
  ///       static var foo;
  ///     }
  ///     m() { C.foo(null, 42); }
  ///
  void visitStaticFieldInvoke(Send node, FieldElement field, NodeList arguments,
      CallStructure callStructure, T arg) {
    super.visitStaticFieldInvoke(node, field, arguments, callStructure, arg);
  }

  /// Invocation of the static [getter] with [arguments].
  ///
  /// For instance
  ///     class C {
  ///       static get foo => null;
  ///     }
  ///     m() { C.foo(null, 42; }
  ///
  void visitStaticGetterInvoke(Send node, FunctionElement getter,
      NodeList arguments, CallStructure callStructure, T arg) {
    super.visitStaticGetterInvoke(node, getter, arguments, callStructure, arg);
  }

  /// Invocation of the top level [field] with [arguments].
  ///
  /// For instance
  ///     var foo;
  ///     m() { foo(null, 42); }
  ///
  void visitTopLevelFieldInvoke(Send node, FieldElement field,
      NodeList arguments, CallStructure callStructure, T arg) {
    super.visitTopLevelFieldInvoke(node, field, arguments, callStructure, arg);
  }

  /// Invocation of the top level [getter] with [arguments].
  ///
  /// For instance
  ///     get foo => null;
  ///     m() { foo(null, 42); }
  ///
  void visitTopLevelGetterInvoke(Send node, FunctionElement getter,
      NodeList arguments, CallStructure callStructure, T arg) {
    super.visitTopLevelGetterInvoke(
        node, getter, arguments, callStructure, arg);
  }

  // shouldn't this be an errorMethod? ---
  /// Invocation of the type literal for class [element] with [arguments].
  ///
  /// For instance
  ///     class C {}
  ///     m() => C(null, 42);
  ///
  void visitClassTypeLiteralInvoke(Send node, ConstantExpression constant,
      NodeList arguments, CallStructure callStructure, T arg) {
    super.visitClassTypeLiteralInvoke(
        node, constant, arguments, callStructure, arg);
  }

// ditto
  /// Invocation of the type literal for typedef [element] with [arguments].
  ///
  /// For instance
  ///     typedef F();
  ///     m() => F(null, 42);
  ///
  void visitTypedefTypeLiteralInvoke(Send node, ConstantExpression constant,
      NodeList arguments, CallStructure callStructure, T arg) {
    super.visitTypedefTypeLiteralInvoke(
        node, constant, arguments, callStructure, arg);
  }

  /// Invocation of the type literal for type variable [element] with
  /// [arguments].
  ///
  /// For instance
  ///     class C<T> {
  ///       m() { T(null, 42); }
  ///     }
  ///
  void visitTypeVariableTypeLiteralInvoke(Send node,
      TypeVariableElement element, NodeList arguments,
      CallStructure callStructure, T arg) {
    super.visitTypeVariableTypeLiteralInvoke(
        node, element, arguments, callStructure, arg);
  }

// huh?
  /// Invocation of the type literal for `dynamic` with [arguments].
  ///
  /// For instance
  ///     m() { dynamic(null, 42); }
  ///
  void visitDynamicTypeLiteralInvoke(Send node, ConstantExpression constant,
      NodeList arguments, CallStructure callStructure, T arg) {
    super.visitDynamicTypeLiteralInvoke(
        node, constant, arguments, callStructure, arg);
  }

  /// Binary expression `left operator right` where [operator] is a user
  /// definable operator. Binary expressions using operator `==` are handled
  /// by [visitEquals] and index operations `a[b]` are handled by [visitIndex].
  ///
  /// For instance:
  ///     add(a, b) => a + b;
  ///     sub(a, b) => a - b;
  ///     mul(a, b) => a * b;
  ///
  void visitBinary(
      Send node, Node left, BinaryOperator operator, Node right, T arg) {
    super.visitBinary(node, left, operator, right, arg);
  }

  /// Index expression `receiver[index]`.
  ///
  /// For instance:
  ///     lookup(a, b) => a[b];
  ///
  void visitIndex(Send node, Node receiver, Node index, T arg) {
    super.visitIndex(node, receiver, index, arg);
  }

  /// Prefix operation on an index expression `operator receiver[index]` where
  /// the operation is defined by [operator].
  ///
  /// For instance:
  ///     lookup(a, b) => --a[b];
  ///
  void visitIndexPrefix(
      Send node, Node receiver, Node index, IncDecOperator operator, T arg) {
    super.visitIndexPrefix(node, receiver, index, operator, arg);
  }

  /// Postfix operation on an index expression `receiver[index] operator` where
  /// the operation is defined by [operator].
  ///
  /// For instance:
  ///     lookup(a, b) => a[b]++;
  ///
  void visitIndexPostfix(
      Send node, Node receiver, Node index, IncDecOperator operator, T arg) {
    super.visitIndexPostfix(node, receiver, index, operator, arg);
  }

  /// Binary expression `left == right`.
  ///
  /// For instance:
  ///     neq(a, b) => a != b;
  ///
  void visitNotEquals(Send node, Node left, Node right, T arg) {
    super.visitNotEquals(node, left, right, arg);
  }

  /// Binary expression `left == right`.
  ///
  /// For instance:
  ///     eq(a, b) => a == b;
  ///
  void visitEquals(Send node, Node left, Node right, T arg) {
    super.visitEquals(node, left, right, arg);
  }

  /// Unary expression `operator expression` where [operator] is a user
  /// definable operator.
  ///
  /// For instance:
  ///     neg(a, b) => -a;
  ///     comp(a, b) => ~a;
  ///
  void visitUnary(Send node, UnaryOperator operator, Node expression, T arg) {
    super.visitUnary(node, operator, expression, arg);
  }

  /// Unary expression `!expression`.
  ///
  /// For instance:
  ///     not(a) => !a;
  ///
  void visitNot(Send node, Node expression, T arg) {
    super.visitNot(node, expression, arg);
  }

  /// Index set expression `receiver[index] = rhs`.
  ///
  /// For instance:
  ///     m(receiver, index, rhs) => receiver[index] = rhs;
  ///
  void visitIndexSet(SendSet node, Node receiver, Node index, Node rhs, T arg) {
    super.visitIndexSet(node, receiver, index, rhs, arg);
  }

  /// Logical and, &&, expression with operands [left] and [right].
  ///
  /// For instance
  ///     m() => left && right;
  ///
  void visitLogicalAnd(Send node, Node left, Node right, T arg) {
    super.visitLogicalAnd(node, left, right, arg);
  }

  /// Logical or, ||, expression with operands [left] and [right].
  ///
  /// For instance
  ///     m() => left || right;
  ///
  void visitLogicalOr(Send node, Node left, Node right, T arg) {
    super.visitLogicalOr(node, left, right, arg);
  }

  /// Compound assignment expression of [rhs] with [operator] of the property on
  /// [receiver] whose getter and setter are defined by [getterSelector] and
  /// [setterSelector], respectively.
  ///
  /// For instance:
  ///     m(receiver, rhs) => receiver.foo += rhs;
  ///
  void visitDynamicPropertyCompound(Send node, Node receiver,
      AssignmentOperator operator, Node rhs, Selector getterSelector,
      Selector setterSelector, T arg) {
    super.visitDynamicPropertyCompound(
        node, receiver, operator, rhs, getterSelector, setterSelector, arg);
  }

  /// Compound assignment expression of [rhs] with [operator] on a [parameter].
  ///
  /// For instance:
  ///     m(parameter, rhs) => parameter += rhs;
  ///
  void visitParameterCompound(Send node, ParameterElement parameter,
      AssignmentOperator operator, Node rhs, T arg) {
    super.visitParameterCompound(node, parameter, operator, rhs, arg);
  }

  /// Compound assignment expression of [rhs] with [operator] on a local
  /// [variable].
  ///
  /// For instance:
  ///     m(rhs) {
  ///       var variable;
  ///       variable += rhs;
  ///     }
  ///
  void visitLocalVariableCompound(Send node, LocalVariableElement variable,
      AssignmentOperator operator, Node rhs, T arg) {
    super.visitLocalVariableCompound(node, variable, operator, rhs, arg);
  }

  /// Compound assignment expression of [rhs] with [operator] on a static
  /// [field].
  ///
  /// For instance:
  ///     class C {
  ///       static var field;
  ///       m(rhs) => field += rhs;
  ///     }
  ///
  void visitStaticFieldCompound(Send node, FieldElement field,
      AssignmentOperator operator, Node rhs, T arg) {
    super.visitStaticFieldCompound(node, field, operator, rhs, arg);
  }

  /// Compound assignment expression of [rhs] with [operator] reading from a
  /// static [getter] and writing to a static [setter].
  ///
  /// For instance:
  ///     class C {
  ///       static get o => 0;
  ///       static set o(_) {}
  ///       m(rhs) => o += rhs;
  ///     }
  ///
  void visitStaticGetterSetterCompound(Send node, FunctionElement getter,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    super.visitStaticGetterSetterCompound(
        node, getter, setter, operator, rhs, arg);
  }

  /// Compound assignment expression of [rhs] with [operator] reading from a
  /// static [method], that is, closurizing [method], and writing to a static
  /// [setter].
  ///
  /// For instance:
  ///     class C {
  ///       static o() {}
  ///       static set o(_) {}
  ///       m(rhs) => o += rhs;
  ///     }
  ///
  void visitStaticMethodSetterCompound(Send node, FunctionElement method,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    super.visitStaticMethodSetterCompound(
        node, method, setter, operator, rhs, arg);
  }

  /// Compound assignment expression of [rhs] with [operator] on a top level
  /// [field].
  ///
  /// For instance:
  ///     var field;
  ///     m(rhs) => field += rhs;
  ///
  void visitTopLevelFieldCompound(Send node, FieldElement field,
      AssignmentOperator operator, Node rhs, T arg) {
    super.visitTopLevelFieldCompound(node, field, operator, rhs, arg);
  }

  /// Compound assignment expression of [rhs] with [operator] reading from a
  /// top level [getter] and writing to a top level [setter].
  ///
  /// For instance:
  ///     get o => 0;
  ///     set o(_) {}
  ///     m(rhs) => o += rhs;
  ///
  void visitTopLevelGetterSetterCompound(Send node, FunctionElement getter,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    super.visitTopLevelGetterSetterCompound(
        node, getter, setter, operator, rhs, arg);
  }

  /// Compound assignment expression of [rhs] with [operator] reading from a
  /// top level [method], that is, closurizing [method], and writing to a top
  /// level [setter].
  ///
  /// For instance:
  ///     o() {}
  ///     set o(_) {}
  ///     m(rhs) => o += rhs;
  ///
  void visitTopLevelMethodSetterCompound(Send node, FunctionElement method,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    super.visitTopLevelMethodSetterCompound(
        node, method, setter, operator, rhs, arg);
  }

  /// Compound assignment expression of [rhs] with [operator] on the index
  /// operators of [receiver] whose getter and setter are defined by
  /// [getterSelector] and [setterSelector], respectively.
  ///
  /// For instance:
  ///     m(receiver, index, rhs) => receiver[index] += rhs;
  ///
  void visitCompoundIndexSet(SendSet node, Node receiver, Node index,
      AssignmentOperator operator, Node rhs, T arg) {
    super.visitCompoundIndexSet(node, receiver, index, operator, rhs, arg);
  }

  /// Prefix expression with [operator] of the property on [receiver] whose
  /// getter and setter are defined by [getterSelector] and [setterSelector],
  /// respectively.
  ///
  /// For instance:
  ///     m(receiver) => ++receiver.foo;
  ///
  void visitDynamicPropertyPrefix(Send node, Node receiver,
      IncDecOperator operator, Selector getterSelector, Selector setterSelector,
      T arg) {
    super.visitDynamicPropertyPrefix(
        node, receiver, operator, getterSelector, setterSelector, arg);
  }

  /// Prefix expression with [operator] on a [parameter].
  ///
  /// For instance:
  ///     m(parameter) => ++parameter;
  ///
  void visitParameterPrefix(
      Send node, ParameterElement parameter, IncDecOperator operator, T arg) {
    super.visitParameterPrefix(node, parameter, operator, arg);
  }

  /// Prefix expression with [operator] on a local [variable].
  ///
  /// For instance:
  ///     m() {
  ///     var variable;
  ///      ++variable;
  ///     }
  ///
  void visitLocalVariablePrefix(Send node, LocalVariableElement variable,
      IncDecOperator operator, T arg) {
    super.visitLocalVariablePrefix(node, variable, operator, arg);
  }

  /// Prefix expression with [operator] of the property on `this` whose getter
  /// and setter are defined by [getterSelector] and [setterSelector],
  /// respectively.
  ///
  /// For instance:
  ///     class C {
  ///       m() => ++foo;
  ///     }
  /// or
  ///     class C {
  ///       m() => ++this.foo;
  ///     }
  ///
  void visitThisPropertyPrefix(Send node, IncDecOperator operator,
      Selector getterSelector, Selector setterSelector, T arg) {
    super.visitThisPropertyPrefix(
        node, operator, getterSelector, setterSelector, arg);
  }

  // ----------------------

  /// Prefix expression with [operator] on a static [field].
  ///
  /// For instance:
  ///     class C {
  ///       static var field;
  ///       m() => ++field;
  ///     }
  ///
  void visitStaticFieldPrefix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    super.visitStaticFieldPrefix(node, field, operator, arg);
  }

  /// Prefix expression with [operator] reading from a static [getter] and
  /// writing to a static [setter].
  ///
  /// For instance:
  ///     class C {
  ///       static get o => 0;
  ///       static set o(_) {}
  ///       m() => ++o;
  ///     }
  ///
  void visitStaticGetterSetterPrefix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    super.visitStaticGetterSetterPrefix(node, getter, setter, operator, arg);
  }

  /// Prefix expression with [operator] reading from a static [method], that is,
  /// closurizing [method], and writing to a static [setter].
  ///
  /// For instance:
  ///     class C {
  ///       static o() {}
  ///       static set o(_) {}
  ///       m() => ++o;
  ///     }
  ///
  void visitStaticMethodSetterPrefix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    super.visitStaticMethodSetterPrefix(node, getter, setter, operator, arg);
  }

  /// Prefix expression with [operator] on a top level [field].
  ///
  /// For instance:
  ///     var field;
  ///     m() => ++field;
  ///
  void visitTopLevelFieldPrefix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    super.visitTopLevelFieldPrefix(node, field, operator, arg);
  }

  /// Prefix expression with [operator] reading from a top level [getter] and
  /// writing to a top level [setter].
  ///
  /// For instance:
  ///     get o => 0;
  ///     set o(_) {}
  ///     m() => ++o;
  ///
  void visitTopLevelGetterSetterPrefix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    super.visitTopLevelGetterSetterPrefix(node, getter, setter, operator, arg);
  }

  /// Prefix expression with [operator] reading from a top level [method], that
  /// is, closurizing [method], and writing to a top level [setter].
  ///
  /// For instance:
  ///     o() {}
  ///     set o(_) {}
  ///     m() => ++o;
  ///
  void visitTopLevelMethodSetterPrefix(Send node, FunctionElement method,
      FunctionElement setter, IncDecOperator operator, T arg) {
    super.visitTopLevelMethodSetterPrefix(node, method, setter, operator, arg);
  }

  /// Prefix expression with [operator] on a super [field].
  ///
  /// For instance:
  ///     class B {
  ///       var field;
  ///     }
  ///     class C extends B {
  ///       m() => ++super.field;
  ///     }
  ///
  void visitSuperFieldPrefix(node, field, operator, arg) {
    super.visitSuperFieldPrefix(node, field, operator, arg);
  }

  /// Prefix expression with [operator] reading from the super field [readField]
  /// and writing to the different super field [writtenField].
  ///
  /// For instance:
  ///     class A {
  ///       var field;
  ///     }
  ///     class B extends A {
  ///       final field;
  ///     }
  ///     class C extends B {
  ///       m() => ++super.field;
  ///     }
  ///
  void visitSuperFieldFieldPrefix(
      node, readField, writtenField, operator, arg) {
    super.visitSuperFieldFieldPrefix(
        node, readField, writtenField, operator, arg);
  }

  /// Prefix expression with [operator] reading from a super [field] and writing
  /// to a super [setter].
  ///
  /// For instance:
  ///     class A {
  ///       var field;
  ///     }
  ///     class B extends A {
  ///       set field(_) {}
  ///     }
  ///     class C extends B {
  ///       m() => ++super.field;
  ///     }
  ///
  void visitSuperFieldSetterPrefix(node, field, setter, operator, arg) {
    super.visitSuperFieldSetterPrefix(node, field, setter, operator, arg);
  }

  /// Prefix expression with [operator] reading from a super [getter] and
  /// writing to a super [setter].
  ///
  /// For instance:
  ///     class B {
  ///       get field => 0;
  ///       set field(_) {}
  ///     }
  ///     class C extends B {
  ///       m() => ++super.field;
  ///     }
  ///
  void visitSuperGetterSetterPrefix(node, getter, setter, operator, arg) {
    super.visitSuperGetterSetterPrefix(node, getter, setter, operator, arg);
  }

  /// Prefix expression with [operator] reading from a super [getter] and
  /// writing to a super [field].
  ///
  /// For instance:
  ///     class A {
  ///       var field;
  ///     }
  ///     class B extends A {
  ///       get field => 0;
  ///     }
  ///     class C extends B {
  ///       m() => ++super.field;
  ///     }
  ///
  void visitSuperGetterFieldPrefix(node, getter, field, operator, arg) {
    super.visitSuperGetterFieldPrefix(node, getter, field, operator, arg);
  }

  /// Prefix expression with [operator] reading from a super [method], is,
  /// closurizing [method], and writing to a super [setter].
  ///
  /// For instance:
  ///     class B {
  ///       o() {}
  ///       set o(_) {}
  ///     }
  ///     class C extends B {
  ///       m() => ++super.o;
  ///     }
  ///
  void visitSuperMethodSetterPrefix(node, method, setter, operator, arg) {
    super.visitSuperMethodSetterPrefix(node, method, setter, operator, arg);
  }

  /// Prefix expression with [operator] on a type literal for a class [element].
  ///
  /// For instance:
  ///     class C {}
  ///     m() => ++C;
  ///
  void errorClassTypeLiteralPrefix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {}

  /// Prefix expression with [operator] on a type literal for a typedef
  /// [element].
  ///
  /// For instance:
  ///     typedef F();
  ///     m() => ++F;
  ///
  void errorTypedefTypeLiteralPrefix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {}

  /// Prefix expression with [operator] on a type literal for a type variable
  /// [element].
  ///
  /// For instance:
  ///     class C<T> {
  ///       m() => ++T;
  ///     }
  ///
  void errorTypeVariableTypeLiteralPrefix(
      Send node, TypeVariableElement element, IncDecOperator operator, T arg) {}

  /// Prefix expression with [operator] on the type literal for `dynamic`.
  ///
  /// For instance:
  ///     m() => ++dynamic;
  ///
  void errorDynamicTypeLiteralPrefix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {}

  /// Postfix expression with [operator] of the property on [receiver] whose
  /// getter and setter are defined by [getterSelector] and [setterSelector],
  /// respectively.
  ///
  /// For instance:
  ///     m(receiver) => receiver.foo++;
  ///
  void visitDynamicPropertyPostfix(Send node, Node receiver,
      IncDecOperator operator, Selector getterSelector, Selector setterSelector,
      T arg) {
    super.visitDynamicPropertyPostfix(
        node, receiver, operator, getterSelector, setterSelector, arg);
  }

  /// Postfix expression with [operator] on a [parameter].
  ///
  /// For instance:
  ///     m(parameter) => parameter++;
  ///
  void visitParameterPostfix(
      Send node, ParameterElement parameter, IncDecOperator operator, T arg) {
    super.visitParameterPostfix(node, parameter, operator, arg);
  }

  /// Postfix expression with [operator] on a local [variable].
  ///
  /// For instance:
  ///     m() {
  ///     var variable;
  ///      variable++;
  ///     }
  ///
  void visitLocalVariablePostfix(Send node, LocalVariableElement variable,
      IncDecOperator operator, T arg) {
    super.visitLocalVariablePostfix(node, variable, operator, arg);
  }

  /// Postfix expression with [operator] on a local [function].
  ///
  /// For instance:
  ///     m() {
  ///     function() {}
  ///      function++;
  ///     }
  ///
  void errorLocalFunctionPostfix(Send node, LocalFunctionElement function,
      IncDecOperator operator, T arg) {}

  /// Postfix expression with [operator] of the property on `this` whose getter
  /// and setter are defined by [getterSelector] and [setterSelector],
  /// respectively.
  ///
  /// For instance:
  ///     class C {
  ///       m() => foo++;
  ///     }
  /// or
  ///     class C {
  ///       m() => this.foo++;
  ///     }
  ///
  void visitThisPropertyPostfix(Send node, IncDecOperator operator,
      Selector getterSelector, Selector setterSelector, T arg) {
    super.visitThisPropertyPostfix(
        node, operator, getterSelector, setterSelector, arg);
  }

  /// Postfix expression with [operator] on a static [field].
  ///
  /// For instance:
  ///     class C {
  ///       static var field;
  ///       m() => field++;
  ///     }
  ///
  void visitStaticFieldPostfix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    super.visitStaticFieldPostfix(node, field, operator, arg);
  }

  /// Postfix expression with [operator] reading from a static [getter] and
  /// writing to a static [setter].
  ///
  /// For instance:
  ///     class C {
  ///       static get o => 0;
  ///       static set o(_) {}
  ///       m() => o++;
  ///     }
  ///
  void visitStaticGetterSetterPostfix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    super.visitStaticGetterSetterPostfix(node, getter, setter, operator, arg);
  }

  /// Postfix expression with [operator] reading from a static [method], that
  /// is, closurizing [method], and writing to a static [setter].
  ///
  /// For instance:
  ///     class C {
  ///       static o() {}
  ///       static set o(_) {}
  ///       m() => o++;
  ///     }
  ///
  void visitStaticMethodSetterPostfix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    super.visitStaticMethodSetterPostfix(node, getter, setter, operator, arg);
  }

  /// Postfix expression with [operator] on a top level [field].
  ///
  /// For instance:
  ///     var field;
  ///     m() => field++;
  ///
  void visitTopLevelFieldPostfix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    super.visitTopLevelFieldPostfix(node, field, operator, arg);
  }

  /// Postfix expression with [operator] reading from a top level [getter] and
  /// writing to a top level [setter].
  ///
  /// For instance:
  ///     get o => 0;
  ///     set o(_) {}
  ///     m() => o++;
  ///
  void visitTopLevelGetterSetterPostfix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    super.visitTopLevelGetterSetterPostfix(node, getter, setter, operator, arg);
  }

  /// Postfix expression with [operator] reading from a top level [method], that
  /// is, closurizing [method], and writing to a top level [setter].
  ///
  /// For instance:
  ///     o() {}
  ///     set o(_) {}
  ///     m() => o++;
  ///
  void visitTopLevelMethodSetterPostfix(Send node, FunctionElement method,
      FunctionElement setter, IncDecOperator operator, T arg) {
    super.visitTopLevelMethodSetterPostfix(node, method, setter, operator, arg);
  }

  /// Postfix expression with [operator] on a super [field].
  ///
  /// For instance:
  ///     class B {
  ///       var field;
  ///     }
  ///     class C extends B {
  ///       m() => super.field++;
  ///     }
  ///
  void visitSuperFieldPostfix(node, field, operator, arg) {
    super.visitSuperFieldPostfix(node, field, operator, arg);
  }

  /// Postfix expression with [operator] reading from the super field
  /// [readField] and writing to the different super field [writtenField].
  ///
  /// For instance:
  ///     class A {
  ///       var field;
  ///     }
  ///     class B extends A {
  ///       final field;
  ///     }
  ///     class C extends B {
  ///       m() => super.field++;
  ///     }
  ///
  void visitSuperFieldFieldPostfix(
      node, readField, writtenField, operator, arg) {
    super.visitSuperFieldFieldPostfix(
        node, readField, writtenField, operator, arg);
  }

  /// Postfix expression with [operator] reading from a super [field] and
  /// writing to a super [setter].
  ///
  /// For instance:
  ///     class A {
  ///       var field;
  ///     }
  ///     class B extends A {
  ///       set field(_) {}
  ///     }
  ///     class C extends B {
  ///       m() => super.field++;
  ///     }
  ///
  void visitSuperFieldSetterPostfix(node, field, setter, operator, arg) {
    super.visitSuperFieldSetterPostfix(node, field, setter, operator, arg);
  }

  /// Postfix expression with [operator] reading from a super [getter] and
  /// writing to a super [setter].
  ///
  /// For instance:
  ///     class B {
  ///       get field => 0;
  ///       set field(_) {}
  ///     }
  ///     class C extends B {
  ///       m() => super.field++;
  ///     }
  ///
  void visitSuperGetterSetterPostfix(node, getter, setter, operator, arg) {
    super.visitSuperGetterSetterPostfix(node, getter, setter, operator, arg);
  }

  /// Postfix expression with [operator] reading from a super [getter] and
  /// writing to a super [field].
  ///
  /// For instance:
  ///     class A {
  ///       var field;
  ///     }
  ///     class B extends A {
  ///       get field => 0;
  ///     }
  ///     class C extends B {
  ///       m() => super.field++;
  ///     }
  ///
  void visitSuperGetterFieldPostfix(node, getter, field, operator, arg) {
    super.visitSuperGetterFieldPostfix(node, getter, field, operator, arg);
  }

  /// Postfix expression with [operator] reading from a super [method], is,
  /// closurizing [method], and writing to a super [setter].
  ///
  /// For instance:
  ///     class B {
  ///       o() {}
  ///       set o(_) {}
  ///     }
  ///     class C extends B {
  ///       m() => super.o++;
  ///     }
  ///
  void visitSuperMethodSetterPostfix(node, method, setter, operator, arg) {
    super.visitSuperMethodSetterPostfix(node, method, setter, operator, arg);
  }

  /// Postfix expression with [operator] on a type literal for a class
  /// [element].
  ///
  /// For instance:
  ///     class C {}
  ///     m() => C++;
  ///
  void errorClassTypeLiteralPostfix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {}

  /// Postfix expression with [operator] on a type literal for a typedef
  /// [element].
  ///
  /// For instance:
  ///     typedef F();
  ///     m() => F++;
  ///
  void errorTypedefTypeLiteralPostfix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {}

  /// Postfix expression with [operator] on a type literal for a type variable
  /// [element].
  ///
  /// For instance:
  ///     class C<T> {
  ///       m() => T++;
  ///     }
  ///
  void errorTypeVariableTypeLiteralPostfix(
      Send node, TypeVariableElement element, IncDecOperator operator, T arg) {}

  /// Postfix expression with [operator] on the type literal for `dynamic`.
  ///
  /// For instance:
  ///     m() => dynamic++;
  ///
  void errorDynamicTypeLiteralPostfix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {}

  /// Read of the [constant].
  ///
  /// For instance
  ///     const c = c;
  ///     m() => c;
  ///
  void visitConstantGet(Send node, ConstantExpression constant, T arg) {
    super.visitConstantGet(node, constant, arg);
  }

  /// Invocation of the [constant] with [arguments].
  ///
  /// For instance
  ///     const c = null;
  ///     m() => c(null, 42);
  ///
  void visitConstantInvoke(Send node, ConstantExpression constant,
      NodeList arguments, CallStructure callStreucture, T arg) {
    super.visitConstantInvoke(node, constant, arguments, callStreucture, arg);
  }

  /// Read of the unresolved [element].
  ///
  /// For instance
  ///     class C {}
  ///     m1() => unresolved;
  ///     m2() => prefix.unresolved;
  ///     m3() => Unresolved.foo;
  ///     m4() => unresolved.foo;
  ///     m5() => unresolved.Foo.bar;
  ///     m6() => C.unresolved;
  ///     m7() => prefix.C.unresolved;
  ///
  // TODO(johnniwinther): Split the cases in which a prefix is resolved.
  void errorUnresolvedGet(Send node, Element element, T arg) {}

  /// Assignment of [rhs] to the unresolved [element].
  ///
  /// For instance
  ///     class C {}
  ///     m1() => unresolved = 42;
  ///     m2() => prefix.unresolved = 42;
  ///     m3() => Unresolved.foo = 42;
  ///     m4() => unresolved.foo = 42;
  ///     m5() => unresolved.Foo.bar = 42;
  ///     m6() => C.unresolved = 42;
  ///     m7() => prefix.C.unresolved = 42;
  ///
  // TODO(johnniwinther): Split the cases in which a prefix is resolved.
  void errorUnresolvedSet(Send node, Element element, Node rhs, T arg) {}

  /// Invocation of the unresolved [element] with [arguments].
  ///
  /// For instance
  ///     class C {}
  ///     m1() => unresolved(null, 42);
  ///     m2() => prefix.unresolved(null, 42);
  ///     m3() => Unresolved.foo(null, 42);
  ///     m4() => unresolved.foo(null, 42);
  ///     m5() => unresolved.Foo.bar(null, 42);
  ///     m6() => C.unresolved(null, 42);
  ///     m7() => prefix.C.unresolved(null, 42);
  ///
  // TODO(johnniwinther): Split the cases in which a prefix is resolved.
  void errorUnresolvedInvoke(Send node, Element element, NodeList arguments,
      Selector selector, T arg) {}

  /// Compound assignment of [rhs] on the unresolved [element].
  ///
  /// For instance
  ///     class C {}
  ///     m1() => unresolved += 42;
  ///     m2() => prefix.unresolved += 42;
  ///     m3() => Unresolved.foo += 42;
  ///     m4() => unresolved.foo += 42;
  ///     m5() => unresolved.Foo.bar += 42;
  ///     m6() => C.unresolved += 42;
  ///     m7() => prefix.C.unresolved += 42;
  ///
  // TODO(johnniwinther): Split the cases in which a prefix is resolved.
  void errorUnresolvedCompound(Send node, Element element,
      AssignmentOperator operator, Node rhs, T arg) {}

  /// Prefix operation on the unresolved [element].
  ///
  /// For instance
  ///     class C {}
  ///     m1() => ++unresolved;
  ///     m2() => ++prefix.unresolved;
  ///     m3() => ++Unresolved.foo;
  ///     m4() => ++unresolved.foo;
  ///     m5() => ++unresolved.Foo.bar;
  ///     m6() => ++C.unresolved;
  ///     m7() => ++prefix.C.unresolved;
  ///
  // TODO(johnniwinther): Split the cases in which a prefix is resolved.
  void errorUnresolvedPrefix(
      Send node, Element element, IncDecOperator operator, T arg) {}

  /// Postfix operation on the unresolved [element].
  ///
  /// For instance
  ///     class C {}
  ///     m1() => unresolved++;
  ///     m2() => prefix.unresolved++;
  ///     m3() => Unresolved.foo++;
  ///     m4() => unresolved.foo++;
  ///     m5() => unresolved.Foo.bar++;
  ///     m6() => C.unresolved++;
  ///     m7() => prefix.C.unresolved++;
  ///
  // TODO(johnniwinther): Split the cases in which a prefix is resolved.
  void errorUnresolvedPostfix(
      Send node, Element element, IncDecOperator operator, T arg) {}

  /// Index set operation on the unresolved super [element].
  ///
  /// For instance
  ///     class B {
  ///     }
  ///     class C extends B {
  ///       m() => super[1] = 42;
  ///     }
  ///
  void errorUnresolvedSuperIndexSet(node, element, index, rhs, arg) {}

  /// Compound index set operation on the unresolved super [element].
  ///
  /// For instance
  ///     class B {
  ///     }
  ///     class C extends B {
  ///       m() => super[1] += 42;
  ///     }
  ///
  // TODO(johnniwinther): Split this case into unresolved getter/setter cases.
  void errorUnresolvedSuperCompoundIndexSet(
      node, element, index, operator, rhs, arg) {}

  /// Unary operation on the unresolved super [element].
  ///
  /// For instance
  ///     class B {
  ///     }
  ///     class C extends B {
  ///       m() => -super;
  ///     }
  ///
  void errorUnresolvedSuperUnary(node, operator, element, arg) {}

  /// Binary operation on the unresolved super [element].
  ///
  /// For instance
  ///     class B {
  ///     }
  ///     class C extends B {
  ///       m() => super + 42;
  ///     }
  ///
  void errorUnresolvedSuperBinary(node, element, operator, argument, arg) {}

  /// Invocation of an undefined unary [operator] on [expression].
  void errorUndefinedUnaryExpression(
      Send node, Operator operator, Node expression, T arg) {}

  /// Invocation of an undefined unary [operator] with operands
  /// [left] and [right].
  void errorUndefinedBinaryExpression(
      Send node, Node left, Operator operator, Node right, T arg) {}

  /// Const invocation of a [constructor].
  ///
  /// For instance
  ///   class C<T> {
  ///     const C(a, b);
  ///   }
  ///   m() => const C<int>(true, 42);
  ///
  void visitConstConstructorInvoke(
      NewExpression node, ConstructedConstantExpression constant, T arg) {
    super.visitConstConstructorInvoke(node, constant, arg);
  }

  /// Invocation of a generative [constructor] on [type] with [arguments].
  ///
  /// For instance
  ///   class C<T> {
  ///     C(a, b);
  ///   }
  ///   m() => new C<int>(true, 42);
  ///
  /// where [type] is `C<int>`.
  ///
  void visitGenerativeConstructorInvoke(NewExpression node,
      ConstructorElement constructor, InterfaceType type, NodeList arguments,
      CallStructure callStructure, T arg) {
    super.visitGenerativeConstructorInvoke(
        node, constructor, type, arguments, callStructure, arg);
  }

  /// Invocation of a redirecting generative [constructor] on [type] with
  /// [arguments].
  ///
  /// For instance
  ///   class C<T> {
  ///     C(a, b) : this._(b, a);
  ///     C._(b, a);
  ///   }
  ///   m() => new C<int>(true, 42);
  ///
  /// where [type] is `C<int>`.
  ///
  void visitRedirectingGenerativeConstructorInvoke(NewExpression node,
      ConstructorElement constructor, InterfaceType type, NodeList arguments,
      CallStructure callStructure, T arg) {
    super.visitRedirectingGenerativeConstructorInvoke(
        node, constructor, type, arguments, callStructure, arg);
  }

  /// Invocation of a factory [constructor] on [type] with [arguments].
  ///
  /// For instance
  ///   class C<T> {
  ///     factory C(a, b) => new C<T>._(b, a);
  ///     C._(b, a);
  ///   }
  ///   m() => new C<int>(true, 42);
  ///
  /// where [type] is `C<int>`.
  ///
  void visitFactoryConstructorInvoke(NewExpression node,
      ConstructorElement constructor, InterfaceType type, NodeList arguments,
      CallStructure callStructure, T arg) {
    super.visitFactoryConstructorInvoke(
        node, constructor, type, arguments, callStructure, arg);
  }

  /// Invocation of a factory [constructor] on [type] with [arguments] where
  /// [effectiveTarget] and [effectiveTargetType] are the constructor effective
  /// invoked and its type, respectively.
  ///
  /// For instance
  ///   class C<T> {
  ///     factory C(a, b) = C<int>.a;
  ///     factory C.a(a, b) = C<C<T>>.b;
  ///     C.b(a, b);
  ///   }
  ///   m() => new C<double>(true, 42);
  ///
  /// where [type] is `C<double>`, [effectiveTarget] is `C.b` and
  /// [effectiveTargetType] is `C<C<int>>`.
  ///
  void visitRedirectingFactoryConstructorInvoke(NewExpression node,
      ConstructorElement constructor, InterfaceType type,
      ConstructorElement effectiveTarget, InterfaceType effectiveTargetType,
      NodeList arguments, CallStructure callStructure, T arg) {}

  /// Invocation of an unresolved [constructor] on [type] with [arguments].
  ///
  /// For instance
  ///   class C<T> {
  ///     C();
  ///   }
  ///   m() => new C<int>.unresolved(true, 42);
  ///
  /// where [type] is `C<int>`.
  ///
  // TODO(johnniwinther): Update [type] to be [InterfaceType] when this is no
  // longer a catch-all clause for the erroneous constructor invocations.
  void errorUnresolvedConstructorInvoke(NewExpression node, Element constructor,
      DartType type, NodeList arguments, Selector selector, T arg) {}

  /// Invocation of a constructor on an unresolved [type] with [arguments].
  ///
  /// For instance
  ///   m() => new Unresolved(true, 42);
  ///
  /// where [type] is the malformed type `Unresolved`.
  ///
  void errorUnresolvedClassConstructorInvoke(NewExpression node,
      Element element, MalformedType type, NodeList arguments,
      Selector selector, T arg) {}

  /// Invocation of a constructor on an abstract [type] with [arguments].
  ///
  /// For instance
  ///   m() => new Unresolved(true, 42);
  ///
  /// where [type] is the malformed type `Unresolved`.
  ///
  void errorAbstractClassConstructorInvoke(NewExpression node,
      ConstructorElement element, InterfaceType type, NodeList arguments,
      CallStructure callStructure, T arg) {}

  /// Invocation of a factory [constructor] on [type] with [arguments] where
  /// [effectiveTarget] and [effectiveTargetType] are the constructor effective
  /// invoked and its type, respectively.
  ///
  /// For instance
  ///   class C {
  ///     factory C(a, b) = Unresolved;
  ///     factory C.a(a, b) = C.unresolved;
  ///   }
  ///   m1() => new C(true, 42);
  ///   m2() => new C.a(true, 42);
  ///
  void errorUnresolvedRedirectingFactoryConstructorInvoke(NewExpression node,
      ConstructorElement constructor, InterfaceType type, NodeList arguments,
      Selector selector, T arg) {}
}

/// Helper to visit elements recursively
// TODO(sigmund): generalize and move to elements/visitor.dart?
abstract class RecursiveElementVisitor<R, A> extends ElementVisitor<R, A> {
  R merge(List<R> results);

  @override
  R visitWarnOnUseElement(WarnOnUseElement e, A arg) =>
      e.wrappedElement.accept(this, arg);

  R visitScopeContainerElement(ScopeContainerElement e, A arg) {
    List<R> results = e.forEachLocalMember((l) => l.accept(this, arg));
    return merge(results);
  }

  @override
  R visitCompilationUnitElement(CompilationUnitElement e, A arg) {
    List<R> results = [];
    e.forEachLocalMember((l) => results.add(l.accept(this, arg)));
    return merge(results);
  }

  @override
  R visitLibraryElement(LibraryElement e, A arg) {
    List<R> results = [];
    e.implementation.compilationUnits.forEach(
        (u) => results.add(u.accept(this, arg)));
    return merge(results);
  }

  @override
  R visitVariableElement(VariableElement e, A arg) {
  }

  @override
  R visitParameterElement(ParameterElement e, A arg) {
  }

  @override
  R visitFormalElement(FormalElement e, A arg) {
  }

  @override
  R visitFieldElement(FieldElement e, A arg) {
  }

  @override
  R visitFieldParameterElement(InitializingFormalElement e, A arg) {
  }

  @override
  R visitAbstractFieldElement(AbstractFieldElement e, A arg) {
  }

  @override
  R visitFunctionElement(FunctionElement e, A arg) {
    //return super.visitFunctionElement(e, arg);
  }

  @override
  R visitConstructorElement(ConstructorElement e, A arg) {
    return visitFunctionElement(e, arg);
  }

  @override
  R visitConstructorBodyElement(ConstructorBodyElement e, A arg) {
    return visitFunctionElement(e.constructor, arg);
  }

  @override
  R visitClassElement(ClassElement e, A arg) {
    return visitScopeContainerElement(e, arg);
  }

  @override
  R visitEnumClassElement(EnumClassElement e, A arg) {
    return visitClassElement(e, arg);
  }

  @override
  R visitBoxFieldElement(BoxFieldElement e, A arg) {
  }

  @override
  R visitClosureClassElement(ClosureClassElement e, A arg) {
    return visitClassElement(e, arg);
  }

  @override
  R visitClosureFieldElement(ClosureFieldElement e, A arg) {
    return visitVariableElement(e, arg);
  }
}
