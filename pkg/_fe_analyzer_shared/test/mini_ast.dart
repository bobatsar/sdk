// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// This file implements the AST of a Dart-like language suitable for testing
/// flow analysis.  Callers may use the top level methods in this file to create
/// AST nodes and then feed them to [Harness.run] to run them through flow
/// analysis testing.
import 'package:_fe_analyzer_shared/src/flow_analysis/flow_analysis.dart'
    show EqualityInfo, FlowAnalysis, Operations;
import 'package:_fe_analyzer_shared/src/type_inference/assigned_variables.dart';
import 'package:_fe_analyzer_shared/src/type_inference/type_analysis_result.dart';
import 'package:_fe_analyzer_shared/src/type_inference/type_analysis_result.dart'
    as shared;
import 'package:_fe_analyzer_shared/src/type_inference/type_analyzer.dart'
    hide MapPatternEntry, NamedType, RecordPatternField, RecordType;
import 'package:_fe_analyzer_shared/src/type_inference/type_analyzer.dart'
    as shared;
import 'package:_fe_analyzer_shared/src/type_inference/type_operations.dart';
import 'package:_fe_analyzer_shared/src/type_inference/type_operations.dart'
    as shared;
import 'package:_fe_analyzer_shared/src/type_inference/variable_bindings.dart';
import 'package:test/test.dart';

import 'mini_ir.dart';
import 'mini_types.dart';

final RegExp _locationRegExp =
    RegExp('(file:)?[a-zA-Z0-9_./]+.dart:[0-9]+:[0-9]+');

_SwitchHeadDefault get default_ =>
    _SwitchHeadDefault(location: computeLocation());

Expression get nullLiteral => new _NullLiteral(location: computeLocation());

Expression get this_ => new _This(location: computeLocation());

Statement assert_(Expression condition, [Expression? message]) =>
    new _Assert(condition, message, location: computeLocation());

Statement block(List<Statement> statements) =>
    new _Block(statements, location: computeLocation());

Expression booleanLiteral(bool value) =>
    _BooleanLiteral(value, location: computeLocation());

Statement break_([Label? target]) =>
    new _Break(target, location: computeLocation());

/// Creates a pseudo-statement whose function is to verify that flow analysis
/// considers [variable]'s assigned state to be [expectedAssignedState].
Statement checkAssigned(Var variable, bool expectedAssignedState) =>
    new _CheckAssigned(variable, expectedAssignedState,
        location: computeLocation());

/// Creates a pseudo-statement whose function is to verify that flow analysis
/// considers [promotable] to be un-promoted.
Statement checkNotPromoted(Promotable promotable) =>
    new _CheckPromoted(promotable, null, location: computeLocation());

/// Creates a pseudo-statement whose function is to verify that flow analysis
/// considers [promotable]'s assigned state to be promoted to [expectedTypeStr].
Statement checkPromoted(Promotable promotable, String? expectedTypeStr) =>
    new _CheckPromoted(promotable, expectedTypeStr,
        location: computeLocation());

/// Creates a pseudo-statement whose function is to verify that flow analysis
/// considers the current location's reachability state to be
/// [expectedReachable].
Statement checkReachable(bool expectedReachable) =>
    new _CheckReachable(expectedReachable, location: computeLocation());

/// Creates a pseudo-statement whose function is to verify that flow analysis
/// considers [variable]'s unassigned state to be [expectedUnassignedState].
Statement checkUnassigned(Var variable, bool expectedUnassignedState) =>
    new _CheckUnassigned(variable, expectedUnassignedState,
        location: computeLocation());

/// Computes a "location" string using `StackTrace.current` to find the source
/// location of the caller's caller.
///
/// Note: this is highly dependent on the behavior of VM stack traces.  This
/// won't work in code compiled with dart2js for example.  That's fine, though,
/// since we only run these tests under the VM.
String computeLocation() {
  var callStack = StackTrace.current.toString().split('\n');
  assert(callStack[0].contains('mini_ast.dart'));
  assert(callStack[1].contains('mini_ast.dart'));

  String stackLine;
  if (callStack[3].contains('joinPatternVariables')) {
    stackLine = callStack[3];
  } else {
    stackLine = callStack[2];
    assert(
        stackLine.contains('type_inference_test.dart') ||
            stackLine.contains('flow_analysis_test.dart'),
        'Unexpected file: $stackLine');
  }

  var match = _locationRegExp.firstMatch(stackLine);
  if (match == null) {
    throw AssertionError(
        '_locationRegExp failed to match $stackLine in $callStack');
  }
  return match.group(0)!;
}

Statement continue_() => new _Continue(location: computeLocation());

Statement declare(Var variable,
    {bool isLate = false,
    bool isFinal = false,
    String? type,
    Expression? initializer,
    String? expectInferredType}) {
  var location = computeLocation();
  return new _Declare(
      new _VariablePattern(
          type == null ? null : Type(type), variable, expectInferredType,
          location: location),
      initializer,
      isLate: isLate,
      isFinal: isFinal,
      location: location);
}

Statement do_(List<Statement> body, Expression condition) {
  var location = computeLocation();
  return _Do(_Block(body, location: location), condition, location: location);
}

/// Creates a pseudo-expression having type [typeStr] that otherwise has no
/// effect on flow analysis.
Expression expr(String typeStr) =>
    new _PlaceholderExpression(new Type(typeStr), location: computeLocation());

/// Creates a conventional `for` statement.  Optional boolean [forCollection]
/// indicates that this `for` statement is actually a collection element, so
/// `null` should be passed to [for_bodyBegin].
Statement for_(Statement? initializer, Expression? condition,
    Expression? updater, List<Statement> body,
    {bool forCollection = false}) {
  var location = computeLocation();
  return new _For(initializer, condition, updater,
      _Block(body, location: location), forCollection,
      location: location);
}

/// Creates a "for each" statement where the identifier being assigned to by the
/// iteration is not a local variable.
///
/// This models code like:
///     var x; // Top level variable
///     f(Iterable iterable) {
///       for (x in iterable) { ... }
///     }
Statement forEachWithNonVariable(Expression iterable, List<Statement> body) {
  var location = computeLocation();
  return new _ForEach(null, iterable, _Block(body, location: location), false,
      location: location);
}

/// Creates a "for each" statement where the identifier being assigned to by the
/// iteration is a variable that is being declared by the "for each" statement.
///
/// This models code like:
///     f(Iterable iterable) {
///       for (var x in iterable) { ... }
///     }
Statement forEachWithVariableDecl(
    Var variable, Expression iterable, List<Statement> body) {
  // ignore: unnecessary_null_comparison
  assert(variable != null);
  return new _ForEach(variable, iterable, block(body), true,
      location: computeLocation());
}

/// Creates a "for each" statement where the identifier being assigned to by the
/// iteration is a local variable that is declared elsewhere in the function.
///
/// This models code like:
///     f(Iterable iterable) {
///       var x;
///       for (x in iterable) { ... }
///     }
Statement forEachWithVariableSet(
    Var variable, Expression iterable, List<Statement> body) {
  // ignore: unnecessary_null_comparison
  assert(variable != null);
  var location = computeLocation();
  return new _ForEach(
      variable, iterable, _Block(body, location: location), false,
      location: location);
}

Statement if_(Expression condition, List<Statement> ifTrue,
    [List<Statement>? ifFalse]) {
  var location = computeLocation();
  return new _If(condition, _Block(ifTrue, location: location),
      ifFalse == null ? null : _Block(ifFalse, location: location),
      location: location);
}

Statement ifCase(
  Expression expression,
  PossiblyGuardedPattern pattern, {
  List<Statement>? ifTrue,
  List<Statement>? ifFalse,
}) {
  var location = computeLocation();
  var guardedPattern = pattern._asGuardedPattern;
  return _IfCase(
    expression,
    guardedPattern.pattern,
    guardedPattern.guard,
    _Block(ifTrue ?? [], location: location),
    ifFalse != null ? _Block(ifFalse, location: location) : null,
    location: location,
  );
}

CollectionElement ifCaseElement(
  Expression expression,
  PossiblyGuardedPattern pattern,
  CollectionElement ifTrue, {
  CollectionElement? ifFalse,
}) {
  var location = computeLocation();
  var guardedPattern = pattern._asGuardedPattern;
  return new _IfCaseElement(
    expression,
    guardedPattern.pattern,
    guardedPattern.guard,
    ifTrue,
    ifFalse,
    location: location,
  );
}

CollectionElement ifElement(Expression condition, CollectionElement ifTrue,
    [CollectionElement? ifFalse]) {
  var location = computeLocation();
  return new _IfElement(condition, ifTrue, ifFalse, location: location);
}

Expression intLiteral(int value, {bool? expectConversionToDouble}) =>
    new _IntLiteral(value,
        expectConversionToDouble: expectConversionToDouble,
        location: computeLocation());

Pattern listPattern(List<ListPatternElement> elements, {String? elementType}) =>
    _ListPattern(elementType == null ? null : Type(elementType), elements,
        location: computeLocation());

ListPatternElement listPatternRestElement([Pattern? pattern]) =>
    _RestPatternElement(pattern, location: computeLocation());

Statement localFunction(List<Statement> body) {
  var location = computeLocation();
  return _LocalFunction(_Block(body, location: location), location: location);
}

Pattern mapPattern(List<MapPatternElement> elements) {
  var location = computeLocation();
  return _MapPattern(null, elements, location: location);
}

MapPatternElement mapPatternEntry(Expression key, Pattern value) {
  return _MapPatternEntry(key, value, location: computeLocation());
}

MapPatternElement mapPatternRestElement([Pattern? pattern]) =>
    _RestPatternElement(pattern, location: computeLocation());

Pattern mapPatternWithTypeArguments({
  required String keyType,
  required String valueType,
  required List<MapPatternElement> elements,
}) {
  var location = computeLocation();
  return _MapPattern(
    shared.MapPatternTypeArguments<Type>(
      keyType: Type(keyType),
      valueType: Type(valueType),
    ),
    elements,
    location: location,
  );
}

Statement match(Pattern pattern, Expression initializer,
        {bool isLate = false, bool isFinal = false}) =>
    new _Declare(pattern, initializer,
        isLate: isLate, isFinal: isFinal, location: computeLocation());

Pattern objectPattern({
  required String requiredType,
  required List<RecordPatternField> fields,
}) {
  var parsedType = Type(requiredType);
  if (parsedType is! PrimaryType) {
    fail('Expected a primary type, got $parsedType');
  }
  return _ObjectPattern(
    requiredType: parsedType,
    fields: fields,
    location: computeLocation(),
  );
}

Pattern recordPattern(List<RecordPatternField> fields) =>
    _RecordPattern(fields, location: computeLocation());

Pattern relationalPattern(
    RelationalOperatorResolution<Type>? operator, Expression operand,
    {String? errorId}) {
  var result =
      _RelationalPattern(operator, operand, location: computeLocation());
  if (errorId != null) {
    result.errorId = errorId;
  }
  return result;
}

Statement return_() => new _Return(location: computeLocation());

Statement switch_(Expression expression, List<_SwitchStatementMember> cases,
        {required bool isExhaustive,
        bool? expectHasDefault,
        bool? expectIsExhaustive,
        bool? expectLastCaseTerminates,
        String? expectScrutineeType}) =>
    new _SwitchStatement(expression, cases, isExhaustive,
        location: computeLocation(),
        expectHasDefault: expectHasDefault,
        expectIsExhaustive: expectIsExhaustive,
        expectLastCaseTerminates: expectLastCaseTerminates,
        expectScrutineeType: expectScrutineeType);

Expression switchExpr(Expression expression, List<ExpressionCase> cases) =>
    new _SwitchExpression(expression, cases, location: computeLocation());

_SwitchStatementMember switchStatementMember(
  List<SwitchHead> cases,
  List<Statement> body, {
  bool hasLabels = false,
}) {
  var location = computeLocation();
  return _SwitchStatementMember._(
    cases,
    _Block(body, location: location),
    hasLabels: hasLabels,
    location: computeLocation(),
  );
}

PromotableLValue thisOrSuperProperty(String name) =>
    new _ThisOrSuperProperty(name, location: computeLocation());

Expression throw_(Expression operand) =>
    new _Throw(operand, location: computeLocation());

TryBuilder try_(List<Statement> body) {
  var location = computeLocation();
  return new _TryStatement(_Block(body, location: location), [], null,
      location: location);
}

Statement while_(Expression condition, List<Statement> body) {
  var location = computeLocation();
  return new _While(condition, _Block(body, location: location),
      location: location);
}

Pattern wildcard({String? type, String? expectInferredType}) =>
    _VariablePattern(type == null ? null : Type(type), null, expectInferredType,
        location: computeLocation());

typedef SharedMatchContext
    = shared.MatchContext<Node, Expression, Pattern, Type, Var>;

typedef SharedRecordPatternField = shared.RecordPatternField<Node, Pattern>;

/// Representation of a collection element in the pseudo-Dart language used for
/// type analysis testing.
abstract class CollectionElement extends Node {
  CollectionElement({required super.location}) : super._();

  /// Wraps `this` in such a way that, when the test is run, it will verify that
  /// the IR produced matches [expectedIr].
  CollectionElement checkIr(String expectedIr) =>
      _CheckCollectionElementIr(this, expectedIr, location: computeLocation());

  /// Creates a [Statement] that, when analyzed, will analyze `this`, supplying
  /// [type] as the context (for `List` and `Set` literals).
  Statement inContextElementType(String type) =>
      _CollectionElementInContext(this, _CollectionElementContextType(type),
          location: computeLocation());

  /// Creates a [Statement] that, when analyzed, will analyze `this`, supplying
  /// [keyType] and [valueType] as the context (for `Map` literals).
  Statement inContextMapEntry(String keyType, String valueType) =>
      _CollectionElementInContext(
          this, _CollectionElementContextMapEntry(keyType, valueType),
          location: computeLocation());

  void preVisit(PreVisitor visitor);

  void visit(Harness h, _CollectionElementContext context);
}

/// Representation of an expression in the pseudo-Dart language used for flow
/// analysis testing.  Methods in this class may be used to create more complex
/// expressions based on this one.
abstract class Expression extends Node {
  Expression({required super.location}) : super._();

  /// Creates a [CollectionElement] that, when analyzed, will analyze `this`.
  CollectionElement get asCollectionElement =>
      _ExpressionCollectionElement(this, location: computeLocation());

  /// If `this` is an expression `x`, creates the expression `x!`.
  Expression get nonNullAssert =>
      new _NonNullAssert(this, location: computeLocation());

  /// If `this` is an expression `x`, creates the expression `!x`.
  Expression get not => new _Not(this, location: computeLocation());

  /// If `this` is an expression `x`, creates the expression `(x)`.
  Expression get parenthesized =>
      new _ParenthesizedExpression(this, location: computeLocation());

  Pattern get pattern => _ConstantPattern(this, location: computeLocation());

  /// If `this` is an expression `x`, creates the statement `x;`.
  Statement get stmt =>
      new _ExpressionStatement(this, location: computeLocation());

  /// If `this` is an expression `x`, creates the expression `x && other`.
  Expression and(Expression other) =>
      new _Logical(this, other, isAnd: true, location: computeLocation());

  /// If `this` is an expression `x`, creates the expression `x as typeStr`.
  Expression as_(String typeStr) =>
      new _As(this, Type(typeStr), location: computeLocation());

  /// Wraps `this` in such a way that, when the test is run, it will verify that
  /// the context provided when analyzing the expression matches
  /// [expectedContext].
  Expression checkContext(String expectedContext) =>
      _CheckExpressionContext(this, expectedContext,
          location: computeLocation());

  /// Wraps `this` in such a way that, when the test is run, it will verify that
  /// the IR produced matches [expectedIr].
  Expression checkIr(String expectedIr) =>
      _CheckExpressionIr(this, expectedIr, location: computeLocation());

  /// Creates an [Expression] that, when analyzed, will behave the same as
  /// `this`, but after visiting it, will verify that the type of the expression
  /// was [expectedType].
  Expression checkType(String expectedType) =>
      new _CheckExpressionType(this, expectedType, location: computeLocation());

