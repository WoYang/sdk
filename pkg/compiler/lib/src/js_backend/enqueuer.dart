// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.js.enqueue;

import 'dart:collection' show Queue;

import '../common/codegen.dart' show CodegenWorkItem;
import '../common/names.dart' show Identifiers;
import '../common/resolution.dart' show Resolution;
import '../common/work.dart' show WorkItem;
import '../common.dart';
import '../compiler.dart' show Compiler;
import '../dart_types.dart' show DartType, InterfaceType;
import '../elements/elements.dart'
    show
        ClassElement,
        ConstructorElement,
        Element,
        Elements,
        Entity,
        FunctionElement,
        LibraryElement,
        Member,
        MemberElement,
        Name,
        TypedElement,
        TypedefElement;
import '../enqueue.dart';
import '../js/js.dart' as js;
import '../native/native.dart' as native;
import '../types/types.dart' show TypeMaskStrategy;
import '../universe/selector.dart' show Selector;
import '../universe/universe.dart';
import '../universe/use.dart'
    show DynamicUse, StaticUse, StaticUseKind, TypeUse, TypeUseKind;
import '../universe/world_impact.dart'
    show ImpactUseCase, WorldImpact, WorldImpactVisitor;
import '../util/util.dart' show Setlet;

/// [Enqueuer] which is specific to code generation.
class CodegenEnqueuer implements Enqueuer {
  final String name;
  final Compiler compiler; // TODO(ahe): Remove this dependency.
  final EnqueuerStrategy strategy;
  final ItemCompilationContextCreator itemCompilationContextCreator;
  final Map<String, Set<Element>> instanceMembersByName =
      new Map<String, Set<Element>>();
  final Map<String, Set<Element>> instanceFunctionsByName =
      new Map<String, Set<Element>>();
  final Set<ClassElement> _processedClasses = new Set<ClassElement>();
  Set<ClassElement> recentClasses = new Setlet<ClassElement>();
  final Universe universe = new Universe(const TypeMaskStrategy());

  static final TRACE_MIRROR_ENQUEUING =
      const bool.fromEnvironment("TRACE_MIRROR_ENQUEUING");

  bool queueIsClosed = false;
  EnqueueTask task;
  native.NativeEnqueuer nativeEnqueuer; // Set by EnqueueTask

  bool hasEnqueuedReflectiveElements = false;
  bool hasEnqueuedReflectiveStaticFields = false;

  WorldImpactVisitor impactVisitor;

  CodegenEnqueuer(
      Compiler compiler, this.itemCompilationContextCreator, this.strategy)
      : queue = new Queue<CodegenWorkItem>(),
        newlyEnqueuedElements = compiler.cacheStrategy.newSet(),
        newlySeenSelectors = compiler.cacheStrategy.newSet(),
        this.name = 'codegen enqueuer',
        this.compiler = compiler {
    impactVisitor = new _EnqueuerImpactVisitor(this);
  }

  // TODO(johnniwinther): Move this to [ResolutionEnqueuer].
  Resolution get resolution => compiler.resolution;

  bool get queueIsEmpty => queue.isEmpty;

  /// Returns [:true:] if this enqueuer is the resolution enqueuer.
  bool get isResolutionQueue => false;

  QueueFilter get filter => compiler.enqueuerFilter;

  DiagnosticReporter get reporter => compiler.reporter;

  bool isClassProcessed(ClassElement cls) => _processedClasses.contains(cls);

  Iterable<ClassElement> get processedClasses => _processedClasses;

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [element] must be a declaration element.
   */
  void addToWorkList(Element element) {
    assert(invariant(element, element.isDeclaration));
    if (internalAddToWorkList(element) && compiler.options.dumpInfo) {
      // TODO(sigmund): add other missing dependencies (internals, selectors
      // enqueued after allocations), also enable only for the codegen enqueuer.
      compiler.dumpInfoTask
          .registerDependency(compiler.currentElement, element);
    }
  }

  /// Apply the [worldImpact] of processing [element] to this enqueuer.
  void applyImpact(Element element, WorldImpact worldImpact) {
    compiler.impactStrategy
        .visitImpact(element, worldImpact, impactVisitor, impactUse);
  }

