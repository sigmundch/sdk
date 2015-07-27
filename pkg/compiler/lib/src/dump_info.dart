// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dump_info;

import 'dart:convert'
    show HtmlEscape, JsonEncoder, StringConversionSink, ChunkedConversionSink;

import 'elements/elements.dart';
import 'elements/visitor.dart';
import 'dart2jslib.dart'
    show Backend, CodeBuffer, Compiler, CompilerTask, MessageKind;
import 'types/types.dart' show TypeMask;
import 'deferred_load.dart' show OutputUnit;
import 'info/info.dart';
import 'js_backend/js_backend.dart' show JavaScriptBackend;
import 'js_emitter/full_emitter/emitter.dart' as full show Emitter;
import 'js/js.dart' as jsAst;
import 'universe/universe.dart' show Selector, UniverseSelector;
import 'util/util.dart' show NO_LOCATION_SPANNABLE;

class ElementInfoCollector extends BaseElementVisitor<Info, dynamic> {
  final Compiler compiler;

  final AllInfo result = new AllInfo();
  final Map<Element, Info> _elementToInfo = {};
  final Map<OutputUnit, OutputUnitInfo> _outputToInfo = {};

  ElementInfoCollector(this.compiler);

  void run() => compiler.libraryLoader.libraries.forEach(visit);

  Info visit(Element e, [_]) => e.accept(this, null);

  /// Whether to emit information about [element].
  ///
  /// By default we emit information for any element that contributes to the
  /// output size. Either becuase the it is a function being emitted or inlined,
  /// or because it is an element that holds dependencies to other elements.
  bool shouldKeep(Element element) {
    return compiler.dumpInfoTask.selectorsFromElement.containsKey(element) ||
        compiler.dumpInfoTask.inlineCount.containsKey(element);
  }

  /// Visits [element] and produces it's corresponding info.
  Info process(Element element) {
    // TODO(sigmund): change the visit order to eliminate the need to check
    // whether or not an element has been processed.
    return _elementToInfo.putIfAbsent(element, () => visit(element));
  }

  void _record(Element element, Info info, List list) {
    _elementToInfo[element] = info;
    list.add(info);
  }

  // Returns the id of an [element] if it has already been processed.
  // If the element has not been processed, this function does not
  // process it, and simply returns null instead.
  String idOf(Element element) => _elementToInfo[element]?.id;

  Info visitElement(Element element, _) => null;

  FunctionInfo visitConstructorBodyElement(ConstructorBodyElement e, _) {
    return visitFunctionElement(e.constructor, _);
  }

  LibraryInfo visitLibraryElement(LibraryElement element, _) {
    String libname = element.getLibraryName();
    libname = libname == "" ? "<unnamed>" : libname;
    int size = compiler.dumpInfoTask.sizeOf(element);
    LibraryInfo info =
      new LibraryInfo(libname, element.canonicalUri, null, size);

    LibraryElement realElement = element.isPatched ? element.patch : element;
    realElement.forEachLocalMember((Element member) {
      Info child = this.process(member);
      if (child is ClassInfo) {
        info.classes.add(child);
      } else if (child is FunctionInfo) {
        info.topLevelFunctions.add(child);
      } else if (child is FieldInfo) {
        info.topLevelVariables.add(child);
      } else if (child != null) {
        print('unexpected child of $info: $child ==> ${child.runtimeType}');
        assert(false);
      }
    });

    if (info.isEmpty && !shouldKeep(element)) return null;
    _record(element, info, result.libraries);
    return info;
  }

  TypedefInfo visitTypedefElement(TypedefElement element, _) {
    if (element.alias == null) return null;
    TypedefInfo info = new TypedefInfo(element.name, '${element.alias}');
    _record(element, info, result.typedefs);
    return info;
  }

  FieldInfo visitFieldElement(FieldElement element, _) {
    TypeMask inferredType =
        compiler.typesTask.getGuaranteedTypeOfElement(element);
    // If a field has an empty inferred type it is never used.
    if (inferredType == null || inferredType.isEmpty || element.isConst) {
      return null;
    }

    int size = compiler.dumpInfoTask.sizeOf(element);
    String code;
    StringBuffer emittedCode = compiler.dumpInfoTask.codeOf(element);
    if (emittedCode != null) {
      size += emittedCode.length;
      code = emittedCode.toString();
    }

    List<FunctionInfo> nestedClosures = <FunctionInfo>[];
    for (Element closure in element.nestedClosures) {
      Info child = this.process(closure);
      if (child != null) {
        nestedClosures.add(child);
        size += child.size;
      }
    }

    FieldInfo field = new FieldInfo(
        name: element.name,
        type: '${element.type}',
        inferredType: '$inferredType',
        closures: nestedClosures,
        size: size,
        code: code,
        outputUnit: _unitInfoForElement(element));
    _record(element, field, result.fields);
    return field;
  }