  /// If `this` is an expression `x`, creates the expression
  /// `x ? ifTrue : ifFalse`.
  Expression conditional(Expression ifTrue, Expression ifFalse) =>
      new _Conditional(this, ifTrue, ifFalse, location: computeLocation());

  /// If `this` is an expression `x`, creates the expression `x == other`.
  Expression eq(Expression other) =>
      new _Equal(this, other, false, location: computeLocation());

  /// If `this` is an expression `x`, creates the expression `x ?? other`.
  Expression ifNull(Expression other) =>
      new _IfNull(this, other, location: computeLocation());

  /// Creates a [Statement] that, when analyzed, will analyze `this`, supplying
  /// a context type of [context].
  Statement inContext(String context) =>
      _ExpressionInContext(this, Type(context), location: computeLocation());

  /// If `this` is an expression `x`, creates the expression `x is typeStr`.
  ///
  /// With [isInverted] set to `true`, creates the expression `x is! typeStr`.
  Expression is_(String typeStr, {bool isInverted = false}) =>
      new _Is(this, Type(typeStr), isInverted, location: computeLocation());

  /// If `this` is an expression `x`, creates the expression `x is! typeStr`.
  Expression isNot(String typeStr) =>
      _Is(this, Type(typeStr), true, location: computeLocation());

  /// If `this` is an expression `x`, creates the expression `x != other`.
  Expression notEq(Expression other) =>
      _Equal(this, other, true, location: computeLocation());

  /// If `this` is an expression `x`, creates the expression `x?.other`.
  ///
  /// Note that in the real Dart language, the RHS of a null aware access isn't
  /// strictly speaking an expression.  However for flow analysis it suffices to
  /// model it as an expression.
  Expression nullAwareAccess(Expression other, {bool isCascaded = false}) =>
      _NullAwareAccess(this, other, isCascaded, location: computeLocation());

  /// If `this` is an expression `x`, creates the expression `x || other`.
  Expression or(Expression other) =>
      new _Logical(this, other, isAnd: false, location: computeLocation());

  void preVisit(PreVisitor visitor);

  /// If `this` is an expression `x`, creates the L-value `x.name`.
  PromotableLValue property(String name) =>
      new _Property(this, name, location: computeLocation());

  /// If `this` is an expression `x`, creates a pseudo-expression that models
  /// evaluation of `x` followed by execution of [stmt].  This can be used to
  /// test that flow analysis is in the correct state after an expression is
  /// visited.
  Expression thenStmt(Statement stmt) =>
      new _WrappedExpression(null, this, stmt, location: computeLocation());

  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context);
}

/// Representation of a single case clause in a switch expression.  Use
/// [caseExpr] to create instances of this class.
class ExpressionCase extends Node {
  final GuardedPattern? guardedPattern;
  final Expression expression;

  ExpressionCase._(this.guardedPattern, this.expression,
      {required super.location})
      : super._();

  @override
  String toString() => [
        guardedPattern == null ? 'default' : 'case $guardedPattern',
        ': $expression'
      ].join('');

  void _preVisit(PreVisitor visitor) {
    var variableBinder = _VariableBinder(errors: visitor.errors);
    variableBinder.casePatternStart();
    guardedPattern?.pattern.preVisit(visitor, variableBinder);
    variableBinder.casePatternFinish();
    variableBinder.finish();
    expression.preVisit(visitor);
  }
}

class GuardedPattern extends Node with PossiblyGuardedPattern {
  final Pattern pattern;
  late final Map<String, Var> variables;
  final Expression? guard;

  GuardedPattern._({
    required this.pattern,
    required this.guard,
    required super.location,
  }) : super._();

  @override
  GuardedPattern get _asGuardedPattern => this;
}

class Harness {
  final MiniAstOperations _operations = MiniAstOperations();

  bool _started = false;

  late final FlowAnalysis<Node, Statement, Expression, Var, Type> flow;

  bool? _patternsEnabled;

  Type? _thisType;

  final Map<String, _PropertyElement> _members = {};

  late final typeAnalyzer = _MiniAstTypeAnalyzer(
      this,
      TypeAnalyzerOptions(
          nullSafetyEnabled: !_operations.legacy,
          patternsEnabled: patternsEnabled));

  /// Indicates whether initializers of implicitly typed variables should be
  /// accounted for by SSA analysis.  (In an ideal world, they always would be,
  /// but due to https://github.com/dart-lang/language/issues/1785, they weren't
  /// always, and we need to be able to replicate the old behavior when
  /// analyzing old language versions).
  bool _respectImplicitlyTypedVarInitializers = true;

  MiniIrBuilder get irBuilder => typeAnalyzer._irBuilder;

  set legacy(bool value) {
    assert(!_started);
    _operations.legacy = value;
  }

  bool get patternsEnabled => _patternsEnabled ?? !_operations.legacy;

  set patternsEnabled(bool value) {
    assert(!_started);
    _patternsEnabled = value;
  }

  set respectImplicitlyTypedVarInitializers(bool value) {
    assert(!_started);
    _respectImplicitlyTypedVarInitializers = value;
  }

  set thisType(String type) {
    assert(!_started);
    _thisType = Type(type);
  }

  /// Updates the harness with a new result for [downwardInfer].
  void addDownwardInfer({
    required String name,
    required String context,
    required String result,
  }) {
    _operations.addDownwardInfer(
      name: name,
      context: context,
      result: result,
    );
  }

  /// Updates the harness so that when a [factor] query is invoked on types
  /// [from] and [what], [result] will be returned.
  void addFactor(String from, String what, String result) {
    _operations.addFactor(from, what, result);
  }

  /// Updates the harness so that when member [memberName] is looked up on type
  /// [targetType], a member is found having the given [type].
  void addMember(String targetType, String memberName, String type,
      {bool promotable = false}) {
    var query = '$targetType.$memberName';
    var member = _PropertyElement(Type(type));
    _members[query] = member;
    if (promotable) {
      _operations.promotableFields.add(member);
    }
  }

  void addPromotionException(String from, String to, String result) {
    _operations.addPromotionException(from, to, result);
  }

  /// Updates the harness so that when an [isSubtypeOf] query is invoked on
  /// types [leftType] and [rightType], [isSubtype] will be returned.
  void addSubtype(String leftType, String rightType, bool isSubtype) {
    _operations.addSubtype(leftType, rightType, isSubtype);
  }

  /// Attempts to look up a member named [memberName] in the given [type].  If
  /// a member is found, returns its [_PropertyElement] object.  Otherwise the
  /// test fails.
  _PropertyElement getMember(Type type, String memberName) {
    var query = '$type.$memberName';
    return _members[query] ?? fail('Unknown member query: $query');
  }

  /// Runs the given [statements] through flow analysis, checking any assertions
  /// they contain.
  void run(List<Statement> statements,
      {bool errorRecoveryOk = false, Set<String> expectedErrors = const {}}) {
    _started = true;
    if (_operations.legacy && patternsEnabled) {
      fail('Patterns cannot be enabled in legacy mode');
    }
    var visitor = PreVisitor(typeAnalyzer.errors);
    var b = _Block(statements, location: computeLocation());
    b.preVisit(visitor);
    flow = _operations.legacy
        ? FlowAnalysis<Node, Statement, Expression, Var, Type>.legacy(
            _operations, visitor._assignedVariables)
        : FlowAnalysis<Node, Statement, Expression, Var, Type>(
            _operations, visitor._assignedVariables,
            respectImplicitlyTypedVarInitializers:
                _respectImplicitlyTypedVarInitializers);
    typeAnalyzer.dispatchStatement(b);
    typeAnalyzer.finish();
    expect(typeAnalyzer.errors._accumulatedErrors, expectedErrors);
    var assertInErrorRecoveryStack =
        typeAnalyzer.errors._assertInErrorRecoveryStack;
    if (!errorRecoveryOk && assertInErrorRecoveryStack != null) {
      fail('assertInErrorRecovery called but no errors reported: '
          '$assertInErrorRecoveryStack');
    }
  }

  Type _getIteratedType(Type iterableType) {
    var typeStr = iterableType.type;
    if (typeStr.startsWith('List<') && typeStr.endsWith('>')) {
      return Type(typeStr.substring(5, typeStr.length - 1));
    } else {
      throw UnimplementedError('TODO(paulberry): getIteratedType($typeStr)');
    }
  }
}

class Label extends Node {
  final String _name;

  late final Node _binding;

  Label(this._name) : super._(location: computeLocation());

  Statement thenStmt(Statement statement) {
    if (statement is! _LabeledStatement) {
      statement = _LabeledStatement(statement, location: computeLocation());
    }
    statement._labels.insert(0, this);
    _binding = statement;
    return statement;
  }

  @override
  String toString() => _name;
}

abstract class ListPatternElement implements _ListOrMapPatternElement {}

/// Representation of an expression that can appear on the left hand side of an
/// assignment (or as the target of `++` or `--`).  Methods in this class may be
/// used to create more complex expressions based on this one.
abstract class LValue extends Expression {
  LValue._({required super.location});

  @override
  void preVisit(PreVisitor visitor, {_LValueDisposition disposition});

  /// Creates an expression representing a write to this L-value.
  Expression write(Expression? value) =>
      new _Write(this, value, location: computeLocation());

  void _visitWrite(Harness h, Expression assignmentExpression, Type writtenType,
      Expression? rhs);
}

abstract class MapPatternElement implements _ListOrMapPatternElement {}

class MiniAstOperations
    with TypeOperations<Type>
    implements Operations<Var, Type> {
  static const Map<String, bool> _coreSubtypes = const {
    'bool <: int': false,
    'bool <: Object': true,
    'double <: bool': false,
    'double <: double?': true,
    'double <: Object': true,
    'double <: Object?': true,
    'double <: Never': false,
    'double <: num': true,
    'double <: num?': true,
    'double <: int': false,
    'double <: int?': false,
    'double <: String': false,
    'dynamic <: int': false,
    'dynamic <: Null': false,
    'dynamic <: Object': false,
    'int <: bool': false,
    'int <: double': false,
    'int <: double?': false,
    'int <: dynamic': true,
    'int <: int?': true,
    'int <: Iterable': false,
    'int <: List': false,
    'int <: Never': false,
    'int <: Null': false,
    'int <: num': true,
    'int <: num?': true,
    'int <: num*': true,
    'int <: Never?': false,
    'int <: Object': true,
    'int <: Object?': true,
    'int <: String': false,
    'int <: ?': true,
    'int? <: int': false,
    'int? <: Null': false,
    'int? <: num': false,
    'int? <: num?': true,
    'int? <: Object': false,
    'int? <: Object?': true,
    'List<int> <: Object': true,
    'Never <: Object': true,
    'Never <: Object?': true,
    'Null <: double?': true,
    'Null <: int': false,
    'Null <: Object': false,
    'Null <: Object?': true,
    'Null <: dynamic': true,
    'num <: double': false,
    'num <: int': false,
    'num <: Iterable': false,
    'num <: List': false,
    'num <: num?': true,
    'num <: num*': true,
    'num <: Object': true,
    'num <: Object?': true,
    'num? <: int?': false,
    'num? <: num': false,
    'num? <: num*': true,
    'num? <: Object': false,
    'num? <: Object?': true,
    'num* <: num': true,
    'num* <: num?': true,
    'num* <: Object': true,
    'num* <: Object?': true,
    'Iterable <: int': false,
    'Iterable <: num': false,
    'Iterable <: Object': true,
    'Iterable <: Object?': true,
    'List <: int': false,
    'List <: Iterable': true,
    'List <: Object': true,
    'List<dynamic> <: Object': true,
    'List<Object?> <: Object': true,
    'List<int> <: dynamic': true,
    'List<int> <: Iterable<double>': false,
    'List<int> <: Iterable<int>': true,
    'List<int> <: List<num>': true,
    'List<int> <: String': false,
    'Map<bool, int> <: Map<Object, num>': true,
    'Never <: int': true,
    'Never <: int?': true,
    'Never <: Null': true,
    'Never? <: int': false,
    'Never? <: int?': true,
    'Never? <: num?': true,
    'Never? <: Object?': true,
    'Null <: int?': true,
    'Object <: int': false,
    'Object <: int?': false,
    'Object <: List': false,
    'Object <: List<Object?>': false,
    'Object <: Null': false,
    'Object <: num': false,
    'Object <: num?': false,
    'Object <: Object?': true,
    'Object <: String': false,
    'Object? <: Object': false,
    'Object? <: int': false,
    'Object? <: int?': false,
    'Object? <: Null': false,
    'String <: int': false,
    'String <: int?': false,
    'String <: List<num>': false,
    'String <: Map<bool, int>': false,
    'String <: num': false,
    'String <: num?': false,
    'String <: Object': true,
    'String <: Object?': true,
    'String? <: Object?': true,
  };

  static final Map<String, Type> _coreFactors = {
    'Object? - double': Type('Object?'),
    'Object? - int': Type('Object?'),
    'Object? - int?': Type('Object'),
    'Object? - Never': Type('Object?'),
    'Object? - Null': Type('Object'),
    'Object? - num?': Type('Object'),
    'Object? - Object?': Type('Never?'),
    'Object? - String': Type('Object?'),
    'Object? - String?': Type('Object?'),
    'Object - bool': Type('Object'),
    'Object - int': Type('Object'),
    'Object - String': Type('Object'),
    'int - Object': Type('Never'),
    'int - String': Type('int'),
    'int - int': Type('Never'),
    'int - int?': Type('Never'),
    'int? - int': Type('Never?'),
    'int? - int?': Type('Never'),
    'int? - String': Type('int?'),
    'Null - int': Type('Null'),
    'num - int': Type('num'),
    'num? - num': Type('Never?'),
    'num? - int': Type('num?'),
    'num? - int?': Type('num'),
    'num? - Object': Type('Never?'),
    'num? - String': Type('num?'),
    'Object - int?': Type('Object'),
    'Object - num': Type('Object'),
    'Object - num?': Type('Object'),
    'Object - num*': Type('Object'),
    'Object - Iterable': Type('Object'),
    'Object? - Object': Type('Never?'),
    'Object? - Iterable': Type('Object?'),
    'Object? - num': Type('Object?'),
    'Iterable - List': Type('Iterable'),
    'num* - Object': Type('Never'),
  };

  static final Map<String, Type> _coreGlbs = {
    'Object?, double': Type('double'),
    'Object?, int': Type('int'),
    'double, int': Type('Never'),
    'double?, int?': Type('Null'),
    'int?, num': Type('int'),
  };

  static final Map<String, Type> _coreLubs = {
    'double, int': Type('num'),
    'double?, int?': Type('num?'),
    'int, num': Type('num'),
    'Never, int': Type('int'),
    'Null, int': Type('int?'),
    '?, int': Type('int'),
    '?, List<?>': Type('List<?>'),
    '?, Null': Type('Null'),
  };

  static final Map<String, Type> _coreDownwardInferenceResults = {
    'dynamic <: int': Type('dynamic'),
    'int <: num': Type('int'),
    'List <: Iterable<int>': Type('List<int>'),
    'Never <: int': Type('Never'),
    'num <: int': Type('num'),
  };

  static final Map<String, Type> _coreNormalizeResults = {
    'Object': Type('Object'),
    'FutureOr<Object>': Type('Object'),
    'int': Type('int'),
    'num': Type('num'),
    'List<int>': Type('List<int>'),
  };

  static final Map<String, bool> _coreAreStructurallyEqualResults = {
    'Object == FutureOr<Object>': false,
    'int == Object': false,
    'int == num': false,
    'num == int': false,
    'List<int> == int': false,
  };

  bool? _legacy;

  final Map<String, bool> _subtypes = Map.of(_coreSubtypes);

  final Map<String, Type> _factorResults = Map.of(_coreFactors);

  final Map<String, Type> _glbs = Map.of(_coreGlbs);

  final Map<String, Type> _lubs = Map.of(_coreLubs);

  final Map<String, Type> _downwardInferenceResults =
      Map.of(_coreDownwardInferenceResults);

  Map<String, Map<String, String>> _promotionExceptions = {};

  Map<String, Type> _normalizeResults = Map.of(_coreNormalizeResults);

  Map<String, bool> _areStructurallyEqualResults =
      Map.of(_coreAreStructurallyEqualResults);

  final Set<_PropertyElement> promotableFields = {};

  bool get legacy => _legacy ?? false;

  set legacy(bool value) {
    _legacy = value;
  }

  /// Updates the harness with a new result for [downwardInfer].
  void addDownwardInfer({
    required String name,
    required String context,
    required String result,
  }) {
    var query = '$name <: $context';
    _downwardInferenceResults[query] = Type(result);
  }

  /// Updates the harness so that when a [factor] query is invoked on types
  /// [from] and [what], [result] will be returned.
  void addFactor(String from, String what, String result) {
    var query = '$from - $what';
    _factorResults[query] = Type(result);
  }

  void addPromotionException(String from, String to, String result) {
    (_promotionExceptions[from] ??= {})[to] = result;
  }

  /// Updates the harness so that when an [isSubtypeOf] query is invoked on
  /// types [leftType] and [rightType], [isSubtype] will be returned.
  void addSubtype(String leftType, String rightType, bool isSubtype) {
    var query = '$leftType <: $rightType';
    _subtypes[query] = isSubtype;
  }

  @override
  bool areStructurallyEqual(Type type1, Type type2) {
    if ('$type1' == '$type2') {
      return true;
    }
    var query = '$type1 == $type2';
    return _areStructurallyEqualResults[query] ?? fail('Unknown query: $query');
  }

  @override
  TypeClassification classifyType(Type type) {
    if (isSubtypeOf(type, Type('Object'))) {
      return TypeClassification.nonNullable;
    } else if (isSubtypeOf(type, Type('Null'))) {
      return TypeClassification.nullOrEquivalent;
    } else {
      return TypeClassification.potentiallyNullable;
    }
  }

  /// Returns the downward inference result of a type with the given [name],
  /// in the [context]. For example infer `List<int>` from `Iterable<int>`.
  Type downwardInfer(String name, Type context) {
    var query = '$name <: $context';
    return _downwardInferenceResults[query] ??
        fail('Unknown downward inference query: $query');
  }

  @override
  Type factor(Type from, Type what) {
    var query = '$from - $what';
    return _factorResults[query] ?? fail('Unknown factor query: $query');
  }

  @override
  Type glb(Type type1, Type type2) {
    if (type1.type == type2.type) return type1;
    var typeNames = [type1.type, type2.type];
    typeNames.sort();
    var query = typeNames.join(', ');
    return _glbs[query] ?? fail('Unknown glb query: $query');
  }

  @override
  bool isAssignableTo(Type fromType, Type toType) {
    if (legacy && isSubtypeOf(toType, fromType)) return true;
    if (fromType.type == 'dynamic') return true;
    return isSubtypeOf(fromType, toType);
  }

  @override
  bool isDynamic(Type type) =>
      type is PrimaryType && type.name == 'dynamic' && type.args.isEmpty;

  @override
  bool isNever(Type type) {
    return type.type == 'Never';
  }

  @override
  bool isPropertyPromotable(Object property) =>
      promotableFields.contains(property);

  @override
  bool isSameType(Type type1, Type type2) {
    return type1.type == type2.type;
  }

  @override
  bool isSubtypeOf(Type leftType, Type rightType) {
    if (leftType.type == rightType.type) return true;
    var query = '$leftType <: $rightType';
    return _subtypes[query] ?? fail('Unknown subtype query: $query');
  }

  @override
  bool isTypeParameterType(Type type) => type is PromotedTypeVariableType;

  @override
  Type lub(Type type1, Type type2) {
    if (type1.type == type2.type) return type1;
    var typeNames = [type1.type, type2.type];
    typeNames.sort();
    var query = typeNames.join(', ');
    return _lubs[query] ?? fail('Unknown lub query: $query');
  }

  @override
  Type makeNullable(Type type) => lub(type, Type('Null'));

  @override
  Type? matchIterableType(Type type) {
    if (type is PrimaryType &&
        type.name == 'Iterable' &&
        type.args.length == 1) {
      return type.args[0];
    }
    return null;
  }

  @override
  Type? matchListType(Type type) {
    if (type is PrimaryType && type.name == 'List' && type.args.length == 1) {
      return type.args[0];
    }
    return null;
  }

  @override
  shared.MapPatternTypeArguments<Type>? matchMapType(Type type) {
    if (type is PrimaryType && type.name == 'Map' && type.args.length == 2) {
      return shared.MapPatternTypeArguments<Type>(
        keyType: type.args[0],
        valueType: type.args[1],
      );
    }
    return null;
  }

  @override
  Type normalize(Type type) {
    var query = '$type';
    return _normalizeResults[query] ?? fail('Unknown query: $query');
  }

  @override
  Type promoteToNonNull(Type type) {
    if (type.type.endsWith('?')) {
      return Type(type.type.substring(0, type.type.length - 1));
    } else if (type.type == 'Null') {
      return Type('Never');
    } else {
      return type;
    }
  }

  @override
  Type? tryPromoteToType(Type to, Type from) {
    var exception = (_promotionExceptions[from.type] ?? {})[to.type];
    if (exception != null) {
      return Type(exception);
    }
    if (isSubtypeOf(to, from)) {
      return to;
    } else {
      return null;
    }
  }

  @override
  Type variableType(Var variable) {
    return variable.type;
  }

  Type _lub(Type type1, Type type2) {
    if (isSameType(type1, type2)) {
      return type1;
    } else if (isSameType(promoteToNonNull(type1), type2)) {
      return type1;
    } else if (isSameType(promoteToNonNull(type2), type1)) {
      return type2;
    } else if (type1.type == 'Null' &&
        !isSameType(promoteToNonNull(type2), type2)) {
      // type2 is already nullable
      return type2;
    } else if (type2.type == 'Null' &&
        !isSameType(promoteToNonNull(type1), type1)) {
      // type1 is already nullable
      return type1;
    } else if (type1.type == 'Never') {
      return type2;
    } else if (type2.type == 'Never') {
      return type1;
    } else {
      throw UnimplementedError(
          'TODO(paulberry): least upper bound of $type1 and $type2');
    }
  }
}