  void registerInstantiatedType(InterfaceType type, {bool mirrorUsage: false}) {
    task.measure(() {
      ClassElement cls = type.element;
      cls.ensureResolved(resolution);
      bool isNative = compiler.backend.isNative(cls);
      universe.registerTypeInstantiation(type,
          isNative: isNative,
          byMirrors: mirrorUsage, onImplemented: (ClassElement cls) {
        compiler.backend
            .registerImplementedClass(cls, this, compiler.globalDependencies);
      });
      // TODO(johnniwinther): Share this reasoning with [Universe].
      if (!cls.isAbstract || isNative || mirrorUsage) {
        processInstantiatedClass(cls);
      }
    });
  }

  bool checkNoEnqueuedInvokedInstanceMethods() {
    return filter.checkNoEnqueuedInvokedInstanceMethods(this);
  }

  void processInstantiatedClassMembers(ClassElement cls) {
    strategy.processInstantiatedClass(this, cls);
  }

  void processInstantiatedClassMember(ClassElement cls, Element member) {
    assert(invariant(member, member.isDeclaration));
    if (isProcessed(member)) return;
    if (!member.isInstanceMember) return;
    String memberName = member.name;

    if (member.isField) {
      // The obvious thing to test here would be "member.isNative",
      // however, that only works after metadata has been parsed/analyzed,
      // and that may not have happened yet.
      // So instead we use the enclosing class, which we know have had
      // its metadata parsed and analyzed.
      // Note: this assumes that there are no non-native fields on native
      // classes, which may not be the case when a native class is subclassed.
      if (compiler.backend.isNative(cls)) {
        compiler.world.registerUsedElement(member);
        if (universe.hasInvokedGetter(member, compiler.world) ||
            universe.hasInvocation(member, compiler.world)) {
          addToWorkList(member);
          return;
        }
        if (universe.hasInvokedSetter(member, compiler.world)) {
          addToWorkList(member);
          return;
        }
        // Native fields need to go into instanceMembersByName as they
        // are virtual instantiation points and escape points.
      } else {
        // All field initializers must be resolved as they could
        // have an observable side-effect (and cannot be tree-shaken
        // away).
        addToWorkList(member);
        return;
      }
    } else if (member.isFunction) {
      FunctionElement function = member;
      function.computeType(resolution);
      if (function.name == Identifiers.noSuchMethod_) {
        registerNoSuchMethod(function);
      }
      if (function.name == Identifiers.call && !cls.typeVariables.isEmpty) {
        registerCallMethodWithFreeTypeVariables(function);
      }
      // If there is a property access with the same name as a method we
      // need to emit the method.
      if (universe.hasInvokedGetter(function, compiler.world)) {
        registerClosurizedMember(function);
        addToWorkList(function);
        return;
      }
      // Store the member in [instanceFunctionsByName] to catch
      // getters on the function.
      instanceFunctionsByName
          .putIfAbsent(memberName, () => new Set<Element>())
          .add(member);
      if (universe.hasInvocation(function, compiler.world)) {
        addToWorkList(function);
        return;
      }
    } else if (member.isGetter) {
      FunctionElement getter = member;
      getter.computeType(resolution);
      if (universe.hasInvokedGetter(getter, compiler.world)) {
        addToWorkList(getter);
        return;
      }
      // We don't know what selectors the returned closure accepts. If
      // the set contains any selector we have to assume that it matches.
      if (universe.hasInvocation(getter, compiler.world)) {
        addToWorkList(getter);
        return;
      }
    } else if (member.isSetter) {
      FunctionElement setter = member;
      setter.computeType(resolution);
      if (universe.hasInvokedSetter(setter, compiler.world)) {
        addToWorkList(setter);
        return;
      }
    }

    // The element is not yet used. Add it to the list of instance
    // members to still be processed.
    instanceMembersByName
        .putIfAbsent(memberName, () => new Set<Element>())
        .add(member);
  }

  void enableIsolateSupport() {}

