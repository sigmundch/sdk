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
import 'type_queries.dart';

/// Task that collects metric information about types.
class StatsBuilderTask extends CompilerTask {
  String get name => "Inference Stats";

  GlobalResult resultForTesting;

  StatsBuilderTask(Compiler compiler) : super(compiler);

  void run() {
    measure(() {
      var visitor = new StatsBuilder(compiler);
      for (var lib in compiler.libraryLoader.libraries) {
        lib.accept(visitor, null);
      }
      resultForTesting = visitor.result;
      // TODO(sigmund): comment this out
      //print(formatAsTable(visitor.result));
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
        if (e is PartialElement) {
          currentLib.functions.add(new FunctionResult(e.name,
              const Measurements.unreachableFunction()));
        } else {
          assert (e is ConstructorElement && e.isSynthesized);
          // TODO(sigmund): measure synthethic forwarding sends, initializers?
          currentLib.functions.add(new FunctionResult(e.name,
                new Measurements.reachableFunction()));
        }
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
        assert (e is PartialElement);
        currentLib.functions.add(new FunctionResult(e.name,
            const Measurements.unreachableFunction()));
        return;
      }
      resolvedAst.node.accept(visitor);
      currentLib.functions
          .add(new FunctionResult(e.name, visitor.measurements));
    });
  }

  // TODO(sigmund): visit initializers too, they can contain `sends`.
}