/// Representation of an expression or statement in the pseudo-Dart language
/// used for flow analysis testing.
class Node {
  static int _nextId = 0;

  final int id;

  final String location;

  String? _errorId;

  Node._({required this.location}) : id = _nextId++;

  String get errorId {
    String? errorId = _errorId;
    if (errorId == null) {
      fail('No error ID assigned for $runtimeType $this at $location');
    } else {
      return errorId;
    }
  }

  set errorId(String value) {
    _errorId = value;
  }

  @override
  String toString() => 'Node#$id';
}

abstract class Pattern extends Node
    with PossiblyGuardedPattern
    implements ListPatternElement {
  Pattern._({required super.location}) : super._();

  Pattern get nullAssert =>
      _NullCheckOrAssertPattern(this, true, location: computeLocation());

  Pattern get nullCheck =>
      _NullCheckOrAssertPattern(this, false, location: computeLocation());

  @override
  GuardedPattern get _asGuardedPattern {
    return GuardedPattern._(
      pattern: this,
      guard: null,
      location: location,
    );
  }

  Pattern and(Pattern other) =>
      _LogicalPattern(this, other, isAnd: true, location: computeLocation());

  Pattern as_(String type) =>
      new _CastPattern(this, Type(type), location: computeLocation());

  Type computeSchema(Harness h);

  Pattern or(Pattern other) =>
      _LogicalPattern(this, other, isAnd: false, location: computeLocation());

  RecordPatternField recordField([String? name]) {
    return RecordPatternField(
      name: name,
      pattern: this,
      location: computeLocation(),
    );
  }

  @override
  String toString() => _debugString(needsKeywordOrType: true);

  void visit(
    Harness h,
    Type matchedType,
    SharedMatchContext context,
  );

  GuardedPattern when(Expression? guard) {
    return GuardedPattern._(
      pattern: this,
      guard: guard,
      location: location,
    );
  }
}

class PatternVariableJoin extends Var {
  final List<Var> components;

  @override
  bool isConsistent;

  PatternVariableJoin(
    super.name, {
    required this.components,
    required this.isConsistent,
  });

  @override
  String get stringToCheckVariables {
    return toString();
  }

  @override
  String toString() {
    var isConsistent = this.isConsistent;
    var declarationStr = <String>[
      if (_type != null) ...[
        if (!isConsistent) 'notConsistent',
        if (isFinal) 'final',
        type.type,
      ],
      name,
    ].join(' ');
    var componentsStr = components.map((v) => v._errorId ?? v).join(', ');
    return '$declarationStr = [$componentsStr]';
  }
}

/// Mixin containing logic shared by [Pattern] and [GuardedPattern].  Both of
/// these types can be used in a case where a pattern with an optional guard is
/// expected.
mixin PossiblyGuardedPattern on Node {
  SwitchHead get switchCase {
    return _SwitchHeadCase._(
      _asGuardedPattern,
      location: location,
    );
  }

  /// Converts `this` to a [GuardedPattern], including a `null` guard if
  /// necessary.
  GuardedPattern get _asGuardedPattern;

  _SwitchStatementMember then(List<Statement> body) {
    return _SwitchStatementMember._(
      [
        _SwitchHeadCase._(_asGuardedPattern, location: location),
      ],
      _Block(body, location: location),
      hasLabels: false,
      location: location,
    );
  }

  ExpressionCase thenExpr(Expression body) =>
      ExpressionCase._(_asGuardedPattern, body, location: computeLocation());
}

/// Data structure holding information needed during the "pre-visit" phase of
/// type analysis.
class PreVisitor {
  final AssignedVariables<Node, Var> _assignedVariables =
      AssignedVariables<Node, Var>();

  final VariableBinderErrors<Node, Var>? errors;

  PreVisitor(this.errors);
}

/// Base class for language constructs that, at a given point in flow analysis,
/// might or might not be promoted.
abstract class Promotable {
  /// Makes the appropriate calls to [AssignedVariables] and [VariableBinder]
  /// for this syntactic construct.
  void preVisit(PreVisitor visitor);

  /// Queries the current promotion status of `this`.  Return value is either a
  /// type (if `this` is promoted), or `null` (if it isn't).
  Type? _getPromotedType(Harness h);
}

/// Base class for l-values that, at a given point in flow analysis, might or
/// might not be promoted.
abstract class PromotableLValue extends LValue implements Promotable {
  PromotableLValue._({required super.location}) : super._();
}

/// A field in object and record patterns.
class RecordPatternField extends Node
    implements shared.RecordPatternField<Node, Pattern> {
  @override
  final String? name;
  @override
  final Pattern pattern;

  RecordPatternField({
    required this.name,
    required this.pattern,
    required super.location,
  }) : super._();

  @override
  Node get node => this;
}

/// Representation of a statement in the pseudo-Dart language used for flow
/// analysis testing.
abstract class Statement extends Node {
  Statement({required super.location}) : super._();

  /// Wraps `this` in such a way that, when the test is run, it will verify that
  /// the IR produced matches [expectedIr].
  Statement checkIr(String expectedIr) =>
      _CheckStatementIr(this, expectedIr, location: computeLocation());

  void preVisit(PreVisitor visitor);

  /// If `this` is a statement `x`, creates a pseudo-expression that models
  /// execution of `x` followed by evaluation of [expr].  This can be used to
  /// test that flow analysis is in the correct state before an expression is
  /// visited.
  Expression thenExpr(Expression expr) =>
      _WrappedExpression(this, expr, null, location: computeLocation());

  void visit(Harness h);
}

abstract class SwitchHead extends Node {
  SwitchHead._({required super.location}) : super._();

  _SwitchStatementMember then(List<Statement> body) {
    return _SwitchStatementMember._(
      [this],
      _Block(body, location: location),
      hasLabels: false,
      location: location,
    );
  }

  ExpressionCase thenExpr(Expression body) =>
      ExpressionCase._(null, body, location: computeLocation());
}

abstract class TryBuilder {
  TryStatement catch_(
      {Var? exception, Var? stackTrace, required List<Statement> body});

  Statement finally_(List<Statement> statements);
}

abstract class TryStatement extends Statement implements TryBuilder {
  TryStatement._({required super.location});
}

/// Representation of a local variable in the pseudo-Dart language used for flow
/// analysis testing.
class Var extends Node implements Promotable {
  final String name;
  bool isFinal;

  /// The type of the variable, or `null` if it is not yet known.
  Type? _type;

  Var(this.name, {this.isFinal = false, String? errorId})
      : super._(location: computeLocation()) {
    if (errorId != null) {
      this.errorId = errorId;
    }
  }

  /// Creates an L-value representing a reference to this variable.
  LValue get expr =>
      new _VariableReference(this, null, location: computeLocation());

  bool get isConsistent => true;

  /// The string that should be used to check variables in a set.
  String get stringToCheckVariables => errorId;

  /// Gets the type if known; otherwise throws an exception.
  Type get type {
    if (_type == null) {
      throw 'Type not yet known';
    } else {
      return _type!;
    }
  }

  set type(Type value) {
    if (_type != null) {
      throw 'Type already set';
    }
    _type = value;
  }

  Pattern pattern({String? type, String? expectInferredType}) =>
      new _VariablePattern(
          type == null ? null : Type(type), this, expectInferredType,
          location: computeLocation());

  @override
  void preVisit(PreVisitor visitor) {}

  /// Creates an expression representing a read of this variable, which as a
  /// side effect will call the given callback with the returned promoted type.
  Expression readAndCheckPromotedType(void Function(Type?) callback) =>
      new _VariableReference(this, callback, location: computeLocation());

  @override
  String toString() => 'var $name';

  /// Creates an expression representing a write to this variable.
  Expression write(Expression? value) {
    var location = computeLocation();
    return new _Write(
        new _VariableReference(this, null, location: location), value,
        location: location);
  }

  @override
  Type? _getPromotedType(Harness h) {
    h.irBuilder.atom(name, Kind.expression, location: location);
    return h.flow.promotedType(this);
  }
}

class _As extends Expression {
  final Expression target;
  final Type type;

  _As(this.target, this.type, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    target.preVisit(visitor);
  }

  @override
  String toString() => '$target as $type';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    return h.typeAnalyzer.analyzeTypeCast(this, target, type);
  }
}

class _Assert extends Statement {
  final Expression condition;
  final Expression? message;

  _Assert(this.condition, this.message, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    condition.preVisit(visitor);
    message?.preVisit(visitor);
  }

  @override
  String toString() =>
      'assert($condition${message == null ? '' : ', $message'});';

  @override
  void visit(Harness h) {
    h.typeAnalyzer.analyzeAssertStatement(this, condition, message);
    h.irBuilder.apply(
        'assert', [Kind.expression, Kind.expression], Kind.statement,
        location: location);
  }
}

class _Block extends Statement {
  final List<Statement> statements;

  _Block(this.statements, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    for (var statement in statements) {
      statement.preVisit(visitor);
    }
  }

  @override
  String toString() =>
      statements.isEmpty ? '{}' : '{ ${statements.join(' ')} }';

  @override
  void visit(Harness h) {
    h.typeAnalyzer.analyzeBlock(statements);
    h.irBuilder.apply(
        'block', List.filled(statements.length, Kind.statement), Kind.statement,
        location: location);
  }
}

class _BooleanLiteral extends Expression {
  final bool value;

  _BooleanLiteral(this.value, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {}

  @override
  String toString() => '$value';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var type = h.typeAnalyzer.analyzeBoolLiteral(this, value);
    h.irBuilder.atom('$value', Kind.expression, location: location);
    return new SimpleTypeAnalysisResult<Type>(type: type);
  }
}

class _Break extends Statement {
  final Label? target;

  _Break(this.target, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {}

  @override
  String toString() => 'break;';

  @override
  void visit(Harness h) {
    h.typeAnalyzer.analyzeBreakStatement(target?._binding as Statement?);
    h.irBuilder.apply('break', [], Kind.statement, location: location);
  }
}

class _CastPattern extends Pattern {
  final Pattern _inner;

  final Type _type;