  void processInstantiatedClass(ClassElement cls) {
    task.measure(() {
      if (_processedClasses.contains(cls)) return;
      // The class must be resolved to compute the set of all
      // supertypes.
      cls.ensureResolved(resolution);

      void processClass(ClassElement superclass) {
        if (_processedClasses.contains(superclass)) return;
        // TODO(johnniwinther): Re-insert this invariant when unittests don't
        // fail. There is already a similar invariant on the members.
        /*if (!isResolutionQueue) {
          assert(invariant(superclass,
              superclass.isClosure ||
              compiler.enqueuer.resolution.isClassProcessed(superclass),
              message: "Class $superclass has not been "
                       "processed in resolution."));
        }*/

        _processedClasses.add(superclass);
        recentClasses.add(superclass);
        superclass.ensureResolved(resolution);
        superclass.implementation.forEachMember(processInstantiatedClassMember);
        if (isResolutionQueue &&
            !compiler.serialization.isDeserialized(superclass)) {
          compiler.resolver.checkClass(superclass);
        }
        // We only tell the backend once that [superclass] was instantiated, so
        // any additional dependencies must be treated as global
        // dependencies.
        compiler.backend.registerInstantiatedClass(
            superclass, this, compiler.globalDependencies);
      }

      ClassElement superclass = cls;
      while (superclass != null) {
        processClass(superclass);
        superclass = superclass.superclass;
      }
    });
  }

  void registerDynamicUse(DynamicUse dynamicUse) {
    task.measure(() {
      if (universe.registerDynamicUse(dynamicUse)) {
        handleUnseenSelector(dynamicUse);
      }
    });
  }

  void logEnqueueReflectiveAction(action, [msg = ""]) {
    if (TRACE_MIRROR_ENQUEUING) {
      print("MIRROR_ENQUEUE (${isResolutionQueue ? "R" : "C"}): $action $msg");
    }
  }

  /// Enqeue the constructor [ctor] if it is required for reflection.
  ///
  /// [enclosingWasIncluded] provides a hint whether the enclosing element was
  /// needed for reflection.
  void enqueueReflectiveConstructor(
      ConstructorElement ctor, bool enclosingWasIncluded) {
    if (shouldIncludeElementDueToMirrors(ctor,
        includedEnclosing: enclosingWasIncluded)) {
      logEnqueueReflectiveAction(ctor);
      ClassElement cls = ctor.declaration.enclosingClass;
      compiler.backend.registerInstantiatedType(
          cls.rawType, this, compiler.mirrorDependencies,
          mirrorUsage: true);
      registerStaticUse(new StaticUse.foreignUse(ctor.declaration));
    }
  }

  /// Enqeue the member [element] if it is required for reflection.
  ///
  /// [enclosingWasIncluded] provides a hint whether the enclosing element was
  /// needed for reflection.
  void enqueueReflectiveMember(Element element, bool enclosingWasIncluded) {
    if (shouldIncludeElementDueToMirrors(element,
        includedEnclosing: enclosingWasIncluded)) {
      logEnqueueReflectiveAction(element);
      if (element.isTypedef) {
        TypedefElement typedef = element;
        typedef.ensureResolved(resolution);
        compiler.world.allTypedefs.add(element);
      } else if (Elements.isStaticOrTopLevel(element)) {
        registerStaticUse(new StaticUse.foreignUse(element.declaration));
      } else if (element.isInstanceMember) {
        // We need to enqueue all members matching this one in subclasses, as
        // well.
        // TODO(herhut): Use TypedSelector.subtype for enqueueing
        DynamicUse dynamicUse =
            new DynamicUse(new Selector.fromElement(element), null);
        registerDynamicUse(dynamicUse);
        if (element.isField) {
          DynamicUse dynamicUse = new DynamicUse(
              new Selector.setter(
                  new Name(element.name, element.library, isSetter: true)),
              null);
          registerDynamicUse(dynamicUse);
        }
      }
    }
  }

  /// Enqeue the member [element] if it is required for reflection.
  ///
  /// [enclosingWasIncluded] provides a hint whether the enclosing element was
  /// needed for reflection.
  void enqueueReflectiveElementsInClass(ClassElement cls,
      Iterable<ClassElement> recents, bool enclosingWasIncluded) {
    if (cls.library.isInternalLibrary || cls.isInjected) return;
    bool includeClass = shouldIncludeElementDueToMirrors(cls,
        includedEnclosing: enclosingWasIncluded);
    if (includeClass) {
      logEnqueueReflectiveAction(cls, "register");
      ClassElement decl = cls.declaration;
      decl.ensureResolved(resolution);
      compiler.backend.registerInstantiatedType(
          decl.rawType, this, compiler.mirrorDependencies,
          mirrorUsage: true);
    }
    // If the class is never instantiated, we know nothing of it can possibly
    // be reflected upon.
    // TODO(herhut): Add a warning if a mirrors annotation cannot hit.
    if (recents.contains(cls.declaration)) {
      logEnqueueReflectiveAction(cls, "members");
      cls.constructors.forEach((Element element) {
        enqueueReflectiveConstructor(element, includeClass);
      });
      cls.forEachClassMember((Member member) {
        enqueueReflectiveMember(member.element, includeClass);
      });
    }
  }

