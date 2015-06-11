library inference_stats;

import 'dart:io';

import '../stats/stats.dart';
import '../stats/stats_viewer.dart';
import '../dart_types.dart';
import '../elements/elements.dart';
import '../resolution/operators.dart';
import '../resolution/resolution.dart';
import '../resolution/semantic_visitor.dart';
import '../tree/tree.dart';
import '../universe/universe.dart' show Selector, CallStructure;
import '../dart2jslib.dart'
    show CompilerTask, Compiler, SourceSpan, MessageKind;
import '../elements/visitor.dart' show ElementVisitor;
import '../scanner/scannerlib.dart' show PartialElement;

/// Task that collects metric information about types.
class StatsBuilderTask extends CompilerTask {
  String get name => "Inference Stats";

  StatsBuilderTask(Compiler compiler) : super(compiler);

  void run() {
    measure(() {
      var visitor = new StatsBuilder(compiler);
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
  final Compiler compiler;
  StatsBuilder(this.compiler);
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

  visitFunctionElement(FunctionElement e, arg) {
    compiler.withCurrentElement(e, () {
      if (e.library.isPlatformLibrary) return;
      if (!e.hasNode) {
        // TODO: this may be wrong, no node could mean an empty constructor body
        if (!e.library.isPlatformLibrary) print('>> $e: unreachable');
        currentLib.functions.add(new FunctionResult(
            e.name, const Measurements.unreachableFunction()));
        return;
      }
      if (!e.hasResolvedAst) {
        _debug('no resolved ast ${e.runtimeType}');
        return;
      }
      var resolvedAst = e.resolvedAst;
      var visitor = new _StatsTraversalVisitor(compiler, resolvedAst.elements);
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
      if (!e.library.isPlatformLibrary) print(
          '>> $e: reachable, add ${visitor.measurements[Metric.functions]}');
      currentLib.functions
          .add(new FunctionResult(e.name, visitor.measurements));
    });
  }

  // TODO(sigmund): visit initializers too, they can contain `sends`.
}

class _StatsVisitor<T> extends Visitor<T>
    with SendResolverMixin, SemanticSendResolvedMixin, BaseImplementationOfStaticsMixin<Void, T>, BaseImplementationOfLocalsMixin<Void, T>, BaseImplementationOfDynamicsMixin<Void, T>, BaseImplementationOfCompoundsMixin<Void, T>, BaseImplementationOfIndexCompoundsMixin<Void, T> {
  SemanticSendVisitor<Void, T> get sendVisitor => this;
  Measurements measurements = new Measurements.reachableFunction();
  final Compiler compiler;
  final TreeElements elements;
  _StatsVisitor(this.compiler, this.elements);

  visitSend(Send node) {
    _check(node, 'before');
    measurements[Metric.send]++;
    if (node is SendSet && 
        ((node.assignmentOperator != null && node.assignmentOperator.source != '=')
        || node.isPrefix || node.isPostfix)) {
      print('=> ${node.assignmentOperator.runtimeType}');
      measurements[Metric.send] += 2;
    }
    super.visitSend(node);
    _check(node, 'after');
  }

  handleLocal() => measurements[Metric.localSend]++;
  handleDynamic() => measurements[Metric.dynamicSend]++;
  handleCompoundDynamic() {
    // Count 2 more for the get and set portions of the compound
    measurements[Metric.send] += 2;

    // TODO(sigmund): refine, the other two are likely better.
    measurements[Metric.dynamicSend] += 3;
  }
  handleVirtual() => measurements[Metric.virtualSend]++;
  handleNSM() => measurements[Metric.nsmSend]++;
  handleMonomorphic() => measurements[Metric.monomorphicSend]++;
  handleStatic() => measurements[Metric.staticSend]++;
  handleNoSend() => measurements[Metric.send]--;

  // Constructors

  void visitAbstractClassConstructorInvoke(NewExpression node,
      ConstructorElement element, InterfaceType type, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleConstructor();
  }

  void visitBoolFromEnvironmentConstructorInvoke(NewExpression node,
      BoolFromEnvironmentConstantExpression constant, T arg) {
    handleConstructor();
  }

  void visitConstConstructorInvoke(
      NewExpression node, ConstructedConstantExpression constant, T arg) {
    handleConstructor();
  }

  void visitGenerativeConstructorInvoke(NewExpression node,
      ConstructorElement constructor, InterfaceType type, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleConstructor();
  }

  void visitIntFromEnvironmentConstructorInvoke(NewExpression node,
      IntFromEnvironmentConstantExpression constant, T arg) {
    handleConstructor();
  }

  void visitRedirectingFactoryConstructorInvoke(NewExpression node,
      ConstructorElement constructor, InterfaceType type,
      ConstructorElement effectiveTarget, InterfaceType effectiveTargetType,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleConstructor();
  }

  void visitRedirectingGenerativeConstructorInvoke(NewExpression node,
      ConstructorElement constructor, InterfaceType type, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleConstructor();
  }

  void visitStringFromEnvironmentConstructorInvoke(NewExpression node,
      StringFromEnvironmentConstantExpression constant, T arg) {
    handleConstructor();
  }

  // Dynamic sends

  void visitBinary(
      Send node, Node left, BinaryOperator operator, Node right, T arg) {
    handleDynamic();
  }

  void visitCompoundIndexSet(SendSet node, Node receiver, Node index,
      AssignmentOperator operator, Node rhs, T arg) {
    handleDynamic(); // t1 = receiver[index]
    handleDynamic(); // t2 = t1 op rhs
    handleDynamic(); // receiver[index] = t2
  }

  void visitDynamicPropertyCompound(Send node, Node receiver,
      AssignmentOperator operator, Node rhs, Selector getterSelector,
      Selector setterSelector, T arg) {
    handleDynamic();
    handleDynamic();
    handleDynamic();
  }

  void visitDynamicPropertyGet(
      Send node, Node receiver, Selector selector, T arg) {
    handleDynamic();
  }

  void visitDynamicPropertyInvoke(
      Send node, Node receiver, NodeList arguments, Selector selector, T arg) {
    handleDynamic();
  }

  void visitDynamicPropertyPostfix(Send node, Node receiver,
      IncDecOperator operator, Selector getterSelector, Selector setterSelector,
      T arg) {
    handleDynamic();
    handleDynamic();
    handleDynamic();
  }

  void visitDynamicPropertyPrefix(Send node, Node receiver,
      IncDecOperator operator, Selector getterSelector, Selector setterSelector,
      T arg) {
    handleDynamic();
    handleDynamic();
    handleDynamic();
  }

  void visitDynamicPropertySet(
      SendSet node, Node receiver, Selector selector, Node rhs, T arg) {
    handleDynamic();
  }

  void visitEquals(Send node, Node left, Node right, T arg) {
    handleDynamic();
  }

  void visitExpressionInvoke(Send node, Node expression, NodeList arguments,
      Selector selector, T arg) {
    handleDynamic();
  }

  void visitIfNotNullDynamicPropertyCompound(Send node, Node receiver,
      AssignmentOperator operator, Node rhs, Selector getterSelector,
      Selector setterSelector, T arg) {
    handleDynamic();
    handleDynamic();
    handleDynamic();
  }

  void visitIfNotNullDynamicPropertyGet(
      Send node, Node receiver, Selector selector, T arg) {
    handleDynamic();
  }

  void visitIfNotNullDynamicPropertyInvoke(
      Send node, Node receiver, NodeList arguments, Selector selector, T arg) {
    handleDynamic();
  }

  void visitIfNotNullDynamicPropertyPostfix(Send node, Node receiver,
      IncDecOperator operator, Selector getterSelector, Selector setterSelector,
      T arg) {
    handleDynamic();
    handleDynamic();
    handleDynamic();
  }

  void visitIfNotNullDynamicPropertyPrefix(Send node, Node receiver,
      IncDecOperator operator, Selector getterSelector, Selector setterSelector,
      T arg) {
    handleDynamic();
    handleDynamic();
    handleDynamic();
  }

  void visitIfNotNullDynamicPropertySet(
      SendSet node, Node receiver, Selector selector, Node rhs, T arg) {
    handleDynamic();
  }

  void visitIndex(Send node, Node receiver, Node index, T arg) {
    handleDynamic();
  }

  void visitIndexPostfix(
      Send node, Node receiver, Node index, IncDecOperator operator, T arg) {
    handleDynamic();
    handleDynamic();
    handleDynamic();
  }

  void visitIndexPrefix(
      Send node, Node receiver, Node index, IncDecOperator operator, T arg) {
    handleDynamic();
    handleDynamic();
    handleDynamic();
  }

  void visitIndexSet(SendSet node, Node receiver, Node index, Node rhs, T arg) {
    handleDynamic();
  }

  void visitLocalVariableCompound(Send node, LocalVariableElement variable,
      AssignmentOperator operator, Node rhs, T arg) {
    handleLocal();
    handleDynamic();
    handleLocal();
  }

  void visitLocalVariableInvoke(Send node, LocalVariableElement variable,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleDynamic();
  }

  void visitLocalVariablePostfix(Send node, LocalVariableElement variable,
      IncDecOperator operator, T arg) {
    handleLocal();
    handleDynamic();
    handleLocal();
  }

  void visitLocalVariablePrefix(Send node, LocalVariableElement variable,
      IncDecOperator operator, T arg) {
    handleLocal();
    handleDynamic();
    handleLocal();
  }

  void visitNotEquals(Send node, Node left, Node right, T arg) {
    handleDynamic();
  }

  void visitParameterCompound(Send node, ParameterElement parameter,
      AssignmentOperator operator, Node rhs, T arg) {
    handleLocal();
    handleDynamic();
    handleLocal();
  }

  void visitParameterInvoke(Send node, ParameterElement parameter,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleDynamic();
  }

  void visitParameterPostfix(
      Send node, ParameterElement parameter, IncDecOperator operator, T arg) {
    handleLocal();
    handleDynamic();
    handleLocal();
  }

  void visitParameterPrefix(
      Send node, ParameterElement parameter, IncDecOperator operator, T arg) {
    handleLocal();
    handleDynamic();
    handleLocal();
  }

  void visitStaticFieldCompound(Send node, FieldElement field,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleDynamic();
    handleStatic();
  }

  void visitStaticFieldInvoke(Send node, FieldElement field, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleDynamic();
  }

  void visitStaticFieldPostfix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleStatic();
  }

  void visitStaticFieldPrefix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleStatic();
  }

  void visitStaticGetterInvoke(Send node, FunctionElement getter,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleDynamic();
  }

  void visitStaticGetterSetterCompound(Send node, FunctionElement getter,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleDynamic();
    handleStatic();
  }

  void visitStaticGetterSetterPostfix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleStatic();
  }