  _CastPattern(this._inner, this._type, {required super.location}) : super._();

  @override
  Type computeSchema(Harness h) => h.typeAnalyzer.analyzeCastPatternSchema();

  @override
  void preVisit(PreVisitor visitor, VariableBinder<Node, Var> variableBinder) {
    _inner.preVisit(visitor, variableBinder);
  }

  @override
  void visit(
    Harness h,
    Type matchedType,
    SharedMatchContext context,
  ) {
    h.typeAnalyzer.analyzeCastPattern(matchedType, context, _inner, _type);
    h.irBuilder.atom(_type.type, Kind.type, location: location);
    h.irBuilder.atom(matchedType.type, Kind.type, location: location);
    h.irBuilder.apply(
        'castPattern', [Kind.pattern, Kind.type, Kind.type], Kind.pattern,
        names: ['matchedType'], location: location);
  }

  @override
  String _debugString({required bool needsKeywordOrType}) =>
      '${_inner._debugString(needsKeywordOrType: needsKeywordOrType)} as '
      '${_type.type}';
}

/// Representation of a single catch clause in a try/catch statement.  Use
/// [catch_] to create instances of this class.
class _CatchClause {
  final Statement _body;
  final Var? _exception;
  final Var? _stackTrace;

  _CatchClause(this._body, this._exception, this._stackTrace);

  @override
  String toString() {
    String initialPart;
    if (_stackTrace != null) {
      initialPart = 'catch (${_exception!.name}, ${_stackTrace!.name})';
    } else if (_exception != null) {
      initialPart = 'catch (${_exception!.name})';
    } else {
      initialPart = 'on ...';
    }
    return '$initialPart $_body';
  }

  void _preVisit(PreVisitor visitor) {
    _body.preVisit(visitor);
  }
}

class _CheckAssigned extends Statement {
  final Var variable;
  final bool expectedAssignedState;

  _CheckAssigned(this.variable, this.expectedAssignedState,
      {required super.location});

  @override
  void preVisit(PreVisitor visitor) {}

  @override
  String toString() {
    var verb = expectedAssignedState ? 'is' : 'is not';
    return 'check $variable $verb definitely assigned;';
  }

  @override
  void visit(Harness h) {
    expect(h.flow.isAssigned(variable), expectedAssignedState,
        reason: 'at $location');
    h.irBuilder.atom('null', Kind.statement, location: location);
  }
}

class _CheckCollectionElementIr extends CollectionElement {
  final CollectionElement inner;

  final String expectedIr;

  _CheckCollectionElementIr(this.inner, this.expectedIr,
      {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    inner.preVisit(visitor);
  }

  @override
  String toString() => '$inner (should produce IR $expectedIr)';

  @override
  void visit(Harness h, _CollectionElementContext context) {
    h.typeAnalyzer.dispatchCollectionElement(inner, context);
    h.irBuilder.check(expectedIr, Kind.collectionElement, location: location);
  }
}

class _CheckExpressionContext extends Expression {
  final Expression inner;

  final String expectedContext;

  _CheckExpressionContext(this.inner, this.expectedContext,
      {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    inner.preVisit(visitor);
  }

  @override
  String toString() => '$inner (should be in context $expectedContext)';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    expect(context.type, expectedContext);
    var result =
        h.typeAnalyzer.analyzeParenthesizedExpression(this, inner, context);
    return result;
  }
}

class _CheckExpressionIr extends Expression {
  final Expression inner;

  final String expectedIr;

  _CheckExpressionIr(this.inner, this.expectedIr, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    inner.preVisit(visitor);
  }

  @override
  String toString() => '$inner (should produce IR $expectedIr)';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var result =
        h.typeAnalyzer.analyzeParenthesizedExpression(this, inner, context);
    h.irBuilder.check(expectedIr, Kind.expression, location: location);
    return result;
  }
}

class _CheckExpressionType extends Expression {
  final Expression target;
  final String expectedType;

  _CheckExpressionType(this.target, this.expectedType,
      {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    target.preVisit(visitor);
  }

  @override
  String toString() => '$target (expected type: $expectedType)';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var result =
        h.typeAnalyzer.analyzeParenthesizedExpression(this, target, context);
    expect(result.type.type, expectedType, reason: 'at $location');
    return result;
  }
}

class _CheckPromoted extends Statement {
  final Promotable promotable;
  final String? expectedTypeStr;

  _CheckPromoted(this.promotable, this.expectedTypeStr,
      {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    promotable.preVisit(visitor);
  }

  @override
  String toString() {
    var predicate = expectedTypeStr == null
        ? 'not promoted'
        : 'promoted to $expectedTypeStr';
    return 'check $promotable $predicate;';
  }

  @override
  void visit(Harness h) {
    var promotedType = promotable._getPromotedType(h);
    expect(promotedType?.type, expectedTypeStr, reason: 'at $location');
    h.irBuilder
        .apply('stmt', [Kind.expression], Kind.statement, location: location);
  }
}

class _CheckReachable extends Statement {
  final bool expectedReachable;

  _CheckReachable(this.expectedReachable, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {}

  @override
  String toString() => 'check reachable;';

  @override
  void visit(Harness h) {
    expect(h.flow.isReachable, expectedReachable, reason: 'at $location');
    h.irBuilder.atom('null', Kind.statement, location: location);
  }
}

class _CheckStatementIr extends Statement {
  final Statement inner;

  final String expectedIr;

  _CheckStatementIr(this.inner, this.expectedIr, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    inner.preVisit(visitor);
  }

  @override
  String toString() => '$inner (should produce IR $expectedIr)';

  @override
  void visit(Harness h) {
    h.typeAnalyzer.dispatchStatement(inner);
    h.irBuilder.check(expectedIr, Kind.statement, location: location);
  }
}

class _CheckUnassigned extends Statement {
  final Var variable;
  final bool expectedUnassignedState;

  _CheckUnassigned(this.variable, this.expectedUnassignedState,
      {required super.location});

  @override
  void preVisit(PreVisitor visitor) {}

  @override
  String toString() {
    var verb = expectedUnassignedState ? 'is' : 'is not';
    return 'check $variable $verb definitely unassigned;';
  }

  @override
  void visit(Harness h) {
    expect(h.flow.isUnassigned(variable), expectedUnassignedState,
        reason: 'at $location');
    h.irBuilder.atom('null', Kind.statement, location: location);
  }
}

abstract class _CollectionElementContext {}

class _CollectionElementContextMapEntry extends _CollectionElementContext {
  final Type keyType;
  final Type valueType;

  _CollectionElementContextMapEntry(String keyType, String valueType)
      : keyType = Type(keyType),
        valueType = Type(valueType);
}

class _CollectionElementContextType extends _CollectionElementContext {
  final Type elementType;

  _CollectionElementContextType(String type) : elementType = Type(type);
}

/// TODO(scheglov) This is a weird statement. We need `ListLiteral`, etc.
class _CollectionElementInContext extends Statement {
  final CollectionElement element;

  final _CollectionElementContext context;

  _CollectionElementInContext(this.element, this.context,
      {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    element.preVisit(visitor);
  }

  @override
  String toString() => '$element (in context $context);';

  @override
  void visit(Harness h) {
    h.typeAnalyzer.dispatchCollectionElement(element, context);
    h.irBuilder.apply('stmt', [Kind.collectionElement], Kind.statement,
        location: location);
  }
}

class _Conditional extends Expression {
  final Expression condition;
  final Expression ifTrue;
  final Expression ifFalse;

  _Conditional(this.condition, this.ifTrue, this.ifFalse,
      {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    condition.preVisit(visitor);
    visitor._assignedVariables.beginNode();
    ifTrue.preVisit(visitor);
    visitor._assignedVariables.endNode(this);
    ifFalse.preVisit(visitor);
  }

  @override
  String toString() => '$condition ? $ifTrue : $ifFalse';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var result = h.typeAnalyzer
        .analyzeConditionalExpression(this, condition, ifTrue, ifFalse);
    h.irBuilder.apply('if', [Kind.expression, Kind.expression, Kind.expression],
        Kind.expression,
        location: location);
    return result;
  }
}

class _ConstantPattern extends Pattern {
  final Expression constant;

  _ConstantPattern(this.constant, {required super.location}) : super._();

  @override
  Type computeSchema(Harness h) =>
      h.typeAnalyzer.analyzeConstantPatternSchema();

  @override
  void preVisit(PreVisitor visitor, VariableBinder<Node, Var> variableBinder) {
    constant.preVisit(visitor);
  }

  @override
  void visit(
    Harness h,
    Type matchedType,
    SharedMatchContext context,
  ) {
    h.typeAnalyzer.analyzeConstantPattern(matchedType, context, this, constant);
    h.irBuilder.atom(matchedType.type, Kind.type, location: location);
    h.irBuilder.apply('const', [Kind.expression, Kind.type], Kind.pattern,
        names: ['matchedType'], location: location);
  }

  @override
  _debugString({required bool needsKeywordOrType}) => constant.toString();
}

class _Continue extends Statement {
  _Continue({required super.location});

  @override
  void preVisit(PreVisitor visitor) {}

  @override
  String toString() => 'continue;';

  @override
  void visit(Harness h) {
    h.typeAnalyzer.analyzeContinueStatement();
    h.irBuilder.apply('continue', [], Kind.statement, location: location);
  }
}

class _Declare extends Statement {
  final bool isLate;
  final bool isFinal;
  final Pattern pattern;
  final Expression? initializer;

  _Declare(this.pattern, this.initializer,
      {required this.isLate, required this.isFinal, required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    var variableBinder = _VariableBinder(errors: visitor.errors);
    variableBinder.casePatternStart();
    pattern.preVisit(visitor, variableBinder);
    variableBinder.casePatternFinish();
    variableBinder.finish();
    if (isLate) {
      visitor._assignedVariables.beginNode();
    }
    initializer?.preVisit(visitor);
    if (isLate) {
      visitor._assignedVariables.endNode(this);
    }
  }

  @override
  String toString() {
    var parts = <String>[
      if (isLate) 'late',
      if (isFinal) 'final',
      pattern._debugString(needsKeywordOrType: !isFinal),
      if (initializer != null) '= $initializer'
    ];
    return '${parts.join(' ')};';
  }

  @override
  void visit(Harness h) {
    String irName;
    List<Kind> argKinds;
    var initializer = this.initializer;
    if (initializer == null) {
      var pattern = this.pattern as _VariablePattern;
      var staticType = h.typeAnalyzer.analyzeUninitializedVariableDeclaration(
          this, pattern.variable!, pattern.declaredType,
          isFinal: isFinal, isLate: isLate);
      h.typeAnalyzer.handleVariablePattern(pattern,
          matchedType: staticType, staticType: staticType);
      irName = 'declare';
      argKinds = [Kind.pattern];
    } else {
      h.typeAnalyzer.analyzePatternVariableDeclarationStatement(
          this, pattern, initializer,
          isFinal: isFinal, isLate: isLate);
      irName = 'match';
      argKinds = [Kind.expression, Kind.pattern];
    }
    h.irBuilder.apply(
        [irName, if (isLate) 'late', if (isFinal) 'final'].join('_'),
        argKinds,
        Kind.statement,
        location: location);
  }
}

class _Do extends Statement {
  final Statement body;
  final Expression condition;

  _Do(this.body, this.condition, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    visitor._assignedVariables.beginNode();
    body.preVisit(visitor);
    condition.preVisit(visitor);
    visitor._assignedVariables.endNode(this);
  }

  @override
  String toString() => 'do $body while ($condition);';

  @override
  void visit(Harness h) {
    h.typeAnalyzer.analyzeDoLoop(this, body, condition);
    h.irBuilder.apply('do', [Kind.statement, Kind.expression], Kind.statement,
        location: location);
  }
}

class _Equal extends Expression {
  final Expression lhs;
  final Expression rhs;
  final bool isInverted;

  _Equal(this.lhs, this.rhs, this.isInverted, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    lhs.preVisit(visitor);
    rhs.preVisit(visitor);
  }

  @override
  String toString() => '$lhs ${isInverted ? '!=' : '=='} $rhs';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var operatorName = isInverted ? '!=' : '==';
    var result =
        h.typeAnalyzer.analyzeBinaryExpression(this, lhs, operatorName, rhs);
    h.irBuilder.apply(
        operatorName, [Kind.expression, Kind.expression], Kind.expression,
        location: location);
    return result;
  }
}

class _ExpressionCollectionElement extends CollectionElement {
  final Expression expression;

  _ExpressionCollectionElement(this.expression, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    expression.preVisit(visitor);
  }

  @override
  String toString() => '$expression;';

  @override
  void visit(Harness h, _CollectionElementContext context) {
    Type contextType = context is _CollectionElementContextType
        ? context.elementType
        : h.typeAnalyzer.unknownType;
    h.typeAnalyzer.dispatchExpression(expression, contextType);
    h.irBuilder.apply('celt', [Kind.expression], Kind.collectionElement,
        location: location);
  }
}

class _ExpressionInContext extends Statement {
  final Expression expr;

  final Type context;

  _ExpressionInContext(this.expr, this.context, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    expr.preVisit(visitor);
  }

  @override
  String toString() => '$expr (in context $context);';

  @override
  void visit(Harness h) {
    h.typeAnalyzer.analyzeExpression(expr, context);
    h.irBuilder
        .apply('stmt', [Kind.expression], Kind.statement, location: location);
  }
}

class _ExpressionStatement extends Statement {
  final Expression expr;

  _ExpressionStatement(this.expr, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    expr.preVisit(visitor);
  }

  @override
  String toString() => '$expr;';

  @override
  void visit(Harness h) {
    h.typeAnalyzer.analyzeExpressionStatement(expr);
    h.irBuilder
        .apply('stmt', [Kind.expression], Kind.statement, location: location);
  }
}

class _For extends Statement {
  final Statement? initializer;
  final Expression? condition;
  final Expression? updater;
  final Statement body;
  final bool forCollection;

  _For(this.initializer, this.condition, this.updater, this.body,
      this.forCollection,
      {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    initializer?.preVisit(visitor);
    visitor._assignedVariables.beginNode();
    condition?.preVisit(visitor);
    body.preVisit(visitor);
    updater?.preVisit(visitor);
    visitor._assignedVariables.endNode(this);
  }

  @override
  String toString() {
    var buffer = StringBuffer('for (');
    if (initializer == null) {
      buffer.write(';');
    } else {
      buffer.write(initializer);
    }
    if (condition == null) {
      buffer.write(';');
    } else {
      buffer.write(' $condition;');
    }
    if (updater != null) {
      buffer.write(' $updater');
    }
    buffer.write(') $body');
    return buffer.toString();
  }

  @override
  void visit(Harness h) {
    if (initializer != null) {
      h.typeAnalyzer.dispatchStatement(initializer!);
    } else {
      h.typeAnalyzer.handleNoInitializer(this);
    }
    h.flow.for_conditionBegin(this);
    if (condition != null) {
      h.typeAnalyzer.analyzeExpression(condition!, h.typeAnalyzer.unknownType);
    } else {
      h.typeAnalyzer.handleNoCondition(this);
    }
    h.flow.for_bodyBegin(forCollection ? null : this, condition);
    h.typeAnalyzer._visitLoopBody(this, body);
    h.flow.for_updaterBegin();
    if (updater != null) {
      h.typeAnalyzer.analyzeExpression(updater!, h.typeAnalyzer.unknownType);
    } else {
      h.typeAnalyzer.handleNoCondition(this);
    }
    h.flow.for_end();
    h.irBuilder.apply(
        'for',
        [Kind.statement, Kind.expression, Kind.statement, Kind.expression],
        Kind.statement,
        location: location);
  }
}

class _ForEach extends Statement {
  final Var? variable;
  final Expression iterable;
  final Statement body;
  final bool declaresVariable;