  /// Enqeue special classes that might not be visible by normal means or that
  /// would not normally be enqueued:
  ///
  /// [Closure] is treated specially as it is the superclass of all closures.
  /// Although it is in an internal library, we mark it as reflectable. Note
  /// that none of its methods are reflectable, unless reflectable by
  /// inheritance.
  void enqueueReflectiveSpecialClasses() {
    Iterable<ClassElement> classes =
        compiler.backend.classesRequiredForReflection;
    for (ClassElement cls in classes) {
      if (compiler.backend.referencedFromMirrorSystem(cls)) {
        logEnqueueReflectiveAction(cls);
        cls.ensureResolved(resolution);
        compiler.backend.registerInstantiatedType(
            cls.rawType, this, compiler.mirrorDependencies,
            mirrorUsage: true);
      }
    }
  }

  /// Enqeue all local members of the library [lib] if they are required for
  /// reflection.
  void enqueueReflectiveElementsInLibrary(
      LibraryElement lib, Iterable<ClassElement> recents) {
    bool includeLibrary =
        shouldIncludeElementDueToMirrors(lib, includedEnclosing: false);
    lib.forEachLocalMember((Element member) {
      if (member.isInjected) return;
      if (member.isClass) {
        enqueueReflectiveElementsInClass(member, recents, includeLibrary);
      } else {
        enqueueReflectiveMember(member, includeLibrary);
      }
    });
  }

  /// Enqueue all elements that are matched by the mirrors used
  /// annotation or, in lack thereof, all elements.
  void enqueueReflectiveElements(Iterable<ClassElement> recents) {
    if (!hasEnqueuedReflectiveElements) {
      logEnqueueReflectiveAction("!START enqueueAll");
      // First round of enqueuing, visit everything that is visible to
      // also pick up static top levels, etc.
      // Also, during the first round, consider all classes that have been seen
      // as recently seen, as we do not know how many rounds of resolution might
      // have run before tree shaking is disabled and thus everything is
      // enqueued.
      recents = _processedClasses.toSet();
      reporter.log('Enqueuing everything');
      for (LibraryElement lib in compiler.libraryLoader.libraries) {
        enqueueReflectiveElementsInLibrary(lib, recents);
      }
      enqueueReflectiveSpecialClasses();
      hasEnqueuedReflectiveElements = true;
      hasEnqueuedReflectiveStaticFields = true;
      logEnqueueReflectiveAction("!DONE enqueueAll");
    } else if (recents.isNotEmpty) {
      // Keep looking at new classes until fixpoint is reached.
      logEnqueueReflectiveAction("!START enqueueRecents");
      recents.forEach((ClassElement cls) {
        enqueueReflectiveElementsInClass(
            cls,
            recents,
            shouldIncludeElementDueToMirrors(cls.library,
                includedEnclosing: false));
      });
      logEnqueueReflectiveAction("!DONE enqueueRecents");
    }
  }

  /// Enqueue the static fields that have been marked as used by reflective
  /// usage through `MirrorsUsed`.
  void enqueueReflectiveStaticFields(Iterable<Element> elements) {
    if (hasEnqueuedReflectiveStaticFields) return;
    hasEnqueuedReflectiveStaticFields = true;
    for (Element element in elements) {
      enqueueReflectiveMember(element, true);
    }
  }

  void processSet(
      Map<String, Set<Element>> map, String memberName, bool f(Element e)) {
    Set<Element> members = map[memberName];
    if (members == null) return;
    // [f] might add elements to [: map[memberName] :] during the loop below
    // so we create a new list for [: map[memberName] :] and prepend the
    // [remaining] members after the loop.
    map[memberName] = new Set<Element>();
    Set<Element> remaining = new Set<Element>();
    for (Element member in members) {
      if (!f(member)) remaining.add(member);
    }
    map[memberName].addAll(remaining);
  }

  processInstanceMembers(String n, bool f(Element e)) {
    processSet(instanceMembersByName, n, f);
  }

  processInstanceFunctions(String n, bool f(Element e)) {
    processSet(instanceFunctionsByName, n, f);
  }

  void _handleUnseenSelector(DynamicUse universeSelector) {
    strategy.processDynamicUse(this, universeSelector);
  }