class _StatsVisitor<T> extends Visitor<T>
    with SendResolverMixin<T>, SemanticSendResolvedMixin<T>
    implements SemanticSendVisitor<Void, T> {
  AnalysisResult info;
  SemanticSendVisitor<Void, T> get sendVisitor => this;
  Measurements measurements = new Measurements.reachableFunction();
  final Compiler compiler;
  final TreeElements elements;
  _StatsVisitor(this.compiler, this.elements, this.info);

  visitSend(Send node) {
    _check(node, 'before');
    measurements[Metric.send]++;
    if (node is SendSet &&
        ((node.assignmentOperator != null &&
                node.assignmentOperator.source != '=') ||
            node.isPrefix ||
            node.isPostfix)) {
      print('=> ${node.assignmentOperator.runtimeType}');
      measurements[Metric.send] += 2;
    }
    super.visitSend(node);
    _check(node, 'after ');
  }

  visitNewExpression(NewExpression node) {
    _check(node, 'before');
    measurements[Metric.send]++;
    super.visitNewExpression(node);
    _check(node, 'after ');
  }

  handleLocal() {
    measurements[Metric.monomorphicSend]++;
    measurements[Metric.localSend]++;
  }

  handleSingleInstance() {
    measurements[Metric.monomorphicSend]++;
    measurements[Metric.instanceSend]++;
  }

  handleSingleInterceptor() {
    measurements[Metric.monomorphicSend]++;
    measurements[Metric.interceptorSend]++;
  }

  handleMultiInterceptor() {
    measurements[Metric.polymorphicSend]++;
    measurements[Metric.multiInterceptorSend]++;
  }

  handleConstructor() {
    measurements[Metric.monomorphicSend]++;
    measurements[Metric.constructorSend]++;
  }
  handleDynamic() {
    measurements[Metric.polymorphicSend]++;
    measurements[Metric.dynamicSend]++;
  }
  handleVirtual() {
    measurements[Metric.polymorphicSend]++;
    measurements[Metric.virtualSend]++;
  }
  handleNSMError() {
    measurements[Metric.monomorphicSend]++;
    measurements[Metric.nsmErrorSend]++;
  }
  handleNSMSingle() {
    measurements[Metric.monomorphicSend]++;
    measurements[Metric.singleNsmCallSend]++;
  }

  handleNSMSuper(Element targetType) {
    print('\n||||-> ${targetType.runtimeType}');
    //if (targetType contains a nSM function) {
    //  handleNSMSingle();
    //} else {
    handleNSMError();
    //}
  }
  handleNSMAny() {
    measurements[Metric.polymorphicSend]++;
    measurements[Metric.multiNsmCallSend]++;
  }
  handleSuper() {
    measurements[Metric.monomorphicSend]++;
    measurements[Metric.superSend]++;
  }
  handleTypeVariable() {
    measurements[Metric.monomorphicSend]++;
    measurements[Metric.typeVariableSend]++;
  }
  handleStatic() {
    measurements[Metric.monomorphicSend]++;
    measurements[Metric.staticSend]++;
  }

  handleNoSend() {
    measurements[Metric.send]--;
  }

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

  handleDynamic2(Node receiver, Selector selector) {
    // staticSend: no (automatically)
    // superSend: no (automatically)
    // localSend: no (automatically)
    // constructorSend: no (automatically)
    // typeVariableSend: no (automatically)

    // nsmErrorSend:      receiver has no `selector` nor nSM.
    // singleNsmCallSend: receiver has no `selector`, but definitely has `nSM`
    // instanceSend:      receiver has `selector`, no need to use an interceptor
    // interceptorSend:   receiver has `selector`, but we know we need an interceptor to get it 

    // multiNsmCallSend:  receiver has no `selector`, not sure if receiver has
    //                    nSM, or not sure which nSM is called (does this one
    //                    matter, or does nSM is treated like an instance method
    //                    call)?
    // virtualSend:       receiver has `selector`, we know we do not need an
    //                    interceptor, not sure which specific type implements
    //                    the selector.
    // multiInterceptorSend: multiple possible receiver types, all using an
    //                       interceptor to get the `selector`, might be
    //                       possbile to pick a special selector logic for this
    //                       combination?
    // dynamicSend: any combination of the above.

    ReceiverInfo receiverInfo = info.infoForReceiver(receiver);
    SelectorInfo selectorInfo = info.infoForSelector(receiver, selector);
    boolish hasSelector = selectorInfo.exists;
    boolish hasNsm = receiverInfo.hasNoSuchMethod;

    if (hasSelector == boolish.no) {
      if (hasNsm == boolish.no) {
        handleNSMError();
      } else if (hasNsm == boolish.yes) {
        //if (receiverInfo.possibleNumberOfNSM == 1) {
        //  handleNSMSingle();
        //} else {
          handleNSMAny();
        //}
      } else {
        handleDynamic();
      }
      return;
    }

    boolish usesInterceptor = selectorInfo.usesInterceptor;
    int possibleTargets = selectorInfo.possibleTargets;
    if (hasSelector == boolish.yes) {
      if (selectorInfo.isAccurate && selectorInfo.possibleTargets == 1) {
        assert (usesInterceptor != boolish.maybe);
        if (usesInterceptor == boolish.yes) {
          handleSingleInterceptor();
        } else {
          handleSingleInstance();
        }
      } else {
        if (usesInterceptor == boolish.no) {
          handleVirtual();
        } else if (usesInterceptor == boolish.yes) {
          handleMultiInterceptor();
        } else {
          handleDynamic();
        }
      }
      return;
    }
    handleDynamic();
  }

  void visitDynamicPropertyGet(
      Send node, Node receiver, Selector selector, T arg) {
    handleDynamic2(receiver, selector);
  }

  void visitDynamicPropertyInvoke(
      Send node, Node receiver, NodeList arguments, Selector selector, T arg) {
    handleDynamic2(receiver, selector);
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
    handleDynamic2(receiver, selector);
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
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperFieldFieldCompound(Send node, FieldElement readField,
      FieldElement writtenField, AssignmentOperator operator, Node rhs, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperFieldFieldPostfix(Send node, FieldElement readField,
      FieldElement writtenField, IncDecOperator operator, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperFieldFieldPrefix(Send node, FieldElement readField,
      FieldElement writtenField, IncDecOperator operator, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperFieldInvoke(Send node, FieldElement field, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleDynamic();
  }

  void visitSuperFieldPostfix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperFieldPrefix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperFieldSetterCompound(Send node, FieldElement field,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperFieldSetterPostfix(Send node, FieldElement field,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperFieldSetterPrefix(Send node, FieldElement field,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperGetterFieldCompound(Send node, FunctionElement getter,
      FieldElement field, AssignmentOperator operator, Node rhs, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperGetterFieldPostfix(Send node, FunctionElement getter,
      FieldElement field, IncDecOperator operator, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperGetterFieldPrefix(Send node, FunctionElement getter,
      FieldElement field, IncDecOperator operator, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperGetterInvoke(Send node, FunctionElement getter,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleDynamic();
  }

  void visitSuperGetterSetterCompound(Send node, FunctionElement getter,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperGetterSetterPostfix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperGetterSetterPrefix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperIndexPostfix(Send node, MethodElement indexFunction,
      MethodElement indexSetFunction, Node index, IncDecOperator operator,
      T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperIndexPrefix(Send node, MethodElement indexFunction,
      MethodElement indexSetFunction, Node index, IncDecOperator operator,
      T arg) {
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitSuperMethodSetterCompound(Send node, FunctionElement method,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleSuper();
    handleNSMSuper(method.owner);
    handleSuper();
  }

  void visitSuperMethodSetterPostfix(Send node, FunctionElement method,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleSuper();
    handleNSMSuper(method.owner);
    handleSuper();
  }

  void visitSuperMethodSetterPrefix(Send node, FunctionElement method,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleSuper();
    handleNSMSuper(method.owner);
    handleSuper();
  }

  void visitThisPropertyCompound(Send node, AssignmentOperator operator,
      Node rhs, Selector getterSelector, Selector setterSelector, T arg) {
    handleDynamic();
    handleDynamic();
    handleDynamic();
  }

  void visitThisPropertyInvoke(
      Send node, NodeList arguments, Selector selector, T arg) {
    handleDynamic();
  }

  void visitThisPropertyPostfix(Send node, IncDecOperator operator,
      Selector getterSelector, Selector setterSelector, T arg) {
    handleDynamic();
    handleDynamic();
    handleDynamic();
  }

  void visitThisPropertyPrefix(Send node, IncDecOperator operator,
      Selector getterSelector, Selector setterSelector, T arg) {
    handleDynamic();
    handleDynamic();
    handleDynamic();
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
    handleSuper();
  }

  void visitSuperEquals(
      Send node, FunctionElement function, Node argument, T arg) {
    handleSuper();
  }

  void visitSuperFieldGet(Send node, FieldElement field, T arg) {
    handleSuper();
  }

  void visitSuperFieldSet(SendSet node, FieldElement field, Node rhs, T arg) {
    handleSuper();
  }

  void visitSuperGetterGet(Send node, FunctionElement getter, T arg) {
    handleSuper();
  }

  void visitSuperGetterSet(
      SendSet node, FunctionElement getter, Node rhs, T arg) {
    handleSuper();
  }

  void visitSuperIndex(Send node, FunctionElement function, Node index, T arg) {
    handleSuper();
  }

  void visitSuperIndexSet(
      SendSet node, FunctionElement function, Node index, Node rhs, T arg) {
    handleSuper();
  }

  void visitSuperMethodGet(Send node, MethodElement method, T arg) {
    handleSuper();
  }

  void visitSuperMethodInvoke(Send node, MethodElement method,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleSuper();
  }

  void visitSuperNotEquals(
      Send node, FunctionElement function, Node argument, T arg) {
    handleSuper();
  }

  void visitSuperSetterSet(
      SendSet node, FunctionElement setter, Node rhs, T arg) {
    handleSuper();
  }

  void visitSuperUnary(
      Send node, UnaryOperator operator, FunctionElement function, T arg) {
    handleSuper();
  }

// Statically known "no such method" sends

  void visitConstructorIncompatibleInvoke(NewExpression node,
      ConstructorElement constructor, InterfaceType type, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleNSMError();
  }

  void visitFinalLocalVariableCompound(Send node, LocalVariableElement variable,
      AssignmentOperator operator, Node rhs, T arg) {
    handleLocal();
    handleDynamic();
    handleNSMError();
  }

  void visitFinalLocalVariablePostfix(Send node, LocalVariableElement variable,
      IncDecOperator operator, T arg) {
    handleLocal();
    handleDynamic();
    handleNSMError();
  }

  void visitFinalLocalVariablePrefix(Send node, LocalVariableElement variable,
      IncDecOperator operator, T arg) {
    handleLocal();
    handleDynamic();
    handleNSMError();
  }

  void visitFinalLocalVariableSet(
      SendSet node, LocalVariableElement variable, Node rhs, T arg) {
    handleNSMError();
  }

  void visitFinalParameterCompound(Send node, ParameterElement parameter,
      AssignmentOperator operator, Node rhs, T arg) {
    handleLocal();
    handleDynamic();
    handleNSMError();
  }

  void visitFinalParameterPostfix(
      Send node, ParameterElement parameter, IncDecOperator operator, T arg) {
    handleLocal();
    handleDynamic();
    handleNSMError();
  }

  void visitFinalParameterPrefix(
      Send node, ParameterElement parameter, IncDecOperator operator, T arg) {
    handleLocal();
    handleDynamic();
    handleNSMError();
  }

  void visitFinalParameterSet(
      SendSet node, ParameterElement parameter, Node rhs, T arg) {
    handleNSMError();
  }

  void visitFinalStaticFieldCompound(Send node, FieldElement field,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleDynamic();
    handleNSMError();
  }

  void visitFinalStaticFieldPostfix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleNSMError();
  }

  void visitFinalStaticFieldPrefix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleNSMError();
  }

  void visitFinalStaticFieldSet(
      SendSet node, FieldElement field, Node rhs, T arg) {
    handleNSMError();
  }

  void visitFinalSuperFieldCompound(Send node, FieldElement field,
      AssignmentOperator operator, Node rhs, T arg) {
    handleSuper();
    handleDynamic();
    handleNSMSuper(field.owner);
  }

  void visitFinalSuperFieldPostfix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleSuper();
    handleDynamic();
    handleNSMSuper(field.owner);
  }

  void visitFinalSuperFieldPrefix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleSuper();
    handleDynamic();
    handleNSMSuper(field.owner);
  }

  void visitFinalSuperFieldSet(
      SendSet node, FieldElement field, Node rhs, T arg) {
    print("// #? here");
    handleNSMSuper(field.owner);
  }

  void visitFinalTopLevelFieldCompound(Send node, FieldElement field,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleDynamic();
    handleNSMError();
  }

  void visitFinalTopLevelFieldPostfix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleNSMError();
  }

  void visitFinalTopLevelFieldPrefix(
      Send node, FieldElement field, IncDecOperator operator, T arg) {
    handleStatic();
    handleDynamic();
    handleNSMError();
  }

  void visitFinalTopLevelFieldSet(
      SendSet node, FieldElement field, Node rhs, T arg) {
    handleNSMError();
  }

  void visitLocalFunctionIncompatibleInvoke(Send node,
      LocalFunctionElement function, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleNSMError();
  }

  void visitLocalFunctionCompound(Send node, LocalFunctionElement function,
      AssignmentOperator operator, Node rhs, T arg) {
    handleLocal();
    handleNSMError();
    handleNoSend();
  }

  void visitLocalFunctionPostfix(Send node, LocalFunctionElement function,
      IncDecOperator operator, T arg) {
    handleLocal();
    handleNSMError();
    handleNoSend();
  }

  void visitLocalFunctionPrefix(Send node, LocalFunctionElement function,
      IncDecOperator operator, T arg) {
    handleLocal();
    handleNSMError();
    handleNoSend();
  }

  void visitLocalFunctionSet(
      SendSet node, LocalFunctionElement function, Node rhs, T arg) {
    handleNSMError();
  }

  void visitStaticFunctionIncompatibleInvoke(Send node, MethodElement function,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSMError();
  }

  void visitStaticFunctionSet(
      Send node, MethodElement function, Node rhs, T arg) {
    handleNSMError();
  }

  void visitStaticMethodCompound(Send node, MethodElement method,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleNSMError(); // operator on a method closure yields nSM
    handleNoSend(); // setter is not invoked, don't count it.
  }

  void visitStaticMethodPostfix(
      Send node, MethodElement method, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSMError();
    handleNoSend();
  }

  void visitStaticMethodPrefix(
      Send node, MethodElement method, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSMError();
    handleNoSend();
  }

  void visitStaticMethodSetterCompound(Send node, MethodElement method,
      MethodElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleNSMError(); // operator on a method closure yields nSM
    handleNoSend(); // setter is not invoked, don't count it.
  }

  void visitStaticMethodSetterPostfix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSMError();
    handleNoSend();
  }

  void visitStaticMethodSetterPrefix(Send node, FunctionElement getter,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSMError();
    handleNoSend();
  }

  void visitStaticSetterGet(Send node, FunctionElement setter, T arg) {
    handleNSMError();
  }

  void visitStaticSetterInvoke(Send node, FunctionElement setter,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSMError();
  }

  void visitSuperMethodCompound(Send node, FunctionElement method,
      AssignmentOperator operator, Node rhs, T arg) {
    handleSuper();
    handleNSMSuper(method.owner); // operator on a method closure yields nSM
    handleNoSend(); // setter is not invoked, don't count it.
  }

  void visitSuperMethodIncompatibleInvoke(Send node, MethodElement method,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSMSuper(method.owner);
  }

  void visitSuperMethodPostfix(
      Send node, FunctionElement method, IncDecOperator operator, T arg) {
    handleSuper();
    handleNSMSuper(method.owner);
    handleNoSend();
  }

  void visitSuperMethodPrefix(
      Send node, FunctionElement method, IncDecOperator operator, T arg) {
    handleSuper();
    handleNSMSuper(method.owner);
    handleNoSend();
  }

  void visitSuperMethodSet(Send node, MethodElement method, Node rhs, T arg) {
    handleNSMSuper(method.owner);
  }

  void visitSuperSetterGet(Send node, FunctionElement setter, T arg) {
    handleNSMSuper(method.owner);
  }

  void visitSuperSetterInvoke(Send node, FunctionElement setter,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSMSuper(method.owner);
  }

  void visitTopLevelFunctionIncompatibleInvoke(Send node,
      MethodElement function, NodeList arguments, CallStructure callStructure,
      T arg) {
    handleNSMError();
  }

  void visitTopLevelFunctionSet(
      Send node, MethodElement function, Node rhs, T arg) {
    handleNSMError();
  }

  void visitTopLevelGetterSet(
      SendSet node, FunctionElement getter, Node rhs, T arg) {
    handleNSMError();
  }

  void visitTopLevelMethodCompound(Send node, FunctionElement method,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleNSMError(); // operator on a method closure yields nSM
    handleNoSend(); // setter is not invoked, don't count it.
  }

  void visitTopLevelMethodPostfix(
      Send node, MethodElement method, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSMError();
    handleNoSend();
  }

  void visitTopLevelMethodPrefix(
      Send node, MethodElement method, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSMError();
    handleNoSend();
  }

  void visitTopLevelMethodSetterCompound(Send node, FunctionElement method,
      FunctionElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleNSMError(); // operator on a method closure yields nSM
    handleNoSend(); // setter is not invoked, don't count it.
  }

  void visitTopLevelMethodSetterPostfix(Send node, FunctionElement method,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSMError();
    handleNoSend();
  }

  void visitTopLevelMethodSetterPrefix(Send node, FunctionElement method,
      FunctionElement setter, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSMError();
    handleNoSend();
  }

  void visitTopLevelSetterGet(Send node, FunctionElement setter, T arg) {
    handleNSMError();
  }

  void visitTopLevelSetterInvoke(Send node, FunctionElement setter,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSMError();
  }

  void visitTypeVariableTypeLiteralCompound(Send node,
      TypeVariableElement element, AssignmentOperator operator, Node rhs,
      T arg) {
    handleTypeVariable();
    handleNSMError(); // operator on a method closure yields nSM
    handleNoSend(); // setter is not invoked, don't count it.
  }

  void visitTypeVariableTypeLiteralGet(
      Send node, TypeVariableElement element, T arg) {
    handleTypeVariable();
  }

  void visitTypeVariableTypeLiteralInvoke(Send node,
      TypeVariableElement element, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleNSMError();
  }

  void visitTypeVariableTypeLiteralPostfix(
      Send node, TypeVariableElement element, IncDecOperator operator, T arg) {
    handleTypeVariable();
    handleNSMError();
    handleNoSend();
  }

  void visitTypeVariableTypeLiteralPrefix(
      Send node, TypeVariableElement element, IncDecOperator operator, T arg) {
    handleTypeVariable();
    handleNSMError();
    handleNoSend();
  }

  void visitTypeVariableTypeLiteralSet(
      SendSet node, TypeVariableElement element, Node rhs, T arg) {
    handleNSMError();
  }

  void visitTypedefTypeLiteralCompound(Send node, ConstantExpression constant,
      AssignmentOperator operator, Node rhs, T arg) {
    handleTypeVariable();
    handleNSMError();
    handleNoSend();
  }

  void visitTypedefTypeLiteralGet(
      Send node, ConstantExpression constant, T arg) {
    handleTypeVariable();
  }

  void visitTypedefTypeLiteralInvoke(Send node, ConstantExpression constant,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSMError();
  }

  void visitTypedefTypeLiteralPostfix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {
    handleTypeVariable();
    handleNSMError();
    handleNoSend();
  }

  void visitTypedefTypeLiteralPrefix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {
    handleTypeVariable();
    handleNSMError();
    handleNoSend();
  }

  void visitTypedefTypeLiteralSet(
      SendSet node, ConstantExpression constant, Node rhs, T arg) {
    handleNSMError();
  }

  void visitUnresolvedClassConstructorInvoke(NewExpression node,
      Element element, DartType type, NodeList arguments, Selector selector,
      T arg) {
    handleNSMError();
  }

  void visitUnresolvedCompound(Send node, Element element,
      AssignmentOperator operator, Node rhs, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedConstructorInvoke(NewExpression node, Element constructor,
      DartType type, NodeList arguments, Selector selector, T arg) {
    handleNSMError();
  }

  void visitUnresolvedGet(Send node, Element element, T arg) {
    handleNSMError();
  }

  void visitUnresolvedInvoke(Send node, Element element, NodeList arguments,
      Selector selector, T arg) {
    handleNSMError();
  }

  void visitUnresolvedPostfix(
      Send node, Element element, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedPrefix(
      Send node, Element element, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedRedirectingFactoryConstructorInvoke(NewExpression node,
      ConstructorElement constructor, InterfaceType type, NodeList arguments,
      CallStructure callStructure, T arg) {
    handleNSMError();
  }

  void visitUnresolvedSet(Send node, Element element, Node rhs, T arg) {
    handleNSMError();
  }

  void visitUnresolvedStaticGetterCompound(Send node, Element element,
      MethodElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedStaticGetterPostfix(Send node, Element element,
      MethodElement setter, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedStaticGetterPrefix(Send node, Element element,
      MethodElement setter, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedStaticSetterCompound(Send node, MethodElement getter,
      Element element, AssignmentOperator operator, Node rhs, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedStaticSetterPostfix(Send node, MethodElement getter,
      Element element, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedStaticSetterPrefix(Send node, MethodElement getter,
      Element element, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperBinary(Send node, Element element,
      BinaryOperator operator, Node argument, T arg) {
    handleNSMError();
  }

  void visitUnresolvedSuperCompound(Send node, Element element,
      AssignmentOperator operator, Node rhs, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperCompoundIndexSet(Send node, Element element,
      Node index, AssignmentOperator operator, Node rhs, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperGet(Send node, Element element, T arg) {
    handleNSMError();
  }

  void visitUnresolvedSuperGetterCompound(Send node, Element element,
      MethodElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperGetterCompoundIndexSet(Send node, Element element,
      MethodElement setter, Node index, AssignmentOperator operator, Node rhs,
      T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperGetterIndexPostfix(Send node, Element element,
      MethodElement setter, Node index, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperGetterIndexPrefix(Send node, Element element,
      MethodElement setter, Node index, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperGetterPostfix(Send node, Element element,
      MethodElement setter, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperGetterPrefix(Send node, Element element,
      MethodElement setter, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperIndex(
      Send node, Element element, Node index, T arg) {
    handleNSMError();
  }

  void visitUnresolvedSuperIndexPostfix(
      Send node, Element element, Node index, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperIndexPrefix(
      Send node, Element element, Node index, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperIndexSet(
      Send node, Element element, Node index, Node rhs, T arg) {
    handleNSMError();
  }

  void visitUnresolvedSuperInvoke(Send node, Element element,
      NodeList arguments, Selector selector, T arg) {
    handleNSMError();
  }

  void visitUnresolvedSuperPostfix(
      Send node, Element element, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperPrefix(
      Send node, Element element, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperSetterCompound(Send node, MethodElement getter,
      Element element, AssignmentOperator operator, Node rhs, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperSetterCompoundIndexSet(Send node,
      MethodElement getter, Element element, Node index,
      AssignmentOperator operator, Node rhs, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperSetterIndexPostfix(Send node,
      MethodElement indexFunction, Element element, Node index,
      IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperSetterIndexPrefix(Send node,
      MethodElement indexFunction, Element element, Node index,
      IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperSetterPostfix(Send node, MethodElement getter,
      Element element, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperSetterPrefix(Send node, MethodElement getter,
      Element element, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedSuperUnary(
      Send node, UnaryOperator operator, Element element, T arg) {
    handleNSMError();
  }

  void visitUnresolvedTopLevelGetterCompound(Send node, Element element,
      MethodElement setter, AssignmentOperator operator, Node rhs, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedTopLevelGetterPostfix(Send node, Element element,
      MethodElement setter, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedTopLevelGetterPrefix(Send node, Element element,
      MethodElement setter, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedTopLevelSetterCompound(Send node, MethodElement getter,
      Element element, AssignmentOperator operator, Node rhs, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedTopLevelSetterPostfix(Send node, MethodElement getter,
      Element element, IncDecOperator operator, T arg) {
    handleNSMError();
    handleNoSend();
    handleNoSend();
  }

  void visitUnresolvedTopLevelSetterPrefix(Send node, MethodElement getter,
      Element element, IncDecOperator operator, T arg) {
    handleNSMError();
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
    handleSuper();
    handleDynamic();
    handleSuper();
  }

  void visitThisGet(Identifier node, T arg) {
    handleLocal(); // TODO: should we add a metric for "this"?
  }

  void visitThisInvoke(
      Send node, NodeList arguments, CallStructure callStructure, T arg) {
    // TODO:
    // - does the type of this define `call`? => virtual
    // - it doesn't, but it's abstract, all concrete subtypes do => virtual
    // - it doesn't, but it's abstract, all concrete subtypes do, but there is
    //   only one => instance
    // - none of them do => nsm error/call (depending on similar rules)
    handleDynamic();
  }

  void visitThisPropertyGet(Send node, Selector selector, T arg) {
    // TODO(sigmund): this may include NSM, we can:
    // - call it virtual if we find the definition in the class hierarchy and we
    //   know that the type contains it for sure (e.g. all types mising it are
    //   abstract)
    // - monomorphic-instance => if there is only one
    // - dynamic (if it could be NSM too).
    handleDynamic();
  }

  void visitThisPropertySet(SendSet node, Selector selector, Node rhs, T arg) {
    handleDynamic();
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
    handleNSMError();
    handleNoSend();
  }

  void visitClassTypeLiteralGet(Send node, ConstantExpression constant, T arg) {
    handleStatic();
  }

  void visitClassTypeLiteralInvoke(Send node, ConstantExpression constant,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSMError();
  }

  void visitClassTypeLiteralPostfix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSMError();
    handleNoSend();
  }

  void visitClassTypeLiteralPrefix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSMError();
    handleNoSend();
  }

  void visitClassTypeLiteralSet(
      SendSet node, ConstantExpression constant, Node rhs, T arg) {
    handleNSMError();
  }

  void visitDynamicTypeLiteralCompound(Send node, ConstantExpression constant,
      AssignmentOperator operator, Node rhs, T arg) {
    handleStatic();
    handleNSMError();
    handleNoSend();
  }

  void visitDynamicTypeLiteralGet(
      Send node, ConstantExpression constant, T arg) {
    handleNSMError();
  }

  void visitDynamicTypeLiteralInvoke(Send node, ConstantExpression constant,
      NodeList arguments, CallStructure callStructure, T arg) {
    handleNSMError();
  }

  void visitDynamicTypeLiteralPostfix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSMError();
    handleNoSend();
  }

  void visitDynamicTypeLiteralPrefix(
      Send node, ConstantExpression constant, IncDecOperator operator, T arg) {
    handleStatic();
    handleNSMError();
    handleNoSend();
  }

  void visitDynamicTypeLiteralSet(
      SendSet node, ConstantExpression constant, Node rhs, T arg) {
    handleNSMError();
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
  _check(node, String msg) {
    msg = '$msg ${recursiveDiagnosticString(measurements, Metric.send)}';
    if (!measurements.checkInvariant(Metric.send) ||
        !measurements.checkInvariant(Metric.monomorphicSend) ||
        !measurements.checkInvariant(Metric.polymorphicSend)) {
      compiler.reportError(
          node, MessageKind.GENERIC, {'text': 'bad\n-- $msg\nlast:\n-- $last\n'});
      last = msg;
    } else {
      last = msg;
    }
  }
}

/// Visitor that collects statistics about our understanding of a function.
class _StatsTraversalVisitor<T> extends TraversalVisitor<Void, T>
    implements SemanticSendVisitor<Void, T> {
  final Compiler compiler;
  final _StatsVisitor statsVisitor;
  Measurements get measurements => statsVisitor.measurements;
  _StatsTraversalVisitor(Compiler compiler, TreeElements elements)
      : compiler = compiler,
        statsVisitor = new _StatsVisitor(compiler, elements,
            // TODO(sigmund): accept a list of results
            new TrustTypesAnalysisResult(elements, compiler.world)),
        super(elements);

  void visitSend(Send node) {
    try {
      node.accept(statsVisitor);
    } catch (e, t) {
      compiler.reportError(node, MessageKind.GENERIC, {'text': '$e\n$t'});
    }
    super.visitSend(node);
  }

  void visitNewExpression(NewExpression node) {
    try {
      node.accept(statsVisitor);
    } catch (e, t) {
      compiler.reportError(node, MessageKind.GENERIC, {'text': '$e\n$t'});
    }
    super.visitNewExpression(node);
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