  _ForEach(this.variable, this.iterable, this.body, this.declaresVariable,
      {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    iterable.preVisit(visitor);
    if (variable != null) {
      if (declaresVariable) {
        visitor._assignedVariables.declare(variable!);
      } else {
        visitor._assignedVariables.write(variable!);
      }
    }
    visitor._assignedVariables.beginNode();
    body.preVisit(visitor);
    visitor._assignedVariables.endNode(this);
  }

  @override
  String toString() {
    String declarationPart;
    if (variable == null) {
      declarationPart = '<identifier>';
    } else if (declaresVariable) {
      declarationPart = variable.toString();
    } else {
      declarationPart = variable!.name;
    }
    return 'for ($declarationPart in $iterable) $body';
  }

  @override
  void visit(Harness h) {
    var iteratedType = h._getIteratedType(
        h.typeAnalyzer.analyzeExpression(iterable, h.typeAnalyzer.unknownType));
    h.flow.forEach_bodyBegin(this);
    var variable = this.variable;
    if (variable != null && !declaresVariable) {
      h.flow.write(this, variable, iteratedType, null);
    }
    h.typeAnalyzer._visitLoopBody(this, body);
    h.flow.forEach_end();
    h.irBuilder.apply(
        'forEach', [Kind.expression, Kind.statement], Kind.statement,
        location: location);
  }
}

class _If extends _IfBase {
  final Expression condition;

  _If(this.condition, super.ifTrue, super.ifFalse, {required super.location});

  @override
  String get _conditionPartString => condition.toString();

  @override
  void preVisit(PreVisitor visitor) {
    condition.preVisit(visitor);
    super.preVisit(visitor);
  }

  @override
  void visit(Harness h) {
    h.typeAnalyzer.analyzeIfStatement(this, condition, ifTrue, ifFalse);
    h.irBuilder.apply(
        'if', [Kind.expression, Kind.statement, Kind.statement], Kind.statement,
        location: location);
  }
}

abstract class _IfBase extends Statement {
  final Statement ifTrue;
  final Statement? ifFalse;

  _IfBase(this.ifTrue, this.ifFalse, {required super.location});

  String get _conditionPartString;

  @override
  void preVisit(PreVisitor visitor) {
    visitor._assignedVariables.beginNode();
    ifTrue.preVisit(visitor);
    visitor._assignedVariables.endNode(this);
    ifFalse?.preVisit(visitor);
  }

  @override
  String toString() =>
      'if ($_conditionPartString) $ifTrue' +
      (ifFalse == null ? '' : 'else $ifFalse');
}

class _IfCase extends _IfBase {
  final Expression _expression;
  final Pattern _pattern;
  final Expression? _guard;

  /// These variables are set during pre-visit, and some of them are joins of
  /// pattern variable declarations. We don't know their types until we do
  /// type analysis. So, some of these variables might become unavailable.
  late final Map<String, Var> _candidateVariables;

  _IfCase(
      this._expression, this._pattern, this._guard, super.ifTrue, super.ifFalse,
      {required super.location});

  @override
  String get _conditionPartString => '$_expression case $_pattern';

  @override
  void preVisit(PreVisitor visitor) {
    _expression.preVisit(visitor);
    var variableBinder = _VariableBinder(errors: visitor.errors);
    variableBinder.casePatternStart();
    _pattern.preVisit(visitor, variableBinder);
    _candidateVariables = variableBinder.casePatternFinish();
    variableBinder.finish();
    _guard?.preVisit(visitor);
    super.preVisit(visitor);
  }

  @override
  void visit(Harness h) {
    h.typeAnalyzer.analyzeIfCaseStatement(this, _expression, _pattern, _guard,
        ifTrue, ifFalse, _candidateVariables);
    h.irBuilder.apply(
      'ifCase',
      [
        Kind.expression,
        Kind.pattern,
        Kind.variables,
        Kind.expression,
        Kind.statement,
        Kind.statement,
      ],
      Kind.statement,
      location: location,
    );
  }
}

class _IfCaseElement extends _IfElementBase {
  final Expression _expression;
  final Pattern _pattern;
  final Expression? _guard;

  _IfCaseElement(
      this._expression, this._pattern, this._guard, super.ifTrue, super.ifFalse,
      {required super.location});

  @override
  String get _conditionPartString => '$_expression case $_pattern';

  @override
  void preVisit(PreVisitor visitor) {
    _expression.preVisit(visitor);
    var variableBinder = _VariableBinder(errors: visitor.errors);
    variableBinder.casePatternStart();
    _pattern.preVisit(visitor, variableBinder);
    variableBinder.casePatternFinish();
    variableBinder.finish();
    _guard?.preVisit(visitor);
    super.preVisit(visitor);
  }

  @override
  void visit(Harness h, Object context) {
    h.typeAnalyzer.analyzeIfCaseElement(
      node: this,
      expression: _expression,
      pattern: _pattern,
      guard: _guard,
      ifTrue: ifTrue,
      ifFalse: ifFalse,
      context: context,
    );
    h.irBuilder.apply(
      'if',
      [
        Kind.expression,
        Kind.pattern,
        Kind.expression,
        Kind.collectionElement,
        Kind.collectionElement,
      ],
      Kind.collectionElement,
      names: ['expression', 'pattern', 'guard', 'ifTrue', 'ifFalse'],
      location: location,
    );
  }
}

class _IfElement extends _IfElementBase {
  final Expression condition;

  _IfElement(this.condition, super.ifTrue, super.ifFalse,
      {required super.location});

  @override
  String get _conditionPartString => condition.toString();

  @override
  void preVisit(PreVisitor visitor) {
    condition.preVisit(visitor);
    super.preVisit(visitor);
  }

  @override
  void visit(Harness h, Object context) {
    h.typeAnalyzer.analyzeIfElement(
      node: this,
      condition: condition,
      ifTrue: ifTrue,
      ifFalse: ifFalse,
      context: context,
    );
    h.irBuilder.apply(
      'if',
      [Kind.expression, Kind.collectionElement, Kind.collectionElement],
      Kind.collectionElement,
      location: location,
    );
  }
}

abstract class _IfElementBase extends CollectionElement {
  final CollectionElement ifTrue;
  final CollectionElement? ifFalse;

  _IfElementBase(this.ifTrue, this.ifFalse, {required super.location});

  String get _conditionPartString;

  @override
  void preVisit(PreVisitor visitor) {
    visitor._assignedVariables.beginNode();
    ifTrue.preVisit(visitor);
    visitor._assignedVariables.endNode(this);
    ifFalse?.preVisit(visitor);
  }

  @override
  String toString() =>
      'if ($_conditionPartString) $ifTrue' +
      (ifFalse == null ? '' : 'else $ifFalse');
}

class _IfNull extends Expression {
  final Expression lhs;
  final Expression rhs;

  _IfNull(this.lhs, this.rhs, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    lhs.preVisit(visitor);
    rhs.preVisit(visitor);
  }

  @override
  String toString() => '$lhs ?? $rhs';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var result = h.typeAnalyzer.analyzeIfNullExpression(this, lhs, rhs);
    h.irBuilder.apply(
        'ifNull', [Kind.expression, Kind.expression], Kind.expression,
        location: location);
    return result;
  }
}

class _IntLiteral extends Expression {
  final int value;

  /// `true` or `false` if we should assert that int->double conversion either
  /// does, or does not, happen.  `null` if no assertion should be done.
  final bool? expectConversionToDouble;

  _IntLiteral(this.value,
      {this.expectConversionToDouble, required super.location});

  @override
  void preVisit(PreVisitor visitor) {}

  @override
  String toString() => '$value';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var result = h.typeAnalyzer.analyzeIntLiteral(context);
    if (expectConversionToDouble != null) {
      expect(result.convertedToDouble, expectConversionToDouble);
    }
    h.irBuilder.atom(
        result.convertedToDouble ? '${value.toDouble()}f' : '$value',
        Kind.expression,
        location: location);
    return result;
  }
}

class _Is extends Expression {
  final Expression target;
  final Type type;
  final bool isInverted;

  _Is(this.target, this.type, this.isInverted, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    target.preVisit(visitor);
  }

  @override
  String toString() => '$target is${isInverted ? '!' : ''} $type';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    return h.typeAnalyzer
        .analyzeTypeTest(this, target, type, isInverted: isInverted);
  }
}

class _LabeledStatement extends Statement {
  final List<Label> _labels = [];

  final Statement _body;

  _LabeledStatement(this._body, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    _body.preVisit(visitor);
  }

  @override
  String toString() => [..._labels, _body].join(': ');

  @override
  void visit(Harness h) {
    h.typeAnalyzer.analyzeLabeledStatement(this, _body);
  }
}

abstract class _ListOrMapPatternElement implements Node {
  void preVisit(PreVisitor visitor, VariableBinder<Node, Var> variableBinder);

  String _debugString({required bool needsKeywordOrType});
}

class _ListPattern extends Pattern {
  final Type? _elementType;

  final List<ListPatternElement> _elements;

  _ListPattern(this._elementType, this._elements, {required super.location})
      : super._();

  @override
  Type computeSchema(Harness h) => h.typeAnalyzer
      .analyzeListPatternSchema(elementType: _elementType, elements: _elements);

  @override
  void preVisit(PreVisitor visitor, VariableBinder<Node, Var> variableBinder) {
    for (var element in _elements) {
      element.preVisit(visitor, variableBinder);
    }
  }

  @override
  void visit(
    Harness h,
    Type matchedType,
    SharedMatchContext context,
  ) {
    var requiredType = h.typeAnalyzer.analyzeListPattern(
        matchedType, context, this,
        elementType: _elementType, elements: _elements);
    h.irBuilder.atom(matchedType.type, Kind.type, location: location);
    h.irBuilder.atom(requiredType.type, Kind.type, location: location);
    h.irBuilder.apply(
        'listPattern',
        [...List.filled(_elements.length, Kind.pattern), Kind.type, Kind.type],
        Kind.pattern,
        names: ['matchedType', 'requiredType'],
        location: location);
  }

  @override
  String _debugString({required bool needsKeywordOrType}) {
    var elements = [
      for (var element in _elements)
        element._debugString(needsKeywordOrType: needsKeywordOrType)
    ];
    return '[${elements.join(', ')}]';
  }
}

class _LocalFunction extends Statement {
  final Statement body;

  _LocalFunction(this.body, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    visitor._assignedVariables.beginNode();
    body.preVisit(visitor);
    visitor._assignedVariables
        .endNode(this, isClosureOrLateVariableInitializer: true);
  }

  @override
  String toString() => '() $body';

  @override
  void visit(Harness h) {
    h.flow.functionExpression_begin(this);
    h.typeAnalyzer.dispatchStatement(body);
    h.flow.functionExpression_end();
  }
}

class _Logical extends Expression {
  final Expression lhs;
  final Expression rhs;
  final bool isAnd;

  _Logical(this.lhs, this.rhs, {required this.isAnd, required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    lhs.preVisit(visitor);
    visitor._assignedVariables.beginNode();
    rhs.preVisit(visitor);
    visitor._assignedVariables.endNode(this);
  }

  @override
  String toString() => '$lhs ${isAnd ? '&&' : '||'} $rhs';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var operatorName = isAnd ? '&&' : '||';
    var result =
        h.typeAnalyzer.analyzeBinaryExpression(this, lhs, operatorName, rhs);
    h.irBuilder.apply(
        operatorName, [Kind.expression, Kind.expression], Kind.expression,
        location: location);
    return result;
  }
}

class _LogicalPattern extends Pattern {
  final Pattern _lhs;

  final Pattern _rhs;

  final bool isAnd;

  _LogicalPattern(this._lhs, this._rhs,
      {required this.isAnd, required super.location})
      : super._();

  @override
  Type computeSchema(Harness h) =>
      h.typeAnalyzer.analyzeLogicalPatternSchema(_lhs, _rhs, isAnd: isAnd);

  @override
  void preVisit(PreVisitor visitor, VariableBinder<Node, Var> variableBinder) {
    if (isAnd) {
      _lhs.preVisit(visitor, variableBinder);
      _rhs.preVisit(visitor, variableBinder);
    } else {
      variableBinder.logicalOrPatternStart();
      _lhs.preVisit(visitor, variableBinder);
      variableBinder.logicalOrPatternFinishLeft();
      _rhs.preVisit(visitor, variableBinder);
      variableBinder.logicalOrPatternFinish(this);
    }
  }

  @override
  void visit(
    Harness h,
    Type matchedType,
    SharedMatchContext context,
  ) {
    h.typeAnalyzer.analyzeLogicalPattern(matchedType, context, this, _lhs, _rhs,
        isAnd: isAnd);
    h.irBuilder.atom(matchedType.type, Kind.type, location: location);
    h.irBuilder.apply(isAnd ? 'logicalAndPattern' : 'logicalOrPattern',
        [Kind.pattern, Kind.pattern, Kind.type], Kind.pattern,
        names: ['matchedType'], location: location);
  }

  @override
  _debugString({required bool needsKeywordOrType}) => [
        _lhs._debugString(needsKeywordOrType: false),
        isAnd ? '&' : '|',
        _rhs._debugString(needsKeywordOrType: false)
      ].join(' ');
}

/// Enum representing the different ways an [LValue] might be used.
enum _LValueDisposition {
  /// The [LValue] is being read from only, not written to.  This happens if it
  /// appears in a place where an ordinary expression is expected.
  read,

  /// The [LValue] is being written to only, not read from.  This happens if it
  /// appears on the left hand side of `=`.
  write,

  /// The [LValue] is being both read from and written to.  This happens if it
  /// appears on the left and side of `op=` (where `op` is some operator), or as
  /// the target of `++` or `--`.
  readWrite,
}

class _MapPattern extends Pattern {
  final shared.MapPatternTypeArguments<Type>? _typeArguments;

  final List<MapPatternElement> _elements;

  _MapPattern(this._typeArguments, this._elements, {required super.location})
      : super._();

  @override
  Type computeSchema(Harness h) => h.typeAnalyzer.analyzeMapPatternSchema(
      typeArguments: _typeArguments, elements: _elements);

  @override
  void preVisit(PreVisitor visitor, VariableBinder<Node, Var> variableBinder) {
    for (var element in _elements) {
      element.preVisit(visitor, variableBinder);
    }
  }

  @override
  void visit(Harness h, Type matchedType, SharedMatchContext context) {
    var requiredType = h.typeAnalyzer.analyzeMapPattern(
        matchedType, context, this,
        typeArguments: _typeArguments, elements: _elements);
    h.irBuilder.atom(matchedType.type, Kind.type, location: location);
    h.irBuilder.atom(requiredType.type, Kind.type, location: location);
    h.irBuilder.apply(
      'mapPattern',
      [
        ...List.filled(_elements.length, Kind.mapPatternElement),
        Kind.type,
        Kind.type,
      ],
      Kind.pattern,
      names: ['matchedType', 'requiredType'],
      location: location,
    );
  }

  @override
  String _debugString({required bool needsKeywordOrType}) {
    var elements = [
      for (var element in _elements)
        element._debugString(needsKeywordOrType: needsKeywordOrType)
    ];
    return '[${elements.join(', ')}]';
  }
}

class _MapPatternEntry extends Node implements MapPatternElement {
  final Expression key;
  final Pattern value;

  _MapPatternEntry(this.key, this.value, {required super.location}) : super._();

  @override
  void preVisit(PreVisitor visitor, VariableBinder<Node, Var> variableBinder) {
    value.preVisit(visitor, variableBinder);
  }