  void handleUnseenSelectorInternal(DynamicUse dynamicUse) {
    Selector selector = dynamicUse.selector;
    String methodName = selector.name;
    processInstanceMembers(methodName, (Element member) {
      if (dynamicUse.appliesUnnamed(member, compiler.world)) {
        if (member.isFunction && selector.isGetter) {
          registerClosurizedMember(member);
        }
        addToWorkList(member);
        return true;
      }
      return false;
    });
    if (selector.isGetter) {
      processInstanceFunctions(methodName, (Element member) {
        if (dynamicUse.appliesUnnamed(member, compiler.world)) {
          registerClosurizedMember(member);
          return true;
        }
        return false;
      });
    }
  }

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [element] must be a declaration element.
   */
  void registerStaticUse(StaticUse staticUse) {
    strategy.processStaticUse(this, staticUse);
  }

  void registerStaticUseInternal(StaticUse staticUse) {
    Element element = staticUse.element;
    assert(invariant(element, element.isDeclaration,
        message: "Element ${element} is not the declaration."));
    universe.registerStaticUse(staticUse);
    compiler.backend.registerStaticUse(element, this);
    bool addElement = true;
    switch (staticUse.kind) {
      case StaticUseKind.STATIC_TEAR_OFF:
        compiler.backend.registerGetOfStaticFunction(this);
        break;
      case StaticUseKind.FIELD_GET:
      case StaticUseKind.FIELD_SET:
      case StaticUseKind.CLOSURE:
        // TODO(johnniwinther): Avoid this. Currently [FIELD_GET] and
        // [FIELD_SET] contains [BoxFieldElement]s which we cannot enqueue.
        // Also [CLOSURE] contains [LocalFunctionElement] which we cannot
        // enqueue.
        addElement = false;
        break;
      case StaticUseKind.SUPER_FIELD_SET:
      case StaticUseKind.SUPER_TEAR_OFF:
      case StaticUseKind.GENERAL:
        break;
    }
    if (addElement) {
      addToWorkList(element);
    }
  }

  void registerTypeUse(TypeUse typeUse) {
    DartType type = typeUse.type;
    switch (typeUse.kind) {
      case TypeUseKind.INSTANTIATION:
        registerInstantiatedType(type);
        break;
      case TypeUseKind.INSTANTIATION:
      case TypeUseKind.IS_CHECK:
      case TypeUseKind.AS_CAST:
      case TypeUseKind.CATCH_TYPE:
        _registerIsCheck(type);
        break;
      case TypeUseKind.CHECKED_MODE_CHECK:
        if (compiler.options.enableTypeAssertions) {
          _registerIsCheck(type);
        }
        break;
      case TypeUseKind.TYPE_LITERAL:
        break;
    }
  }

  void _registerIsCheck(DartType type) {
    type = universe.registerIsCheck(type, compiler);
    // Even in checked mode, type annotations for return type and argument
    // types do not imply type checks, so there should never be a check
    // against the type variable of a typedef.
    assert(!type.isTypeVariable || !type.element.enclosingElement.isTypedef);
  }

  void registerCallMethodWithFreeTypeVariables(Element element) {
    compiler.backend.registerCallMethodWithFreeTypeVariables(
        element, this, compiler.globalDependencies);
    universe.callMethodsWithFreeTypeVariables.add(element);
  }

  void registerClosurizedMember(TypedElement element) {
    assert(element.isInstanceMember);
    if (element.computeType(resolution).containsTypeVariables) {
      compiler.backend.registerClosureWithFreeTypeVariables(
          element, this, compiler.globalDependencies);
    }
    compiler.backend.registerBoundClosure(this);
    universe.closurizedMembers.add(element);
  }

  void forEach(void f(WorkItem work)) {
    do {
      while (queue.isNotEmpty) {
        // TODO(johnniwinther): Find an optimal process order.
        filter.processWorkItem(f, queue.removeLast());
      }
      List recents = recentClasses.toList(growable: false);
      recentClasses.clear();
      if (!onQueueEmpty(recents)) recentClasses.addAll(recents);
    } while (queue.isNotEmpty || recentClasses.isNotEmpty);
  }