  ClassInfo visitClassElement(ClassElement element, _) {
    ClassInfo classInfo = new ClassInfo(
        name: element.name,
        isAbstract: element.isAbstract,
        outputUnit: _unitInfoForElement(element));
    _elementToInfo[element] = classInfo;

    int size = compiler.dumpInfoTask.sizeOf(element);
    element.forEachLocalMember((Element member) {
      Info info = this.process(member);
      if (info == null) return;
      if (info is FieldInfo) {
        classInfo.fields.add(info);
      } else {
        assert(info is FunctionInfo);
        classInfo.functions.add(info);
      }

      // Closures are placed in the library namespace, but we want to attribute
      // them to a function, and by extension, this class.  Process and add the
      // sizes here.
      if (member is MemberElement) {
        for (Element closure in member.nestedClosures) {
          FunctionInfo closureInfo = this.process(closure);
          if (closureInfo == null) continue;

          // TODO(sigmund): remove this legacy update on the name, represent the
          // information explicitly in the info format.
          // Look for the parent element of this closure might be the enclosing
          // class or an enclosing function.
          Element parent = closure.enclosingElement;
          ClassInfo parentInfo = this.process(parent);
          if (parentInfo != null) {
            closureInfo.name = "${parentInfo.name}.${closureInfo.name}";
          }
          size += closureInfo.size;
        }
      }
    });

    classInfo.size = size;

    // Omit element if it is not needed.
    if (!compiler.backend.emitter.neededClasses.contains(element) &&
        classInfo.fields.isEmpty &&
        classInfo.functions.isEmpty) {
      return null;
    }
    _record(element, classInfo, result.classes);
    return classInfo;
  }

  FunctionInfo visitFunctionElement(FunctionElement element, _) {
    int size = compiler.dumpInfoTask.sizeOf(element);
    if (size == 0 && !shouldKeep(element)) return null;

    String name = element.name;
    int kind = FunctionInfo.TOP_LEVEL_FUNCTION_KIND;
    var enclosingElement = element.enclosingElement;
    if (enclosingElement.isField ||
        enclosingElement.isFunction ||
        element.isClosure ||
        enclosingElement.isConstructor) {
      kind = FunctionInfo.CLOSURE_FUNCTION_KIND;
      name = "<unnamed>";
    } else if (element.isStatic) {
      kind = FunctionInfo.TOP_LEVEL_FUNCTION_KIND;
    } else if (enclosingElement.isClass) {
      kind = FunctionInfo.METHOD_FUNCTION_KIND;
    }

    if (element.isConstructor) {
      name = name == ""
          ? "${element.enclosingElement.name}"
          : "${element.enclosingElement.name}.${element.name}";
      kind = FunctionInfo.CONSTRUCTOR_FUNCTION_KIND;
    }

    FunctionModifiers modifiers = new FunctionModifiers(
        isStatic: element.isStatic,
        isConst: element.isConst,
        isFactory: element.isFactoryConstructor,
        isExternal: element.isPatched);
    StringBuffer emittedCode = compiler.dumpInfoTask.codeOf(element);
    String code = emittedCode == null ? null : '$emittedCode';

    List<ParameterInfo> parameters = <ParameterInfo>[];
    if (element.hasFunctionSignature) {
      FunctionSignature signature = element.functionSignature;
      signature.forEachParameter((parameter) {
        parameters.add(new ParameterInfo(
            parameter.name,
            '${compiler.typesTask.getGuaranteedTypeOfElement(parameter)}',
            '${parameter.node.type}'));
      });
    }

    String returnType = null;
    // TODO(sigmund): why all these checks?
    if (element.isInstanceMember &&
        !element.isAbstract &&
        compiler.world.allFunctions.contains(element)) {
      returnType = '${element.type.returnType}';
    }
    String inferredReturnType =
        '${compiler.typesTask.getGuaranteedReturnTypeOfElement(element)}';
    String sideEffects = '${compiler.world.getSideEffectsOfElement(element)}';

    List<FunctionInfo> nestedClosures = <FunctionInfo>[];
    if (element is MemberElement) {
      MemberElement member = element as MemberElement;
      for (Element closure in member.nestedClosures) {
        Info child = this.process(closure);
        if (child != null) {
          nestedClosures.add(child);
          size += child.size;
        }
      }
    }

    int inlinedCount = compiler.dumpInfoTask.inlineCount[element];
    if (inlinedCount == null) inlinedCount = 0;

    FunctionInfo info = new FunctionInfo(
        name: name,
        modifiers: modifiers,
        closures: nestedClosures,
        size: size,
        returnType: returnType,
        inferredReturnType: inferredReturnType,
        parameters: parameters,
        sideEffects: sideEffects,
        inlinedCount: inlinedCount,
        code: code,
        type: element.type.toString(),
        outputUnit: _unitInfoForElement(element));
    _record(element, info, result.functions);
    return info;
  }