  @override
  String _debugString({required bool needsKeywordOrType}) {
    return '$key: $value';
  }
}

class _MiniAstErrors
    implements
        TypeAnalyzerErrors<Node, Statement, Expression, Var, Type, Pattern>,
        VariableBinderErrors<Node, Var> {
  final Set<String> _accumulatedErrors = {};

  /// If [assertInErrorRecovery] is called prior to any errors being reported,
  /// the stack trace is captured and stored in this variable, so that if no
  /// errors are reported by the end of running the test, we can use it to
  /// highlight the point of failure.
  StackTrace? _assertInErrorRecoveryStack;

  @override
  void argumentTypeNotAssignable({
    required Expression argument,
    required Type argumentType,
    required Type parameterType,
  }) {
    _recordError(
      'argumentTypeNotAssignable(argument: ${argument.errorId}, '
      'argumentType: ${argumentType.type}, '
      'parameterType: ${parameterType.type})',
    );
  }

  @override
  void assertInErrorRecovery() {
    if (_accumulatedErrors.isEmpty) {
      _assertInErrorRecoveryStack ??= StackTrace.current;
    }
  }

  @override
  void caseExpressionTypeMismatch(
      {required Expression scrutinee,
      required Expression caseExpression,
      required scrutineeType,
      required caseExpressionType,
      required bool nullSafetyEnabled}) {
    _recordError('caseExpressionTypeMismatch(scrutinee: ${scrutinee.errorId}, '
        'caseExpression: ${caseExpression.errorId}, '
        'scrutineeType: ${scrutineeType.type}, '
        'caseExpressionType: ${caseExpressionType.type}, '
        'nullSafetyEnabled: $nullSafetyEnabled)');
  }

  @override
  void duplicateRecordPatternField({
    required String name,
    required covariant RecordPatternField original,
    required covariant RecordPatternField duplicate,
  }) {
    _recordError(
      'duplicateRecordPatternField(name: $name, '
      'original: ${original.errorId}, duplicate: ${duplicate.errorId})',
    );
  }

  @override
  void duplicateVariablePattern({
    required String name,
    required Var original,
    required Var duplicate,
  }) {
    _recordError(
      'duplicateVariablePattern(name: $name, original: ${original.errorId}, '
      'duplicate: ${duplicate.errorId})',
    );
  }

  @override
  void inconsistentJoinedPatternVariable({
    required covariant PatternVariableJoin variable,
    required Var component,
  }) {
    _recordError(
      'inconsistentJoinedPatternVariable(variable: $variable, '
      'component: ${component.errorId})',
    );
  }

  @override
  void logicalOrPatternBranchMissingVariable({
    required Node node,
    required bool hasInLeft,
    required String name,
    required Var variable,
  }) {
    _recordError(
      'logicalOrPatternBranchMissingVariable(node: ${node.errorId}, '
      'hasInLeft: $hasInLeft, name: $name, variable: ${variable.errorId})',
    );
  }

  @override
  void nonBooleanCondition(Expression node) {
    _recordError('nonBooleanCondition(${node.errorId})');
  }

  @override
  void patternDoesNotAllowLate(Node pattern) {
    _recordError('patternDoesNotAllowLate(${pattern.errorId})');
  }

  @override
  void patternTypeMismatchInIrrefutableContext(
      {required Node pattern,
      required Node context,
      required Type matchedType,
      required Type requiredType}) {
    _recordError(
        'patternTypeMismatchInIrrefutableContext(pattern: ${pattern.errorId}, '
        'context: ${context.errorId}, matchedType: ${matchedType.type}, '
        'requiredType: ${requiredType.type})');
  }

  @override
  void refutablePatternInIrrefutableContext(Node pattern, Node context) {
    _recordError('refutablePatternInIrrefutableContext(${pattern.errorId}, '
        '${context.errorId})');
  }

  @override
  void relationalPatternOperatorReturnTypeNotAssignableToBool({
    required Node node,
    required Type returnType,
  }) {
    _recordError(
      'relationalPatternOperatorReturnTypeNotAssignableToBool('
      'node: ${node.errorId}, '
      'returnType: ${returnType.type})',
    );
  }

  @override
  void switchCaseCompletesNormally(
      covariant _SwitchStatement node, int caseIndex, int numHeads) {
    _recordError(
        'switchCaseCompletesNormally(${node.errorId}, $caseIndex, $numHeads)');
  }

  void _recordError(String errorText) {
    _assertInErrorRecoveryStack = null;
    if (!_accumulatedErrors.add(errorText)) {
      fail('Same error reported twice: $errorText');
    }
  }
}

class _MiniAstTypeAnalyzer
    with TypeAnalyzer<Node, Statement, Expression, Var, Type, Pattern> {
  final Harness _harness;

  @override
  final _MiniAstErrors errors = _MiniAstErrors();

  Statement? _currentBreakTarget;

  Statement? _currentContinueTarget;

  final _irBuilder = MiniIrBuilder();

  @override
  late final Type boolType = Type('bool');

  @override
  late final Type doubleType = Type('double');

  @override
  late final Type dynamicType = Type('dynamic');

  @override
  late final Type intType = Type('int');

  late final Type neverType = Type('Never');

  late final Type nullType = Type('Null');

  @override
  late final Type objectQuestionType = Type('Object?');

  @override
  late final Type unknownType = Type('?');

  @override
  final TypeAnalyzerOptions options;

  _MiniAstTypeAnalyzer(this._harness, this.options);

  @override
  FlowAnalysis<Node, Statement, Expression, Var, Type> get flow =>
      _harness.flow;

  Type get thisType => _harness._thisType!;

  @override
  MiniAstOperations get typeOperations => _harness._operations;

  void analyzeAssertStatement(
      Statement node, Expression condition, Expression? message) {
    flow.assert_begin();
    analyzeExpression(condition, unknownType);
    flow.assert_afterCondition(condition);
    if (message != null) {
      analyzeExpression(message, unknownType);
    } else {
      handleNoMessage(node);
    }
    flow.assert_end();
  }

  SimpleTypeAnalysisResult<Type> analyzeBinaryExpression(
      Expression node, Expression lhs, String operatorName, Expression rhs) {
    bool isEquals = false;
    bool isNot = false;
    bool isLogical = false;
    bool isAnd = false;
    switch (operatorName) {
      case '==':
        isEquals = true;
        break;
      case '!=':
        isEquals = true;
        isNot = true;
        operatorName = '==';
        break;
      case '&&':
        isLogical = true;
        isAnd = true;
        break;
      case '||':
        isLogical = true;
        break;
    }
    if (operatorName == '==') {
      isEquals = true;
    } else if (operatorName == '!=') {
      isEquals = true;
      isNot = true;
      operatorName = '==';
    }
    if (isLogical) {
      flow.logicalBinaryOp_begin();
    }
    var leftType = analyzeExpression(lhs, unknownType);
    EqualityInfo<Type>? leftInfo;
    if (isEquals) {
      leftInfo = flow.equalityOperand_end(lhs, leftType);
    } else if (isLogical) {
      flow.logicalBinaryOp_rightBegin(lhs, node, isAnd: isAnd);
    }
    var rightType = analyzeExpression(rhs, unknownType);
    if (isEquals) {
      flow.equalityOperation_end(
          node, leftInfo, flow.equalityOperand_end(rhs, rightType),
          notEqual: isNot);
    } else if (isLogical) {
      flow.logicalBinaryOp_end(node, rhs, isAnd: isAnd);
    }
    return new SimpleTypeAnalysisResult<Type>(type: boolType);
  }

  void analyzeBlock(Iterable<Statement> statements) {
    for (var statement in statements) {
      dispatchStatement(statement);
    }
  }

  Type analyzeBoolLiteral(Expression node, bool value) {
    flow.booleanLiteral(node, value);
    return boolType;
  }

  void analyzeBreakStatement(Statement? target) {
    flow.handleBreak(target ?? _currentBreakTarget!);
  }

  SimpleTypeAnalysisResult<Type> analyzeConditionalExpression(Expression node,
      Expression condition, Expression ifTrue, Expression ifFalse) {
    flow.conditional_conditionBegin();
    analyzeExpression(condition, unknownType);
    flow.conditional_thenBegin(condition, node);
    var ifTrueType = analyzeExpression(ifTrue, unknownType);
    flow.conditional_elseBegin(ifTrue);
    var ifFalseType = analyzeExpression(ifFalse, unknownType);
    flow.conditional_end(node, ifFalse);
    return new SimpleTypeAnalysisResult<Type>(
        type: leastUpperBound(ifTrueType, ifFalseType));
  }

  void analyzeContinueStatement() {
    flow.handleContinue(_currentContinueTarget!);
  }

  void analyzeDoLoop(Statement node, Statement body, Expression condition) {
    flow.doStatement_bodyBegin(node);
    _visitLoopBody(node, body);
    flow.doStatement_conditionBegin();
    analyzeExpression(condition, unknownType);
    flow.doStatement_end(condition);
  }

  void analyzeExpressionStatement(Expression expression) {
    analyzeExpression(expression, unknownType);
  }

  SimpleTypeAnalysisResult<Type> analyzeIfNullExpression(
      Expression node, Expression lhs, Expression rhs) {
    var leftType = analyzeExpression(lhs, unknownType);
    flow.ifNullExpression_rightBegin(lhs, leftType);
    var rightType = analyzeExpression(rhs, unknownType);
    flow.ifNullExpression_end();
    return new SimpleTypeAnalysisResult<Type>(
        type: leastUpperBound(
            flow.operations.promoteToNonNull(leftType), rightType));
  }

  void analyzeLabeledStatement(Statement node, Statement body) {
    flow.labeledStatement_begin(node);
    dispatchStatement(body);
    flow.labeledStatement_end();
  }

  SimpleTypeAnalysisResult<Type> analyzeLogicalNot(
      Expression node, Expression expression) {
    analyzeExpression(expression, unknownType);
    flow.logicalNot_end(node, expression);
    return new SimpleTypeAnalysisResult<Type>(type: boolType);
  }

  SimpleTypeAnalysisResult<Type> analyzeNonNullAssert(
      Expression node, Expression expression) {
    var type = analyzeExpression(expression, unknownType);
    flow.nonNullAssert_end(expression);
    return new SimpleTypeAnalysisResult<Type>(
        type: flow.operations.promoteToNonNull(type));
  }

  SimpleTypeAnalysisResult<Type> analyzeNullLiteral(Expression node) {
    flow.nullLiteral(node);
    return new SimpleTypeAnalysisResult<Type>(type: nullType);
  }

  SimpleTypeAnalysisResult<Type> analyzeParenthesizedExpression(
      Expression node, Expression expression, Type context) {
    var type = analyzeExpression(expression, context);
    flow.parenthesizedExpression(node, expression);
    return new SimpleTypeAnalysisResult<Type>(type: type);
  }

  ExpressionTypeAnalysisResult<Type> analyzePropertyGet(
      Expression node, Expression receiver, String propertyName) {
    var receiverType = analyzeExpression(receiver, unknownType);
    var member = _lookupMember(node, receiverType, propertyName);
    var promotedType =
        flow.propertyGet(node, receiver, propertyName, member, member._type);
    // TODO(paulberry): handle null shorting
    return new SimpleTypeAnalysisResult<Type>(
        type: promotedType ?? member._type);
  }

  void analyzeReturnStatement() {
    flow.handleExit();
  }

  SimpleTypeAnalysisResult<Type> analyzeThis(Expression node) {
    var thisType = this.thisType;
    flow.thisOrSuper(node, thisType);
    return new SimpleTypeAnalysisResult<Type>(type: thisType);
  }

  SimpleTypeAnalysisResult<Type> analyzeThisPropertyGet(
      Expression node, String propertyName) {
    var member = _lookupMember(node, thisType, propertyName);
    var promotedType =
        flow.thisOrSuperPropertyGet(node, propertyName, member, member._type);
    return new SimpleTypeAnalysisResult<Type>(
        type: promotedType ?? member._type);
  }

  SimpleTypeAnalysisResult<Type> analyzeThrow(
      Expression node, Expression expression) {
    analyzeExpression(expression, unknownType);
    flow.handleExit();
    return new SimpleTypeAnalysisResult<Type>(type: neverType);
  }

  void analyzeTryStatement(Statement node, Statement body,
      Iterable<_CatchClause> catchClauses, Statement? finallyBlock) {
    if (finallyBlock != null) {
      flow.tryFinallyStatement_bodyBegin();
    }
    if (catchClauses.isNotEmpty) {
      flow.tryCatchStatement_bodyBegin();
    }
    dispatchStatement(body);
    if (catchClauses.isNotEmpty) {
      flow.tryCatchStatement_bodyEnd(body);
      for (var catch_ in catchClauses) {
        flow.tryCatchStatement_catchBegin(
            catch_._exception, catch_._stackTrace);
        dispatchStatement(catch_._body);
        flow.tryCatchStatement_catchEnd();
      }
      flow.tryCatchStatement_end();
    }
    if (finallyBlock != null) {
      flow.tryFinallyStatement_finallyBegin(
          catchClauses.isNotEmpty ? node : body);
      dispatchStatement(finallyBlock);
      flow.tryFinallyStatement_end();
    } else {
      handleNoStatement(node);
    }
  }

  SimpleTypeAnalysisResult<Type> analyzeTypeCast(
      Expression node, Expression expression, Type type) {
    analyzeExpression(expression, unknownType);
    flow.asExpression_end(expression, type);
    return new SimpleTypeAnalysisResult<Type>(type: type);
  }

  SimpleTypeAnalysisResult<Type> analyzeTypeTest(
      Expression node, Expression expression, Type type,
      {bool isInverted = false}) {
    analyzeExpression(expression, unknownType);
    flow.isExpression_end(node, expression, isInverted, type);
    return new SimpleTypeAnalysisResult<Type>(type: boolType);
  }

  SimpleTypeAnalysisResult<Type> analyzeVariableGet(
      Expression node, Var variable, void Function(Type?)? callback) {
    var promotedType = flow.variableRead(node, variable);
    callback?.call(promotedType);
    return new SimpleTypeAnalysisResult<Type>(
        type: promotedType ?? variable.type);
  }

  void analyzeWhileLoop(Statement node, Expression condition, Statement body) {
    flow.whileStatement_conditionBegin(node);
    analyzeExpression(condition, unknownType);
    flow.whileStatement_bodyBegin(node, condition);
    _visitLoopBody(node, body);
    flow.whileStatement_end();
  }

  @override
  shared.RecordType<Type>? asRecordType(Type type) {
    if (type is RecordType) {
      return shared.RecordType<Type>(
        positional: type.positional,
        named: type.named.map((namedType) {
          return shared.NamedType(
            namedType.name,
            namedType.type,
          );
        }).toList(),
      );
    }
    return null;
  }

  @override
  void dispatchCollectionElement(
    covariant CollectionElement element,
    covariant _CollectionElementContext context,
  ) {
    _irBuilder.guard(element, () => element.visit(_harness, context));
  }

  @override
  ExpressionTypeAnalysisResult<Type> dispatchExpression(
          Expression expression, Type context) =>
      _irBuilder.guard(expression, () => expression.visit(_harness, context));

  @override
  void dispatchPattern(
      Type matchedType, SharedMatchContext context, covariant Pattern node) {
    return node.visit(_harness, matchedType, context);
  }

  @override
  Type dispatchPatternSchema(covariant Pattern node) {
    return node.computeSchema(_harness);
  }

  @override
  void dispatchStatement(Statement statement) =>
      _irBuilder.guard(statement, () => statement.visit(_harness));

  @override
  Type downwardInferObjectPatternRequiredType({
    required Type matchedType,
    required covariant _ObjectPattern pattern,
  }) {
    var requiredType = pattern.requiredType;
    if (requiredType.args.isNotEmpty) {
      return requiredType;
    } else {
      return typeOperations.downwardInfer(requiredType.name, matchedType);
    }
  }

  void finish() {
    flow.finish();
  }

  @override
  void finishExpressionCase(Expression node, int caseIndex) {
    _irBuilder.apply(
        'case', [Kind.caseHead, Kind.expression], Kind.expressionCase,
        location: node.location);
  }

  @override
  void finishJoinedPatternVariable(
    covariant PatternVariableJoin variable, {
    required bool isConsistent,
    required bool isFinal,
    required Type type,
  }) {
    variable.isFinal = isFinal;
    variable.type = type;
    if (!isConsistent) {
      variable.isConsistent = false;
    }
  }

  @override
  List<Var>? getJoinedVariableComponents(Var variable) {
    if (variable is PatternVariableJoin) {
      return variable.components;
    }
    return null;
  }

  @override
  shared.MapPatternEntry<Expression, Pattern>? getMapPatternEntry(
      Node element) {
    if (element is _MapPatternEntry) {
      return shared.MapPatternEntry<Expression, Pattern>(
        key: element.key,
        value: element.value,
      );
    }
    return null;
  }

  @override
  Pattern? getRestPatternElementPattern(Node element) {
    return element is _RestPatternElement ? element._pattern : null;
  }

  @override
  SwitchExpressionMemberInfo<Node, Expression, Var>
      getSwitchExpressionMemberInfo(
          covariant _SwitchExpression node, int index) {
    var case_ = node.cases[index];
    return SwitchExpressionMemberInfo(
      head: CaseHeadOrDefaultInfo(
        pattern: case_.guardedPattern?.pattern,
        variables: {}, // TODO(scheglov) provide it
        guard: case_.guardedPattern?.guard,
      ),
      expression: case_.expression,
    );
  }

  @override
  SwitchStatementMemberInfo<Node, Statement, Expression, Var>
      getSwitchStatementMemberInfo(
          covariant _SwitchStatement node, int caseIndex) {
    _SwitchStatementMember case_ = node.cases[caseIndex];
    return SwitchStatementMemberInfo(
      [
        for (var element in case_.elements)
          if (element is _SwitchHeadCase)
            CaseHeadOrDefaultInfo(
              pattern: element.guardedPattern.pattern,
              variables: element.guardedPattern.variables,
              guard: element.guardedPattern.guard,
            )
          else
            CaseHeadOrDefaultInfo(
              pattern: null,
              variables: {},
              guard: null,
            )
      ],
      case_._body.statements,
      case_._candidateVariables,
      hasLabels: case_.hasLabels,
    );
  }

  @override
  Type getVariableType(Var node) {
    return node.type;
  }

  @override
  void handle_ifCaseStatement_afterPattern({
    required covariant _IfCase node,
    required Iterable<Var> variables,
  }) {
    var variableList = variables.toList();
    for (var variable in variableList) {
      _irBuilder.atom(variable.stringToCheckVariables, Kind.variable,
          location: variable.location);
    }
    _irBuilder.apply(
      'variables',
      List.filled(variableList.length, Kind.variable),
      Kind.variables,
      location: node.location,
    );
  }

  @override
  void handleCase_afterCaseHeads(
      covariant _SwitchStatement node, int caseIndex, Iterable<Var> variables) {
    var case_ = node.cases[caseIndex];

    for (var variable in variables) {
      _irBuilder.atom(variable.stringToCheckVariables, Kind.variable,
          location: variable.location);
    }
    _irBuilder.apply(
      'variables',
      List.filled(variables.length, Kind.variable),
      Kind.variables,
      location: node.location,
    );
    _irBuilder.apply(
      'heads',
      [
        ...List.filled(case_.elements.length, Kind.caseHead),
        Kind.variables,
      ],
      Kind.caseHeads,
      location: node.location,
    );
  }

  @override
  void handleCaseHead(Node node,
      {required int caseIndex, required int subIndex}) {
    _irBuilder.apply('head', [Kind.pattern, Kind.expression], Kind.caseHead,
        location: node.location);
  }

  @override
  void handleDefault(Node node, int caseIndex) {
    _irBuilder.atom('default', Kind.caseHead, location: node.location);
  }

  @override
  void handleListPatternRestElement(
    Pattern container,
    covariant _RestPatternElement restElement,
  ) {
    if (restElement._pattern != null) {
      _irBuilder.apply('...', [Kind.pattern], Kind.pattern,
          location: restElement.location);
    } else {
      _irBuilder.atom('...', Kind.pattern, location: restElement.location);
    }
  }

  @override
  void handleMapPatternEntry(Pattern container, Node entryElement) {
    _irBuilder.apply('mapPatternEntry', [Kind.expression, Kind.pattern],
        Kind.mapPatternElement,
        location: entryElement.location);
  }

  @override
  void handleMapPatternRestElement(
    Pattern container,
    covariant _RestPatternElement restElement,
  ) {
    if (restElement._pattern != null) {
      _irBuilder.apply('...', [Kind.pattern], Kind.mapPatternElement,
          location: restElement.location);
    } else {
      _irBuilder.atom('...', Kind.mapPatternElement,
          location: restElement.location);
    }
  }

  @override
  void handleMergedStatementCase(
    covariant _SwitchStatement node, {
    required int caseIndex,
  }) {
    var numStatements = node.cases[caseIndex]._body.statements.length;
    _irBuilder.apply(
        'block', List.filled(numStatements, Kind.statement), Kind.statement,
        location: node.location);
    _irBuilder.apply(
        'case', [Kind.caseHeads, Kind.statement], Kind.statementCase,
        location: node.location);
  }

  @override
  void handleNoCollectionElement(Node node) {
    _irBuilder.atom('noop', Kind.collectionElement, location: node.location);
  }

  void handleNoCondition(Node node) {
    _irBuilder.atom('true', Kind.expression, location: node.location);
  }

  @override
  void handleNoGuard(Node node, int caseIndex) {
    _irBuilder.atom('true', Kind.expression, location: node.location);
  }

  void handleNoInitializer(Node node) {
    _irBuilder.atom('uninitialized', Kind.statement, location: node.location);
  }

  void handleNoMessage(Node node) {
    _irBuilder.atom('failure', Kind.expression, location: node.location);
  }

  @override
  void handleNoStatement(Node node) {
    _irBuilder.atom('noop', Kind.statement, location: node.location);
  }

  @override
  void handleSwitchScrutinee(Type type) {}

  void handleVariablePattern(covariant _VariablePattern node,
      {required Type matchedType, required Type staticType}) {
    _irBuilder.atom(node.variable?.name ?? '_', Kind.variable,
        location: node.location);
    _irBuilder.atom(matchedType.type, Kind.type, location: node.location);
    _irBuilder.atom(staticType.type, Kind.type, location: node.location);
    _irBuilder.apply(
        'varPattern', [Kind.variable, Kind.type, Kind.type], Kind.pattern,
        names: ['matchedType', 'staticType'], location: node.location);
    var expectInferredType = node.expectInferredType;
    if (expectInferredType != null) {
      expect(staticType.type, expectInferredType);
    }
  }

  @override
  bool isRestPatternElement(Node element) {
    return element is _RestPatternElement;
  }

  @override
  bool isSwitchExhaustive(
      covariant _SwitchStatement node, Type expressionType) {
    return node.isExhaustive;
  }

  @override
  bool isVariableFinal(Var node) {
    return node.isFinal;
  }

  @override
  bool isVariablePattern(Node pattern) => pattern is _VariablePattern;

  Type leastUpperBound(Type t1, Type t2) => _harness._operations._lub(t1, t2);

  @override
  Type listType(Type elementType) => PrimaryType('List', args: [elementType]);

  _PropertyElement lookupInterfaceMember(
      Node node, Type receiverType, String memberName) {
    return _harness.getMember(receiverType, memberName);
  }

  @override
  Type mapType({
    required Type keyType,
    required Type valueType,
  }) {
    return PrimaryType('Map', args: [keyType, valueType]);
  }

  @override
  RecordType recordType(
      {required List<Type> positional,
      required List<shared.NamedType<Type>> named}) {
    return RecordType(
      positional: positional,
      named: named.map((e) => NamedType(e.name, e.type)).toList(),
    );
  }

  @override
  Type resolveObjectPatternPropertyGet({
    required Type receiverType,
    required shared.RecordPatternField<Node, Pattern> field,
  }) {
    return _harness.getMember(receiverType, field.name!)._type;
  }

  @override
  void setVariableType(Var variable, Type type) {
    variable.type = type;
  }

  @override
  String toString() => _irBuilder.toString();

  @override
  Type variableTypeFromInitializerType(Type type) {
    // Variables whose initializer has type `Null` receive the inferred type
    // `dynamic`.
    if (_harness._operations.classifyType(type) ==
        TypeClassification.nullOrEquivalent) {
      type = dynamicType;
    }
    // Variables whose initializer type includes a promoted type variable
    // receive the nearest supertype that could be expressed in Dart source code
    // (e.g. `T&int` is demoted to `T`).
    // TODO(paulberry): add language tests to verify that the behavior of
    // `type.recursivelyDemote` matches what the analyzer and CFE do.
    return type.recursivelyDemote(covariant: true) ?? type;
  }

  _PropertyElement _lookupMember(
      Expression node, Type receiverType, String memberName) {
    return lookupInterfaceMember(node, receiverType, memberName);
  }

  void _visitLoopBody(Statement loop, Statement body) {
    var previousBreakTarget = _currentBreakTarget;
    var previousContinueTarget = _currentContinueTarget;
    _currentBreakTarget = loop;
    _currentContinueTarget = loop;
    dispatchStatement(body);
    _currentBreakTarget = previousBreakTarget;
    _currentContinueTarget = previousContinueTarget;
  }
}

class _NonNullAssert extends Expression {
  final Expression operand;