  void visitStaticGetterSetterPrefix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleStatic();
  }

  void visitSuperFieldCompound(Send node, FieldElement field,
      AssignmentOperator operator, Node rhs, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperFieldFieldCompound(Send node, FieldElement readField,
      FieldElement writtenField, AssignmentOperator operator, Node rhs, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperFieldFieldPostfix(Send node, FieldElement readField,
      FieldElement writtenField, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperFieldFieldPrefix(Send node, FieldElement readField,
      FieldElement writtenField, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperFieldInvoke(Send node, FieldElement field, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleDynamic();
  }

  void visitSuperFieldPostfix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperFieldPrefix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperFieldSetterCompound(Send node, FieldElement field,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperFieldSetterPostfix(Send node, FieldElement field,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperFieldSetterPrefix(Send node, FieldElement field,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperGetterFieldCompound(Send node, FunctionElement getter,
      FieldElement field, AssignmentOperator operator, Node rhs, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperGetterFieldPostfix(Send node, FunctionElement getter,
      FieldElement field, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperGetterFieldPrefix(Send node, FunctionElement getter,
      FieldElement field, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperGetterInvoke(Send node, FunctionElement getter,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleDynamic();
  }

  void visitSuperGetterSetterCompound(Send node, FunctionElement getter,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperGetterSetterPostfix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperGetterSetterPrefix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperIndexPostfix(Send node, MethodElement indexFunction,
      MethodElement indexSetFunction, Node index, IncDecOperator operator,
      T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperIndexPrefix(Send node, MethodElement indexFunction,
      MethodElement indexSetFunction, Node index, IncDecOperator operator,
      T arg) {
    handleMonomorphic();
    handleDynamic();
    handleMonomorphic();
  }

  void visitSuperMethodSetterCompound(Send node, FunctionElement method,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleMonomorphic();
    handleNSM();
    handleMonomorphic();
  }

  void visitSuperMethodSetterPostfix(Send node, FunctionElement method,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleNSM();
    handleMonomorphic();
  }

  void visitSuperMethodSetterPrefix(Send node, FunctionElement method,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleNSM();
    handleMonomorphic();
  }

  void visitThisPropertyCompound(Send node, AssignmentOperator operator,
      Node rhs, Selector getterSelector, Selector setterSelector, T arg) {
    handleVirtual();
    handleDynamic();
    handleVirtual();
  }

  void visitThisPropertyInvoke(
      Send node, NodeList arguments, Selector selector, T arg) {
    handleDynamic();
  }

  void visitThisPropertyPostfix(Send node, IncDecOperator operator,
      Selector getterSelector, Selector setterSelector, T arg) {
    handleVirtual();
    handleDynamic();
    handleVirtual();
  }

  void visitThisPropertyPrefix(Send node, IncDecOperator operator,
      Selector getterSelector, Selector setterSelector, T arg) {
    handleVirtual();
    handleDynamic();
    handleVirtual();
  }

  void visitTopLevelFieldCompound(Send node, FieldElement field,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleDynamic();
    handleStatic();
  }

  void visitTopLevelFieldInvoke(Send node, FieldElement field,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleDynamic();
  }

  void visitTopLevelFieldPostfix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleStatic();
  }

  void visitTopLevelFieldPrefix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleStatic();
  }

  void visitTopLevelGetterInvoke(Send node, FunctionElement getter,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleDynamic();
  }

  void visitTopLevelGetterSetterCompound(Send node, FunctionElement getter,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleDynamic();
    handleStatic();
  }

  void visitTopLevelGetterSetterPostfix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleStatic();
  }

  void visitTopLevelGetterSetterPrefix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleStatic();
  }

  void visitUnary(Send node, UnaryOperator operator, Node expression, T arg) {
    handleDynamic();
  }

  // Local variable sends

  void visitLocalFunctionGet(Send node, LocalFunctionElement function, T arg) {
    handleLocal();
  }

  void visitLocalFunctionInvoke(Send node, LocalFunctionElement function,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleLocal();
  }

  void visitLocalVariableGet(Send node, LocalVariableElement variable, T arg) {
    handleLocal();
  }

  void visitLocalVariableSet(
      SendSet node, LocalVariableElement variable, Node rhs, T arg) {
    handleLocal();
  }

  void visitParameterGet(Send node, ParameterElement parameter, T arg) {
    handleLocal();
  }

  void visitParameterSet(
      SendSet node, ParameterElement parameter, Node rhs, T arg) {
    handleLocal();
  }

  // Super monomorphic sends

  void visitSuperBinary(Send node, FunctionElement function,
      BinaryOperator operator, Node argument, T arg) {
    handleMonomorphic();
  }

  void visitSuperEquals(
      Send node, FunctionElement function, Node argument, T arg) {
    handleMonomorphic();
  }

  void visitSuperFieldGet(Send node, FieldElement field, T arg) {
    handleMonomorphic();
  }

  void visitSuperFieldSet(SendSet node, FieldElement field, Node rhs, T arg) {
    handleMonomorphic();
  }

  void visitSuperGetterGet(Send node, FunctionElement getter, T arg) {
    handleMonomorphic();
  }

  void visitSuperGetterSet(
      SendSet node, FunctionElement getter, Node rhs, T arg) {
    handleMonomorphic();
  }

  void visitSuperIndex(Send node, FunctionElement function, Node index, T arg) {
    handleMonomorphic();
  }

  void visitSuperIndexSet(
      SendSet node, FunctionElement function, Node index, Node rhs, T arg) {
    handleMonomorphic();
  }

  void visitSuperMethodGet(Send node, MethodElement method, T arg) {
    handleMonomorphic();
  }

  void visitSuperMethodInvoke(Send node, MethodElement method,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleMonomorphic();
  }

  void visitSuperNotEquals(
      Send node, FunctionElement function, Node argument, T arg) {
    handleMonomorphic();
  }

  void visitSuperSetterSet(
      SendSet node, FunctionElement setter, Node rhs, T arg) {
    handleMonomorphic();
  }

  void visitSuperUnary(
      Send node, UnaryOperator operator, FunctionElement function, T arg) {
    handleMonomorphic();
  }

// Statically known "no such method" sends

  void visitConstructorIncompatibleInvoke(NewExpression node,
      ConstructorElement constructor, InterfaceType type, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleNSM();
  }

  void visitFinalLocalVariableCompound(Send node, LocalVariableElement variable,
      AssignmentOperator operator, Node rhs, T arg) {
    handleLocal();
    handleDynamic();
    handleNSM();
  }

  void visitFinalLocalVariablePostfix(Send node, LocalVariableElement variable,
      IncDecOperator operator, T arg) {
    handleLocal();
    handleDynamic();
    handleNSM();
  }

  void visitFinalLocalVariablePrefix(Send node, LocalVariableElement variable,
      IncDecOperator operator, T arg) {
    handleLocal();
    handleDynamic();
    handleNSM();
  }

  void visitFinalLocalVariableSet(
      SendSet node, LocalVariableElement variable, Node rhs, T arg) {
    handleNSM();
  }

  void visitFinalParameterCompound(Send node, ParameterElement parameter,
      AssignmentOperator operator, Node rhs, T arg) {
    handleLocal();
    handleDynamic();
    handleNSM();
  }

  void visitFinalParameterPostfix(
      Send node, ParameterElement parameter, IncDecOperator operator, T arg) {
    handleLocal();
    handleDynamic();
    handleNSM();
  }

  void visitFinalParameterPrefix(
      Send node, ParameterElement parameter, IncDecOperator operator, T arg) {
    handleLocal();
    handleDynamic();
    handleNSM();
  }

  void visitFinalParameterSet(
      SendSet node, ParameterElement parameter, Node rhs, T arg) {
    handleNSM();
  }

  void visitFinalStaticFieldCompound(Send node, FieldElement field,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleDynamic();
    handleNSM();
  }

  void visitFinalStaticFieldPostfix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleNSM();
  }

  void visitFinalStaticFieldPrefix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleNSM();
  }

  void visitFinalStaticFieldSet(
      SendSet node, FieldElement field, Node rhs, T arg) {
    handleNSM();
  }

  void visitFinalSuperFieldCompound(Send node, FieldElement field,
      AssignmentOperator operator, Node rhs, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleNSM();
  }

  void visitFinalSuperFieldPostfix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleNSM();
  }

  void visitFinalSuperFieldPrefix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleDynamic();
    handleNSM();
  }

  void visitFinalSuperFieldSet(
      SendSet node, FieldElement field, Node rhs, T arg) {
    handleNSM();
  }

  void visitFinalTopLevelFieldCompound(Send node, FieldElement field,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleDynamic();
    handleNSM();
  }

  void visitFinalTopLevelFieldPostfix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleNSM();
  }

  void visitFinalTopLevelFieldPrefix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleNSM();
  }

  void visitFinalTopLevelFieldSet(
      SendSet node, FieldElement field, Node rhs, T arg) {
    handleNSM();
  }

  void visitLocalFunctionIncompatibleInvoke(Send node,
      LocalFunctionElement function, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleNSM();
  }

  void visitLocalFunctionCompound(Send node, LocalFunctionElement function,
      AssignmentOperator operator, Node rhs, T arg) {
    handleLocal();
    handleNSM();
    handleNoSend();
  }

  void visitLocalFunctionPostfix(Send node, LocalFunctionElement function,
      IncDecOperator operator, T arg) {
    handleLocal();
    handleNSM();
    handleNoSend();
  }

  void visitLocalFunctionPrefix(Send node, LocalFunctionElement function,
      IncDecOperator operator, T arg) {
    handleLocal();
    handleNSM();
    handleNoSend();
  }

  void visitLocalFunctionSet(
      SendSet node, LocalFunctionElement function, Node rhs, T arg) {
    handleNSM();
  }

  void visitStaticFunctionIncompatibleInvoke(Send node, MethodElement function,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSM();
  }

  void visitStaticFunctionSet(
      Send node, MethodElement function, Node rhs, T arg) {
    handleNSM();
  }

  void visitStaticMethodCompound(Send node, MethodElement method,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleNSM();    // operator on a method closure yields nSM
    handleNoSend(); // setter is not invoked, don't count it.
  }

  void visitStaticMethodPostfix(
      Send node, MethodElement method, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitStaticMethodPrefix(
      Send node, MethodElement method, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitStaticMethodSetterCompound(Send node, MethodElement method,
      MethodElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleNSM();    // operator on a method closure yields nSM
    handleNoSend(); // setter is not invoked, don't count it.
  }

  void visitStaticMethodSetterPostfix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitStaticMethodSetterPrefix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitStaticSetterGet(Send node, FunctionElement setter, T arg) {
    handleNSM();
  }

  void visitStaticSetterInvoke(Send node, FunctionElement setter,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSM();
  }

  void visitSuperMethodCompound(Send node, FunctionElement method,
      AssignmentOperator operator, Node rhs, T arg) {
    handleMonomorphic();
    handleNSM();    // operator on a method closure yields nSM
    handleNoSend(); // setter is not invoked, don't count it.
  }

  void visitSuperMethodIncompatibleInvoke(Send node, MethodElement method,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSM();
  }

  void visitSuperMethodPostfix(
      Send node, FunctionElement method, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitSuperMethodPrefix(
      Send node, FunctionElement method, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitSuperMethodSet(Send node, MethodElement method, Node rhs, T arg) {
    handleNSM();
  }

  void visitSuperSetterGet(Send node, FunctionElement setter, T arg) {
    handleNSM();
  }

  void visitSuperSetterInvoke(Send node, FunctionElement setter,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSM();
  }

  void visitTopLevelFunctionIncompatibleInvoke(Send node,
      MethodElement function, NodeList arguments, CallStructure callStructure,
      T arg) {
    handleNSM();
  }

  void visitTopLevelFunctionSet(
      Send node, MethodElement function, Node rhs, T arg) {
    handleNSM();
  }

  void visitTopLevelGetterSet(
      SendSet node, FunctionElement getter, Node rhs, T arg) {
    handleNSM();
  }

  void visitTopLevelMethodCompound(Send node, FunctionElement method,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleNSM();    // operator on a method closure yields nSM
    handleNoSend(); // setter is not invoked, don't count it.
  }

  void visitTopLevelMethodPostfix(
      Send node, MethodElement method, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitTopLevelMethodPrefix(
      Send node, MethodElement method, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitTopLevelMethodSetterCompound(Send node, FunctionElement method,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleNSM();    // operator on a method closure yields nSM
    handleNoSend(); // setter is not invoked, don't count it.
  }

  void visitTopLevelMethodSetterPostfix(Send node, FunctionElement method,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitTopLevelMethodSetterPrefix(Send node, FunctionElement method,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitTopLevelSetterGet(Send node, FunctionElement setter, T arg) {
    handleNSM();
  }

  void visitTopLevelSetterInvoke(Send node, FunctionElement setter,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSM();
  }

  void visitTypeVariableTypeLiteralCompound(Send node,
      TypeVariableElement element, AssignmentOperator operator, Node rhs,
      T arg) {
    handleMonomorphic();
    handleNSM();    // operator on a method closure yields nSM
    handleNoSend(); // setter is not invoked, don't count it.
  }

  void visitTypeVariableTypeLiteralGet(
      Send node, TypeVariableElement element, T arg) {
    handleMonomorphic();
  }

  void visitTypeVariableTypeLiteralInvoke(Send node,
      TypeVariableElement element, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleNSM();
  }

  void visitTypeVariableTypeLiteralPostfix(
      Send node, TypeVariableElement element, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleNSM();
    handleNoSend();
  }

  void visitTypeVariableTypeLiteralPrefix(
      Send node, TypeVariableElement element, IncDecOperator operator, T arg) {
    handleMonomorphic();
    handleNSM();
    handleNoSend();
  }

  void visitTypeVariableTypeLiteralSet(
      SendSet node, TypeVariableElement element, Node rhs, T arg) {
    handleNSM();
  }

  void visitTypedefTypeLiteralCompound(Send node, ConstantExpression constant,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitTypedefTypeLiteralGet(
      Send node, ConstantExpression constant, T arg) {
    handleStatic();
  }

  void visitTypedefTypeLiteralInvoke(Send node, ConstantExpression constant,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSM();
  }

  void visitTypedefTypeLiteralPostfix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitTypedefTypeLiteralPrefix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitTypedefTypeLiteralSet(
      SendSet node, ConstantExpression constant, Node rhs, T arg) {
    handleNSM();
  }

  void visitUnresolvedClassConstructorInvoke(NewExpression node,
      Element element, DartType type, NodeList arguments, Selector selector,
      T arg) {
    handleNSM();
  }

  void visitUnresolvedCompound(Send node, Element element,
      AssignmentOperator operator, Node rhs, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedConstructorInvoke(NewExpression node, Element constructor,
      DartType type, NodeList arguments, Selector selector, T arg) {
    handleNSM();
  }

  void visitUnresolvedGet(Send node, Element element, T arg) {
    handleNSM();
  }

  void visitUnresolvedInvoke(Send node, Element element, NodeList arguments,
      Selector selector, T arg) {
    handleNSM();
  }

  void visitUnresolvedPostfix(
      Send node, Element element, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedPrefix(
      Send node, Element element, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedRedirectingFactoryConstructorInvoke(NewExpression node,
      ConstructorElement constructor, InterfaceType type, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleNSM();
  }

  void visitUnresolvedSet(Send node, Element element, Node rhs, T arg) {
    handleNSM();
  }

  void visitUnresolvedStaticGetterCompound(Send node, Element element,
      MethodElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedStaticGetterPostfix(Send node, Element element,
      MethodElement setter, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedStaticGetterPrefix(Send node, Element element,
      MethodElement setter, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedStaticSetterCompound(Send node, MethodElement getter,
      Element element, AssignmentOperator operator, Node rhs, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedStaticSetterPostfix(Send node, MethodElement getter,
      Element element, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedStaticSetterPrefix(Send node, MethodElement getter,
      Element element, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperBinary(Send node, Element element,
      BinaryOperator operator, Node argument, T arg) {
    handleNSM();
  }

  void visitUnresolvedSuperCompound(Send node, Element element,
      AssignmentOperator operator, Node rhs, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperCompoundIndexSet(Send node, Element element,
      Node index, AssignmentOperator operator, Node rhs, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperGet(Send node, Element element, T arg) {
    handleNSM();
  }

  void visitUnresolvedSuperGetterCompound(Send node, Element element,
      MethodElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperGetterCompoundIndexSet(Send node, Element element,
      MethodElement setter, Node index, AssignmentOperator operator, Node rhs,
      T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperGetterIndexPostfix(Send node, Element element,
      MethodElement setter, Node index, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperGetterIndexPrefix(Send node, Element element,
      MethodElement setter, Node index, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperGetterPostfix(Send node, Element element,
      MethodElement setter, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperGetterPrefix(Send node, Element element,
      MethodElement setter, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperIndex(
      Send node, Element element, Node index, T arg) {
    handleNSM();
  }

  void visitUnresolvedSuperIndexPostfix(
      Send node, Element element, Node index, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperIndexPrefix(
      Send node, Element element, Node index, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperIndexSet(
      Send node, Element element, Node index, Node rhs, T arg) {
    handleNSM();
  }

  void visitUnresolvedSuperInvoke(Send node, Element element,
      NodeList arguments, Selector selector, T arg) {
    handleNSM();
  }

  void visitUnresolvedSuperPostfix(
      Send node, Element element, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperPrefix(
      Send node, Element element, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperSetterCompound(Send node, MethodElement getter,
      Element element, AssignmentOperator operator, Node rhs, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperSetterCompoundIndexSet(Send node,
      MethodElement getter, Element element, Node index,
      AssignmentOperator operator, Node rhs, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperSetterIndexPostfix(Send node,
      MethodElement indexFunction, Element element, Node index,
      IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperSetterIndexPrefix(Send node,
      MethodElement indexFunction, Element element, Node index,
      IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperSetterPostfix(Send node, MethodElement getter,
      Element element, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperSetterPrefix(Send node, MethodElement getter,
      Element element, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperUnary(
      Send node, UnaryOperator operator, Element element, T arg) {
    handleNSM();
  }

  void visitUnresolvedTopLevelGetterCompound(Send node, Element element,
      MethodElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedTopLevelGetterPostfix(Send node, Element element,
      MethodElement setter, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedTopLevelGetterPrefix(Send node, Element element,
      MethodElement setter, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedTopLevelSetterCompound(Send node, MethodElement getter,
      Element element, AssignmentOperator operator, Node rhs, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedTopLevelSetterPostfix(Send node, MethodElement getter,
      Element element, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedTopLevelSetterPrefix(Send node, MethodElement getter,
      Element element, IncDecOperator operator, T arg) {
    handleNSM();
    handleNoSend();
    handleNoSend();
  }

  // Static

  void visitConstantGet(Send node, ConstantExpression constant, T arg) {
    handleStatic();
  }

  void visitConstantInvoke(Send node, ConstantExpression constant,
      NodeList arguments, CallStructure callStreucture, T arg) {
    handleStatic();
  }

  void visitFactoryConstructorInvoke(NewExpression node,
      ConstructorElement constructor, InterfaceType type, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleStatic();
  }

  void visitStaticFieldGet(Send node, FieldElement field, T arg) {
    handleStatic();
  }

  void visitStaticFieldSet(SendSet node, FieldElement field, Node rhs, T arg) {
    handleStatic();
  }

  void visitStaticFunctionGet(Send node, MethodElement function, T arg) {
    handleStatic();
  }

  void visitStaticFunctionInvoke(Send node, MethodElement function,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleStatic();
  }

  void visitStaticGetterGet(Send node, FunctionElement getter, T arg) {
    handleStatic();
  }

  void visitStaticGetterSet(
      SendSet node, FunctionElement getter, Node rhs, T arg) {
    handleStatic();
  }

  void visitStaticSetterSet(
      SendSet node, FunctionElement setter, Node rhs, T arg) {
    handleStatic();
  }

  void visitTopLevelFieldGet(Send node, FieldElement field, T arg) {
    handleStatic();
  }

  void visitTopLevelFieldSet(
      SendSet node, FieldElement field, Node rhs, T arg) {
    handleStatic();
  }

  void visitTopLevelFunctionGet(Send node, MethodElement function, T arg) {
    handleStatic();
  }

  void visitTopLevelFunctionInvoke(Send node, MethodElement function,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleStatic();
  }

  void visitTopLevelGetterGet(Send node, FunctionElement getter, T arg) {
    handleStatic();
  }

  void visitTopLevelSetterSet(
      SendSet node, FunctionElement setter, Node rhs, T arg) {
    handleStatic();
  }

  // Virtual

  void visitSuperCompoundIndexSet(SendSet node, MethodElement getter,
      MethodElement setter, Node index, AssignmentOperator operator, Node rhs,
      T arg) {
    handleMonomorphic();
    handleVirtual();
    handleMonomorphic();
  }

  void visitThisGet(Identifier node, T arg) {
    handleVirtual();
  }

  void visitThisInvoke(
      Send node, NodeList arguments, CallStructure callStructure, T arg) {
    handleVirtual();
  }

  void visitThisPropertyGet(Send node, Selector selector, T arg) {
    handleVirtual();
  }

  void visitThisPropertySet(SendSet node, Selector selector, Node rhs, T arg) {
    handleVirtual();
  }

  // Not count

  void errorInvalidAssert(Send node, NodeList arguments, T arg) {
    handleNoSend();
  }

  void errorNonConstantConstructorInvoke(NewExpression node, Element element,
      DartType type, NodeList arguments, CallStructure callStructure, T arg) {
    handleNoSend();
  }

  void errorUndefinedBinaryExpression(
      Send node, Node left, Operator operator, Node right, T arg) {
    handleNoSend();
  }

  void errorUndefinedUnaryExpression(
      Send node, Operator operator, Node expression, T arg) {
    handleNoSend();
  }

  void visitAs(Send node, Node expression, DartType type, T arg) {
    handleNoSend();
  }

  void visitAssert(Send node, Node expression, T arg) {
    handleNoSend();
  }

  void visitClassTypeLiteralCompound(Send node, ConstantExpression constant,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitClassTypeLiteralGet(Send node, ConstantExpression constant, T arg) {
    handleStatic();
  }

  void visitClassTypeLiteralInvoke(Send node, ConstantExpression constant,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSM();
  }

  void visitClassTypeLiteralPostfix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitClassTypeLiteralPrefix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitClassTypeLiteralSet(
      SendSet node, ConstantExpression constant, Node rhs, T arg) {
    handleNSM();
  }

  void visitDynamicTypeLiteralCompound(Send node, ConstantExpression constant,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitDynamicTypeLiteralGet(
      Send node, ConstantExpression constant, T arg) {
    handleNSM();
  }

  void visitDynamicTypeLiteralInvoke(Send node, ConstantExpression constant,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSM();
  }

  void visitDynamicTypeLiteralPostfix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitDynamicTypeLiteralPrefix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSM();
    handleNoSend();
  }

  void visitDynamicTypeLiteralSet(
      SendSet node, ConstantExpression constant, Node rhs, T arg) {
    handleNSM();
  }

  void visitIfNull(Send node, Node left, Node right, T arg) {
    handleNoSend();
  }

  void visitIs(Send node, Node expression, DartType type, T arg) {
    handleNoSend();
  }

  void visitIsNot(Send node, Node expression, DartType type, T arg) {
    handleNoSend();
  }

  void visitLogicalAnd(Send node, Node left, Node right, T arg) {
    handleNoSend();
  }

  void visitLogicalOr(Send node, Node left, Node right, T arg) {
    handleNoSend();
  }

  void visitNot(Send node, Node expression, T arg) {
    handleNoSend();
  }

  String last;
  _check(Send node, String msg) {
    var sb = new StringBuffer();
    sb.write('$msg');
    sb.write(measurements[Metric.send]);
    sb.write(' (sends) | ');
    bool first = true;
    for (var specificSend in Metric.send.submetrics) {
      if (first) {
        first = false;
      } else {
        sb.write(' + ');
      }
      sb.write(measurements[specificSend]);
      sb.write(' (${specificSend.name})');
    }
    if (!measurements.checkInvariant(Metric.send)) {
      compiler.reportError(
          node, MessageKind.GENERIC, {'text': 'bad $sb\nlast: $last'});
      last = '$sb';
      exit(1);
    } else {
      //compiler.reportInfo(node, MessageKind.GENERIC, {'text': 'good $msg $sb'});
      last = '$sb';
    }
  }
}

/// Visitor that collects statistics about our understanding of a function.
class _StatsTraversalVisitor<T> extends TraversalVisitor<Void, T>
    implements SemanticSendVisitor {
  final Compiler compiler;
  final _StatsVisitor statsVisitor;
  Measurements get measurements => statsVisitor.measurements;
  _StatsTraversalVisitor(Compiler compiler, TreeElements elements)
      : compiler = compiler,
        statsVisitor = new _StatsVisitor(compiler, elements),
        super(elements);

  void visitSend(Send node) {
    try {
      node.accept(statsVisitor);
    } catch (e) {
      compiler.reportError(node, MessageKind.GENERIC, {'text': '$e'});
    }
    super.visitSend(node);
  }
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
    e.implementation.compilationUnits
        .forEach((u) => results.add(u.accept(this, arg)));
    return merge(results);
  }

  @override
  R visitVariableElement(VariableElement e, A arg) {}

  @override
  R visitParameterElement(ParameterElement e, A arg) {}

  @override
  R visitFormalElement(FormalElement e, A arg) {}

  @override
  R visitFieldElement(FieldElement e, A arg) {}

  @override
  R visitFieldParameterElement(InitializingFormalElement e, A arg) {}

  @override
  R visitAbstractFieldElement(AbstractFieldElement e, A arg) {}

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
  R visitBoxFieldElement(BoxFieldElement e, A arg) {}

  @override
  R visitClosureClassElement(ClosureClassElement e, A arg) {
    return visitClassElement(e, arg);
  }

  @override
  R visitClosureFieldElement(ClosureFieldElement e, A arg) {
    return visitVariableElement(e, arg);
  }
}

Set<String> _messages = new Set<String>();
_debug(String message) {
  //if (_messages.add(message)) {
  print('[33mdebug:[0m $message');
  //}
}
