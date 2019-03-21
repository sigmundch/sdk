// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart' as ir;
import 'package:kernel/class_hierarchy.dart' as ir;
import 'package:kernel/core_types.dart' as ir;
import 'package:kernel/type_algebra.dart' as ir;
import 'package:kernel/type_environment.dart' as ir;

import 'package:front_end/src/api_unstable/dart2js.dart' as ir show
LocatedMessage;

import '../diagnostics/diagnostic_listener.dart';
import '../diagnostics/source_span.dart';
import '../diagnostics/messages.dart';
import '../environment.dart';
import '../js_backend/annotations.dart';
import '../options.dart';
import '../serialization/serialization.dart';
import '../util/enumset.dart';

import 'annotations.dart';
import 'constants.dart';
import 'impact.dart';
import 'scope.dart';

class ModularMemberData {
  final ScopeModel scopeModel;
  final ImpactBuilderData impactBuilderData;

  ModularMemberData(this.scopeModel, this.impactBuilderData);
}

abstract class ModularStrategy {
  List<PragmaAnnotationData> getPragmaAnnotationData(ir.Member node);

  // TODO(johnniwinther): Avoid the need for passing [pragmaAnnotations].
  ModularMemberData getModularMemberData(
      ir.Member node, EnumSet<PragmaAnnotation> pragmaAnnotations);
}

/// Data computed for an entire compilation module.
class ModuleData {
  static const String tag = 'ModuleData';

  // TODO(sigmund): should be ModularMemberData once we add support for
  // serializing it.
  final List<ImpactBuilderData> impactData;

  ModuleData(this.impactData);

  factory ModuleData.fromDataSource(DataSource source) {
    source.begin(tag);
    List<ImpactBuilderData> impactData =
        source.readList(() => ImpactBuilderData.fromDataSource(source));
    source.end(tag);
    return new ModuleData(impactData);
  }

  void toDataSink(DataSink sink) {
    sink.begin(tag);
    sink.writeList(impactData, (ImpactBuilderData e) => e.toDataSink(sink));
    sink.end(tag);
  }
}

/// Compute modular member data entirely from the IR.
ModularMemberData computeModularMemberData(ir.Member node,
    {CompilerOptions options,
    DiagnosticReporter reporter,
    Dart2jsConstantEvaluator constantEvaluator,
    ir.TypeEnvironment typeEnvironment,
    ir.ClassHierarchy classHierarchy}) {
  EnumSet<PragmaAnnotation> annotations = processMemberAnnotations(
      options, reporter, node, computePragmaAnnotationDataFromIr(node));
  ScopeModel scopeModel = new ScopeModel.from(node, constantEvaluator);
  ImpactBuilderData impactBuilderData = (new ImpactBuilder(
          typeEnvironment, classHierarchy, scopeModel.variableScopeModel,
          useAsserts: options.enableUserAssertions,
          inferEffectivelyFinalVariableTypes:
              !annotations.contains(PragmaAnnotation.disableFinal)))
      .computeImpact(node);
  return new ModularMemberData(scopeModel, impactBuilderData);
}

ModuleData computeModuleData(
    ir.Component component,
    Set<Uri> includedLibraries,
    CompilerOptions options,
    DiagnosticReporter reporter,
    Environment environment) {
  List<ModularMemberData> result = [];

  ir.ClassHierarchy classHierarchy = new ir.ClassHierarchy(component);
  ir.TypeEnvironment typeEnvironment =
      new ir.TypeEnvironment(new ir.CoreTypes(component), classHierarchy);

  Dart2jsConstantEvaluator constantEvaluator = new Dart2jsConstantEvaluator(
      typeEnvironment,
      (ir.LocatedMessage message, List<ir.LocatedMessage> context) {
      reportLocatedMessage(reporter, message, context);
      },
      enableAsserts: options.enableUserAssertions,
      environment: environment.toMap());

  void computeForMember(ir.Member member) {
    result.add(computeModularMemberData(member,
        options: options,
        reporter: reporter,
        constantEvaluator: constantEvaluator,
        typeEnvironment: typeEnvironment,
        classHierarchy: classHierarchy));
  }

  for (var library in component.libraries) {
    if (!includedLibraries.contains(library.importUri)) continue;
    library.members.forEach(computeForMember);
    for (var cls in library.classes) {
      cls.members.forEach(computeForMember);
    }
  }

  return new ModuleData(result.map((e) => e.impactBuilderData).toList());
}

void reportLocatedMessage(DiagnosticReporter reporter,
    ir.LocatedMessage message, List<ir.LocatedMessage> context) {
  DiagnosticMessage diagnosticMessage =
      _createDiagnosticMessage(reporter, message);
  List<DiagnosticMessage> infos = [];
  for (ir.LocatedMessage message in context) {
    infos.add(_createDiagnosticMessage(reporter, message));
  }
  reporter.reportError(diagnosticMessage, infos);
}
DiagnosticMessage _createDiagnosticMessage(
    DiagnosticReporter reporter, ir.LocatedMessage message) {
  SourceSpan sourceSpan = new SourceSpan(
      message.uri, message.charOffset, message.charOffset + message.length);
  return reporter.createMessage(
      sourceSpan, MessageKind.GENERIC, {'text': message.message});
}