  OutputUnitInfo _unitInfoForElement(Element element) {
    OutputUnit outputUnit =
      compiler.deferredLoadTask.outputUnitForElement(element);
    return _outputToInfo.putIfAbsent(outputUnit, () {
      // Dump-info currently only works with the full emitter. If another
      // emitter is used it will fail here.
      full.Emitter emitter = compiler.backend.emitter.emitter;
      OutputUnitInfo info = new OutputUnitInfo(
          outputUnit.name, emitter.outputBuffers[outputUnit].length);
      result.outputUnits.add(info);
      return info;
    });
  }
}

class Selection {
  final Element selectedElement;
  final TypeMask mask;
  Selection(this.selectedElement, this.mask);
}

class DumpInfoTask extends CompilerTask {
  DumpInfoTask(Compiler compiler) : super(compiler);

  String get name => "Dump Info";

  ElementInfoCollector infoCollector;

  /// The size of the generated output.
  int _programSize;

  // A set of javascript AST nodes that we care about the size of.
  // This set is automatically populated when registerElementAst()
  // is called.
  final Set<jsAst.Node> _tracking = new Set<jsAst.Node>();
  // A mapping from Dart Elements to Javascript AST Nodes.
  final Map<Element, List<jsAst.Node>> _elementToNodes =
      <Element, List<jsAst.Node>>{};
  // A mapping from Javascript AST Nodes to the size of their
  // pretty-printed contents.
  final Map<jsAst.Node, int> _nodeToSize = <jsAst.Node, int>{};

  final Map<Element, Set<UniverseSelector>> selectorsFromElement = {};
  final Map<Element, int> inlineCount = <Element, int>{};
  // A mapping from an element to a list of elements that are
  // inlined inside of it.
  final Map<Element, List<Element>> inlineMap = <Element, List<Element>>{};

  /// Register the size of the generated output.
  void reportSize(int programSize) {
    _programSize = programSize;
  }

  void registerInlined(Element element, Element inlinedFrom) {
    inlineCount.putIfAbsent(element, () => 0);
    inlineCount[element] += 1;
    inlineMap.putIfAbsent(inlinedFrom, () => new List<Element>());
    inlineMap[inlinedFrom].add(element);
  }

  /**
   * Registers that a function uses a selector in the
   * function body
   */
  void elementUsesSelector(Element element, UniverseSelector selector) {
    if (compiler.dumpInfo) {
      selectorsFromElement
          .putIfAbsent(element, () => new Set<UniverseSelector>())
          .add(selector);
    }
  }

  /**
   * Returns an iterable of [Selection]s that are used by
   * [element].  Each [Selection] contains an element that is
   * used and the selector that selected the element.
   */
  Iterable<Selection> getRetaining(Element element) {
    if (!selectorsFromElement.containsKey(element)) {
      return const <Selection>[];
    } else {
      return selectorsFromElement[element].expand((UniverseSelector selector) {
        return compiler.world.allFunctions
            .filter(selector.selector, selector.mask)
            .map((element) {
          return new Selection(element, selector.mask);
        });
      });
    }
  }

  // Returns true if we care about tracking the size of
  // this node.
  bool isTracking(jsAst.Node code) {
    if (compiler.dumpInfo) {
      return _tracking.contains(code);
    } else {
      return false;
    }
  }