  /// [onQueueEmpty] is called whenever the queue is drained. [recentClasses]
  /// contains the set of all classes seen for the first time since
  /// [onQueueEmpty] was called last. A return value of [true] indicates that
  /// the [recentClasses] have been processed and may be cleared. If [false] is
  /// returned, [onQueueEmpty] will be called once the queue is empty again (or
  /// still empty) and [recentClasses] will be a superset of the current value.
  bool onQueueEmpty(Iterable<ClassElement> recentClasses) {
    return compiler.backend.onQueueEmpty(this, recentClasses);
  }

  void logSummary(log(message)) {
    _logSpecificSummary(log);
    nativeEnqueuer.logSummary(log);
  }

  String toString() => 'Enqueuer($name)';

  void _forgetElement(Element element) {
    universe.forgetElement(element, compiler);
    _processedClasses.remove(element);
    instanceMembersByName[element.name]?.remove(element);
    instanceFunctionsByName[element.name]?.remove(element);
  }

  final Queue<CodegenWorkItem> queue;
  final Map<Element, js.Expression> generatedCode = <Element, js.Expression>{};

  final Set<Element> newlyEnqueuedElements;

  final Set<DynamicUse> newlySeenSelectors;

  bool enabledNoSuchMethod = false;

  static const ImpactUseCase IMPACT_USE =
      const ImpactUseCase('CodegenEnqueuer');

  ImpactUseCase get impactUse => IMPACT_USE;

  bool isProcessed(Element member) =>
      member.isAbstract || generatedCode.containsKey(member);

  /**
   * Decides whether an element should be included to satisfy requirements
   * of the mirror system.
   *
   * For code generation, we rely on the precomputed set of elements that takes
   * subtyping constraints into account.
   */
  bool shouldIncludeElementDueToMirrors(Element element,
      {bool includedEnclosing}) {
    return compiler.backend.isAccessibleByReflection(element);
  }

  /**
   * Adds [element] to the work list if it has not already been processed.
   *
   * Returns [true] if the element was actually added to the queue.
   */
  bool internalAddToWorkList(Element element) {
    // Don't generate code for foreign elements.
    if (compiler.backend.isForeign(element)) return false;

    // Codegen inlines field initializers. It only needs to generate
    // code for checked setters.
    if (element.isField && element.isInstanceMember) {
      if (!compiler.options.enableTypeAssertions ||
          element.enclosingElement.isClosure) {
        return false;
      }
    }

    if (compiler.options.hasIncrementalSupport && !isProcessed(element)) {
      newlyEnqueuedElements.add(element);
    }

    if (queueIsClosed) {
      throw new SpannableAssertionFailure(
          element, "Codegen work list is closed. Trying to add $element");
    }
    CodegenWorkItem workItem =
        new CodegenWorkItem(compiler, element, itemCompilationContextCreator());
    queue.add(workItem);
    return true;
  }

  void registerNoSuchMethod(Element element) {
    if (!enabledNoSuchMethod && compiler.backend.enabledNoSuchMethod) {
      compiler.backend.enableNoSuchMethod(this);
      enabledNoSuchMethod = true;
    }
  }

  void _logSpecificSummary(log(message)) {
    log('Compiled ${generatedCode.length} methods.');
  }

  void forgetElement(Element element) {
    _forgetElement(element);
    generatedCode.remove(element);
    if (element is MemberElement) {
      for (Element closure in element.nestedClosures) {
        generatedCode.remove(closure);
        removeFromSet(instanceMembersByName, closure);
        removeFromSet(instanceFunctionsByName, closure);
      }
    }
  }

  void handleUnseenSelector(DynamicUse dynamicUse) {
    if (compiler.options.hasIncrementalSupport) {
      newlySeenSelectors.add(dynamicUse);
    }
    _handleUnseenSelector(dynamicUse);
  }

  @override
  Iterable<Entity> get processedEntities => generatedCode.keys;
}

void removeFromSet(Map<String, Set<Element>> map, Element element) {
  Set<Element> set = map[element.name];
  if (set == null) return;
  set.remove(element);
}

class _EnqueuerImpactVisitor implements WorldImpactVisitor {
  final CodegenEnqueuer enqueuer;

  _EnqueuerImpactVisitor(this.enqueuer);

  @override
  void visitDynamicUse(DynamicUse dynamicUse) {
    enqueuer.registerDynamicUse(dynamicUse);
  }

  @override
  void visitStaticUse(StaticUse staticUse) {
    enqueuer.registerStaticUse(staticUse);
  }

  @override
  void visitTypeUse(TypeUse typeUse) {
    enqueuer.registerTypeUse(typeUse);
  }
}