  _NonNullAssert(this.operand, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    operand.preVisit(visitor);
  }

  @override
  String toString() => '$operand!';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    return h.typeAnalyzer.analyzeNonNullAssert(this, operand);
  }
}

class _Not extends Expression {
  final Expression operand;

  _Not(this.operand, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    operand.preVisit(visitor);
  }

  @override
  String toString() => '!$operand';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    return h.typeAnalyzer.analyzeLogicalNot(this, operand);
  }
}

class _NullAwareAccess extends Expression {
  static String _fakeMethodName = 'm';

  final Expression lhs;
  final Expression rhs;
  final bool isCascaded;

  _NullAwareAccess(this.lhs, this.rhs, this.isCascaded,
      {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    lhs.preVisit(visitor);
    rhs.preVisit(visitor);
  }

  @override
  String toString() => '$lhs?.${isCascaded ? '.' : ''}($rhs)';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var lhsType =
        h.typeAnalyzer.analyzeExpression(lhs, h.typeAnalyzer.unknownType);
    h.flow.nullAwareAccess_rightBegin(isCascaded ? null : lhs, lhsType);
    var rhsType =
        h.typeAnalyzer.analyzeExpression(rhs, h.typeAnalyzer.unknownType);
    h.flow.nullAwareAccess_end();
    var type = h._operations._lub(rhsType, Type('Null'));
    h.irBuilder.apply(
        _fakeMethodName, [Kind.expression, Kind.expression], Kind.expression,
        location: location);
    return new SimpleTypeAnalysisResult<Type>(type: type);
  }
}

class _NullCheckOrAssertPattern extends Pattern {
  final Pattern _inner;

  final bool _isAssert;

  _NullCheckOrAssertPattern(this._inner, this._isAssert,
      {required super.location})
      : super._();

  @override
  Type computeSchema(Harness h) => h.typeAnalyzer
      .analyzeNullCheckOrAssertPatternSchema(_inner, isAssert: _isAssert);

  @override
  void preVisit(PreVisitor visitor, VariableBinder<Node, Var> variableBinder) {
    _inner.preVisit(visitor, variableBinder);
  }

  @override
  void visit(
    Harness h,
    Type matchedType,
    SharedMatchContext context,
  ) {
    h.typeAnalyzer.analyzeNullCheckOrAssertPattern(
        matchedType, context, this, _inner,
        isAssert: _isAssert);
    h.irBuilder.atom(matchedType.type, Kind.type, location: location);
    h.irBuilder.apply(_isAssert ? 'nullAssertPattern' : 'nullCheckPattern',
        [Kind.pattern, Kind.type], Kind.pattern,
        names: ['matchedType'], location: location);
  }

  @override
  String _debugString({required bool needsKeywordOrType}) =>
      '${_inner._debugString(needsKeywordOrType: needsKeywordOrType)}?';
}

class _NullLiteral extends Expression {
  _NullLiteral({required super.location});

  @override
  void preVisit(PreVisitor visitor) {}

  @override
  String toString() => 'null';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var result = h.typeAnalyzer.analyzeNullLiteral(this);
    h.irBuilder.atom('null', Kind.expression, location: location);
    return result;
  }
}

class _ObjectPattern extends Pattern {
  final PrimaryType requiredType;
  final List<RecordPatternField> fields;

  _ObjectPattern({
    required this.requiredType,
    required this.fields,
    required super.location,
  }) : super._();

  @override
  Type computeSchema(Harness h) {
    return h.typeAnalyzer.analyzeObjectPatternSchema(requiredType);
  }

  @override
  void preVisit(
    PreVisitor visitor,
    VariableBinder<Node, Var> variableBinder,
  ) {
    for (var field in fields) {
      field.pattern.preVisit(visitor, variableBinder);
    }
  }

  @override
  void visit(
    Harness h,
    Type matchedType,
    SharedMatchContext context,
  ) {
    var requiredType = h.typeAnalyzer
        .analyzeObjectPattern(matchedType, context, this, fields: fields);
    h.irBuilder.atom(matchedType.type, Kind.type, location: location);
    h.irBuilder.atom(requiredType.type, Kind.type, location: location);
    h.irBuilder.apply(
      'objectPattern',
      [...List.filled(fields.length, Kind.pattern), Kind.type, Kind.type],
      Kind.pattern,
      names: ['matchedType', 'requiredType'],
      location: location,
    );
  }

  @override
  String _debugString({required bool needsKeywordOrType}) {
    var fieldStrings = [
      for (var field in fields)
        field.pattern._debugString(needsKeywordOrType: needsKeywordOrType)
    ];
    final requiredType = this.requiredType;
    return '$requiredType(${fieldStrings.join(', ')})';
  }
}

class _ParenthesizedExpression extends Expression {
  final Expression expr;

  _ParenthesizedExpression(this.expr, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    expr.preVisit(visitor);
  }

  @override
  String toString() => '($expr)';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    return h.typeAnalyzer.analyzeParenthesizedExpression(this, expr, context);
  }
}

class _PlaceholderExpression extends Expression {
  final Type type;

  _PlaceholderExpression(this.type, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {}

  @override
  String toString() => '(expr with type $type)';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    h.irBuilder.atom(type.type, Kind.type, location: location);
    h.irBuilder.apply('expr', [Kind.type], Kind.expression, location: location);
    return new SimpleTypeAnalysisResult<Type>(type: type);
  }
}

class _Property extends PromotableLValue {
  final Expression target;

  final String propertyName;

  _Property(this.target, this.propertyName, {required super.location})
      : super._();

  @override
  void preVisit(PreVisitor visitor,
      {_LValueDisposition disposition = _LValueDisposition.read}) {
    target.preVisit(visitor);
  }

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    return h.typeAnalyzer.analyzePropertyGet(this, target, propertyName);
  }

  @override
  Type? _getPromotedType(Harness h) {
    var receiverType =
        h.typeAnalyzer.analyzeExpression(target, h.typeAnalyzer.unknownType);
    var member = h.typeAnalyzer._lookupMember(this, receiverType, propertyName);
    return h.flow
        .promotedPropertyType(target, propertyName, member, member._type);
  }

  @override
  void _visitWrite(Harness h, Expression assignmentExpression, Type writtenType,
      Expression? rhs) {
    // No flow analysis impact
  }
}

/// Mini-ast representation of a class property.  Instances of this class are
/// used to represent class members in the flow analysis `promotableFields` set.
class _PropertyElement {
  /// The type of the property.
  final Type _type;

  _PropertyElement(this._type);
}

class _RecordPattern extends Pattern {
  final List<RecordPatternField> fields;

  _RecordPattern(this.fields, {required super.location}) : super._();

  @override
  Type computeSchema(Harness h) {
    return h.typeAnalyzer.analyzeRecordPatternSchema(
      fields: fields,
    );
  }

  @override
  void preVisit(
    PreVisitor visitor,
    VariableBinder<Node, Var> variableBinder,
  ) {
    for (var field in fields) {
      field.pattern.preVisit(visitor, variableBinder);
    }
  }

  @override
  void visit(
    Harness h,
    Type matchedType,
    SharedMatchContext context,
  ) {
    var requiredType = h.typeAnalyzer
        .analyzeRecordPattern(matchedType, context, this, fields: fields);
    h.irBuilder.atom(matchedType.type, Kind.type, location: location);
    h.irBuilder.atom(requiredType.type, Kind.type, location: location);
    h.irBuilder.apply(
      'recordPattern',
      [...List.filled(fields.length, Kind.pattern), Kind.type, Kind.type],
      Kind.pattern,
      names: ['matchedType', 'requiredType'],
      location: location,
    );
  }