  // Registers that a javascript AST node `code` was produced by the
  // dart Element `element`.
  void registerElementAst(Element element, jsAst.Node code) {
    if (compiler.dumpInfo) {
      _elementToNodes
          .putIfAbsent(element, () => new List<jsAst.Node>())
          .add(code);
      _tracking.add(code);
    }
  }

  // Records the size of a dart AST node after it has been
  // pretty-printed into the output buffer.
  void recordAstSize(jsAst.Node node, int size) {
    if (isTracking(node)) {
      //TODO: should I be incrementing here instead?
      _nodeToSize[node] = size;
    }
  }

  // Returns the size of the source code that
  // was generated for an element.  If no source
  // code was produced, return 0.
  int sizeOf(Element element) {
    if (_elementToNodes.containsKey(element)) {
      return _elementToNodes[element].map(sizeOfNode).fold(0, (a, b) => a + b);
    } else {
      return 0;
    }
  }

  int sizeOfNode(jsAst.Node node) {
    if (_nodeToSize.containsKey(node)) {
      return _nodeToSize[node];
    } else {
      return 0;
    }
  }

  StringBuffer codeOf(Element element) {
    List<jsAst.Node> code = _elementToNodes[element];
    if (code == null) return null;
    // Concatenate rendered ASTs.
    StringBuffer sb = new StringBuffer();
    for (jsAst.Node ast in code) {
      sb.writeln(jsAst.prettyPrint(ast, compiler).getText());
    }
    return sb;
  }

  void collectInfo() {
    infoCollector = new ElementInfoCollector(compiler)..run();
  }

  void dumpInfo() {
    measure(() {
      if (infoCollector == null) {
        collectInfo();
      }

      StringBuffer jsonBuffer = new StringBuffer();
      dumpInfoJson(jsonBuffer);
      compiler.outputProvider('', 'info.json')
        ..add(jsonBuffer.toString())
        ..close();
    });
  }

  void dumpInfoJson(StringSink buffer) {
    JsonEncoder encoder = const JsonEncoder.withIndent('  ');
    Stopwatch stopwatch = new Stopwatch();
    stopwatch.start();

    // Recursively build links to function uses
    Iterable<FunctionElement> functionElements =
        infoCollector._elementToInfo.keys.where((k) => k is FunctionElement);
    for (FunctionElement element in functionElements) {
      FunctionInfo info = infoCollector._elementToInfo[element];
      Iterable<Selection> uses = getRetaining(element);
      // Don't bother recording an empty list of dependencies.
      for (Selection selection in uses) {
        // Don't register dart2js builtin functions that are not recorded.
        Info useInfo = infoCollector._elementToInfo[selection.selectedElement];
        if (useInfo == null) continue;
        info.uses.add(new DependencyInfo(useInfo, '${selection.mask}'));
      }
    }

    // Track dependencies that come from inlining.
    for (Element element in inlineMap.keys) {
      FunctionInfo functionInfo = infoCollector._elementToInfo[element];
      if (functionInfo == null) continue;
      for (Element held in inlineMap[element]) {
        Info heldInfo = infoCollector._elementToInfo[held];
        if (heldInfo == null) continue;
        functionInfo.uses.add(new DependencyInfo(heldInfo, 'inlined'));
      }
    }

    AllInfo result = infoCollector.result;
    result.deferredFiles = compiler.deferredLoadTask.computeDeferredMap();
    stopwatch.stop();
    result.program = new ProgramInfo(
        size: _programSize,
        dart2jsVersion: compiler.hasBuildId ? compiler.buildId : null,
        compilationMoment: new DateTime.now(),
        compilationDuration: compiler.totalCompileTime.elapsed,
        toJsonDuration: stopwatch.elapsedMilliseconds,
        dumpInfoDuration: this.timing,
        noSuchMethodEnabled: compiler.backend.enabledNoSuchMethod,
        minified: compiler.enableMinification);

    ChunkedConversionSink<Object> sink = encoder.startChunkedConversion(
        new StringConversionSink.fromStringSink(buffer));
    sink.add(result.toJson());
    compiler.reportInfo(NO_LOCATION_SPANNABLE, MessageKind.GENERIC, {
      'text': "View the dumped .info.json file at "
          "https://dart-lang.github.io/dump-info-visualizer"
    });
  }
}