  @override
  String _debugString({required bool needsKeywordOrType}) {
    var fieldStrings = [
      for (var field in fields)
        field.pattern._debugString(needsKeywordOrType: needsKeywordOrType)
    ];
    return '(${fieldStrings.join(', ')})';
  }
}

class _RelationalPattern extends Pattern {
  final RelationalOperatorResolution<Type>? operator;
  final Expression operand;

  _RelationalPattern(this.operator, this.operand, {required super.location})
      : super._();

  @override
  Type computeSchema(Harness h) =>
      h.typeAnalyzer.analyzeRelationalPatternSchema();

  @override
  void preVisit(PreVisitor visitor, VariableBinder<Node, Var> variableBinder) {
    operand.preVisit(visitor);
  }

  @override
  void visit(
    Harness h,
    Type matchedType,
    SharedMatchContext context,
  ) {
    h.typeAnalyzer.analyzeRelationalPattern(
        matchedType, context, this, operator, operand);
    h.irBuilder.atom(matchedType.type, Kind.type, location: location);
    h.irBuilder.apply(
        'relationalPattern', [Kind.expression, Kind.type], Kind.pattern,
        names: ['matchedType'], location: location);
  }

  @override
  _debugString({required bool needsKeywordOrType}) => '$operator $operand';
}

class _RestPatternElement extends Node
    implements ListPatternElement, MapPatternElement {
  final Pattern? _pattern;

  _RestPatternElement(this._pattern, {required super.location}) : super._();

  @override
  void preVisit(PreVisitor visitor, VariableBinder<Node, Var> variableBinder) {
    _pattern?.preVisit(visitor, variableBinder);
  }

  @override
  String _debugString({required bool needsKeywordOrType}) {
    var pattern = _pattern;
    if (pattern == null) {
      return '...';
    } else {
      return '...${pattern._debugString(needsKeywordOrType: false)}';
    }
  }
}

class _Return extends Statement {
  _Return({required super.location});

  @override
  void preVisit(PreVisitor visitor) {}

  @override
  String toString() => 'return;';

  @override
  void visit(Harness h) {
    h.typeAnalyzer.analyzeReturnStatement();
    h.irBuilder.apply('return', [], Kind.statement, location: location);
  }
}

class _SwitchExpression extends Expression {
  final Expression scrutinee;

  final List<ExpressionCase> cases;

  _SwitchExpression(this.scrutinee, this.cases, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    scrutinee.preVisit(visitor);
    for (var case_ in cases) {
      case_._preVisit(visitor);
    }
  }

  @override
  String toString() {
    String body;
    if (cases.isEmpty) {
      body = '{}';
    } else {
      var contents = cases.join(' ');
      body = '{ $contents }';
    }
    return 'switch ($scrutinee) $body';
  }

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var result = h.typeAnalyzer
        .analyzeSwitchExpression(this, scrutinee, cases.length, context);
    h.irBuilder.apply(
        'switchExpr',
        [Kind.expression, ...List.filled(cases.length, Kind.expressionCase)],
        Kind.expression,
        location: location);
    return result;
  }
}

class _SwitchHeadCase extends SwitchHead {
  final GuardedPattern guardedPattern;

  _SwitchHeadCase._(this.guardedPattern, {required super.location}) : super._();
}

class _SwitchHeadDefault extends SwitchHead {
  _SwitchHeadDefault({required super.location}) : super._();
}

class _SwitchStatement extends Statement {
  final Expression scrutinee;

  final List<_SwitchStatementMember> cases;

  final bool isExhaustive;

  final bool? expectHasDefault;

  final bool? expectIsExhaustive;

  final bool? expectLastCaseTerminates;

  final String? expectScrutineeType;

  _SwitchStatement(this.scrutinee, this.cases, this.isExhaustive,
      {required super.location,
      required this.expectHasDefault,
      required this.expectIsExhaustive,
      required this.expectLastCaseTerminates,
      required this.expectScrutineeType});

  @override
  void preVisit(PreVisitor visitor) {
    scrutinee.preVisit(visitor);
    visitor._assignedVariables.beginNode();
    for (var case_ in cases) {
      case_._preVisit(visitor);
    }
    visitor._assignedVariables.endNode(this);
  }

  @override
  String toString() {
    var exhaustiveness = isExhaustive ? 'exhaustive' : 'non-exhaustive';
    String body;
    if (cases.isEmpty) {
      body = '{}';
    } else {
      var contents = cases.join(' ');
      body = '{ $contents }';
    }
    return 'switch<$exhaustiveness> ($scrutinee) $body';
  }

  @override
  void visit(Harness h) {
    var previousBreakTarget = h.typeAnalyzer._currentBreakTarget;
    h.typeAnalyzer._currentBreakTarget = this;
    var previousContinueTarget = h.typeAnalyzer._currentContinueTarget;
    h.typeAnalyzer._currentContinueTarget = this;
    var analysisResult =
        h.typeAnalyzer.analyzeSwitchStatement(this, scrutinee, cases.length);
    expect(analysisResult.hasDefault, expectHasDefault ?? anything);
    expect(analysisResult.isExhaustive, expectIsExhaustive ?? anything);
    expect(analysisResult.lastCaseTerminates,
        expectLastCaseTerminates ?? anything);
    expect(analysisResult.scrutineeType.type, expectScrutineeType ?? anything);
    h.irBuilder.apply(
      'switch',
      [
        Kind.expression,
        ...List.filled(cases.length, Kind.statementCase),
      ],
      Kind.statement,
      location: location,
    );
    h.typeAnalyzer._currentBreakTarget = previousBreakTarget;
    h.typeAnalyzer._currentContinueTarget = previousContinueTarget;
  }
}

/// Representation of a single case clause in a switch statement.  Use [case_]
/// to create instances of this class.
class _SwitchStatementMember extends Node {
  final bool hasLabels;
  final List<SwitchHead> elements;
  final _Block _body;

  /// These variables are set during pre-visit, and some of them are joins of
  /// pattern variable declarations. We don't know their types until we do
  /// type analysis. So, some of these variables might become unavailable.
  late final Map<String, Var> _candidateVariables;

  _SwitchStatementMember._(
    this.elements,
    this._body, {
    required super.location,
    required this.hasLabels,
  }) : super._();

  void _preVisit(PreVisitor visitor) {
    var variableBinder = _VariableBinder(errors: visitor.errors);
    variableBinder.switchStatementSharedCaseScopeStart(this);
    for (SwitchHead element in elements) {
      if (element is _SwitchHeadCase) {
        variableBinder.casePatternStart();
        element.guardedPattern.pattern.preVisit(visitor, variableBinder);
        element.guardedPattern.guard?.preVisit(visitor);
        element.guardedPattern.variables = variableBinder.casePatternFinish(
          sharedCaseScopeKey: this,
        );
      } else {
        variableBinder.switchStatementSharedCaseScopeEmpty(this);
      }
    }
    if (hasLabels) {
      variableBinder.switchStatementSharedCaseScopeEmpty(this);
    }
    _candidateVariables =
        variableBinder.switchStatementSharedCaseScopeFinish(this);
    _body.preVisit(visitor);
  }
}

class _This extends Expression {
  _This({required super.location});

  @override
  void preVisit(PreVisitor visitor) {}

  @override
  String toString() => 'this';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var result = h.typeAnalyzer.analyzeThis(this);
    h.irBuilder.atom('this', Kind.expression, location: location);
    return result;
  }
}

class _ThisOrSuperProperty extends PromotableLValue {
  final String propertyName;

  _ThisOrSuperProperty(this.propertyName, {required super.location})
      : super._();

  @override
  void preVisit(PreVisitor visitor,
      {_LValueDisposition disposition = _LValueDisposition.read}) {}

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var result = h.typeAnalyzer.analyzeThisPropertyGet(this, propertyName);
    h.irBuilder.atom('this.$propertyName', Kind.expression, location: location);
    return result;
  }

  @override
  Type? _getPromotedType(Harness h) {
    h.irBuilder.atom('this.$propertyName', Kind.expression, location: location);
    var member = h.typeAnalyzer._lookupMember(this, h._thisType!, propertyName);
    return h.flow
        .promotedPropertyType(null, propertyName, member, member._type);
  }

  @override
  void _visitWrite(Harness h, Expression assignmentExpression, Type writtenType,
      Expression? rhs) {
    // No flow analysis impact
  }
}

class _Throw extends Expression {
  final Expression operand;

  _Throw(this.operand, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    operand.preVisit(visitor);
  }

  @override
  String toString() => 'throw ...';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    return h.typeAnalyzer.analyzeThrow(this, operand);
  }
}

class _TryStatement extends TryStatement {
  final Statement _body;
  final List<_CatchClause> _catches;
  final Statement? _finally;

  _TryStatement(this._body, this._catches, this._finally,
      {required super.location})
      : super._();

  @override
  TryStatement catch_(
      {Var? exception, Var? stackTrace, required List<Statement> body}) {
    assert(_finally == null, 'catch after finally');
    return _TryStatement(
        _body,
        [
          ..._catches,
          _CatchClause(
              _Block(body, location: computeLocation()), exception, stackTrace)
        ],
        null,
        location: location);
  }

  @override
  Statement finally_(List<Statement> statements) {
    assert(_finally == null, 'multiple finally clauses');
    return _TryStatement(
        _body, _catches, _Block(statements, location: computeLocation()),
        location: location);
  }

  @override
  void preVisit(PreVisitor visitor) {
    if (_finally != null) {
      visitor._assignedVariables.beginNode();
    }
    if (_catches.isNotEmpty) {
      visitor._assignedVariables.beginNode();
    }
    _body.preVisit(visitor);
    visitor._assignedVariables.endNode(_body);
    for (var catch_ in _catches) {
      catch_._preVisit(visitor);
    }
    if (_finally != null) {
      if (_catches.isNotEmpty) {
        visitor._assignedVariables.endNode(this);
      }
      _finally!.preVisit(visitor);
    }
  }

  @override
  void visit(Harness h) {
    h.typeAnalyzer.analyzeTryStatement(this, _body, _catches, _finally);
    h.irBuilder.apply(
        'try',
        [
          Kind.statement,
          ...List.filled(_catches.length, Kind.statement),
          Kind.statement
        ],
        Kind.statement,
        location: location);
  }
}

class _VariableBinder extends VariableBinder<Node, Var> {
  _VariableBinder({
    required super.errors,
  });

  @override
  Var joinPatternVariables({
    required Object? key,
    required List<Var> components,
    required bool isConsistent,
  }) {
    return PatternVariableJoin(
      components.first.name,
      components: [
        for (var variable in components)
          if (key is _LogicalPattern && variable is PatternVariableJoin)
            ...variable.components
          else
            variable
      ],
      isConsistent: isConsistent && components.every((e) => e.isConsistent),
    );
  }
}

class _VariablePattern extends Pattern {
  final Type? declaredType;

  final Var? variable;

  final String? expectInferredType;

  _VariablePattern(this.declaredType, this.variable, this.expectInferredType,
      {required super.location})
      : super._();

  @override
  Type computeSchema(Harness h) =>
      h.typeAnalyzer.analyzeVariablePatternSchema(declaredType);

  @override
  void preVisit(PreVisitor visitor, VariableBinder<Node, Var> variableBinder) {
    var variable = this.variable;
    if (variable != null && variableBinder.add(variable.name, variable)) {
      visitor._assignedVariables.declare(variable);
    }
  }

  @override
  void visit(
    Harness h,
    Type matchedType,
    SharedMatchContext context,
  ) {
    var staticType = h.typeAnalyzer.analyzeVariablePattern(
        matchedType, context, this, variable, variable?.name, declaredType);
    h.typeAnalyzer.handleVariablePattern(this,
        matchedType: matchedType, staticType: staticType);
  }

  @override
  _debugString({required bool needsKeywordOrType}) => [
        if (declaredType != null)
          declaredType!.type
        else if (needsKeywordOrType)
          'var',
        variable?.name ?? '_',
        if (expectInferredType != null) '(expected type $expectInferredType)'
      ].join(' ');
}

class _VariableReference extends LValue {
  final Var variable;

  final void Function(Type?)? callback;

  _VariableReference(this.variable, this.callback, {required super.location})
      : super._();

  @override
  void preVisit(PreVisitor visitor,
      {_LValueDisposition disposition = _LValueDisposition.read}) {
    if (disposition != _LValueDisposition.write) {
      visitor._assignedVariables.read(variable);
    }
    if (disposition != _LValueDisposition.read) {
      visitor._assignedVariables.write(variable);
    }
  }

  @override
  String toString() => variable.name;

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var result = h.typeAnalyzer.analyzeVariableGet(this, variable, callback);
    h.irBuilder.atom(variable.name, Kind.expression, location: location);
    return result;
  }

  @override
  void _visitWrite(Harness h, Expression assignmentExpression, Type writtenType,
      Expression? rhs) {
    h.flow.write(assignmentExpression, variable, writtenType, rhs);
  }
}

class _While extends Statement {
  final Expression condition;
  final Statement body;

  _While(this.condition, this.body, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    visitor._assignedVariables.beginNode();
    condition.preVisit(visitor);
    body.preVisit(visitor);
    visitor._assignedVariables.endNode(this);
  }

  @override
  String toString() => 'while ($condition) $body';

  @override
  void visit(Harness h) {
    h.typeAnalyzer.analyzeWhileLoop(this, condition, body);
    h.irBuilder.apply(
        'while', [Kind.expression, Kind.statement], Kind.statement,
        location: location);
  }
}

class _WrappedExpression extends Expression {
  final Statement? before;
  final Expression expr;
  final Statement? after;

  _WrappedExpression(this.before, this.expr, this.after,
      {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    before?.preVisit(visitor);
    expr.preVisit(visitor);
    after?.preVisit(visitor);
  }

  @override
  String toString() {
    var s = StringBuffer('(');
    if (before != null) {
      s.write('($before) ');
    }
    s.write(expr);
    if (after != null) {
      s.write(' ($after)');
    }
    s.write(')');
    return s.toString();
  }

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    late MiniIrTmp beforeTmp;
    if (before != null) {
      h.typeAnalyzer.dispatchStatement(before!);
      h.irBuilder
          .apply('expr', [Kind.statement], Kind.expression, location: location);
      beforeTmp = h.irBuilder.allocateTmp();
    }
    var type =
        h.typeAnalyzer.analyzeExpression(expr, h.typeAnalyzer.unknownType);
    if (after != null) {
      var exprTmp = h.irBuilder.allocateTmp();
      h.typeAnalyzer.dispatchStatement(after!);
      h.irBuilder
          .apply('expr', [Kind.statement], Kind.expression, location: location);
      var afterTmp = h.irBuilder.allocateTmp();
      h.irBuilder.readTmp(exprTmp, location: location);
      h.irBuilder.let(afterTmp, location: location);
      h.irBuilder.let(exprTmp, location: location);
    }
    h.flow.forwardExpression(this, expr);
    if (before != null) {
      h.irBuilder.let(beforeTmp, location: location);
    }
    return new SimpleTypeAnalysisResult<Type>(type: type);
  }
}

class _Write extends Expression {
  final LValue lhs;
  final Expression? rhs;

  _Write(this.lhs, this.rhs, {required super.location});

  @override
  void preVisit(PreVisitor visitor) {
    lhs.preVisit(visitor,
        disposition: rhs == null
            ? _LValueDisposition.readWrite
            : _LValueDisposition.write);
    rhs?.preVisit(visitor);
  }

  @override
  String toString() => '$lhs = $rhs';

  @override
  ExpressionTypeAnalysisResult<Type> visit(Harness h, Type context) {
    var rhs = this.rhs;
    Type type;
    if (rhs == null) {
      // We are simulating an increment/decrement operation.
      // TODO(paulberry): Make a separate node type for this.
      type = h.typeAnalyzer.analyzeExpression(lhs, h.typeAnalyzer.unknownType);
    } else {
      type = h.typeAnalyzer.analyzeExpression(rhs, h.typeAnalyzer.unknownType);
    }
    lhs._visitWrite(h, this, type, rhs);
    // TODO(paulberry): null shorting
    return new SimpleTypeAnalysisResult<Type>(type: type);
  }
}
